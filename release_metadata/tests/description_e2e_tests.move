// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for the description attribute, run under
/// `sui::test_scenario`: real transaction boundaries, distinct senders, and
/// the release genuinely published and shared before the extension ever
/// touches it — the production shape, where `uid_mut` is the cap-gated
/// surface that stays open after publish while the release's embedded fields
/// are frozen.
#[test_only]
module release_metadata::description_e2e_tests;

use musicos::release::Release;
use release_metadata::release_metadata as rm;
use release_metadata::test_utils::publish_and_share_release;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const LABEL: address = @0xAD;
const STRANGER: address = @0x51;

// Mirrors `release::EUnauthorized`. A `Release` binds its cap at runtime —
// `uid_mut` calls `authorize`, which asserts `object::id(self) ==
// cap.release_id` — so a foreign cap is testable here.
const EUnauthorized: u64 = 0;

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
    let (cap, rel_id) = publish_and_share_release(&mut ts);

    // --- Tx 2 (STRANGER): the extension surface is readable by anyone, and
    // starts empty ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(!rm::has_description(&rel));
    test_scenario::return_shared(rel);

    // --- Tx 3 (LABEL): writes the description via take_shared + the cap
    // retained from Tx 1 ---
    ts.next_tx(LABEL);
    let mut rel = ts.take_shared<Release>();
    rm::set_description(&mut rel, &cap, b"Recorded live in one room.".to_string());
    assert!(rm::has_description(&rel));
    assert_eq!(*rm::description(&rel), b"Recorded live in one room.".to_string());
    test_scenario::return_shared(rel);

    let set_events = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_description) = rm::description_set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id.to_address());
    assert_eq!(event_description, b"Recorded live in one room.".to_string());

    // --- Tx 4 (STRANGER): reads back the same prose a transaction later ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert_eq!(*rm::description(&rel), b"Recorded live in one room.".to_string());
    test_scenario::return_shared(rel);

    // --- Tx 5 (LABEL): replaces, then clears — both against the shared
    // object, both in one later transaction ---
    ts.next_tx(LABEL);
    let mut rel = ts.take_shared<Release>();
    rm::set_description(&mut rel, &cap, b"Recorded live in one room, in two days.".to_string());
    rm::clear_description(&mut rel, &cap);
    assert!(!rm::has_description(&rel));
    test_scenario::return_shared(rel);

    let set_events = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, after) = rm::description_set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id.to_address());
    assert_eq!(after, b"Recorded live in one room, in two days.".to_string());

    let cleared_events = event::events_by_type<rm::ReleaseDescriptionClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rm::description_cleared_event_fields(&cleared_events[0]), rel_id.to_address());

    // --- Tx 6 (STRANGER): the clear is visible too ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(!rm::has_description(&rel));
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
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun wrong_cap_is_rejected_on_set() {
    let mut ts = test_scenario::begin(LABEL);
    let (_label_cap, label_rel_id) = publish_and_share_release(&mut ts);

    // STRANGER publishes and shares an entirely unrelated release, and holds
    // that release's own (validly-scoped) cap.
    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_and_share_release(&mut ts);

    // STRANGER now tries to write LABEL's description using their own cap —
    // disambiguated from STRANGER's own shared release by id.
    ts.next_tx(STRANGER);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    rm::set_description(&mut label_rel, &stranger_cap, b"Not yours to write.".to_string());
    abort
}

/// Clear cap-gates before it checks existence, so a wrong cap aborts even
/// when there is nothing attached to remove — the case a naive
/// existence-first clear would let silently succeed. Proven with a real
/// adversary: STRANGER's own, validly-scoped cap against LABEL's shared,
/// description-less release.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun wrong_cap_is_rejected_on_clear_of_nothing() {
    let mut ts = test_scenario::begin(LABEL);
    let (_label_cap, label_rel_id) = publish_and_share_release(&mut ts);

    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_and_share_release(&mut ts);

    ts.next_tx(STRANGER);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    assert!(!rm::has_description(&label_rel));
    rm::clear_description(&mut label_rel, &stranger_cap);
    abort
}

/// A wrong cap is rejected on clear even when a description is present. The
/// existence check must not replace the core release authorization boundary.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun wrong_cap_is_rejected_on_clear_of_present_description() {
    let mut ts = test_scenario::begin(LABEL);
    let (label_cap, label_rel_id) = publish_and_share_release(&mut ts);

    ts.next_tx(LABEL);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    rm::set_description(&mut label_rel, &label_cap, b"Label-owned prose.".to_string());
    test_scenario::return_shared(label_rel);

    ts.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_and_share_release(&mut ts);

    ts.next_tx(STRANGER);
    let mut label_rel = test_scenario::take_shared_by_id<Release>(&ts, label_rel_id);
    assert!(rm::has_description(&label_rel));
    rm::clear_description(&mut label_rel, &stranger_cap);
    abort
}
