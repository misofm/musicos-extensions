// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pure boundary, lifecycle and event-payload tests for the description
/// extension: string validation (empty, over-length, exactly-at-bound),
/// verbatim storage, per-release isolation. None of this touches object
/// ownership — each test builds its own release and cap in one synthetic
/// transaction and never crosses actors, so `test_scenario` mechanics would
/// add nothing here. The one genuinely ownership-shaped case — a foreign cap
/// rejected by a different sender, against a release that is actually
/// published and shared — lives in `release_description_e2e_tests`.
#[test_only]
module release_description::release_description_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_description::release_description as rd;
use std::unit_test::{assert_eq, destroy};
use sui::event;

/// A one-track release. Nothing here reads the tracklist; a description is prose
/// about the release as a whole and is never derived from its contents.
fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let comp_id = test_helpers::fake_id(ctx);
    let rec_id = test_helpers::fake_id(ctx);
    let target_release_id = test_helpers::fake_id(ctx);
    let tracks = vector[track::new_for_testing(comp_id, rec_id, target_release_id, 10000u16)];
    release::new_for_testing(b"Some Record".to_string(), tracks, ctx)
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    assert!(!rd::has_description(&rel));

    rd::set_description(&mut rel, &cap, b"Recorded live in one room.".to_string());
    assert!(rd::has_description(&rel));
    assert_eq!(*rd::description(&rel), b"Recorded live in one room.".to_string());

    // A release may rewrite what it says about itself.
    rd::set_description(&mut rel, &cap, b"Recorded live in one room, in two days.".to_string());
    assert_eq!(*rd::description(&rel), b"Recorded live in one room, in two days.".to_string());

    rd::clear_description(&mut rel, &cap);
    assert!(!rd::has_description(&rel));

    // Clear is idempotent.
    rd::clear_description(&mut rel, &cap);
    assert!(!rd::has_description(&rel));

    destroy(rel);
    destroy(cap);
}

/// Stored exactly as given. Prose carries its own line breaks and spacing, and
/// normalising them would be the protocol editing writing it declines to read.
#[test]
fun prose_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    let text = b"Side A was cut first.\n\nSide B came a year later,  after the tour.".to_string();
    rd::set_description(&mut rel, &cap, text);
    assert_eq!(*rd::description(&rel), text);

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
    rd::set_description(&mut rel, &cap, text);
    assert_eq!(*rd::description(&rel), text);

    destroy(rel);
    destroy(cap);
}

#[test]
fun descriptions_are_per_release() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rd::set_description(&mut a, &a_cap, b"The first one.".to_string());

    assert!(rd::has_description(&a));
    assert!(!rd::has_description(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

#[test]
fun exactly_max_length_is_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    // 8192 bytes exactly — the inclusive bound.
    let text = test_helpers::long_string(8192);
    rd::set_description(&mut rel, &cap, text);
    assert_eq!(rd::description(&rel).as_bytes().length(), 8192);

    destroy(rel);
    destroy(cap);
}

#[test]
fun set_emits_the_description() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel);

    rd::set_description(&mut rel, &cap, b"Mixed on the same desk as the last one.".to_string());

    let events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, cap_id, existed, before, description) = rd::set_event_fields(&events[0]);
    assert_eq!(id, rel_id.to_address());
    assert_eq!(cap_id, object::id(&cap).to_address());
    assert!(!existed);
    assert_eq!(before, vector[]);
    // Fat event: the whole payload, so an indexer never re-reads the object.
    assert_eq!(description, b"Mixed on the same desk as the last one.");

    destroy(rel);
    destroy(cap);
}

#[test]
fun replacing_emits_the_new_description() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    rd::set_description(&mut rel, &cap, b"First draft.".to_string());
    rd::set_description(&mut rel, &cap, b"Second draft.".to_string());

    let events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(events.length(), 2);
    let (_, _, existed, before, latest) = rd::set_event_fields(&events[1]);
    assert!(existed);
    assert_eq!(before, b"First draft.");
    assert_eq!(latest, b"Second draft.");

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel);

    rd::clear_description(&mut rel, &cap);
    assert_eq!(event::events_by_type<rd::ReleaseDescriptionClearedEvent>().length(), 0);

    rd::set_description(&mut rel, &cap, b"Out of print.".to_string());
    rd::clear_description(&mut rel, &cap);

    let events = event::events_by_type<rd::ReleaseDescriptionClearedEvent>();
    assert_eq!(events.length(), 1);
    let (event_id, event_cap_id, before) = rd::clear_event_fields(&events[0]);
    assert_eq!(event_id, rel_id.to_address());
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert_eq!(before, b"Out of print.");

    destroy(rel);
    destroy(cap);
}

/// Event bytes are the exact UTF-8 bytes written to the dynamic field. The
/// initial, replacement, and clear shapes also stay fixed-size at the stated
/// BCS boundaries (ULEB vector lengths included).
#[test]
fun max_payloads_are_raw_and_have_exact_bcs_sizes() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let max = test_helpers::long_string(8192);
    let max_bytes = *max.as_bytes();

    rd::set_description(&mut rel, &cap, max);
    let sets = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(sets.length(), 1);
    let (_, _, existed, before, after) = rd::set_event_fields(&sets[0]);
    assert!(!existed);
    assert_eq!(before, vector[]);
    assert_eq!(after, max_bytes);
    assert_eq!(sui::bcs::to_bytes(&sets[0]).length(), 8260);

    // String is copyable; equal replacement still writes and emits a full
    // before/after snapshot, yielding the two-max-vector payload.
    rd::set_description(&mut rel, &cap, max);
    let sets = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(sets.length(), 2);
    let (_, _, existed, before, after) = rd::set_event_fields(&sets[1]);
    assert!(existed);
    assert_eq!(before, max_bytes);
    assert_eq!(after, max_bytes);
    assert_eq!(sui::bcs::to_bytes(&sets[1]).length(), 16453);

    rd::clear_description(&mut rel, &cap);
    let clears = event::events_by_type<rd::ReleaseDescriptionClearedEvent>();
    assert_eq!(clears.length(), 1);
    let (_, _, before) = rd::clear_event_fields(&clears[0]);
    assert_eq!(before, max_bytes);
    assert_eq!(sui::bcs::to_bytes(&clears[0]).length(), 8258);

    destroy(rel);
    destroy(cap);
}

/// Views do not publish events, and an authorized clear of an absent field is
/// a silent no-op. A later clear emits exactly once, after the actual remove.
#[test]
fun views_and_absent_clear_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    assert!(!rd::has_description(&rel));
    rd::clear_description(&mut rel, &cap);
    assert_eq!(event::events_by_type<rd::ReleaseDescriptionSetEvent>().length(), 0);
    assert_eq!(event::events_by_type<rd::ReleaseDescriptionClearedEvent>().length(), 0);

    rd::set_description(&mut rel, &cap, b"No event from reading.".to_string());
    assert!(rd::has_description(&rel));
    assert_eq!(*rd::description(&rel), b"No event from reading.".to_string());
    assert_eq!(event::events_by_type<rd::ReleaseDescriptionSetEvent>().length(), 1);
    assert_eq!(event::events_by_type<rd::ReleaseDescriptionClearedEvent>().length(), 0);

    rd::clear_description(&mut rel, &cap);
    rd::clear_description(&mut rel, &cap);
    assert_eq!(event::events_by_type<rd::ReleaseDescriptionClearedEvent>().length(), 1);

    destroy(rel);
    destroy(cap);
}

/// Every event carries the identity of the release and the supplied cap, so
/// an indexer can replay two independent release streams without object reads.
#[test]
fun two_releases_have_independent_event_identity() {
    let ctx = &mut tx_context::dummy();
    let (mut first, first_cap) = mk_release(ctx);
    let (mut second, second_cap) = mk_release(ctx);
    let first_id = object::id(&first).to_address();
    let second_id = object::id(&second).to_address();
    let first_cap_id = object::id(&first_cap).to_address();
    let second_cap_id = object::id(&second_cap).to_address();

    rd::set_description(&mut first, &first_cap, b"First release.".to_string());
    rd::set_description(&mut second, &second_cap, b"Second release.".to_string());

    let sets = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(sets.length(), 2);
    let (id, cap_id, had, before, after) = rd::set_event_fields(&sets[0]);
    assert_eq!(id, first_id);
    assert_eq!(cap_id, first_cap_id);
    assert!(!had);
    assert_eq!(before, vector[]);
    assert_eq!(after, b"First release.");
    let (id, cap_id, had, before, after) = rd::set_event_fields(&sets[1]);
    assert_eq!(id, second_id);
    assert_eq!(cap_id, second_cap_id);
    assert!(!had);
    assert_eq!(before, vector[]);
    assert_eq!(after, b"Second release.");

    destroy(first); destroy(first_cap); destroy(second); destroy(second_cap);
}

/// The snapshot remains byte-for-byte faithful for spacing, case, line
/// breaks, and multi-byte UTF-8; no view/helper is used to normalize it.
#[test]
fun event_replay_preserves_whitespace_case_and_utf8() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let first = b"  MiXeD\n\n spacing  ".to_string();
    let second = b"\xc3\xa9t\xc3\xa9 \xe2\x9c\xbf".to_string();

    rd::set_description(&mut rel, &cap, first);
    rd::set_description(&mut rel, &cap, second);
    let sets = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    let (_, _, _, _, after_first) = rd::set_event_fields(&sets[0]);
    let (_, _, _, before_second, after_second) = rd::set_event_fields(&sets[1]);
    assert_eq!(after_first, b"  MiXeD\n\n spacing  ");
    assert_eq!(before_second, b"  MiXeD\n\n spacing  ");
    assert_eq!(after_second, *second.as_bytes());

    rd::clear_description(&mut rel, &cap);
    let clears = event::events_by_type<rd::ReleaseDescriptionClearedEvent>();
    let (_, _, before_clear) = rd::clear_event_fields(&clears[0]);
    assert_eq!(before_clear, *second.as_bytes());

    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rd::ENoDescription)]
fun description_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = mk_release(ctx);
    let _ = rd::description(&rel);
    destroy(rel);
    destroy(cap);
}

/// Saying nothing is done by not attaching, not by attaching emptiness.
#[test, expected_failure(abort_code = rd::EEmptyDescription)]
fun empty_description_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    rd::set_description(&mut rel, &cap, b"".to_string());
    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rd::EMaxDescriptionLengthExceeded)]
fun over_max_length_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    // 8193 bytes — one past the bound.
    rd::set_description(&mut rel, &cap, test_helpers::long_string(8193));
    destroy(rel);
    destroy(cap);
}

/// Both validation guards precede the release's cap authorization. A foreign
/// cap therefore cannot change which validation error a caller observes.
#[test, expected_failure(abort_code = rd::EEmptyDescription)]
fun empty_validation_precedes_wrong_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rd::set_description(&mut rel, &other_cap, b"".to_string());
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(abort_code = rd::EMaxDescriptionLengthExceeded)]
fun max_validation_precedes_wrong_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rd::set_description(&mut rel, &other_cap, test_helpers::long_string(8193));
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}
