// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for this package's full use case, run under
/// `sui::test_scenario`: the release is published and shared exactly as in
/// production — core's release is atomic (an `Initialized` release cannot
/// outlive its creating transaction; every release that exists on-chain is
/// `Published` and shared, per `miso::release`'s module doc) — and the kind
/// extension operates on it via `take_shared` in later transactions, exactly
/// as client PTBs would.
///
/// Distinct senders: ADMIN holds the release's admin cap and performs the
/// cap-gated writes; STRANGER owns nothing and proves both that reads are
/// permissionless and that a foreign cap is rejected against the *shared*
/// release, not just against a freshly created one.
#[test_only]
module release_kind::release_kind_e2e_tests;

use miso::release::{Self, Release, ReleaseAdminCap};
use miso::test_helpers;
use miso::track;
use release_kind::release_kind as rk;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self, Scenario};

// Mirrors `release::EUnauthorized` (release.move:110) — see the unit test
// module for why a foreign cap is testable at all (a `Release` binds its cap
// at runtime).
const EUnauthorized: u64 = 0;

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

/// A one-track release, created and published in one transaction — exactly
/// as core's atomicity requires — and therefore shared. Returns the admin
/// cap; the release itself becomes a shared object, reachable via
/// `take_shared` from any later transaction.
fun publish_and_share(ts: &mut Scenario): ReleaseAdminCap {
    let comp_id = test_helpers::fake_id(ts.ctx());
    let rec_id = test_helpers::fake_id(ts.ctx());
    let target_id = test_helpers::fake_id(ts.ctx());
    let tracks = vector[track::new_for_testing(comp_id, rec_id, target_id, 10000u16)];
    let (rel, cap) = release::new_for_testing(b"Some Record".to_string(), tracks, ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    rel.publish(&cap, &clock);
    clock.destroy_for_testing();
    cap
}

/// Set → replace → unset against a published, shared release, crossing
/// transaction boundaries with distinct senders: the cap holder writes, a
/// stranger reads (proving reads need no capability), and event payloads are
/// pinned at each write.
#[test]
fun kind_lifecycle_against_a_published_shared_release() {
    let mut ts = test_scenario::begin(ADMIN);

    // --- Tx 1 (ADMIN): create, publish, share ---
    let cap = publish_and_share(&mut ts);

    // --- Tx 2 (ADMIN): set the kind on the now-shared release ---
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    let rel_id = object::id(&rel);
    rk::set_kind(&mut rel, &cap, b"Album".to_string());
    assert!(rk::has_kind(&rel));
    assert_eq!(rk::kind(&rel), b"Album".to_string());

    let set_events = event::events_by_type<rk::KindSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_kind) = rk::set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id);
    assert_eq!(event_kind, b"Album".to_string());
    test_scenario::return_shared(rel);

    // --- Tx 3 (STRANGER, owns nothing): reads are permissionless ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(rk::has_kind(&rel));
    assert_eq!(rk::kind(&rel), b"Album".to_string());
    test_scenario::return_shared(rel);

    // --- Tx 4 (ADMIN): the release changes its mind, then unsets ---
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    rk::set_kind(&mut rel, &cap, b"Extended Play".to_string());
    assert_eq!(rk::kind(&rel), b"Extended Play".to_string());

    rk::unset_kind(&mut rel, &cap);
    assert!(!rk::has_kind(&rel));

    let unset_events = event::events_by_type<rk::KindUnsetEvent>();
    assert_eq!(unset_events.length(), 1);
    assert_eq!(rk::unset_event_release_id(&unset_events[0]), rel_id);
    test_scenario::return_shared(rel);

    destroy(cap);
    ts.end();
}

/// A cap for a different, never-shared release is rejected against the
/// shared one — the wrong-cap gate holds after publish and sharing, not just
/// against a freshly created object. STRANGER owns nothing of the shared
/// release; the only thing it brings to the call is a cap for an unrelated
/// object.
#[test, expected_failure(abort_code = EUnauthorized, location = miso::release)]
fun wrong_cap_is_rejected_against_the_shared_release() {
    let mut ts = test_scenario::begin(ADMIN);
    let cap = publish_and_share(&mut ts);

    // --- Tx 2 (STRANGER): holds a cap for an unrelated, never-shared release ---
    ts.next_tx(STRANGER);
    let comp_id = test_helpers::fake_id(ts.ctx());
    let rec_id = test_helpers::fake_id(ts.ctx());
    let target_id = test_helpers::fake_id(ts.ctx());
    let other_tracks = vector[track::new_for_testing(comp_id, rec_id, target_id, 10000u16)];
    let (other_rel, other_cap) =
        release::new_for_testing(b"Unrelated".to_string(), other_tracks, ts.ctx());

    let mut rel = ts.take_shared<Release>();
    rk::set_kind(&mut rel, &other_cap, b"Album".to_string());

    destroy(other_rel);
    destroy(other_cap);
    test_scenario::return_shared(rel);
    destroy(cap);
    ts.end();
}
