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

use miso::release::{Self, Release, ReleaseAdminCap};
use miso::test_helpers;
use miso::track;
use release_kind::release_kind as rk;
use std::unit_test::{assert_eq, destroy};
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

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    assert!(!rk::has_kind(&rel));

    rk::set_kind(&mut rel, &cap, b"Album".to_string());
    assert!(rk::has_kind(&rel));
    assert_eq!(rk::kind(&rel), b"Album".to_string());

    // A release may change its mind about what it is.
    rk::set_kind(&mut rel, &cap, b"Extended Play".to_string());
    assert_eq!(rk::kind(&rel), b"Extended Play".to_string());

    rk::unset_kind(&mut rel, &cap);
    assert!(!rk::has_kind(&rel));

    // Unset is idempotent.
    rk::unset_kind(&mut rel, &cap);
    assert!(!rk::has_kind(&rel));

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

    // 32 bytes exactly — the inclusive bound.
    let k = b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_string();
    assert_eq!(k.as_bytes().length(), 32);
    rk::set_kind(&mut rel, &cap, k);
    assert_eq!(rk::kind(&rel).as_bytes().length(), 32);

    destroy(rel);
    destroy(cap);
}

#[test]
fun set_emits_the_kind() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel);

    rk::set_kind(&mut rel, &cap, b"Mixtape".to_string());

    let events = event::events_by_type<rk::KindSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, kind) = rk::set_event_fields(&events[0]);
    assert_eq!(id, rel_id);
    assert_eq!(kind, b"Mixtape".to_string());

    destroy(rel);
    destroy(cap);
}

#[test]
fun unset_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel);

    rk::unset_kind(&mut rel, &cap);
    assert_eq!(event::events_by_type<rk::KindUnsetEvent>().length(), 0);

    rk::set_kind(&mut rel, &cap, b"EP".to_string());
    rk::unset_kind(&mut rel, &cap);

    let events = event::events_by_type<rk::KindUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(rk::unset_event_release_id(&events[0]), rel_id);

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

/// A `Release` binds its cap at runtime, so unlike the recording extensions this
/// gate is testable — and must hold.
#[test, expected_failure(abort_code = EUnauthorized, location = miso::release)]
fun another_releases_cap_is_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rk::set_kind(&mut a, &b_cap, b"Album".to_string());

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}
