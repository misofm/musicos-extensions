// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary, lifecycle and event-payload tests: validation (empty,
/// over-length, exactly at the bound, bytes versus characters), verbatim
/// storage, no-op rules, exact BCS sizes, and per-composition and
/// per-share-type isolation. Each test builds its own composition and cap in
/// one synthetic transaction; the production-shaped flows on a published,
/// shared composition live in `composition_title_e2e_tests`.
#[test_only]
module composition_title::composition_title_tests;

use composition_title::composition_title as ct;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::test_helpers::CompositionShare;
use std::string::String;
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
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

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    assert!(!ct::has_title(&comp));

    ct::set_title(&mut comp, &cap, b"Blue in Green".to_string());
    assert!(ct::has_title(&comp));
    assert_eq!(*ct::title(&comp), b"Blue in Green".to_string());

    // Corrections are the point of a mutable title.
    ct::set_title(&mut comp, &cap, b"Blue In Green".to_string());
    assert_eq!(*ct::title(&comp), b"Blue In Green".to_string());

    ct::clear_title(&mut comp, &cap);
    assert!(!ct::has_title(&comp));

    // Clear is idempotent; a later write starts over.
    ct::clear_title(&mut comp, &cap);
    assert!(!ct::has_title(&comp));
    ct::set_title(&mut comp, &cap, b"Flamenco Sketches".to_string());
    assert_eq!(*ct::title(&comp), b"Flamenco Sketches".to_string());

    destroy(comp);
    destroy(cap);
}

public struct UnrelatedKey() has copy, drop, store;

/// One field under one key; other extensions' fields on the same composition
/// are untouched by its creation and removal.
#[test]
fun unrelated_dynamic_field_survives_title_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    df::add(comp.uid_mut(&cap), UnrelatedKey(), 77u64);
    ct::set_title(&mut comp, &cap, b"Blue in Green".to_string());
    assert_eq!(*df::borrow(comp.uid(), UnrelatedKey()), 77u64);
    ct::clear_title(&mut comp, &cap);
    assert_eq!(*df::borrow(comp.uid(), UnrelatedKey()), 77u64);
    let _: u64 = df::remove(comp.uid_mut(&cap), UnrelatedKey());

    destroy(comp);
    destroy(cap);
}

/// Stored exactly as given: spacing and case are the composition's own.
#[test]
fun title_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    let text = b"  sO whAt  (take 2) ".to_string();
    ct::set_title(&mut comp, &cap, text);
    assert_eq!(*ct::title(&comp), text);

    destroy(comp);
    destroy(cap);
}

#[test]
fun exactly_max_length_is_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    // 300 bytes exactly — the inclusive bound.
    let text = title_of_length(300);
    ct::set_title(&mut comp, &cap, text);
    assert_eq!(ct::title(&comp).as_bytes().length(), 300);

    destroy(comp);
    destroy(cap);
}

/// The bound is on bytes, not characters: 100 three-byte characters are
/// exactly the bound and 101 are over it.
#[test]
fun multibyte_text_is_bounded_by_bytes() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    // "été ✿" — 5 characters, 9 bytes. Accepted, and read back intact.
    let text = b"\xc3\xa9t\xc3\xa9 \xe2\x9c\xbf".to_string();
    assert_eq!(text.as_bytes().length(), 9);
    ct::set_title(&mut comp, &cap, text);
    assert_eq!(*ct::title(&comp), text);

    let ok = vector::tabulate!(100, |_| b"\xe2\x9c\xbf").flatten().to_string();
    assert_eq!(ok.as_bytes().length(), 300);
    ct::set_title(&mut comp, &cap, ok);
    assert_eq!(*ct::title(&comp), ok);

    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = ct::ETitleTooLong)]
fun multibyte_text_over_the_byte_bound_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    // 101 characters, 303 bytes — few characters, too many bytes.
    let over = vector::tabulate!(101, |_| b"\xe2\x9c\xbf").flatten().to_string();
    ct::set_title(&mut comp, &cap, over);
    destroy(comp);
    destroy(cap);
}

#[test]
fun titles_are_per_composition() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_composition(ctx);
    let (mut b, b_cap) = mk_composition(ctx);
    let a_id = object::id(&a);
    let b_id = object::id(&b);

    ct::set_title(&mut a, &a_cap, b"First".to_string());
    assert!(ct::has_title(&a));
    assert!(!ct::has_title(&b));

    ct::set_title(&mut b, &b_cap, b"Second".to_string());
    ct::clear_title(&mut a, &a_cap);
    assert!(!ct::has_title(&a));
    assert_eq!(*ct::title(&b), b"Second".to_string());

    // Every event carries the composition's identity.
    let sets = event::events_by_type<ct::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 2);
    let (id, title) = ct::set_event_fields(&sets[0]);
    assert_eq!(id, a_id);
    assert_eq!(title, b"First".to_string());
    let (id, title) = ct::set_event_fields(&sets[1]);
    assert_eq!(id, b_id);
    assert_eq!(title, b"Second".to_string());
    let clears = event::events_by_type<ct::CompositionTitleClearedEvent<CompositionShare>>();
    assert_eq!(clears.length(), 1);
    assert_eq!(ct::cleared_event_fields(&clears[0]), a_id);

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

public struct OtherShare has copy, drop, store {}

/// The share type is part of the composition's identity and of the event
/// type: different share types keep separate state and event streams.
#[test]
fun composition_share_types_have_separate_state_and_event_streams() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let (mut other, other_cap) = composition::new_for_testing<OtherShare>(1500, ctx);

    ct::set_title(&mut comp, &cap, b"Ours".to_string());
    ct::set_title(&mut other, &other_cap, b"Theirs".to_string());
    assert_eq!(*ct::title(&comp), b"Ours".to_string());
    assert_eq!(*ct::title(&other), b"Theirs".to_string());
    assert_eq!(event::events_by_type<ct::CompositionTitleSetEvent<CompositionShare>>().length(), 1);
    assert_eq!(event::events_by_type<ct::CompositionTitleSetEvent<OtherShare>>().length(), 1);

    ct::clear_title(&mut comp, &cap);
    assert_eq!(*ct::title(&other), b"Theirs".to_string());
    assert_eq!(
        event::events_by_type<ct::CompositionTitleClearedEvent<CompositionShare>>().length(),
        1,
    );
    assert!(event::events_by_type<ct::CompositionTitleClearedEvent<OtherShare>>().is_empty());

    destroy(comp); destroy(cap); destroy(other); destroy(other_cap);
}

/// A first set and a changing replacement each emit the value now attached;
/// an equal replacement is a no-op and emits nothing.
#[test]
fun set_emits_each_transition() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let comp_id = object::id(&comp);

    ct::set_title(&mut comp, &cap, b"First draft".to_string());
    ct::set_title(&mut comp, &cap, b"Second draft".to_string());
    ct::set_title(&mut comp, &cap, b"Second draft".to_string());

    let events = event::events_by_type<ct::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(events.length(), 2);
    assert_eq!(event::num_events(), 2);
    let (id, first) = ct::set_event_fields(&events[0]);
    assert_eq!(id, comp_id);
    assert_eq!(first, b"First draft".to_string());
    let (id, second) = ct::set_event_fields(&events[1]);
    assert_eq!(id, comp_id);
    assert_eq!(second, b"Second draft".to_string());
    assert_eq!(*ct::title(&comp), b"Second draft".to_string());

    destroy(comp);
    destroy(cap);
}

/// Only an attached value can be equalled: a set after a clear of the same
/// value is a real write and emits again.
#[test]
fun first_set_is_never_a_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    ct::set_title(&mut comp, &cap, b"So What".to_string());
    ct::set_title(&mut comp, &cap, b"So What".to_string());
    assert_eq!(event::events_by_type<ct::CompositionTitleSetEvent<CompositionShare>>().length(), 1);

    ct::clear_title(&mut comp, &cap);
    ct::set_title(&mut comp, &cap, b"So What".to_string());
    assert_eq!(event::events_by_type<ct::CompositionTitleSetEvent<CompositionShare>>().length(), 2);

    destroy(comp);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let comp_id = object::id(&comp);

    ct::clear_title(&mut comp, &cap);
    assert_eq!(event::num_events(), 0);

    ct::set_title(&mut comp, &cap, b"Working title".to_string());
    ct::clear_title(&mut comp, &cap);
    ct::clear_title(&mut comp, &cap);

    let events = event::events_by_type<ct::CompositionTitleClearedEvent<CompositionShare>>();
    assert_eq!(events.length(), 1);
    assert_eq!(ct::cleared_event_fields(&events[0]), comp_id);
    assert_eq!(event::num_events(), 2);

    destroy(comp);
    destroy(cap);
}

/// Views do not publish events.
#[test]
fun views_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    assert!(!ct::has_title(&comp));
    assert_eq!(event::num_events(), 0);

    ct::set_title(&mut comp, &cap, b"No event from reading".to_string());
    assert!(ct::has_title(&comp));
    assert_eq!(*ct::title(&comp), b"No event from reading".to_string());
    assert_eq!(event::num_events(), 1);

    destroy(comp);
    destroy(cap);
}

/// Set carries the composition id plus the exact value (32-byte id,
/// ULEB length, bytes); clear carries the id alone.
#[test]
fun payloads_have_exact_bcs_sizes() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);

    ct::set_title(&mut comp, &cap, b"So What".to_string());
    let sets = event::events_by_type<ct::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(to_bytes(&sets[0]).length(), 32 + 1 + 7);

    // A full-size initial set and a full-size replacement are the same shape.
    let max = title_of_length(300);
    ct::set_title(&mut comp, &cap, max);
    let mut different = b"B".to_string();
    different.append(title_of_length(299));
    ct::set_title(&mut comp, &cap, different);
    let sets = event::events_by_type<ct::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 3);
    let (_, title) = ct::set_event_fields(&sets[1]);
    assert_eq!(title, max);
    let (_, title) = ct::set_event_fields(&sets[2]);
    assert_eq!(title, different);
    assert_eq!(to_bytes(&sets[1]).length(), 334);
    assert_eq!(to_bytes(&sets[2]).length(), 334);

    ct::clear_title(&mut comp, &cap);
    let clears = event::events_by_type<ct::CompositionTitleClearedEvent<CompositionShare>>();
    assert_eq!(clears.length(), 1);
    assert_eq!(to_bytes(&clears[0]).length(), 32);

    destroy(comp);
    destroy(cap);
}

/// The emitted value is byte-for-byte the stored one.
#[test]
fun events_preserve_whitespace_case_and_utf8() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let first = b"  MiXeD  spacing  ".to_string();
    let second = b"\xc3\xa9t\xc3\xa9 \xe2\x9c\xbf".to_string();

    ct::set_title(&mut comp, &cap, first);
    ct::set_title(&mut comp, &cap, second);
    let sets = event::events_by_type<ct::CompositionTitleSetEvent<CompositionShare>>();
    let (_, after_first) = ct::set_event_fields(&sets[0]);
    let (_, after_second) = ct::set_event_fields(&sets[1]);
    assert_eq!(*after_first.as_bytes(), b"  MiXeD  spacing  ");
    assert_eq!(*after_second.as_bytes(), *second.as_bytes());

    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = ct::ENoTitle)]
fun title_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = mk_composition(ctx);
    let _ = ct::title(&comp);
    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = ct::ENoTitle)]
fun cleared_title_aborts_on_read() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    ct::set_title(&mut comp, &cap, b"Gone soon".to_string());
    ct::clear_title(&mut comp, &cap);
    let _ = ct::title(&comp);
    destroy(comp);
    destroy(cap);
}

/// Naming nothing is done by not attaching, not by attaching emptiness.
#[test, expected_failure(abort_code = ct::EEmptyTitle)]
fun empty_title_aborts_on_add() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    ct::set_title(&mut comp, &cap, b"".to_string());
    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = ct::EEmptyTitle)]
fun empty_title_aborts_on_replace() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    ct::set_title(&mut comp, &cap, b"Short".to_string());
    ct::set_title(&mut comp, &cap, b"".to_string());
    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = ct::ETitleTooLong)]
fun over_max_length_aborts_on_add() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    // 301 bytes — one past the bound.
    ct::set_title(&mut comp, &cap, title_of_length(301));
    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = ct::ETitleTooLong)]
fun over_max_length_aborts_on_replace() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    ct::set_title(&mut comp, &cap, b"Short".to_string());
    ct::set_title(&mut comp, &cap, title_of_length(301));
    destroy(comp);
    destroy(cap);
}
