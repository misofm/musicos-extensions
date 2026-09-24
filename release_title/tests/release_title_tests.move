// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary, abort-path and event tests for the title extension, in
/// single-transaction `tx_context::dummy()` style: each case holds its own
/// `Release`/`ReleaseAdminCap` pair locally. The production shape — a
/// published, shared `Release` operated on by distinct senders — is covered
/// in `release_title_e2e_tests`.
#[test_only]
module release_title::release_title_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_title::release_title as rt;
use std::string::String;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

/// A one-track release; a title is never derived from the tracklist.
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
/// `release_id` (32) then the title as a ULEB128-prefixed byte vector.
fun assert_set_event(event: &rt::ReleaseTitleSetEvent, release_id: ID, title: &String) {
    let (event_release_id, event_title) = rt::title_set_event_fields(event);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_title, *title);

    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address().to_id(), release_id);
    assert_eq!(bytes.peel_vec_u8(), *title.as_bytes());
    assert!(bytes.into_remainder_bytes().is_empty());
}

/// Asserts the cleared event's field and its exact 32-byte BCS layout.
fun assert_cleared_event(event: &rt::ReleaseTitleClearedEvent, release_id: ID) {
    assert_eq!(rt::title_cleared_event_fields(event), release_id);

    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address().to_id(), release_id);
    assert!(bytes.into_remainder_bytes().is_empty());
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);
    let first = b"Long Player".to_string();
    let second = b"Long Player (Deluxe Edition)".to_string();

    assert!(!rt::has_title(&rel));

    rt::set_title(&mut rel, &cap, first);
    assert!(rt::has_title(&rel));
    assert_eq!(*rt::title(&rel), first);
    let set_events = event::events_by_type<rt::ReleaseTitleSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_set_event(&set_events[0], release_id, &first);

    // A release may be retitled.
    rt::set_title(&mut rel, &cap, second);
    assert_eq!(*rt::title(&rel), second);
    let set_events = event::events_by_type<rt::ReleaseTitleSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_set_event(&set_events[1], release_id, &second);

    rt::clear_title(&mut rel, &cap);
    assert!(!rt::has_title(&rel));
    let cleared_events = event::events_by_type<rt::ReleaseTitleClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_cleared_event(&cleared_events[0], release_id);

    // Clear is idempotent and silent when nothing is attached.
    rt::clear_title(&mut rel, &cap);
    assert!(!rt::has_title(&rel));
    assert_eq!(event::events_by_type<rt::ReleaseTitleClearedEvent>().length(), 1);

    // A fresh set after clearing emits again.
    rt::set_title(&mut rel, &cap, first);
    let set_events = event::events_by_type<rt::ReleaseTitleSetEvent>();
    assert_eq!(set_events.length(), 3);
    assert_set_event(&set_events[2], release_id, &first);

    destroy(rel);
    destroy(cap);
}

/// Stored exactly as given: case, whitespace, punctuation and multi-byte
/// UTF-8, with no normalisation.
#[test]
fun title_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);
    let text = b"  \xc3\x89t\xc3\xa9 \xe2\x9c\xbf / Side B: \"the  Remixes\"\t".to_string();

    rt::set_title(&mut rel, &cap, text);
    assert_eq!(*rt::title(&rel), text);
    let set_events = event::events_by_type<rt::ReleaseTitleSetEvent>();
    assert_set_event(&set_events[0], release_id, &text);

    destroy(rel);
    destroy(cap);
}

/// "Album" and "album" are two distinct titles.
#[test]
fun case_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (mut b, b_cap) = mk_release(ctx);

    rt::set_title(&mut a, &a_cap, b"Album".to_string());
    rt::set_title(&mut b, &b_cap, b"album".to_string());
    assert!(rt::title(&a) != rt::title(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

#[test]
fun titles_are_per_release() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (mut b, b_cap) = mk_release(ctx);
    let a_id = object::id(&a);
    let b_id = object::id(&b);
    let a_title = b"First".to_string();
    let b_title = b"Second".to_string();

    rt::set_title(&mut a, &a_cap, a_title);
    assert!(rt::has_title(&a));
    assert!(!rt::has_title(&b));

    rt::set_title(&mut b, &b_cap, b_title);
    rt::clear_title(&mut a, &a_cap);
    assert!(!rt::has_title(&a));
    assert_eq!(*rt::title(&b), b_title);

    let set_events = event::events_by_type<rt::ReleaseTitleSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_set_event(&set_events[0], a_id, &a_title);
    assert_set_event(&set_events[1], b_id, &b_title);
    let cleared_events = event::events_by_type<rt::ReleaseTitleClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_cleared_event(&cleared_events[0], a_id);

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// 300 bytes is the inclusive bound; the set event is then exactly
/// 32 (release id) + 2 (ULEB128 length) + 300 = 334 bytes.
#[test]
fun exactly_max_length_is_accepted_with_exact_bcs_size() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);
    let max = repeated(65, 300);

    rt::set_title(&mut rel, &cap, max);
    assert_eq!(rt::title(&rel).length(), 300);
    let set_events = event::events_by_type<rt::ReleaseTitleSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_eq!(bcs::to_bytes(&set_events[0]).length(), 334);
    assert_set_event(&set_events[0], release_id, &max);

    rt::clear_title(&mut rel, &cap);
    let cleared_events = event::events_by_type<rt::ReleaseTitleClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(bcs::to_bytes(&cleared_events[0]).length(), 32);
    assert_cleared_event(&cleared_events[0], release_id);

    destroy(rel);
    destroy(cap);
}

/// The bound is on bytes, not characters: 75 four-byte characters fill it
/// exactly, while 76 are rejected.
#[test]
fun bound_is_bytes_not_characters() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let mut text = vector[];
    75u64.do!(|_| text.append(b"\xf0\x9f\x98\x80"));
    assert_eq!(text.length(), 300);

    rt::set_title(&mut rel, &cap, text.to_string());
    assert_eq!(rt::title(&rel).length(), 300);

    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rt::ETitleTooLong)]
fun one_multibyte_character_past_the_byte_bound_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let mut text = vector[];
    76u64.do!(|_| text.append(b"\xf0\x9f\x98\x80"));
    rt::set_title(&mut rel, &cap, text.to_string());
    destroy(rel);
    destroy(cap);
}

/// Setting the value already stored neither writes nor emits.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);
    let text = b"Long Player".to_string();

    rt::set_title(&mut rel, &cap, text);
    let events_after_first = event::num_events();
    rt::set_title(&mut rel, &cap, text);
    assert_eq!(event::num_events(), events_after_first);

    let set_events = event::events_by_type<rt::ReleaseTitleSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_set_event(&set_events[0], release_id, &text);
    assert_eq!(*rt::title(&rel), text);

    destroy(rel);
    destroy(cap);
}

#[test]
fun views_and_absent_clear_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    let events_before = event::num_events();
    assert!(!rt::has_title(&rel));
    rt::clear_title(&mut rel, &cap);
    assert_eq!(event::num_events(), events_before);

    rt::set_title(&mut rel, &cap, b"No event from reading.".to_string());
    let events_after_set = event::num_events();
    assert!(rt::has_title(&rel));
    assert_eq!(*rt::title(&rel), b"No event from reading.".to_string());
    assert_eq!(event::num_events(), events_after_set);

    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rt::ENoTitle)]
fun title_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = mk_release(ctx);
    let _ = rt::title(&rel);
    destroy(rel);
    destroy(cap);
}

/// Saying nothing is done by not attaching, not by attaching emptiness.
#[test, expected_failure(abort_code = rt::EEmptyTitle)]
fun empty_title_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    rt::set_title(&mut rel, &cap, b"".to_string());
    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rt::ETitleTooLong)]
fun over_max_length_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    // 301 bytes — one past the bound.
    rt::set_title(&mut rel, &cap, repeated(65, 301));
    destroy(rel);
    destroy(cap);
}

/// Argument validation precedes cap authorization, so a foreign cap cannot
/// change which validation error a caller observes.
#[test, expected_failure(abort_code = rt::EEmptyTitle)]
fun empty_validation_precedes_wrong_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rt::set_title(&mut rel, &other_cap, b"".to_string());
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(abort_code = rt::ETitleTooLong)]
fun max_validation_precedes_wrong_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rt::set_title(&mut rel, &other_cap, repeated(65, 301));
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
    rt::set_title(&mut a, &b_cap, b"Not yours to name.".to_string());
    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// Clear authorizes before checking existence, so a foreign cap is rejected
/// even when nothing is attached.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun another_releases_cap_is_rejected_on_clear_of_nothing() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);
    rt::clear_title(&mut a, &b_cap);
    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}
