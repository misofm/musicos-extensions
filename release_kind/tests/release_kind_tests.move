// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary and abort-path tests for the kind extension, deliberately kept in
/// single-transaction `tx_context::dummy()` style: every case here holds its
/// `Release`/`ReleaseAdminCap` pair locally, with no shared object and no
/// ownership handoff between transactions — the property under test is the
/// assertion or authorization check itself (length bounds, event payloads,
/// the cap-mismatch abort), not transaction-boundary mechanics, so scenario
/// machinery would add nothing here. The production shape — a published,
/// shared `Release` operated on by distinct senders via `take_shared`,
/// including the wrong-cap path against the shared object — is covered in
/// `release_kind_e2e_tests`.
#[test_only]
module release_kind::release_kind_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_kind::release_kind as rk;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

// Mirrors `release::EUnauthorized` (release.move:110). Unlike `Recording`, a
// `Release` binds its cap at runtime — `uid_mut` calls `authorize`, which asserts
// `object::id(self) == cap.release_id` — so a foreign cap is testable here.
const EUnauthorized: u64 = 0;

/// A one-track release. Nothing here reads the tracklist; a kind is a claim about
/// the release as a whole, and is deliberately not derived from track count.
fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let comp_id = test_helpers::fake_id(ctx);
    let rec_id = test_helpers::fake_id(ctx);
    let target_id = test_helpers::fake_id(ctx);
    let tracks = vector[track::new_for_testing(comp_id, rec_id, target_id, 10000u16)];
    release::new_for_testing(b"Some Record".to_string(), tracks, ctx)
}

fun assert_set_payload(
    event: &rk::KindSetEvent,
    release_id: address,
    release_admin_cap_id: address,
    kind_record_existed_before: bool,
    previous_kind: vector<u8>,
    previous_kind_length: u64,
    kind: vector<u8>,
    kind_length: u64,
    kind_record_exists_after: bool,
    kind_changed: bool,
) {
    let (
        actual_release_id,
        actual_release_admin_cap_id,
        actual_kind_record_existed_before,
        actual_previous_kind,
        actual_previous_kind_length,
        actual_kind,
        actual_kind_length,
        actual_kind_record_exists_after,
        actual_kind_changed,
    ) = rk::set_event_payload(event);
    assert_eq!(actual_release_id, release_id);
    assert_eq!(actual_release_admin_cap_id, release_admin_cap_id);
    assert_eq!(actual_kind_record_existed_before, kind_record_existed_before);
    assert_eq!(actual_previous_kind, previous_kind);
    assert_eq!(actual_previous_kind_length, previous_kind_length);
    assert_eq!(actual_kind, kind);
    assert_eq!(actual_kind_length, kind_length);
    assert_eq!(actual_kind_record_exists_after, kind_record_exists_after);
    assert_eq!(actual_kind_changed, kind_changed);
}

fun assert_unset_payload(
    event: &rk::KindUnsetEvent,
    release_id: address,
    release_admin_cap_id: address,
    kind_record_existed_before: bool,
    previous_kind: vector<u8>,
    previous_kind_length: u64,
    kind: vector<u8>,
    kind_length: u64,
    kind_record_exists_after: bool,
    kind_changed: bool,
) {
    let (
        actual_release_id,
        actual_release_admin_cap_id,
        actual_kind_record_existed_before,
        actual_previous_kind,
        actual_previous_kind_length,
        actual_kind,
        actual_kind_length,
        actual_kind_record_exists_after,
        actual_kind_changed,
    ) = rk::unset_event_payload(event);
    assert_eq!(actual_release_id, release_id);
    assert_eq!(actual_release_admin_cap_id, release_admin_cap_id);
    assert_eq!(actual_kind_record_existed_before, kind_record_existed_before);
    assert_eq!(actual_previous_kind, previous_kind);
    assert_eq!(actual_previous_kind_length, previous_kind_length);
    assert_eq!(actual_kind, kind);
    assert_eq!(actual_kind_length, kind_length);
    assert_eq!(actual_kind_record_exists_after, kind_record_exists_after);
    assert_eq!(actual_kind_changed, kind_changed);
}

fun assert_set_bcs(
    event: &rk::KindSetEvent,
    release_id: address,
    release_admin_cap_id: address,
    kind_record_existed_before: bool,
    previous_kind: vector<u8>,
    previous_kind_length: u64,
    kind: vector<u8>,
    kind_length: u64,
    kind_record_exists_after: bool,
    kind_changed: bool,
) {
    let mut bytes = bcs::new(rk::set_event_bcs(event));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_address(), release_admin_cap_id);
    assert_eq!(bytes.peel_bool(), kind_record_existed_before);
    assert_eq!(bytes.peel_vec_u8(), previous_kind);
    assert_eq!(bytes.peel_u64(), previous_kind_length);
    assert_eq!(bytes.peel_vec_u8(), kind);
    assert_eq!(bytes.peel_u64(), kind_length);
    assert_eq!(bytes.peel_bool(), kind_record_exists_after);
    assert_eq!(bytes.peel_bool(), kind_changed);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_unset_bcs(
    event: &rk::KindUnsetEvent,
    release_id: address,
    release_admin_cap_id: address,
    kind_record_existed_before: bool,
    previous_kind: vector<u8>,
    previous_kind_length: u64,
    kind: vector<u8>,
    kind_length: u64,
    kind_record_exists_after: bool,
    kind_changed: bool,
) {
    let mut bytes = bcs::new(rk::unset_event_bcs(event));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_address(), release_admin_cap_id);
    assert_eq!(bytes.peel_bool(), kind_record_existed_before);
    assert_eq!(bytes.peel_vec_u8(), previous_kind);
    assert_eq!(bytes.peel_u64(), previous_kind_length);
    assert_eq!(bytes.peel_vec_u8(), kind);
    assert_eq!(bytes.peel_u64(), kind_length);
    assert_eq!(bytes.peel_bool(), kind_record_exists_after);
    assert_eq!(bytes.peel_bool(), kind_changed);
    assert!(bytes.into_remainder_bytes().is_empty());
}

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let release_admin_cap_id = object::id(&cap).to_address();

    assert!(!rk::has_kind(&rel));

    rk::set_kind(&mut rel, &cap, b"Album".to_string());
    assert!(rk::has_kind(&rel));
    assert_eq!(rk::kind(&rel), b"Album".to_string());
    let set_events = event::events_by_type<rk::KindSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_set_payload(
        &set_events[0], release_id, release_admin_cap_id, false, vector[], 0,
        b"Album", 5, true, true,
    );

    // A release may change its mind about what it is.
    rk::set_kind(&mut rel, &cap, b"Extended Play".to_string());
    assert_eq!(rk::kind(&rel), b"Extended Play".to_string());
    let set_events = event::events_by_type<rk::KindSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_set_payload(
        &set_events[1], release_id, release_admin_cap_id, true, b"Album", 5,
        b"Extended Play", 13, true, true,
    );

    rk::unset_kind(&mut rel, &cap);
    assert!(!rk::has_kind(&rel));
    let unset_events = event::events_by_type<rk::KindUnsetEvent>();
    assert_eq!(unset_events.length(), 1);
    assert_unset_payload(
        &unset_events[0], release_id, release_admin_cap_id, true,
        b"Extended Play", 13, vector[], 0, false, true,
    );

    // Unset is idempotent.
    rk::unset_kind(&mut rel, &cap);
    assert!(!rk::has_kind(&rel));
    assert_eq!(event::events_by_type<rk::KindUnsetEvent>().length(), 1);

    // Removing the field permits a fresh set with an empty previous snapshot.
    rk::set_kind(&mut rel, &cap, b"Re-set".to_string());
    let set_events = event::events_by_type<rk::KindSetEvent>();
    assert_eq!(set_events.length(), 3);
    assert_set_payload(
        &set_events[2], release_id, release_admin_cap_id, false, vector[], 0,
        b"Re-set", 6, true, true,
    );
    rk::unset_kind(&mut rel, &cap);
    let unset_events = event::events_by_type<rk::KindUnsetEvent>();
    assert_eq!(unset_events.length(), 2);
    assert_unset_payload(
        &unset_events[1], release_id, release_admin_cap_id, true,
        b"Re-set", 6, vector[], 0, false, true,
    );

    destroy(rel);
    destroy(cap);
}

/// The point of the free string: self-descriptions an enum would have excluded
/// are ordinary, and the protocol accepts all of them.
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
        assert_eq!(rk::kind(&rel), k.to_string());
        destroy(rel);
        destroy(cap);
    });
}

/// Stored exactly as given. Normalising would be the protocol having an opinion
/// after all — so "EP", "ep" and "Extended Play" stay three distinct values, and
/// clients that group by kind must fold case themselves.
#[test]
fun case_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (mut b, b_cap) = mk_release(ctx);

    rk::set_kind(&mut a, &a_cap, b"EP".to_string());
    rk::set_kind(&mut b, &b_cap, b"ep".to_string());

    assert_eq!(rk::kind(&a), b"EP".to_string());
    assert_eq!(rk::kind(&b), b"ep".to_string());
    assert!(rk::kind(&a) != rk::kind(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// Nothing is derived from the tracklist: a one-track release may call itself an
/// Album, which is exactly the judgment the protocol declines to make.
#[test]
fun kind_is_not_constrained_by_track_count() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    rk::set_kind(&mut rel, &cap, b"Album".to_string());
    assert_eq!(rk::kind(&rel), b"Album".to_string());

    destroy(rel);
    destroy(cap);
}

#[test]
fun kinds_are_per_release() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rk::set_kind(&mut a, &a_cap, b"Album".to_string());

    assert!(rk::has_kind(&a));
    assert!(!rk::has_kind(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

#[test]
fun exactly_max_length_is_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let release_admin_cap_id = object::id(&cap).to_address();

    // 32 bytes exactly — the inclusive bound.
    let first = b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_string();
    let second = b"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB".to_string();
    assert_eq!(first.as_bytes().length(), 32);
    rk::set_kind(&mut rel, &cap, first);
    assert_eq!(rk::kind(&rel).as_bytes().length(), 32);
    rk::set_kind(&mut rel, &cap, second);
    rk::unset_kind(&mut rel, &cap);

    let set_events = event::events_by_type<rk::KindSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_eq!(rk::set_event_bcs(&set_events[0]).length(), 117);
    assert_eq!(rk::set_event_bcs(&set_events[1]).length(), 149);
    assert_set_bcs(
        &set_events[1], release_id, release_admin_cap_id, true,
        b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 32,
        b"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", 32, true, true,
    );
    let unset_events = event::events_by_type<rk::KindUnsetEvent>();
    assert_eq!(unset_events.length(), 1);
    assert_eq!(rk::unset_event_bcs(&unset_events[0]).length(), 117);
    assert_unset_bcs(
        &unset_events[0], release_id, release_admin_cap_id, true,
        b"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", 32, vector[], 0, false, true,
    );

    destroy(rel);
    destroy(cap);
}

#[test]
fun set_emits_the_kind() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel).to_address();
    let cap_id = object::id(&cap).to_address();

    rk::set_kind(&mut rel, &cap, b"Mixtape".to_string());

    let events = event::events_by_type<rk::KindSetEvent>();
    assert_eq!(events.length(), 1);
    assert_set_payload(
        &events[0], rel_id, cap_id, false, vector[], 0,
        b"Mixtape", 7, true, true,
    );
    assert_set_bcs(
        &events[0], rel_id, cap_id, false, vector[], 0,
        b"Mixtape", 7, true, true,
    );

    destroy(rel);
    destroy(cap);
}

#[test]
fun equal_replacement_is_an_assignment_but_not_a_change() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let release_admin_cap_id = object::id(&cap).to_address();

    rk::set_kind(&mut rel, &cap, b"EP".to_string());
    rk::set_kind(&mut rel, &cap, b"EP".to_string());

    let events = event::events_by_type<rk::KindSetEvent>();
    assert_eq!(events.length(), 2);
    assert_set_payload(
        &events[1], release_id, release_admin_cap_id, true,
        b"EP", 2, b"EP", 2, true, false,
    );
    assert_set_bcs(
        &events[1], release_id, release_admin_cap_id, true,
        b"EP", 2, b"EP", 2, true, false,
    );
    assert_eq!(rk::kind(&rel), b"EP".to_string());

    destroy(rel);
    destroy(cap);
}

#[test]
fun verbatim_whitespace_nul_and_multibyte_kinds() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let release_admin_cap_id = object::id(&cap).to_address();
    let whitespace_nul = vector[69, 80, 32, 9, 0, 32, 101, 112];
    let multibyte = vector[
        240, 159, 152, 128, 240, 159, 152, 128,
        240, 159, 152, 128, 240, 159, 152, 128,
        240, 159, 152, 128, 240, 159, 152, 128,
        240, 159, 152, 128, 240, 159, 152, 128,
    ];
    assert_eq!(multibyte.length(), 32);

    rk::set_kind(&mut rel, &cap, std::string::utf8(whitespace_nul));
    let stored = rk::kind(&rel);
    assert_eq!(stored.as_bytes().length(), 8);
    rk::set_kind(&mut rel, &cap, std::string::utf8(multibyte));
    assert_eq!(rk::kind(&rel).as_bytes().length(), 32);

    let events = event::events_by_type<rk::KindSetEvent>();
    assert_eq!(events.length(), 2);
    assert_set_payload(
        &events[1], release_id, release_admin_cap_id, true,
        vector[69, 80, 32, 9, 0, 32, 101, 112], 8,
        vector[
            240, 159, 152, 128, 240, 159, 152, 128,
            240, 159, 152, 128, 240, 159, 152, 128,
            240, 159, 152, 128, 240, 159, 152, 128,
            240, 159, 152, 128, 240, 159, 152, 128,
        ], 32, true, true,
    );

    destroy(rel);
    destroy(cap);
}

#[test]
fun views_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = mk_release(ctx);
    assert!(!rk::has_kind(&rel));
    assert_eq!(event::events_by_type<rk::KindSetEvent>().length(), 0);
    assert_eq!(event::events_by_type<rk::KindUnsetEvent>().length(), 0);
    destroy(rel);
    destroy(cap);
}

#[test]
fun unset_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel).to_address();
    let cap_id = object::id(&cap).to_address();

    rk::unset_kind(&mut rel, &cap);
    assert_eq!(event::events_by_type<rk::KindUnsetEvent>().length(), 0);

    rk::set_kind(&mut rel, &cap, b"EP".to_string());
    rk::unset_kind(&mut rel, &cap);

    let events = event::events_by_type<rk::KindUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_unset_payload(
        &events[0], rel_id, cap_id, true, b"EP", 2, vector[], 0, false, true,
    );
    assert_unset_bcs(
        &events[0], rel_id, cap_id, true, b"EP", 2, vector[], 0, false, true,
    );

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

/// A `Release` binds its cap at runtime, so unlike the recording extensions this
/// gate is testable — and must hold.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun another_releases_cap_is_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rk::set_kind(&mut a, &b_cap, b"Album".to_string());

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}
