// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pure boundary, lifecycle and event-payload tests for the title attribute:
/// string validation (empty, over-length, exactly-at-bound), verbatim storage,
/// per-composition and per-share-type isolation, and event-only projection.
/// None of this touches object ownership — each test builds its own
/// composition and cap in one synthetic transaction and never crosses actors,
/// so `test_scenario` mechanics would add nothing here. The production-shaped
/// flows — a composition genuinely published and shared, written by its admin
/// and read by a stranger across transactions — live in
/// `composition_metadata_e2e_tests`.
#[test_only]
module composition_metadata::composition_metadata_tests;

use composition_metadata::composition_metadata as cm;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::test_helpers::CompositionShare;
use std::string::String;
use std::unit_test::{assert_eq, destroy};
use sui::dynamic_field as df;
use sui::event;

fun mk_composition(
    ctx: &mut TxContext,
): (Composition<CompositionShare>, CompositionAdminCap<CompositionShare>) {
    composition::new_for_testing(1500, ctx)
}

/// An ASCII title of exactly `length` bytes.
fun title_of_length(length: u64): String {
    vector::tabulate!(length, |_| 65u8).to_string()
}

/// The state an indexer can maintain from the event stream alone: absence is
/// `none`, while an attached title is its value.
fun project_storage(comp: &Composition<CompositionShare>): Option<String> {
    if (cm::has_title(comp)) {
        option::some(*cm::title(comp))
    } else {
        option::none()
    }
}

fun assert_projection_matches_storage(
    projection: &Option<String>,
    comp: &Composition<CompositionShare>,
) {
    assert_eq!(*projection, project_storage(comp));
}

/// Apply a set event without reading the object. The event carries no prior
/// snapshot: the value it names simply becomes the projected state.
fun apply_set_event(
    event: &cm::CompositionTitleSetEvent<CompositionShare>,
): Option<String> {
    let (_, title) = cm::set_event_fields(event);
    option::some(title)
}

/// Apply a clear event without reading the object. A clear always removes the
/// projector's currently attached value because absent clears emit nothing.
fun apply_clear_event(
    projection: Option<String>,
    _event: &cm::CompositionTitleClearedEvent<CompositionShare>,
): Option<String> {
    assert!(projection.is_some());
    option::none()
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    assert!(!cm::has_title(&comp));

    cm::set_title(&mut comp, &cap, b"Blue in Green".to_string());
    assert!(cm::has_title(&comp));
    assert_eq!(*cm::title(&comp), b"Blue in Green".to_string());

    // Corrections are the point of a mutable title.
    cm::set_title(&mut comp, &cap, b"Blue In Green".to_string());
    assert_eq!(*cm::title(&comp), b"Blue In Green".to_string());

    cm::clear_title(&mut comp, &cap);
    assert!(!cm::has_title(&comp));

    // Clear is idempotent.
    cm::clear_title(&mut comp, &cap);
    assert!(!cm::has_title(&comp));

    destroy(comp);
    destroy(cap);
}

// === Field lifecycle ===

/// One dynamic field holds the whole record: absent before any write,
/// created by the first write, kept across replacements, and removed by the
/// clear that leaves every attribute unset — so "field absent" and "no
/// metadata" are the same fact, and an authorized clear of nothing never
/// creates it.
#[test]
fun metadata_field_is_created_on_first_write_and_removed_on_last_clear() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    assert!(!cm::has_metadata_for_testing(&comp));
    cm::clear_title(&mut comp, &cap);
    assert!(!cm::has_metadata_for_testing(&comp));

    cm::set_title(&mut comp, &cap, b"Blue in Green".to_string());
    assert!(cm::has_metadata_for_testing(&comp));
    cm::set_title(&mut comp, &cap, b"Blue In Green".to_string());
    assert!(cm::has_metadata_for_testing(&comp));

    cm::clear_title(&mut comp, &cap);
    assert!(!cm::has_metadata_for_testing(&comp));
    assert!(!cm::has_title(&comp));

    // A later write recreates it from scratch.
    cm::set_title(&mut comp, &cap, b"Flamenco Sketches".to_string());
    assert!(cm::has_metadata_for_testing(&comp));
    assert_eq!(*cm::title(&comp), b"Flamenco Sketches".to_string());

    destroy(comp);
    destroy(cap);
}

public struct UnrelatedKey() has copy, drop, store;

/// The record is one field under one key; other extensions' fields on the
/// same composition are untouched by its creation and removal.
#[test]
fun unrelated_dynamic_field_survives_title_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    df::add(comp.uid_mut(&cap), UnrelatedKey(), 77u64);
    cm::set_title(&mut comp, &cap, b"Blue in Green".to_string());
    assert_eq!(*df::borrow(comp.uid(), UnrelatedKey()), 77u64);
    cm::clear_title(&mut comp, &cap);
    assert!(!cm::has_metadata_for_testing(&comp));
    assert_eq!(*df::borrow(comp.uid(), UnrelatedKey()), 77u64);
    let _: u64 = df::remove(comp.uid_mut(&cap), UnrelatedKey());

    destroy(comp);
    destroy(cap);
}

/// Stored exactly as given. Spacing and case are the composition's own, and
/// normalising them would be the protocol editing a name it declines to read.
#[test]
fun title_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    let text = b"  sO whAt  (take 2) ".to_string();
    cm::set_title(&mut comp, &cap, text);
    assert_eq!(*cm::title(&comp), text);

    destroy(comp);
    destroy(cap);
}

/// The bound is on bytes, not characters: a multi-byte title fits fewer
/// characters, which is the correct trade for a storage backstop.
#[test]
fun multibyte_text_is_bounded_by_bytes() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    // "été ✿" — 5 characters, 9 bytes. Accepted, and read back intact.
    let text = b"\xc3\xa9t\xc3\xa9 \xe2\x9c\xbf".to_string();
    assert_eq!(text.as_bytes().length(), 9);
    cm::set_title(&mut comp, &cap, text);
    assert_eq!(*cm::title(&comp), text);

    // 100 three-byte characters are exactly the bound; 101 are over it.
    let ok = vector::tabulate!(100, |_| b"\xe2\x9c\xbf").flatten().to_string();
    assert_eq!(ok.as_bytes().length(), 300);
    cm::set_title(&mut comp, &cap, ok);
    assert_eq!(*cm::title(&comp), ok);

    destroy(comp);
    destroy(cap);
}

#[test]
fun titles_are_per_composition() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_composition(ctx);
    let (b, b_cap) = mk_composition(ctx);

    cm::set_title(&mut a, &a_cap, b"The first one.".to_string());

    assert!(cm::has_title(&a));
    assert!(!cm::has_title(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

public struct OtherShare has copy, drop, store {}

/// The share type is part of the composition's identity and of the event
/// type: two compositions with different share types keep separate state and
/// separate event streams.
#[test]
fun composition_share_types_have_separate_state_and_event_streams() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let (mut other, other_cap) = composition::new_for_testing<OtherShare>(1500, ctx);

    cm::set_title(&mut comp, &cap, b"Ours".to_string());
    cm::set_title(&mut other, &other_cap, b"Theirs".to_string());
    assert_eq!(*cm::title(&comp), b"Ours".to_string());
    assert_eq!(*cm::title(&other), b"Theirs".to_string());
    assert_eq!(event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>().length(), 1);
    assert_eq!(event::events_by_type<cm::CompositionTitleSetEvent<OtherShare>>().length(), 1);

    cm::clear_title(&mut comp, &cap);
    assert_eq!(*cm::title(&other), b"Theirs".to_string());
    assert_eq!(
        event::events_by_type<cm::CompositionTitleClearedEvent<CompositionShare>>().length(),
        1,
    );
    assert!(event::events_by_type<cm::CompositionTitleClearedEvent<OtherShare>>().is_empty());

    destroy(comp); destroy(cap); destroy(other); destroy(other_cap);
}

#[test]
fun exactly_max_length_is_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    // 300 bytes exactly — the inclusive bound.
    let text = title_of_length(300);
    cm::set_title(&mut comp, &cap, text);
    assert_eq!(cm::title(&comp).as_bytes().length(), 300);

    destroy(comp);
    destroy(cap);
}

#[test]
fun set_emits_the_title() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let comp_id = object::id(&comp);

    cm::set_title(&mut comp, &cap, b"Flamenco Sketches".to_string());

    let events = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(events.length(), 1);
    let (id, title) = cm::set_event_fields(&events[0]);
    assert_eq!(id, comp_id.to_address());
    // The whole value, so an indexer never re-reads the object.
    assert_eq!(title, b"Flamenco Sketches".to_string());

    destroy(comp);
    destroy(cap);
}

/// A replacement that changes the value emits it; the indexer's prior state
/// is its own previous projection, so nothing about "before" travels in the
/// event. A replacement that changes nothing is a no-op and emits nothing.
#[test]
fun replacing_emits_the_new_title() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let comp_id = object::id(&comp).to_address();

    cm::set_title(&mut comp, &cap, b"First draft".to_string());
    cm::set_title(&mut comp, &cap, b"Second draft".to_string());
    cm::set_title(&mut comp, &cap, b"Second draft".to_string());

    let events = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(events.length(), 2);
    let (id, first) = cm::set_event_fields(&events[0]);
    assert_eq!(id, comp_id);
    assert_eq!(first, b"First draft".to_string());
    let (id, second) = cm::set_event_fields(&events[1]);
    assert_eq!(id, comp_id);
    assert_eq!(second, b"Second draft".to_string());
    assert_eq!(*cm::title(&comp), b"Second draft".to_string());

    destroy(comp);
    destroy(cap);
}

/// Setting the title to the value already attached is a no-op: nothing is
/// written and nothing is emitted, so an indexer never sees a transition
/// that did not happen. The record stays attached with its value intact.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    cm::set_title(&mut comp, &cap, b"Blue in Green".to_string());
    assert_eq!(event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>().length(), 1);

    cm::set_title(&mut comp, &cap, b"Blue in Green".to_string());
    assert_eq!(event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>().length(), 1);
    assert_eq!(event::num_events(), 1);
    assert!(cm::has_metadata_for_testing(&comp));
    assert_eq!(*cm::title(&comp), b"Blue in Green".to_string());

    destroy(comp);
    destroy(cap);
}

/// A no-op never creates the record: with nothing attached there is nothing
/// to equal, so the first set of any value is a real write and emits.
#[test]
fun first_set_is_never_a_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    assert!(!cm::has_metadata_for_testing(&comp));

    cm::set_title(&mut comp, &cap, b"So What".to_string());
    assert!(cm::has_metadata_for_testing(&comp));
    assert_eq!(event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>().length(), 1);

    // Cleared and set again to the same value: absent again, so not a no-op.
    cm::clear_title(&mut comp, &cap);
    assert!(!cm::has_metadata_for_testing(&comp));
    cm::set_title(&mut comp, &cap, b"So What".to_string());
    assert!(cm::has_metadata_for_testing(&comp));
    assert_eq!(event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>().length(), 2);

    destroy(comp);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let comp_id = object::id(&comp);

    cm::clear_title(&mut comp, &cap);
    assert_eq!(
        event::events_by_type<cm::CompositionTitleClearedEvent<CompositionShare>>().length(),
        0,
    );

    cm::set_title(&mut comp, &cap, b"Working title".to_string());
    cm::clear_title(&mut comp, &cap);

    let events = event::events_by_type<cm::CompositionTitleClearedEvent<CompositionShare>>();
    assert_eq!(events.length(), 1);
    assert_eq!(cm::cleared_event_fields(&events[0]), comp_id.to_address());

    destroy(comp);
    destroy(cap);
}

/// Event payloads are the composition id plus, on set, the exact UTF-8 value
/// written to the dynamic field. Both shapes stay fixed-size at the stated
/// BCS boundaries (ULEB string length included).
#[test]
fun max_payloads_have_exact_bcs_sizes() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let max = title_of_length(300);

    cm::set_title(&mut comp, &cap, max);
    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 1);
    let (_, title) = cm::set_event_fields(&sets[0]);
    assert_eq!(title, max);
    // 32-byte address + 2-byte ULEB length (300) + 300 bytes.
    assert_eq!(sui::bcs::to_bytes(&sets[0]).length(), 334);

    // A different 300-byte value exercises a full-size replacement, which
    // carries no prior snapshot and so has the same size as an initial set.
    let mut different = b"B".to_string();
    different.append(title_of_length(299));
    assert_eq!(different.as_bytes().length(), 300);
    cm::set_title(&mut comp, &cap, different);
    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 2);
    let (_, title) = cm::set_event_fields(&sets[1]);
    assert_eq!(title, different);
    assert_eq!(sui::bcs::to_bytes(&sets[1]).length(), 334);

    cm::clear_title(&mut comp, &cap);
    let clears = event::events_by_type<cm::CompositionTitleClearedEvent<CompositionShare>>();
    assert_eq!(clears.length(), 1);
    // The composition id alone.
    assert_eq!(sui::bcs::to_bytes(&clears[0]).length(), 32);

    destroy(comp);
    destroy(cap);
}

/// Views do not publish events, and an authorized clear of an absent field is
/// a silent no-op. A later clear emits exactly once, after the actual remove.
#[test]
fun views_and_absent_clear_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    let events_before = event::num_events();
    assert!(!cm::has_title(&comp));
    assert_eq!(event::num_events(), events_before);
    cm::clear_title(&mut comp, &cap);
    assert_eq!(event::num_events(), events_before);

    cm::set_title(&mut comp, &cap, b"No event from reading".to_string());
    let events_after_set = event::num_events();
    assert!(cm::has_title(&comp));
    assert_eq!(*cm::title(&comp), b"No event from reading".to_string());
    assert_eq!(event::num_events(), events_after_set);

    cm::clear_title(&mut comp, &cap);
    let events_after_clear = event::num_events();
    cm::clear_title(&mut comp, &cap);
    assert_eq!(event::num_events(), events_after_clear);
    assert_eq!(events_after_clear, events_after_set + 1);

    destroy(comp);
    destroy(cap);
}

/// Every event carries the identity of the composition, so an indexer can
/// replay two independent composition streams without object reads.
#[test]
fun two_compositions_have_independent_event_identity() {
    let ctx = &mut tx_context::dummy();
    let (mut first, first_cap) = mk_composition(ctx);
    let (mut second, second_cap) = mk_composition(ctx);
    let first_id = object::id(&first).to_address();
    let second_id = object::id(&second).to_address();

    cm::set_title(&mut first, &first_cap, b"First".to_string());
    cm::set_title(&mut second, &second_cap, b"Second".to_string());

    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 2);
    let (id, title) = cm::set_event_fields(&sets[0]);
    assert_eq!(id, first_id);
    assert_eq!(title, b"First".to_string());
    let (id, title) = cm::set_event_fields(&sets[1]);
    assert_eq!(id, second_id);
    assert_eq!(title, b"Second".to_string());

    cm::clear_title(&mut second, &second_cap);
    let clears = event::events_by_type<cm::CompositionTitleClearedEvent<CompositionShare>>();
    assert_eq!(clears.length(), 1);
    assert_eq!(cm::cleared_event_fields(&clears[0]), second_id);

    destroy(first); destroy(first_cap); destroy(second); destroy(second_cap);
}

/// The emitted value is byte-for-byte the stored one — spacing, case and
/// multi-byte UTF-8 — with no view or helper in between to normalize it.
#[test]
fun event_replay_preserves_whitespace_case_and_utf8() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let first = b"  MiXeD  spacing  ".to_string();
    let second = b"\xc3\xa9t\xc3\xa9 \xe2\x9c\xbf".to_string();

    cm::set_title(&mut comp, &cap, first);
    cm::set_title(&mut comp, &cap, second);
    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    let (_, after_first) = cm::set_event_fields(&sets[0]);
    let (_, after_second) = cm::set_event_fields(&sets[1]);
    assert_eq!(*after_first.as_bytes(), b"  MiXeD  spacing  ");
    assert_eq!(*after_second.as_bytes(), *second.as_bytes());

    destroy(comp);
    destroy(cap);
}

/// An indexer can replay every successful transition using only the events —
/// initial set, a different replacement, and a clear — and match the stored
/// state after each operation; an equal replacement is not a transition and
/// leaves both the stream and the projection untouched.
#[test]
fun event_only_projector_matches_storage() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let mut projection: Option<String> = option::none();
    assert_projection_matches_storage(&projection, &comp);

    cm::set_title(&mut comp, &cap, b"Initial".to_string());
    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    projection = apply_set_event(&sets[0]);
    assert_projection_matches_storage(&projection, &comp);

    cm::set_title(&mut comp, &cap, b"A different edit".to_string());
    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    projection = apply_set_event(&sets[1]);
    assert_projection_matches_storage(&projection, &comp);

    cm::set_title(&mut comp, &cap, b"A different edit".to_string());
    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 2);
    assert_projection_matches_storage(&projection, &comp);

    cm::clear_title(&mut comp, &cap);
    let clears = event::events_by_type<cm::CompositionTitleClearedEvent<CompositionShare>>();
    projection = apply_clear_event(projection, &clears[0]);
    assert_projection_matches_storage(&projection, &comp);

    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = cm::ENoTitle)]
fun title_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = mk_composition(ctx);
    let _ = cm::title(&comp);
    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = cm::ENoTitle)]
fun cleared_title_aborts_on_read() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    cm::set_title(&mut comp, &cap, b"Gone soon".to_string());
    cm::clear_title(&mut comp, &cap);
    let _ = cm::title(&comp);
    destroy(comp);
    destroy(cap);
}

/// Naming nothing is done by not attaching, not by attaching emptiness.
#[test, expected_failure(abort_code = cm::EEmptyTitle)]
fun empty_title_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    cm::set_title(&mut comp, &cap, b"".to_string());
    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = cm::ETitleTooLong)]
fun over_max_length_aborts_on_add() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    // 301 bytes — one past the bound.
    cm::set_title(&mut comp, &cap, title_of_length(301));
    destroy(comp);
    destroy(cap);
}

/// An empty replacement aborts before touching the stored value.
#[test, expected_failure(abort_code = cm::EEmptyTitle)]
fun empty_title_aborts_on_replace() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    cm::set_title(&mut comp, &cap, b"Short".to_string());
    cm::set_title(&mut comp, &cap, b"".to_string());
    destroy(comp);
    destroy(cap);
}

/// An over-long replacement aborts before touching the stored value.
#[test, expected_failure(abort_code = cm::ETitleTooLong)]
fun over_max_length_aborts_on_replace() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    cm::set_title(&mut comp, &cap, b"Short".to_string());
    cm::set_title(&mut comp, &cap, title_of_length(301));
    destroy(comp);
    destroy(cap);
}
