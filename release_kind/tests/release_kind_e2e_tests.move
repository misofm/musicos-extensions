// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenarios under `sui::test_scenario`: the release is published
/// and shared exactly as in production (create-and-publish is atomic in
/// core), and the kind extension operates on it via `take_shared` in later
/// transactions. ADMIN holds the release's admin cap; STRANGER owns nothing
/// and proves both that reads are permissionless and that a foreign cap is
/// rejected against the shared release.
#[test_only]
module release_kind::release_kind_e2e_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_kind::release_kind as rk;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self, Scenario};

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

/// Creates, publishes and shares a one-track release as the current sender.
/// Returns the admin cap and the release id.
fun publish_and_share(ts: &mut Scenario): (ReleaseAdminCap, ID) {
    let ctx = ts.ctx();
    let rec_id = test_helpers::fake_id(ctx);
    let target_id = test_helpers::fake_id(ctx);
    let tracks = vector[track::new_for_testing(rec_id, target_id, 10000u16)];
    let (rel, cap) = release::new_for_testing(tracks, ctx);
    let rel_id = object::id(&rel);
    rel.publish(&cap);
    (cap, rel_id)
}

/// Set → replace → clear against a published, shared release, crossing
/// transaction boundaries with distinct senders.
#[test]
fun kind_lifecycle_against_a_published_shared_release() {
    let mut ts = test_scenario::begin(ADMIN);

    // --- Tx 1 (ADMIN): create, publish, share ---
    let (cap, rel_id) = publish_and_share(&mut ts);

    // --- Tx 2 (ADMIN): set the kind on the now-shared release ---
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    assert!(rel.is_published_state());
    rk::set_kind(&mut rel, &cap, b"Album".to_string());
    assert!(rk::has_kind(&rel));
    assert_eq!(*rk::kind(&rel), b"Album".to_string());
    test_scenario::return_shared(rel);

    let set_events = event::events_by_type<rk::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_kind) = rk::kind_set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id);
    assert_eq!(event_kind, b"Album".to_string());

    // --- Tx 3 (STRANGER, owns nothing): reads are permissionless ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(rk::has_kind(&rel));
    assert_eq!(*rk::kind(&rel), b"Album".to_string());
    test_scenario::return_shared(rel);

    // --- Tx 4 (ADMIN): replace, then clear ---
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    rk::set_kind(&mut rel, &cap, b"Extended Play".to_string());
    assert_eq!(*rk::kind(&rel), b"Extended Play".to_string());
    rk::clear_kind(&mut rel, &cap);
    assert!(!rk::has_kind(&rel));
    test_scenario::return_shared(rel);

    let set_events = event::events_by_type<rk::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_kind) = rk::kind_set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id);
    assert_eq!(event_kind, b"Extended Play".to_string());
    let cleared_events = event::events_by_type<rk::ReleaseKindClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rk::kind_cleared_event_fields(&cleared_events[0]), rel_id);

    // --- Tx 5 (STRANGER): the clear is visible too ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(!rk::has_kind(&rel));
    test_scenario::return_shared(rel);

    destroy(cap);
    ts.end();
}

/// A validly-scoped cap for STRANGER's own shared release is rejected against
/// ADMIN's shared release.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun wrong_cap_is_rejected_on_set() {
    let mut ts = test_scenario::begin(ADMIN);
    let (_admin_cap, admin_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(STRANGER);
    let mut admin_rel = test_scenario::take_shared_by_id<Release>(&ts, admin_rel_id);
    rk::set_kind(&mut admin_rel, &stranger_cap, b"Album".to_string());
    abort
}

/// Clear authorizes before checking existence, so a wrong cap aborts even
/// when there is nothing attached to remove.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun wrong_cap_is_rejected_on_clear_of_nothing() {
    let mut ts = test_scenario::begin(ADMIN);
    let (_admin_cap, admin_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(STRANGER);
    let mut admin_rel = test_scenario::take_shared_by_id<Release>(&ts, admin_rel_id);
    assert!(!rk::has_kind(&admin_rel));
    rk::clear_kind(&mut admin_rel, &stranger_cap);
    abort
}
