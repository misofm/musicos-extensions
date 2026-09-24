// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary and abort-path tests for the kind attribute, deliberately kept in
/// single-transaction `tx_context::dummy()` style: every case here holds its
/// `Release`/`ReleaseAdminCap` pair locally, with no shared object and no
/// ownership handoff between transactions — the property under test is the
/// assertion or authorization check itself (length bounds, event payloads,
/// the cap-mismatch abort), not transaction-boundary mechanics, so scenario
/// machinery would add nothing here. The production shape — a published,
/// shared `Release` operated on by distinct senders via `take_shared`,
/// including the wrong-cap path against the shared object — is covered in
/// `kind_e2e_tests`.
#[test_only]
module release_metadata::kind_tests;

use musicos::release::Release;
use release_metadata::release_metadata as rm;
use release_metadata::test_utils::mk_release;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

// Mirrors `release::EUnauthorized`. A `Release` binds its cap at runtime —
// `uid_mut` calls `authorize`, which asserts `object::id(self) ==
// cap.release_id` — so a foreign cap is testable here.
const EUnauthorized: u64 = 0;

// === Event-only projection ===

fun assert_set_payload(e: &rm::ReleaseKindSetEvent, release_id: address, kind: vector<u8>) {
    let (actual_release_id, actual_kind) = rm::kind_set_event_fields(e);
    assert_eq!(actual_release_id, release_id);
    assert_eq!(*actual_kind.as_bytes(), kind);
}

fun assert_set_bcs(e: &rm::ReleaseKindSetEvent, release_id: address, kind: vector<u8>) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_vec_u8(), kind);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_cleared_bcs(e: &rm::ReleaseKindClearedEvent, release_id: address) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), release_id);
    assert!(bytes.into_remainder_bytes().is_empty());
}

/// Replays only the decoded event bytes into a tiny projection. The
/// projection intentionally does not read the dynamic field; the final
/// assertions compare its state with the permissionless views.
fun project_set_event(
    projected_exists: &mut bool,
    projected_kind: &mut vector<u8>,
    e: &rm::ReleaseKindSetEvent,
) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    let _release_id = bytes.peel_address();
    let kind = bytes.peel_vec_u8();
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_exists = true;
    *projected_kind = kind;
}

fun project_cleared_event(
    projected_exists: &mut bool,
    projected_kind: &mut vector<u8>,
    e: &rm::ReleaseKindClearedEvent,
) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    let _release_id = bytes.peel_address();
    assert!(bytes.into_remainder_bytes().is_empty());
    // A cleared event is only ever emitted for an attached field.
    assert!(*projected_exists);
    *projected_exists = false;
    *projected_kind = vector[];
}

fun assert_projection_matches_view(
    release: &Release,
    projected_exists: bool,
    projected_kind: vector<u8>,
) {
    assert_eq!(rm::has_kind(release), projected_exists);
    if (projected_exists) {
        assert_eq!(*rm::kind(release).as_bytes(), projected_kind);
    };
}

// === Lifecycle ===

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let mut projected_exists = false;
    let mut projected_kind = vector[];

    assert!(!rm::has_kind(&rel));

    rm::set_kind(&mut rel, &cap, b"Album".to_string());
    assert!(rm::has_kind(&rel));
    assert_eq!(*rm::kind(&rel), b"Album".to_string());
    let set_events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_set_payload(&set_events[0], release_id, b"Album");
    project_set_event(&mut projected_exists, &mut projected_kind, &set_events[0]);
    assert_projection_matches_view(&rel, projected_exists, projected_kind);

    // A release may change its mind about what it is.
    rm::set_kind(&mut rel, &cap, b"Extended Play".to_string());
    assert_eq!(*rm::kind(&rel), b"Extended Play".to_string());
    let set_events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_set_payload(&set_events[1], release_id, b"Extended Play");
    project_set_event(&mut projected_exists, &mut projected_kind, &set_events[1]);
    assert_projection_matches_view(&rel, projected_exists, projected_kind);

    // Equal replacement is a no-op: no write, no event; the projected state
    // remains identical.
    rm::set_kind(&mut rel, &cap, b"Extended Play".to_string());
    let set_events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_projection_matches_view(&rel, projected_exists, projected_kind);

    rm::clear_kind(&mut rel, &cap);
    assert!(!rm::has_kind(&rel));
    let cleared_events = event::events_by_type<rm::ReleaseKindClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rm::kind_cleared_event_fields(&cleared_events[0]), release_id);
    project_cleared_event(&mut projected_exists, &mut projected_kind, &cleared_events[0]);
    assert_projection_matches_view(&rel, projected_exists, projected_kind);

    // Clear is idempotent.
    rm::clear_kind(&mut rel, &cap);
    assert!(!rm::has_kind(&rel));
    assert_eq!(event::events_by_type<rm::ReleaseKindClearedEvent>().length(), 1);
    assert_projection_matches_view(&rel, projected_exists, projected_kind);

    // Removing the field permits a fresh set.
    rm::set_kind(&mut rel, &cap, b"Re-set".to_string());
    let set_events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 3);
    assert_set_payload(&set_events[2], release_id, b"Re-set");
    project_set_event(&mut projected_exists, &mut projected_kind, &set_events[2]);
    assert_projection_matches_view(&rel, projected_exists, projected_kind);
    rm::clear_kind(&mut rel, &cap);
    let cleared_events = event::events_by_type<rm::ReleaseKindClearedEvent>();
    assert_eq!(cleared_events.length(), 2);
    assert_eq!(rm::kind_cleared_event_fields(&cleared_events[1]), release_id);
    project_cleared_event(&mut projected_exists, &mut projected_kind, &cleared_events[1]);
    assert_projection_matches_view(&rel, projected_exists, projected_kind);

    destroy(rel);
    destroy(cap);
}

/// The point of the free string: self-descriptions an enum would have
/// excluded are ordinary, and the protocol accepts all of them.
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
        rm::set_kind(&mut rel, &cap, k.to_string());
        assert_eq!(*rm::kind(&rel), k.to_string());
        destroy(rel);
        destroy(cap);
    });
}

/// Stored exactly as given. Normalising would be the protocol having an
/// opinion after all — so "EP", "ep" and "Extended Play" stay three distinct
/// values, and clients that group by kind must fold case themselves.
#[test]
fun case_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (mut b, b_cap) = mk_release(ctx);

    rm::set_kind(&mut a, &a_cap, b"EP".to_string());
    rm::set_kind(&mut b, &b_cap, b"ep".to_string());

    assert_eq!(*rm::kind(&a), b"EP".to_string());
    assert_eq!(*rm::kind(&b), b"ep".to_string());
    assert!(*rm::kind(&a) != *rm::kind(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// Nothing is derived from the tracklist: a one-track release may call itself
/// an Album, which is exactly the judgment the protocol declines to make.
#[test]
fun kind_is_not_constrained_by_track_count() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    rm::set_kind(&mut rel, &cap, b"Album".to_string());
    assert_eq!(*rm::kind(&rel), b"Album".to_string());

    destroy(rel);
    destroy(cap);
}

#[test]
fun kinds_are_per_release() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rm::set_kind(&mut a, &a_cap, b"Album".to_string());

    assert!(rm::has_kind(&a));
    assert!(!rm::has_kind(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

// === Bounds ===

/// 32 bytes exactly — the inclusive bound. The maximum set event is 32
/// (release id) + 1 (ULEB128 length) + 32 = 65 bytes; a cleared event is
/// always 32.
#[test]
fun exactly_max_length_is_accepted_with_exact_bcs_sizes() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    let first = b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_string();
    let second = b"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB".to_string();
    assert_eq!(first.as_bytes().length(), 32);
    rm::set_kind(&mut rel, &cap, first);
    assert_eq!(rm::kind(&rel).as_bytes().length(), 32);
    rm::set_kind(&mut rel, &cap, second);
    rm::clear_kind(&mut rel, &cap);

    let set_events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_eq!(bcs::to_bytes(&set_events[0]).length(), 65);
    assert_eq!(bcs::to_bytes(&set_events[1]).length(), 65);
    assert_set_bcs(&set_events[0], release_id, b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    assert_set_bcs(&set_events[1], release_id, b"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
    let cleared_events = event::events_by_type<rm::ReleaseKindClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(bcs::to_bytes(&cleared_events[0]).length(), 32);
    assert_cleared_bcs(&cleared_events[0], release_id);

    destroy(rel);
    destroy(cap);
}

// === Events ===

#[test]
fun set_emits_the_kind() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    rm::set_kind(&mut rel, &cap, b"Mixtape".to_string());

    let events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(events.length(), 1);
    assert_set_payload(&events[0], release_id, b"Mixtape");
    assert_set_bcs(&events[0], release_id, b"Mixtape");

    destroy(rel);
    destroy(cap);
}

/// Setting the kind already attached is a no-op: nothing is written and
/// nothing is emitted, so an indexer never sees a transition that did not
/// happen. The record stays attached with its value intact; a different
/// spelling is a different value and still replaces and emits.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    rm::set_kind(&mut rel, &cap, b"EP".to_string());
    assert_eq!(event::num_events(), 1);

    rm::set_kind(&mut rel, &cap, b"EP".to_string());
    assert_eq!(event::num_events(), 1);
    let events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(events.length(), 1);
    assert_set_bcs(&events[0], release_id, b"EP");
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(*rm::kind(&rel), b"EP".to_string());

    rm::set_kind(&mut rel, &cap, b"ep".to_string());
    assert_eq!(event::events_by_type<rm::ReleaseKindSetEvent>().length(), 2);
    assert_eq!(*rm::kind(&rel), b"ep".to_string());

    // Cleared and set again to the same value: absent, so not a no-op.
    rm::clear_kind(&mut rel, &cap);
    assert!(!rm::has_metadata_for_testing(&rel));
    rm::set_kind(&mut rel, &cap, b"ep".to_string());
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(event::events_by_type<rm::ReleaseKindSetEvent>().length(), 3);

    destroy(rel);
    destroy(cap);
}

#[test]
fun verbatim_whitespace_nul_and_multibyte_kinds() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let whitespace_nul = vector[69, 80, 32, 9, 0, 32, 101, 112];
    let multibyte = vector[
        240, 159, 152, 128, 240, 159, 152, 128,
        240, 159, 152, 128, 240, 159, 152, 128,
        240, 159, 152, 128, 240, 159, 152, 128,
        240, 159, 152, 128, 240, 159, 152, 128,
    ];
    assert_eq!(multibyte.length(), 32);

    rm::set_kind(&mut rel, &cap, std::string::utf8(whitespace_nul));
    assert_eq!(rm::kind(&rel).as_bytes().length(), 8);
    rm::set_kind(&mut rel, &cap, std::string::utf8(multibyte));
    assert_eq!(rm::kind(&rel).as_bytes().length(), 32);

    let events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(events.length(), 2);
    assert_set_payload(&events[0], release_id, whitespace_nul);
    assert_set_payload(&events[1], release_id, multibyte);

    destroy(rel);
    destroy(cap);
}

#[test]
fun views_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = mk_release(ctx);
    assert!(!rm::has_kind(&rel));
    assert_eq!(event::events_by_type<rm::ReleaseKindSetEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseKindClearedEvent>().length(), 0);
    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    rm::clear_kind(&mut rel, &cap);
    assert_eq!(event::events_by_type<rm::ReleaseKindClearedEvent>().length(), 0);

    rm::set_kind(&mut rel, &cap, b"EP".to_string());
    rm::clear_kind(&mut rel, &cap);

    let events = event::events_by_type<rm::ReleaseKindClearedEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(rm::kind_cleared_event_fields(&events[0]), release_id);
    assert_cleared_bcs(&events[0], release_id);

    destroy(rel);
    destroy(cap);
}

// === Aborts ===

#[test, expected_failure(abort_code = rm::ENoKind)]
fun kind_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = mk_release(ctx);
    let _ = rm::kind(&rel);
    destroy(rel);
    destroy(cap);
}

/// Saying nothing is done by not attaching, not by attaching emptiness.
#[test, expected_failure(abort_code = rm::EEmptyKind)]
fun empty_kind_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    rm::set_kind(&mut rel, &cap, b"".to_string());
    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rm::EKindTooLong)]
fun over_max_length_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    // 33 bytes — one past the bound.
    rm::set_kind(&mut rel, &cap, b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_string());
    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rm::EEmptyKind)]
fun empty_kind_precedes_foreign_cap_authorization() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rm::set_kind(&mut rel, &other_cap, b"".to_string());
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(abort_code = rm::EKindTooLong)]
fun over_max_kind_precedes_foreign_cap_authorization() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rm::set_kind(&mut rel, &other_cap, b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_string());
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

/// A `Release` binds its cap at runtime, so unlike the recording extensions
/// this gate is testable — and must hold.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun another_releases_cap_is_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rm::set_kind(&mut a, &b_cap, b"Album".to_string());

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// The cap is checked before the stored value is compared, so a foreign cap
/// is rejected even when the value it supplies is the one already attached.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun another_releases_cap_is_rejected_on_equal_set() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rm::set_kind(&mut a, &a_cap, b"Album".to_string());
    rm::set_kind(&mut a, &b_cap, b"Album".to_string());

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}
