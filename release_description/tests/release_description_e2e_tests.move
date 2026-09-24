// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenarios under `sui::test_scenario`: the release is published
/// and shared exactly as in production, and the description extension
/// operates on it via `take_shared` in later transactions. LABEL holds the
/// release's admin cap; STRANGER owns nothing relevant and proves both that
/// reads are permissionless and that a foreign cap is rejected against the
/// shared release.
#[test_only]
module release_description::release_description_e2e_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_description::release_description as rd;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self, Scenario};

const LABEL: address = @0xAD;
const STRANGER: address = @0x51;

/// Creates, publishes and shares a one-track release as the current sender.
/// Returns the admin cap and the release id.
fun publish_and_share(scenario: &mut Scenario): (ReleaseAdminCap, ID) {
    let ctx = scenario.ctx();
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
fun description_lifecycle_on_a_published_and_shared_release() {
    let mut ts = test_scenario::begin(LABEL);

    // --- Tx 1 (LABEL): publish and share the release, saying nothing yet ---
    let (cap, rel_id) = publish_and_share(&mut ts);

    // --- Tx 2 (STRANGER): the surface is readable by anyone, and starts empty ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(rel.is_published_state());
    assert!(!rd::has_description(&rel));
    test_scenario::return_shared(rel);

    // --- Tx 3 (LABEL): write via take_shared + the cap retained from Tx 1 ---
    ts.next_tx(LABEL);
    let mut rel = ts.take_shared<Release>();
    rd::set_description(&mut rel, &cap, b"Recorded live in one room.".to_string());
    assert!(rd::has_description(&rel));
    assert_eq!(*rd::description(&rel), b"Recorded live in one room.".to_string());
    test_scenario::return_shared(rel);

    let set_events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_description) = rd::description_set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id);
    assert_eq!(event_description, b"Recorded live in one room.".to_string());

    // --- Tx 4 (STRANGER): reads back the same prose a transaction later ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert_eq!(*rd::description(&rel), b"Recorded live in one room.".to_string());
    test_scenario::return_shared(rel);

    // --- Tx 5 (LABEL): replace, then clear ---
    ts.next_tx(LABEL);
    let mut rel = ts.take_shared<Release>();
    rd::set_description(&mut rel, &cap, b"Recorded live in one room, in two days.".to_string());
    rd::clear_description(&mut rel, &cap);
    assert!(!rd::has_description(&rel));
    test_scenario::return_shared(rel);

    let set_events = event::events_by_type<rd::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_description) = rd::description_set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id);
    assert_eq!(event_description, b"Recorded live in one room, in two days.".to_string());
    let cleared_events = event::events_by_type<rd::ReleaseDescriptionClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rd::description_cleared_event_fields(&cleared_events[0]), rel_id);

    // --- Tx 6 (STRANGER): the clear is visible too ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(!rd::has_description(&rel));
    test_scenario::return_shared(rel);

    destroy(cap);
    ts.end();
}

/// A validly-scoped cap for STRANGER's own shared release is rejected against
/// LABEL's shared release.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun wrong_cap_is_rejected_on_set() {
    let mut ts = test_scenario::begin(LABEL);
    let (_label_cap, label_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(STRANGER);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    rd::set_description(&mut label_rel, &stranger_cap, b"Not yours to write.".to_string());
    abort
}

/// Clear authorizes before checking existence, so a wrong cap aborts even
/// when there is nothing attached to remove.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun wrong_cap_is_rejected_on_clear_of_nothing() {
    let mut ts = test_scenario::begin(LABEL);
    let (_label_cap, label_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(STRANGER);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    assert!(!rd::has_description(&label_rel));
    rd::clear_description(&mut label_rel, &stranger_cap);
    abort
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun wrong_cap_is_rejected_on_clear_of_present_description() {
    let mut ts = test_scenario::begin(LABEL);
    let (label_cap, label_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(LABEL);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    rd::set_description(&mut label_rel, &label_cap, b"Label-owned prose.".to_string());
    test_scenario::return_shared(label_rel);

    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_and_share(&mut ts);

    ts.next_tx(STRANGER);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    assert!(rd::has_description(&label_rel));
    rd::clear_description(&mut label_rel, &stranger_cap);
    abort
}
