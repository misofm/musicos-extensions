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

use miso::release::{Self, Release, ReleaseAdminCap};
use miso::test_helpers;
use miso::track;
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

    let events = event::events_by_type<rd::DescriptionSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, description) = rd::set_event_fields(&events[0]);
    assert_eq!(id, rel_id);
    // Fat event: the whole payload, so an indexer never re-reads the object.
    assert_eq!(description, b"Mixed on the same desk as the last one.".to_string());

    destroy(rel);
    destroy(cap);
}

#[test]
fun replacing_emits_the_new_description() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    rd::set_description(&mut rel, &cap, b"First draft.".to_string());
    rd::set_description(&mut rel, &cap, b"Second draft.".to_string());

    let events = event::events_by_type<rd::DescriptionSetEvent>();
    assert_eq!(events.length(), 2);
    let (_, latest) = rd::set_event_fields(&events[1]);
    assert_eq!(latest, b"Second draft.".to_string());

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel);

    rd::clear_description(&mut rel, &cap);
    assert_eq!(event::events_by_type<rd::DescriptionClearedEvent>().length(), 0);

    rd::set_description(&mut rel, &cap, b"Out of print.".to_string());
    rd::clear_description(&mut rel, &cap);

    let events = event::events_by_type<rd::DescriptionClearedEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(rd::cleared_event_release_id(&events[0]), rel_id);

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
