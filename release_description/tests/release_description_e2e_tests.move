// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for this package's full use case, run under
/// `sui::test_scenario`: real transaction boundaries, distinct senders, and
/// the release genuinely published and shared before the extension ever
/// touches it — the production shape, where `uid_mut` is the cap-gated
/// surface that stays open after publish while the release's embedded
/// fields are frozen.
#[test_only]
module release_description::release_description_e2e_tests;

use miso::release::{Self, Release, ReleaseAdminCap};
use miso::test_helpers;
use miso::track;
use release_description::release_description as rd;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self, Scenario};

const LABEL: address = @0xAD;
const STRANGER: address = @0x51;

// Mirrors `release::EUnauthorized` (release.move:159). A `Release` binds its
// cap at runtime — `uid_mut` calls `authorize`, which asserts
// `object::id(self) == cap.release_id` — so a foreign cap is testable here.
const EUnauthorized: u64 = 0;

/// Publishes a minimal, titled, single-track release and returns its admin
/// cap and id (the object itself is shared). Titled per-call so a test can
/// create more than one distinguishable shared `Release` and disambiguate
/// them by id.
fun publish_titled_release(scenario: &mut Scenario, title: vector<u8>): (ReleaseAdminCap, ID) {
    let ctx = scenario.ctx();
    let (rel, cap) = release::new_for_testing(
        title.to_string(),
        vector[
            track::new_for_testing(
                test_helpers::fake_id(ctx),
                test_helpers::fake_id(ctx),
                test_helpers::fake_id(ctx),
                10000u16,
            ),
        ],
        ctx,
    );
    let rel_id = object::id(&rel);
    let clock = sui::clock::create_for_testing(ctx);
    rel.publish(&cap, &clock);
    clock.destroy_for_testing();
    (cap, rel_id)
}

/// The production shape end to end: LABEL publishes and shares a release
/// with nothing said about itself; a stranger reads that absence a
/// transaction later. LABEL then writes, rewrites and clears the
/// description — each time reaching the shared object via `take_shared` in
/// its own later transaction, using the cap retained from publish — and a
/// stranger observes every state change along the way.
#[test]
fun description_lifecycle_on_a_published_and_shared_release() {
    let mut ts = test_scenario::begin(LABEL);

    // --- Tx 1 (LABEL): publish and share the release, saying nothing yet ---
    let (cap, rel_id) = publish_titled_release(&mut ts, b"Long Player");

    // --- Tx 2 (STRANGER): the extension surface is readable by anyone, and
    // starts empty ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(!rd::has_description(&rel));
    test_scenario::return_shared(rel);

    // --- Tx 3 (LABEL): writes the description via take_shared + the cap
    // retained from Tx 1 ---
    ts.next_tx(LABEL);
    let mut rel = ts.take_shared<Release>();
    rd::set_description(&mut rel, &cap, b"Recorded live in one room.".to_string());
    assert!(rd::has_description(&rel));
    assert_eq!(*rd::description(&rel), b"Recorded live in one room.".to_string());
    test_scenario::return_shared(rel);

    let set_events = event::events_by_type<rd::DescriptionSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_description) = rd::set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id);
    assert_eq!(event_description, b"Recorded live in one room.".to_string());

    // --- Tx 4 (STRANGER): reads back the same prose a transaction later ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert_eq!(*rd::description(&rel), b"Recorded live in one room.".to_string());
    test_scenario::return_shared(rel);

    // --- Tx 5 (LABEL): replaces, then clears — both against the shared
    // object, both in one later transaction ---
    ts.next_tx(LABEL);
    let mut rel = ts.take_shared<Release>();
    rd::set_description(&mut rel, &cap, b"Recorded live in one room, in two days.".to_string());
    rd::clear_description(&mut rel, &cap);
    assert!(!rd::has_description(&rel));
    test_scenario::return_shared(rel);

    let cleared_events = event::events_by_type<rd::DescriptionClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rd::cleared_event_release_id(&cleared_events[0]), rel_id);

    // --- Tx 6 (STRANGER): the clear is visible too ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(!rd::has_description(&rel));
    test_scenario::return_shared(rel);

    destroy(cap);
    ts.end();
}

/// The extension surface's authorization is unforgeable: a cap minted for a
/// different, unrelated release cannot write this one's description — even
/// after both are published and shared. This is the realistic production
/// shape of a wrong-cap attempt (`uid_mut` works in any lifecycle state, so
/// the interesting adversarial case is post-publish, cross-actor, not
/// pre-publish same-transaction).
#[test, expected_failure(abort_code = EUnauthorized, location = miso::release)]
fun wrong_cap_is_rejected_on_set() {
    let mut ts = test_scenario::begin(LABEL);
    let (label_cap, label_rel_id) = publish_titled_release(&mut ts, b"Label's Album");

    // STRANGER publishes and shares an entirely unrelated release, and holds
    // that release's own (validly-scoped) cap.
    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_titled_release(&mut ts, b"Stranger's Album");

    // STRANGER now tries to write LABEL's description using their own cap —
    // disambiguated from STRANGER's own shared release by id.
    ts.next_tx(STRANGER);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    rd::set_description(&mut label_rel, &stranger_cap, b"Not yours to write.".to_string());

    test_scenario::return_shared(label_rel);
    destroy(label_cap);
    destroy(stranger_cap);
    abort
}

/// Clear cap-gates before it checks existence, so a wrong cap aborts even
/// when there is nothing attached to remove — the case a naive
/// existence-first clear would let silently succeed. Proven with a real
/// adversary: STRANGER's own, validly-scoped cap against LABEL's shared,
/// description-less release.
#[test, expected_failure(abort_code = EUnauthorized, location = miso::release)]
fun wrong_cap_is_rejected_on_clear_of_nothing() {
    let mut ts = test_scenario::begin(LABEL);
    let (label_cap, label_rel_id) = publish_titled_release(&mut ts, b"Label's Album");

    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_titled_release(&mut ts, b"Stranger's Album");

    ts.next_tx(STRANGER);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    assert!(!rd::has_description(&label_rel));
    rd::clear_description(&mut label_rel, &stranger_cap);

    test_scenario::return_shared(label_rel);
    destroy(label_cap);
    destroy(stranger_cap);
    abort
}
