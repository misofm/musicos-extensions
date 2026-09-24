// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pure boundary, lifecycle and event-payload tests for the description
/// attribute: string validation (empty, over-length, exactly-at-bound),
/// verbatim storage, per-release isolation. None of this touches object
/// ownership — each test builds its own release and cap in one synthetic
/// transaction and never crosses actors, so `test_scenario` mechanics would
/// add nothing here. The genuinely ownership-shaped cases — a foreign cap
/// rejected by a different sender, against a release that is actually
/// published and shared — live in `description_e2e_tests`.
#[test_only]
module release_metadata::description_tests;

use musicos::release::Release;
use release_metadata::release_metadata as rm;
use release_metadata::test_utils::{mk_release, long_string};
use std::option::{Self, Option};
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

// Mirrors `release::EUnauthorized`. A `Release` binds its cap at runtime —
// `uid_mut` calls `authorize`, which asserts `object::id(self) ==
// cap.release_id` — so a foreign cap is testable here.
const EUnauthorized: u64 = 0;

// === Event-only projection ===

/// The state an indexer can maintain from the event stream alone: absence is
/// `none`, while an attached description is its raw UTF-8 byte vector.
fun project_storage(rel: &Release): Option<vector<u8>> {
    if (rm::has_description(rel)) {
        option::some(*rm::description(rel).as_bytes())
    } else {
        option::none()
    }
}

fun assert_projection_matches_storage(projection: &Option<vector<u8>>, rel: &Release) {
    let stored = project_storage(rel);
    assert_eq!(projection.is_some(), stored.is_some());
    if (projection.is_some()) {
        assert_eq!(*projection.borrow(), *stored.borrow());
    };
}

/// Apply a set event without reading the object: the new bytes become the
/// projected state, whatever was there before.
fun apply_set_event(e: &rm::ReleaseDescriptionSetEvent): Option<vector<u8>> {
    let (_, after) = rm::description_set_event_fields(e);
    option::some(*after.as_bytes())
}

/// Apply a clear event without reading the object. A clear always removes the
/// projector's currently attached value because absent clears emit nothing.
fun apply_cleared_event(projection: Option<vector<u8>>): Option<vector<u8>> {
    assert!(projection.is_some());
    option::none()
}

fun assert_set_bcs(e: &rm::ReleaseDescriptionSetEvent, release_id: address, description: vector<u8>) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_vec_u8(), description);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_cleared_bcs(e: &rm::ReleaseDescriptionClearedEvent, release_id: address) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), release_id);
    assert!(bytes.into_remainder_bytes().is_empty());
}

// === Lifecycle ===

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    assert!(!rm::has_description(&rel));

    rm::set_description(&mut rel, &cap, b"Recorded live in one room.".to_string());
    assert!(rm::has_description(&rel));
    assert_eq!(*rm::description(&rel), b"Recorded live in one room.".to_string());

    // A release may rewrite what it says about itself.
    rm::set_description(&mut rel, &cap, b"Recorded live in one room, in two days.".to_string());
    assert_eq!(*rm::description(&rel), b"Recorded live in one room, in two days.".to_string());

    rm::clear_description(&mut rel, &cap);
    assert!(!rm::has_description(&rel));

    // Clear is idempotent.
    rm::clear_description(&mut rel, &cap);
    assert!(!rm::has_description(&rel));

    destroy(rel);
    destroy(cap);
}

/// Stored exactly as given. Prose carries its own line breaks and spacing,
/// and normalising them would be the protocol editing writing it declines to
/// read.
#[test]
fun prose_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    let text = b"Side A was cut first.\n\nSide B came a year later,  after the tour.".to_string();
    rm::set_description(&mut rel, &cap, text);
    assert_eq!(*rm::description(&rel), text);

    destroy(rel);
    destroy(cap);
}

/// The bound is on bytes, not characters: a multi-byte description fits fewer
/// characters, which is the correct trade for a storage backstop.
#[test]
fun multibyte_text_is_bounded_by_bytes() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    // "été ✿" — 5 characters, 9 bytes. Accepted, and read back intact.
    let text = b"\xc3\xa9t\xc3\xa9 \xe2\x9c\xbf".to_string();
    assert_eq!(text.as_bytes().length(), 9);
    rm::set_description(&mut rel, &cap, text);
    assert_eq!(*rm::description(&rel), text);

    destroy(rel);
    destroy(cap);
}

#[test]
fun descriptions_are_per_release() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rm::set_description(&mut a, &a_cap, b"The first one.".to_string());

    assert!(rm::has_description(&a));
    assert!(!rm::has_description(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

// === Bounds ===

#[test]
fun exactly_max_length_is_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    // 8192 bytes exactly — the inclusive bound.
    let text = long_string(8192);
    rm::set_description(&mut rel, &cap, text);
    assert_eq!(rm::description(&rel).as_bytes().length(), 8192);

    destroy(rel);
    destroy(cap);
}

/// Event bytes are the exact UTF-8 bytes written to the dynamic field. The
/// set shape at the bound is 32 (release id) + 2 (ULEB128 length of 8192) +
/// 8192 = 8226 bytes, whether initial or different replacement; an equal
/// replacement at the bound emits nothing; the clear shape is always 32.
#[test]
fun max_payloads_are_raw_and_have_exact_bcs_sizes() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let max = long_string(8192);
    let max_bytes = *max.as_bytes();

    rm::set_description(&mut rel, &cap, max);
    let sets = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(sets.length(), 1);
    assert_set_bcs(&sets[0], release_id, max_bytes);
    assert_eq!(bcs::to_bytes(&sets[0]).length(), 8226);

    // A different 8192-byte value exercises replacement at the bound, rather
    // than only repeating the same max string.
    let mut different = b"B".to_string();
    different.append(long_string(8191));
    let different_bytes = *different.as_bytes();
    assert_eq!(different_bytes.length(), 8192);
    rm::set_description(&mut rel, &cap, different);
    let sets = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(sets.length(), 2);
    assert_set_bcs(&sets[1], release_id, different_bytes);
    assert_eq!(bcs::to_bytes(&sets[1]).length(), 8226);

    // String is copyable; an equal replacement at the bound is a no-op.
    rm::set_description(&mut rel, &cap, different);
    let sets = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(sets.length(), 2);
    assert_eq!(*rm::description(&rel).as_bytes(), different_bytes);

    rm::clear_description(&mut rel, &cap);
    let clears = event::events_by_type<rm::ReleaseDescriptionClearedEvent>();
    assert_eq!(clears.length(), 1);
    assert_cleared_bcs(&clears[0], release_id);
    assert_eq!(bcs::to_bytes(&clears[0]).length(), 32);

    destroy(rel);
    destroy(cap);
}

// === Events ===

#[test]
fun set_emits_the_description() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    rm::set_description(&mut rel, &cap, b"Mixed on the same desk as the last one.".to_string());

    let events = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, description) = rm::description_set_event_fields(&events[0]);
    assert_eq!(id, release_id);
    // The whole value, so an indexer never re-reads the object for it.
    assert_eq!(description, b"Mixed on the same desk as the last one.".to_string());
    assert_set_bcs(&events[0], release_id, b"Mixed on the same desk as the last one.");

    destroy(rel);
    destroy(cap);
}

/// Setting the description already attached is a no-op: nothing is written
/// and nothing is emitted. The record stays attached with its value intact.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    rm::set_description(&mut rel, &cap, b"Recorded live, one take.".to_string());
    assert_eq!(event::num_events(), 1);

    rm::set_description(&mut rel, &cap, b"Recorded live, one take.".to_string());
    assert_eq!(event::num_events(), 1);
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(*rm::description(&rel), b"Recorded live, one take.".to_string());

    // Cleared and set again to the same value: absent, so not a no-op.
    rm::clear_description(&mut rel, &cap);
    assert!(!rm::has_metadata_for_testing(&rel));
    rm::set_description(&mut rel, &cap, b"Recorded live, one take.".to_string());
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(event::events_by_type<rm::ReleaseDescriptionSetEvent>().length(), 2);

    destroy(rel);
    destroy(cap);
}

#[test]
fun replacing_emits_the_new_description() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    rm::set_description(&mut rel, &cap, b"First draft.".to_string());
    rm::set_description(&mut rel, &cap, b"Second draft.".to_string());

    let events = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(events.length(), 2);
    let (_, first) = rm::description_set_event_fields(&events[0]);
    let (_, latest) = rm::description_set_event_fields(&events[1]);
    assert_eq!(first, b"First draft.".to_string());
    assert_eq!(latest, b"Second draft.".to_string());

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    rm::clear_description(&mut rel, &cap);
    assert_eq!(event::events_by_type<rm::ReleaseDescriptionClearedEvent>().length(), 0);

    rm::set_description(&mut rel, &cap, b"Out of print.".to_string());
    rm::clear_description(&mut rel, &cap);

    let events = event::events_by_type<rm::ReleaseDescriptionClearedEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(rm::description_cleared_event_fields(&events[0]), release_id);
    assert_cleared_bcs(&events[0], release_id);

    destroy(rel);
    destroy(cap);
}

/// Views do not publish events, and an authorized clear of an absent field is
/// a silent no-op. A later clear emits exactly once, after the actual remove.
#[test]
fun views_and_absent_clear_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    let events_before = event::num_events();
    assert!(!rm::has_description(&rel));
    assert_eq!(event::num_events(), events_before);
    rm::clear_description(&mut rel, &cap);
    assert_eq!(event::num_events(), events_before);

    rm::set_description(&mut rel, &cap, b"No event from reading.".to_string());
    let events_after_set = event::num_events();
    assert!(rm::has_description(&rel));
    assert_eq!(*rm::description(&rel), b"No event from reading.".to_string());
    assert_eq!(event::num_events(), events_after_set);

    rm::clear_description(&mut rel, &cap);
    let events_after_clear = event::num_events();
    rm::clear_description(&mut rel, &cap);
    assert_eq!(event::num_events(), events_after_clear);
    assert_eq!(events_after_clear, events_after_set + 1);

    destroy(rel);
    destroy(cap);
}

/// Every event carries the identity of its release, so an indexer can replay
/// two independent release streams without object reads.
#[test]
fun two_releases_have_independent_event_identity() {
    let ctx = &mut tx_context::dummy();
    let (mut first, first_cap) = mk_release(ctx);
    let (mut second, second_cap) = mk_release(ctx);
    let first_id = object::id(&first).to_address();
    let second_id = object::id(&second).to_address();

    rm::set_description(&mut first, &first_cap, b"First release.".to_string());
    rm::set_description(&mut second, &second_cap, b"Second release.".to_string());

    let sets = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(sets.length(), 2);
    let (id, after) = rm::description_set_event_fields(&sets[0]);
    assert_eq!(id, first_id);
    assert_eq!(after, b"First release.".to_string());
    let (id, after) = rm::description_set_event_fields(&sets[1]);
    assert_eq!(id, second_id);
    assert_eq!(after, b"Second release.".to_string());

    destroy(first); destroy(first_cap); destroy(second); destroy(second_cap);
}

/// The event bytes remain byte-for-byte faithful for spacing, case, line
/// breaks, and multi-byte UTF-8; no view/helper is used to normalize them.
#[test]
fun event_replay_preserves_whitespace_case_and_utf8() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let first = b"  MiXeD\n\n spacing  ".to_string();
    let second = b"\xc3\xa9t\xc3\xa9 \xe2\x9c\xbf".to_string();

    rm::set_description(&mut rel, &cap, first);
    rm::set_description(&mut rel, &cap, second);
    let sets = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    let (_, after_first) = rm::description_set_event_fields(&sets[0]);
    let (_, after_second) = rm::description_set_event_fields(&sets[1]);
    assert_eq!(after_first, b"  MiXeD\n\n spacing  ".to_string());
    assert_eq!(after_second, second);

    destroy(rel);
    destroy(cap);
}

/// An indexer can replay every successful transition using only the events,
/// including a different replacement, and match the stored state after each
/// operation; an equal replacement is not a transition and leaves both the
/// stream and the projection untouched.
#[test]
fun event_only_optional_projector_matches_storage() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    rm::set_description(&mut rel, &cap, b"Initial words.".to_string());
    let sets = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    let mut projection = apply_set_event(&sets[0]);
    assert_projection_matches_storage(&projection, &rel);

    rm::set_description(&mut rel, &cap, b"A different edit.".to_string());
    let sets = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    projection = apply_set_event(&sets[1]);
    assert_projection_matches_storage(&projection, &rel);

    rm::set_description(&mut rel, &cap, b"A different edit.".to_string());
    let sets = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(sets.length(), 2);
    assert_projection_matches_storage(&projection, &rel);

    rm::clear_description(&mut rel, &cap);
    let clears = event::events_by_type<rm::ReleaseDescriptionClearedEvent>();
    assert_eq!(clears.length(), 1);
    projection = apply_cleared_event(projection);
    assert_projection_matches_storage(&projection, &rel);

    destroy(rel);
    destroy(cap);
}

// === Aborts ===

#[test, expected_failure(abort_code = rm::ENoDescription)]
fun description_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = mk_release(ctx);
    let _ = rm::description(&rel);
    destroy(rel);
    destroy(cap);
}

/// Saying nothing is done by not attaching, not by attaching emptiness.
#[test, expected_failure(abort_code = rm::EEmptyDescription)]
fun empty_description_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    rm::set_description(&mut rel, &cap, b"".to_string());
    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rm::EDescriptionTooLong)]
fun over_max_length_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    // 8193 bytes — one past the bound.
    rm::set_description(&mut rel, &cap, long_string(8193));
    destroy(rel);
    destroy(cap);
}

/// Both validation guards precede the release's cap authorization. A foreign
/// cap therefore cannot change which validation error a caller observes.
#[test, expected_failure(abort_code = rm::EEmptyDescription)]
fun empty_validation_precedes_wrong_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rm::set_description(&mut rel, &other_cap, b"".to_string());
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(abort_code = rm::EDescriptionTooLong)]
fun max_validation_precedes_wrong_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rm::set_description(&mut rel, &other_cap, long_string(8193));
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

/// The cap is checked before the stored value is compared, so a foreign cap
/// is rejected even when the value it supplies is the one already attached.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun another_releases_cap_is_rejected_on_equal_set() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rm::set_description(&mut rel, &rel_cap, b"Mine.".to_string());
    rm::set_description(&mut rel, &other_cap, b"Mine.".to_string());
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}
