// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for this package's full use case, run under
/// `sui::test_scenario`: a release is published and shared exactly as core
/// produces it, credits are attached to and removed from it via `take_shared`
/// in later transactions by distinct senders, and a stranger holding a
/// legitimate admin cap for an unrelated release cannot use it here.
#[test_only]
module release_credits::credits_e2e_tests;

use miso::release::{Self, Release};
use miso_credit::credit;
use partyos::party::{Self, Party};
use release_credits::release_credits as credits;
use release_credits::release_party_role as rpr;
use std::unit_test::{assert_eq, destroy};
use sui::event;
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
    let (rel, rel_cap) = release::new_for_testing(b"Album".to_string(), vector[], ts.ctx());
    let rel_id = object::id(&rel);
    let clock = sui::clock::create_for_testing(ts.ctx());
    rel.publish(&rel_cap, &clock);
    clock.destroy_for_testing();

    // === Tx 2 (ARTIST): registers and shares their own party ===
    ts.next_tx(ARTIST);
    let clock = sui::clock::create_for_testing(ts.ctx());
    let (artist_party, artist_cap) =
        party::new(party::new_individual_kind(), b"Alice".to_string(), &clock, ts.ctx());
    let artist_id = object::id(&artist_party);
    artist_party.share(&artist_cap);
    clock.destroy_for_testing();

    // === Tx 3 (FEATURED_ARTIST): registers and shares their own party ===
    ts.next_tx(FEATURED_ARTIST);
    let clock = sui::clock::create_for_testing(ts.ctx());
    let (feat_party, feat_cap) =
        party::new(party::new_individual_kind(), b"Bob".to_string(), &clock, ts.ctx());
    let feat_id = object::id(&feat_party);
    feat_party.share(&feat_cap);
    clock.destroy_for_testing();

    // === Tx 4 (LABEL): credits both parties on the now-published, shared release ===
    ts.next_tx(LABEL);
    let mut rel = ts.take_shared<Release>();
    assert!(rel.is_published_state());
    assert!(!credits::has_credits(&rel));

    let artist_party = ts.take_shared_by_id<Party>(artist_id);
    let feat_party = ts.take_shared_by_id<Party>(feat_id);

    credits::add_credit(
        &mut rel,
        &rel_cap,
        &artist_party,
        credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]),
    );
    credits::add_credit(
        &mut rel,
        &rel_cap,
        &feat_party,
        credit::new(b"Bob".to_string(), vector[rpr::new_featured_role()]),
    );

    assert!(credits::has_credits(&rel));
    assert_eq!(credits::credits(&rel).length(), 2);

    let events = event::events_by_type<credits::CreditAddedEvent>();
    assert_eq!(events.length(), 2);
    let (event_rel_id, event_party_id, event_credit) = credits::added_event_fields(&events[0]);
    assert_eq!(event_rel_id, rel_id);
    assert_eq!(event_party_id, artist_id);
    assert_eq!(event_credit, credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]));
    let (event_rel_id, event_party_id, event_credit) = credits::added_event_fields(&events[1]);
    assert_eq!(event_rel_id, rel_id);
    assert_eq!(event_party_id, feat_id);
    assert_eq!(event_credit, credit::new(b"Bob".to_string(), vector[rpr::new_featured_role()]));

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

    let removed_events = event::events_by_type<credits::CreditRemovedEvent>();
    assert_eq!(removed_events.length(), 1);
    let (event_rel_id, event_party_id, event_credit) =
        credits::removed_event_fields(&removed_events[0]);
    assert_eq!(event_rel_id, rel_id);
    assert_eq!(event_party_id, artist_id);
    assert_eq!(event_credit, credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]));

    test_scenario::return_shared(rel);

    destroy(rel_cap);
    destroy(artist_cap);
    destroy(feat_cap);
    ts.end();
}

/// A cap that legitimately authorizes a different release cannot be used to
/// credit this one — `add_credit` routes through `release::uid_mut`, whose
/// authorization check is the real enforcement point.
#[test, expected_failure(abort_code = 0, location = miso::release)] // EUnauthorized
fun add_credit_aborts_for_a_cap_from_a_different_release() {
    let mut ts = test_scenario::begin(LABEL);

    // === Tx 1 (LABEL): create and publish the real release — shares it ===
    let (rel, rel_cap) = release::new_for_testing(b"Album".to_string(), vector[], ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    rel.publish(&rel_cap, &clock);
    clock.destroy_for_testing();
    destroy(rel_cap);

    // === Tx 2 (STRANGER): owns an unrelated release, its own cap, and a party ===
    ts.next_tx(STRANGER);
    let (_stranger_rel, stranger_cap) =
        release::new_for_testing(b"Unrelated".to_string(), vector[], ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    let (party, _party_cap) =
        party::new(party::new_individual_kind(), b"Eve".to_string(), &clock, ts.ctx());
    clock.destroy_for_testing();

    let mut rel = ts.take_shared<Release>();
    credits::add_credit(
        &mut rel,
        &stranger_cap, // wrong cap: authorizes `stranger_rel`, not the shared `rel`
        &party,
        credit::new(b"Eve".to_string(), vector[rpr::new_primary_role()]),
    ); // aborts: miso::release::EUnauthorized

    abort
}
