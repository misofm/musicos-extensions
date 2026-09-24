// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for this package's full use case, run under
/// `sui::test_scenario`: a release is published and shared exactly as core
/// produces it, credits are attached to and removed from it via `take_shared`
/// in later transactions by distinct senders, and a stranger holding a
/// legitimate admin cap for an unrelated release cannot use it here.
#[test_only]
module release_credits::credits_e2e_tests;

use credit::credit;
use musicos::release::{Self, Release};
use partyos::party::{Self, Party};
use release_credits::release_credits as credits;
use release_credits::release_party_role as rpr;
use std::unit_test::{assert_eq, destroy};
use sui::event::events_by_type;
use sui::test_scenario;

// Actors. LABEL holds the release's admin cap. ARTIST and FEATURED_ARTIST
// are the credited parties; they own nothing on the release. STRANGER holds
// a legitimate admin cap for an unrelated release and tries to reuse it here.
const LABEL: address = @0xAD;
const ARTIST: address = @0xA1;
const FEATURED_ARTIST: address = @0xA2;
const STRANGER: address = @0x51;

#[test]
fun credits_lifecycle_against_a_published_shared_release() {
    let mut ts = test_scenario::begin(LABEL);

    // === Tx 1 (LABEL): create and publish the release — shares it ===
    let (rel, rel_cap) = release::new_for_testing(vector[], ts.ctx());
    let rel_id = object::id(&rel);
    rel.publish(&rel_cap);

    // === Tx 2 (ARTIST): registers and shares their own party ===
    ts.next_tx(ARTIST);
    let (artist_party, artist_cap) =
        party::new(party::new_individual_kind(), b"Alice".to_string(), ts.ctx());
    let artist_id = object::id(&artist_party);
    artist_party.share(&artist_cap);

    // === Tx 3 (FEATURED_ARTIST): registers and shares their own party ===
    ts.next_tx(FEATURED_ARTIST);
    let (feat_party, feat_cap) =
        party::new(party::new_individual_kind(), b"Bob".to_string(), ts.ctx());
    let feat_id = object::id(&feat_party);
    feat_party.share(&feat_cap);

    // === Tx 4 (LABEL): credits both parties on the now-published, shared release ===
    ts.next_tx(LABEL);
    let mut rel = ts.take_shared<Release>();
    assert!(rel.is_published_state());
    assert!(!credits::has_credits(&rel));

    let artist_party = ts.take_shared_by_id<Party>(artist_id);
    let feat_party = ts.take_shared_by_id<Party>(feat_id);

    let alice = credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]);
    let bob = credit::new(b"Bob".to_string(), vector[rpr::new_featured_role()]);
    credits::add_credit(&mut rel, &rel_cap, &artist_party, alice);
    credits::add_credit(&mut rel, &rel_cap, &feat_party, bob);

    assert!(credits::has_credits(&rel));
    assert_eq!(credits::credits(&rel).length(), 2);

    let events = events_by_type<credits::ReleaseCreditAddedEvent>();
    assert_eq!(events.length(), 2);
    let (event_object, event_party, event_roles) = credits::added_event_fields(&events[0]);
    assert_eq!(event_object, rel_id);
    assert_eq!(event_party, artist_id);
    assert_eq!(event_roles, vector[rpr::new_primary_role()]);
    let (event_object, event_party, event_roles) = credits::added_event_fields(&events[1]);
    assert_eq!(event_object, rel_id);
    assert_eq!(event_party, feat_id);
    assert_eq!(event_roles, vector[rpr::new_featured_role()]);
    assert_eq!(credits::credits(&rel)[&artist_id], alice);
    assert_eq!(credits::credits(&rel)[&feat_id], bob);

    test_scenario::return_shared(artist_party);
    test_scenario::return_shared(feat_party);
    test_scenario::return_shared(rel);

    // === Tx 5 (LABEL): removes the artist's credit; the feature stays ===
    ts.next_tx(LABEL);
    let mut rel = ts.take_shared<Release>();
    credits::remove_credit(&mut rel, &rel_cap, artist_id);

    assert!(credits::has_credits(&rel));
    assert_eq!(credits::credits(&rel).length(), 1);
    assert!(credits::credits(&rel).contains(&feat_id));

    let removed_events = events_by_type<credits::ReleaseCreditRemovedEvent>();
    assert_eq!(removed_events.length(), 1);
    let (event_object, event_party) = credits::removed_event_fields(&removed_events[0]);
    assert_eq!(event_object, rel_id);
    assert_eq!(event_party, artist_id);

    test_scenario::return_shared(rel);

    destroy(rel_cap);
    destroy(artist_cap);
    destroy(feat_cap);
    ts.end();
}

/// A cap that legitimately authorizes a different release cannot be used to
/// credit this one — `add_credit` routes through `release::uid_mut`, whose
/// authorization check is the real enforcement point.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun add_credit_aborts_for_a_cap_from_a_different_release() {
    let mut ts = test_scenario::begin(LABEL);

    // === Tx 1 (LABEL): create and publish the real release — shares it ===
    let (rel, rel_cap) = release::new_for_testing(vector[], ts.ctx());
    rel.publish(&rel_cap);
    destroy(rel_cap);

    // === Tx 2 (STRANGER): owns an unrelated release, its own cap, and a party ===
    ts.next_tx(STRANGER);
    let (_stranger_rel, stranger_cap) = release::new_for_testing(vector[], ts.ctx());
    let (party, _party_cap) =
        party::new(party::new_individual_kind(), b"Eve".to_string(), ts.ctx());

    let mut rel = ts.take_shared<Release>();
    credits::add_credit(
        &mut rel,
        &stranger_cap, // wrong cap: authorizes `stranger_rel`, not the shared `rel`
        &party,
        credit::new(b"Eve".to_string(), vector[rpr::new_primary_role()]),
    ); // aborts: release::EUnauthorized

    abort
}
