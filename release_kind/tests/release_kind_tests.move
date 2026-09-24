// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary, abort-path and event tests for the kind extension, in
/// single-transaction `tx_context::dummy()` style: each case holds its own
/// `Release`/`ReleaseAdminCap` pair locally. The production shape — a
/// published, shared `Release` operated on by distinct senders — is covered
/// in `release_kind_e2e_tests`.
#[test_only]
module release_kind::release_kind_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_kind::release_kind as rk;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

/// A one-track release; a kind is never derived from the tracklist.
fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let rec_id = test_helpers::fake_id(ctx);
    let target_id = test_helpers::fake_id(ctx);
    release::new_for_testing(vector[track::new_for_testing(rec_id, target_id, 10000u16)], ctx)
}

/// Asserts the set event's fields and its exact BCS layout:
/// `release_id` (32) then the kind as a ULEB128-prefixed byte vector.
fun assert_set_event(event: &rk::ReleaseKindSetEvent, release_id: address, kind: vector<u8>) {
    let (event_release_id, event_kind) = rk::kind_set_event_fields(event);
    assert_eq!(event_release_id, release_id);
    assert_eq!(*event_kind.as_bytes(), kind);

    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_vec_u8(), kind);
    assert!(bytes.into_remainder_bytes().is_empty());
}

/// Asserts the cleared event's field and its exact 32-byte BCS layout.
fun assert_cleared_event(event: &rk::ReleaseKindClearedEvent, release_id: address) {
    assert_eq!(rk::kind_cleared_event_fields(event), release_id);

    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), release_id);
    assert!(bytes.into_remainder_bytes().is_empty());
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    assert!(!rk::has_kind(&rel));

    rk::set_kind(&mut rel, &cap, b"Album".to_string());
    assert!(rk::has_kind(&rel));
    assert_eq!(*rk::kind(&rel), b"Album".to_string());
    let set_events = event::events_by_type<rk::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_set_event(&set_events[0], release_id, b"Album");

    // A release may change its mind about what it is.
    rk::set_kind(&mut rel, &cap, b"Extended Play".to_string());
    assert_eq!(*rk::kind(&rel), b"Extended Play".to_string());
    let set_events = event::events_by_type<rk::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_set_event(&set_events[1], release_id, b"Extended Play");

    rk::clear_kind(&mut rel, &cap);
    assert!(!rk::has_kind(&rel));
    let cleared_events = event::events_by_type<rk::ReleaseKindClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_cleared_event(&cleared_events[0], release_id);

    // Clear is idempotent and silent when nothing is attached.
    rk::clear_kind(&mut rel, &cap);
    assert!(!rk::has_kind(&rel));
    assert_eq!(event::events_by_type<rk::ReleaseKindClearedEvent>().length(), 1);

    // A fresh set after clearing emits again.
    rk::set_kind(&mut rel, &cap, b"Re-set".to_string());
    let set_events = event::events_by_type<rk::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 3);
    assert_set_event(&set_events[2], release_id, b"Re-set");

    destroy(rel);
    destroy(cap);
}

/// Self-descriptions an enum would have excluded are ordinary here.
#[test]
fun accepts_self_descriptions_no_fixed_vocabulary_would_have() {
    let ctx = &mut tx_context::dummy();
    let kinds = vector[
        b"Album", b"EP", b"Single", b"Compilation",
        b"Mixtape", b"Beat Tape", b"Split", b"Demo",
        b"Album (Deluxe Edition)", b"Bootleg",
    ];
    kinds.do!(|k| {
        let (mut rel, cap) = mk_release(ctx);
        rk::set_kind(&mut rel, &cap, k.to_string());
        assert_eq!(*rk::kind(&rel), k.to_string());
        destroy(rel);
        destroy(cap);
    });
}

/// Stored exactly as given: "EP" and "ep" are two distinct values.
#[test]
fun case_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (mut b, b_cap) = mk_release(ctx);

    rk::set_kind(&mut a, &a_cap, b"EP".to_string());
    rk::set_kind(&mut b, &b_cap, b"ep".to_string());

    assert_eq!(*rk::kind(&a), b"EP".to_string());
    assert_eq!(*rk::kind(&b), b"ep".to_string());
    assert!(rk::kind(&a) != rk::kind(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

#[test]
fun kinds_are_per_release() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (mut b, b_cap) = mk_release(ctx);
    let a_id = object::id(&a).to_address();
    let b_id = object::id(&b).to_address();

    rk::set_kind(&mut a, &a_cap, b"Album".to_string());
    assert!(rk::has_kind(&a));
    assert!(!rk::has_kind(&b));

    rk::set_kind(&mut b, &b_cap, b"EP".to_string());
    rk::clear_kind(&mut a, &a_cap);
    assert!(!rk::has_kind(&a));
    assert_eq!(*rk::kind(&b), b"EP".to_string());

    let set_events = event::events_by_type<rk::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_set_event(&set_events[0], a_id, b"Album");
    assert_set_event(&set_events[1], b_id, b"EP");
    let cleared_events = event::events_by_type<rk::ReleaseKindClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_cleared_event(&cleared_events[0], a_id);

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// 32 bytes is the inclusive bound; the set event is then exactly
/// 32 (release id) + 1 (ULEB128 length) + 32 = 65 bytes.
#[test]
fun exactly_max_length_is_accepted_with_exact_bcs_size() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    let max = b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    assert_eq!(max.length(), 32);
    rk::set_kind(&mut rel, &cap, max.to_string());
    assert_eq!(rk::kind(&rel).length(), 32);

    let set_events = event::events_by_type<rk::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_eq!(bcs::to_bytes(&set_events[0]).length(), 65);
    assert_set_event(&set_events[0], release_id, max);

    rk::clear_kind(&mut rel, &cap);
    let cleared_events = event::events_by_type<rk::ReleaseKindClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(bcs::to_bytes(&cleared_events[0]).length(), 32);
    assert_cleared_event(&cleared_events[0], release_id);

    destroy(rel);
    destroy(cap);
}

/// The bound is on bytes, not characters: eight 4-byte emoji fill it exactly,
/// while a ninth is rejected even though it is only nine characters.
#[test]
fun bound_is_bytes_not_characters() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let emoji = b"\xf0\x9f\x98\x80";
    let mut eight = vector[];
    8u64.do!(|_| eight.append(emoji));
    assert_eq!(eight.length(), 32);

    rk::set_kind(&mut rel, &cap, eight.to_string());
    assert_eq!(rk::kind(&rel).length(), 32);

    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rk::EKindTooLong)]
fun nine_multibyte_characters_exceed_the_byte_bound() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let mut nine = vector[];
    9u64.do!(|_| nine.append(b"\xf0\x9f\x98\x80"));
    assert_eq!(nine.length(), 36);
    rk::set_kind(&mut rel, &cap, nine.to_string());
    destroy(rel);
    destroy(cap);
}

#[test]
fun verbatim_whitespace_and_nul_bytes() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let whitespace_nul = vector[69, 80, 32, 9, 0, 32, 101, 112];

    rk::set_kind(&mut rel, &cap, whitespace_nul.to_string());
    assert_eq!(*rk::kind(&rel).as_bytes(), whitespace_nul);

    let set_events = event::events_by_type<rk::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_set_event(&set_events[0], release_id, whitespace_nul);

    destroy(rel);
    destroy(cap);
}

/// Setting the value already stored neither writes nor emits.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    rk::set_kind(&mut rel, &cap, b"EP".to_string());
    let events_after_first = event::num_events();
    rk::set_kind(&mut rel, &cap, b"EP".to_string());
    assert_eq!(event::num_events(), events_after_first);

    let set_events = event::events_by_type<rk::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_set_event(&set_events[0], release_id, b"EP");
    assert_eq!(*rk::kind(&rel), b"EP".to_string());

    destroy(rel);
    destroy(cap);
}

#[test]
fun views_and_absent_clear_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    let events_before = event::num_events();
    assert!(!rk::has_kind(&rel));
    rk::clear_kind(&mut rel, &cap);
    assert_eq!(event::num_events(), events_before);

    rk::set_kind(&mut rel, &cap, b"EP".to_string());
    let events_after_set = event::num_events();
    assert!(rk::has_kind(&rel));
    assert_eq!(*rk::kind(&rel), b"EP".to_string());
    assert_eq!(event::num_events(), events_after_set);

    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rk::ENoKind)]
fun kind_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = mk_release(ctx);
    let _ = rk::kind(&rel);
    destroy(rel);
    destroy(cap);
}

/// Saying nothing is done by not attaching, not by attaching emptiness.
#[test, expected_failure(abort_code = rk::EEmptyKind)]
fun empty_kind_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    rk::set_kind(&mut rel, &cap, b"".to_string());
    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rk::EKindTooLong)]
fun over_max_length_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    // 33 bytes — one past the bound.
    rk::set_kind(&mut rel, &cap, b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_string());
    destroy(rel);
    destroy(cap);
}

/// Argument validation precedes cap authorization, so a foreign cap cannot
/// change which validation error a caller observes.
#[test, expected_failure(abort_code = rk::EEmptyKind)]
fun empty_kind_precedes_foreign_cap_authorization() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rk::set_kind(&mut rel, &other_cap, b"".to_string());
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(abort_code = rk::EKindTooLong)]
fun over_max_kind_precedes_foreign_cap_authorization() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rk::set_kind(&mut rel, &other_cap, b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_string());
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
    rk::set_kind(&mut a, &b_cap, b"Album".to_string());
    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// Clear authorizes before checking existence, so a foreign cap is rejected
/// even when nothing is attached.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun another_releases_cap_is_rejected_on_clear_of_nothing() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);
    rk::clear_kind(&mut a, &b_cap);
    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}
