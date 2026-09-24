// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary, lifecycle and event tests for the description extension, in
/// single-transaction `tx_context::dummy()` style: each case holds its own
/// `Release`/`ReleaseAdminCap` pair locally. The production shape — a
/// published, shared `Release` operated on by distinct senders — is covered
/// in `release_description_e2e_tests`.
#[test_only]
module release_description::release_description_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_description::release_description as rd;
use std::string::String;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

/// A one-track release; a description is never derived from the tracklist.
fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let rec_id = test_helpers::fake_id(ctx);
    let target_id = test_helpers::fake_id(ctx);
    release::new_for_testing(vector[track::new_for_testing(rec_id, target_id, 10000u16)], ctx)
}

/// `n` bytes of the given ASCII byte.
fun repeated(byte: u8, n: u64): String {
    vector::tabulate!(n, |_| byte).to_string()
}

/// Asserts the set event's fields and its exact BCS layout:
/// `release_id` (32) then the description as a ULEB128-prefixed byte vector.
fun assert_set_event(
    event: &rd::ReleaseDescriptionSetEvent,
    release_id: address,
    description: &String,
) {
    let (event_release_id, event_description) = rd::description_set_event_fields(event);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_description, *description);

    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_vec_u8(), *description.as_bytes());
    assert!(bytes.into_remainder_bytes().is_empty());
}

/// Asserts the cleared event's field and its exact 32-byte BCS layout.
fun assert_cleared_event(event: &rd::ReleaseDescriptionClearedEvent, release_id: address) {
    assert_eq!(rd::description_cleared_event_fields(event), release_id);

    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), release_id);
    assert!(bytes.into_remainder_bytes().is_empty());
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let first = b"Recorded live in one room.".to_string();
    let second = b"Recorded live in one room, in two days.".to_string();

    assert!(!rd::has_description(&rel));

    rd::set_description(&mut rel, &cap, first);
    assert!(rd::has_description(&rel));
    assert_eq!(*rd::description(&rel), first);
    let set_events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_set_event(&set_events[0], release_id, &first);

    // A release may rewrite what it says about itself.
    rd::set_description(&mut rel, &cap, second);
    assert_eq!(*rd::description(&rel), second);
    let set_events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_set_event(&set_events[1], release_id, &second);

    rd::clear_description(&mut rel, &cap);
    assert!(!rd::has_description(&rel));
    let cleared_events = event::events_by_type<rd::ReleaseDescriptionClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_cleared_event(&cleared_events[0], release_id);

    // Clear is idempotent and silent when nothing is attached.
    rd::clear_description(&mut rel, &cap);
    assert!(!rd::has_description(&rel));
    assert_eq!(event::events_by_type<rd::ReleaseDescriptionClearedEvent>().length(), 1);

    // A fresh set after clearing emits again.
    rd::set_description(&mut rel, &cap, first);
    let set_events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 3);
    assert_set_event(&set_events[2], release_id, &first);

    destroy(rel);
    destroy(cap);
}

/// Stored exactly as given: line breaks, spacing, case and multi-byte UTF-8.
#[test]
fun prose_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let text = b"  Side A was cut first.\n\nSide B came a year later,  \xc3\xa9t\xc3\xa9 \xe2\x9c\xbf.".to_string();

    rd::set_description(&mut rel, &cap, text);
    assert_eq!(*rd::description(&rel), text);
    let set_events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_set_event(&set_events[0], release_id, &text);

    destroy(rel);
    destroy(cap);
}

#[test]
fun descriptions_are_per_release() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (mut b, b_cap) = mk_release(ctx);
    let a_id = object::id(&a).to_address();
    let b_id = object::id(&b).to_address();
    let a_text = b"The first one.".to_string();
    let b_text = b"The second one.".to_string();

    rd::set_description(&mut a, &a_cap, a_text);
    assert!(rd::has_description(&a));
    assert!(!rd::has_description(&b));

    rd::set_description(&mut b, &b_cap, b_text);
    rd::clear_description(&mut a, &a_cap);
    assert!(!rd::has_description(&a));
    assert_eq!(*rd::description(&b), b_text);

    let set_events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_set_event(&set_events[0], a_id, &a_text);
    assert_set_event(&set_events[1], b_id, &b_text);
    let cleared_events = event::events_by_type<rd::ReleaseDescriptionClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_cleared_event(&cleared_events[0], a_id);

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// 8192 bytes is the inclusive bound; the set event is then exactly
/// 32 (release id) + 2 (ULEB128 length) + 8192 = 8226 bytes.
#[test]
fun exactly_max_length_is_accepted_with_exact_bcs_size() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let max = repeated(65, 8192);

    rd::set_description(&mut rel, &cap, max);
    assert_eq!(rd::description(&rel).length(), 8192);
    let set_events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_eq!(bcs::to_bytes(&set_events[0]).length(), 8226);
    assert_set_event(&set_events[0], release_id, &max);

    rd::clear_description(&mut rel, &cap);
    let cleared_events = event::events_by_type<rd::ReleaseDescriptionClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(bcs::to_bytes(&cleared_events[0]).length(), 32);
    assert_cleared_event(&cleared_events[0], release_id);

    destroy(rel);
    destroy(cap);
}

/// The bound is on bytes, not characters: 2048 four-byte characters fill it
/// exactly, while 2049 are rejected.
#[test]
fun bound_is_bytes_not_characters() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let mut text = vector[];
    2048u64.do!(|_| text.append(b"\xf0\x9f\x98\x80"));
    assert_eq!(text.length(), 8192);

    rd::set_description(&mut rel, &cap, text.to_string());
    assert_eq!(rd::description(&rel).length(), 8192);

    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rd::EDescriptionTooLong)]
fun one_multibyte_character_past_the_byte_bound_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let mut text = vector[];
    2049u64.do!(|_| text.append(b"\xf0\x9f\x98\x80"));
    rd::set_description(&mut rel, &cap, text.to_string());
    destroy(rel);
    destroy(cap);
}

/// Setting the value already stored neither writes nor emits.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let text = b"Out of print.".to_string();

    rd::set_description(&mut rel, &cap, text);
    let events_after_first = event::num_events();
    rd::set_description(&mut rel, &cap, text);
    assert_eq!(event::num_events(), events_after_first);

    let set_events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_set_event(&set_events[0], release_id, &text);
    assert_eq!(*rd::description(&rel), text);

    destroy(rel);
    destroy(cap);
}

#[test]
fun views_and_absent_clear_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    let events_before = event::num_events();
    assert!(!rd::has_description(&rel));
    rd::clear_description(&mut rel, &cap);
    assert_eq!(event::num_events(), events_before);

    rd::set_description(&mut rel, &cap, b"No event from reading.".to_string());
    let events_after_set = event::num_events();
    assert!(rd::has_description(&rel));
    assert_eq!(*rd::description(&rel), b"No event from reading.".to_string());
    assert_eq!(event::num_events(), events_after_set);

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

#[test, expected_failure(abort_code = rd::EDescriptionTooLong)]
fun over_max_length_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    // 8193 bytes — one past the bound.
    rd::set_description(&mut rel, &cap, repeated(65, 8193));
    destroy(rel);
    destroy(cap);
}

/// Argument validation precedes cap authorization, so a foreign cap cannot
/// change which validation error a caller observes.
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

#[test, expected_failure(abort_code = rd::EDescriptionTooLong)]
fun max_validation_precedes_wrong_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rd::set_description(&mut rel, &other_cap, repeated(65, 8193));
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun another_releases_cap_is_rejected_on_set() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);
    rd::set_description(&mut a, &b_cap, b"Not yours to write.".to_string());
    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// Clear authorizes before checking existence, so a foreign cap is rejected
/// even when nothing is attached.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun another_releases_cap_is_rejected_on_clear_of_nothing() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);
    rd::clear_description(&mut a, &b_cap);
    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}
