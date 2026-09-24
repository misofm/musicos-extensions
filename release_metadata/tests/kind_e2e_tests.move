// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for the kind attribute, run under
/// `sui::test_scenario`: the release is published and shared exactly as in
/// production — core's release is atomic (an `Initialized` release cannot
/// outlive its creating transaction; every release that exists on-chain is
/// `Published` and shared, per `musicos::release`'s module doc) — and the
/// kind attribute operates on it via `take_shared` in later transactions,
/// exactly as client PTBs would.
///
/// Distinct senders: ADMIN holds the release's admin cap and performs the
/// cap-gated writes; STRANGER owns nothing and proves both that reads are
/// permissionless and that a foreign cap is rejected against the *shared*
/// release, not just against a freshly created one.
#[test_only]
module release_metadata::kind_e2e_tests;

use musicos::release::Release;
use release_metadata::release_metadata as rm;
use release_metadata::test_utils::{mk_release, publish_and_share_release};
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

// Mirrors `release::EUnauthorized` — see the unit test module for why a
// foreign cap is testable at all (a `Release` binds its cap at runtime).
const EUnauthorized: u64 = 0;

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

/// Set → replace → clear against a published, shared release, crossing
/// transaction boundaries with distinct senders: the cap holder writes, a
/// stranger reads (proving reads need no capability), and event payloads are
/// pinned at each write.
#[test]
fun kind_lifecycle_against_a_published_shared_release() {
    let mut ts = test_scenario::begin(ADMIN);

    // --- Tx 1 (ADMIN): create, publish, share ---
    let (cap, rel_id) = publish_and_share_release(&mut ts);

    // --- Tx 2 (ADMIN): set the kind on the now-shared release ---
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    assert_eq!(object::id(&rel), rel_id);
    rm::set_kind(&mut rel, &cap, b"Album".to_string());
    assert!(rm::has_kind(&rel));
    assert_eq!(*rm::kind(&rel), b"Album".to_string());

    let set_events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_kind) = rm::kind_set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id.to_address());
    assert_eq!(event_kind, b"Album".to_string());
    test_scenario::return_shared(rel);

    // --- Tx 3 (STRANGER, owns nothing): reads are permissionless ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(rm::has_kind(&rel));
    assert_eq!(*rm::kind(&rel), b"Album".to_string());
    test_scenario::return_shared(rel);

    // --- Tx 4 (ADMIN): the release changes its mind, then clears ---
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    rm::set_kind(&mut rel, &cap, b"Extended Play".to_string());
    assert_eq!(*rm::kind(&rel), b"Extended Play".to_string());

    let set_events = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_kind) = rm::kind_set_event_fields(&set_events[0]);
    assert_eq!(event_id, rel_id.to_address());
    assert_eq!(event_kind, b"Extended Play".to_string());

    rm::clear_kind(&mut rel, &cap);
    assert!(!rm::has_kind(&rel));

    let cleared_events = event::events_by_type<rm::ReleaseKindClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rm::kind_cleared_event_fields(&cleared_events[0]), rel_id.to_address());
    test_scenario::return_shared(rel);

    destroy(cap);
    ts.end();
}

/// A cap for a different, never-shared release is rejected against the
/// shared one — the wrong-cap gate holds after publish and sharing, not just
/// against a freshly created object. STRANGER owns nothing of the shared
/// release; the only thing it brings to the call is a cap for an unrelated
/// object.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun wrong_cap_is_rejected_against_the_shared_release() {
    let mut ts = test_scenario::begin(ADMIN);
    let (_cap, _rel_id) = publish_and_share_release(&mut ts);

    // --- Tx 2 (STRANGER): holds a cap for an unrelated, never-shared release ---
    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = mk_release(ts.ctx());

    let mut rel = ts.take_shared<Release>();
    rm::set_kind(&mut rel, &other_cap, b"Album".to_string());
    abort
}

/// Clear cap-gates before it checks existence: a foreign cap is rejected
/// against the shared release even when no kind is attached.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun wrong_cap_is_rejected_on_clear_of_nothing() {
    let mut ts = test_scenario::begin(ADMIN);
    let (_cap, _rel_id) = publish_and_share_release(&mut ts);

    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = mk_release(ts.ctx());

    let mut rel = ts.take_shared<Release>();
    assert!(!rm::has_kind(&rel));
    rm::clear_kind(&mut rel, &other_cap);
    abort
}
