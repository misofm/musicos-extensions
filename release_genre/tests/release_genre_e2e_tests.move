// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for `release_genre`'s full use case, run under
/// `sui::test_scenario`: real transaction boundaries, distinct senders, and
/// the release genuinely published and shared before genre operations touch
/// it via `take_shared` in a later transaction — the production shape (core
/// releases are create-and-publish atomic, then shared for their whole life;
/// see `miso::release`'s module doc).
///
/// Scope: canonical vocabulary creation (`genre::genre`, upstream context) feeding a
/// published, shared `Release`'s genre assignment — album primary, album
/// secondaries, per-track overrides — plus the cap-gated adversarial case
/// (wrong `ReleaseAdminCap` from a second release).
#[test_only]
module release_genre::release_genre_e2e_tests;

use genre::genre as g;
use genre::genre::{GenreRegistry, Genre};
use miso::release::{Self, Release, ReleaseAdminCap};
use miso::test_helpers;
use miso::track;
use release_genre::release_genre as rg;
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

// CREATOR creates canonical genres. LABEL creates and owns releases
// (the ReleaseAdminCap holder). STRANGER owns nothing relevant to either
// release and plays the wrong-cap adversary.
const CREATOR: address = @0xC0;
const LABEL: address = @0xAD;
const STRANGER: address = @0x51;

// === Helpers ===

/// Creates a genre in the permissionless registry and returns its derived id.
fun create_genre(scenario: &Scenario, name: vector<u8>): ID {
    let mut registry = scenario.take_shared<GenreRegistry>();
    let id = g::derive_address(&registry, name.to_string()).to_id();
    g::new(&mut registry, name.to_string());
    ts::return_shared(registry);
    id
}

/// Builds a 2-track release and publishes it in the same transaction —
/// create-and-publish is atomic in production (`miso::release`'s module
/// doc): a fresh `Initialized` release cannot outlive its creating
/// transaction, so every release that exists on chain is already `Published`
/// and shared. Returns the admin cap and the release's real (post-creation)
/// id, since callers need the id to `take_shared_by_id` it back later.
fun publish_and_share_release(scenario: &mut Scenario): (ReleaseAdminCap, ID) {
    let ctx = scenario.ctx();
    let comp_id = test_helpers::fake_id(ctx);
    let placeholder_release_id = test_helpers::fake_id(ctx);
    let r0 = test_helpers::fake_id(ctx);
    let r1 = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(comp_id, r0, placeholder_release_id, 5000u16),
        track::new_for_testing(comp_id, r1, placeholder_release_id, 5000u16),
    ];
    // `new_for_testing` patches every track's target_release_id to match the
    // real release id it creates, so the placeholder above never has to be
    // predicted correctly.
    let (rel, cap) = release::new_for_testing(b"Album".to_string(), tracks, ctx);
    let release_id = object::id(&rel);
    let the_clock = clock::create_for_testing(ctx);
    rel.publish(&cap, &the_clock); // verifies track assignment, shares
    the_clock.destroy_for_testing();
    (cap, release_id)
}

// === Full lifecycle against a published, shared release ===

#[test]
fun genre_lifecycle_on_published_shared_release() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    // --- Tx 1 (CREATOR): create the vocabulary entries ---
    scenario.next_tx(CREATOR);
    let hiphop_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let electronic_id = create_genre(&scenario, b"ELECTRONIC");

    // --- Tx 2 (LABEL): create-and-publish the release (shares it) ---
    scenario.next_tx(LABEL);
    let (cap, release_id) = publish_and_share_release(&mut scenario);

    // --- Tx 3 (LABEL): operate on the now-shared release via take_shared ---
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    assert_eq!(object::id(&rel), release_id);
    assert!(rel.is_published_state());
    let hiphop = scenario.take_immutable_by_id<Genre>(hiphop_id);
    let electronic = scenario.take_immutable_by_id<Genre>(electronic_id);

    assert!(!rg::has_genre(&rel));
    rg::set_primary_genre(&mut rel, &cap, &hiphop);
    rg::add_secondary_genre(&mut rel, &cap, &electronic);
    rg::set_track_primary_genre(&mut rel, &cap, 1, &electronic);

    assert_eq!(rg::primary_genre(&rel), option::some(hiphop_id));
    assert_eq!(rg::secondary_genres(&rel), vector[electronic_id]);
    assert_eq!(rg::track_primary_genre(&rel, 0), option::some(hiphop_id));
    assert_eq!(rg::track_primary_genre(&rel, 1), option::some(electronic_id));

    // Full event payloads, pinned against the real (post-publish) release id.
    let primary_events = event::events_by_type<rg::PrimaryGenreSetEvent>();
    assert_eq!(primary_events.length(), 1);
    let (p_release_id, p_genre_id) =
        rg::primary_genre_set_event_fields(&primary_events[0]);
    assert_eq!(p_release_id, release_id);
    assert_eq!(p_genre_id, hiphop_id);

    let secondary_events = event::events_by_type<rg::SecondaryGenreAddedEvent>();
    assert_eq!(secondary_events.length(), 1);
    let (s_release_id, s_genre_id) =
        rg::secondary_genre_added_event_fields(&secondary_events[0]);
    assert_eq!(s_release_id, release_id);
    assert_eq!(s_genre_id, electronic_id);

    let track_events = event::events_by_type<rg::TrackPrimaryGenreSetEvent>();
    assert_eq!(track_events.length(), 1);
    let (t_release_id, t_track_index, t_genre_id) =
        rg::track_primary_genre_set_event_fields(&track_events[0]);
    assert_eq!(t_release_id, release_id);
    assert_eq!(t_track_index, 1);
    assert_eq!(t_genre_id, electronic_id);

    ts::return_immutable(hiphop);
    ts::return_immutable(electronic);
    ts::return_shared(rel);
    destroy(cap);
    scenario.end();
}

// === Adversarial: wrong ReleaseAdminCap from a second release ===

/// A stranger holding the *other* release's admin cap cannot touch this
/// release's genre assignment — `uid_mut`'s `authorize` check (core) rejects
/// it before `release_genre` ever runs its own logic.
#[test]
#[expected_failure(abort_code = 0, location = miso::release)] // EUnauthorized
fun wrong_cap_from_other_release_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let hiphop_id = create_genre(&scenario, b"HIP_HOP");

    // --- Tx (LABEL): publish two distinct, shared releases ---
    scenario.next_tx(LABEL);
    let (_cap_a, release_id_a) = publish_and_share_release(&mut scenario);
    scenario.next_tx(LABEL);
    let (cap_b, _release_id_b) = publish_and_share_release(&mut scenario);

    // --- Tx (STRANGER): try to set release A's genre using cap B ---
    scenario.next_tx(STRANGER);
    let mut rel_a = scenario.take_shared_by_id<Release>(release_id_a);
    let hiphop = scenario.take_immutable_by_id<Genre>(hiphop_id);
    rg::set_primary_genre(&mut rel_a, &cap_b, &hiphop); // aborts: wrong cap

    // Unreachable, but the compiler requires all non-drop values consumed on
    // any path that returns normally; this path never does.
    abort
}
