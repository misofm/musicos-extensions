// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenarios for `release_cover_art`'s full use case, run under
/// `sui::test_scenario`: the release is created and published (shared) in
/// one admin transaction — core's create-and-publish is atomic in production
/// — then the cover art extension operates on the shared object via
/// `take_shared` across later transactions. This is the production shape
/// every extension that attaches to a core `Release` must support: the
/// object is genuinely shared, `uid_mut` stays the cap-gated extension
/// surface afterward, and public reads are open to anyone. Distinct senders
/// prove the cap gate itself: the admin's own cap succeeds, a stranger
/// holding an unrelated release's cap aborts.
#[test_only]
module release_cover_art::cover_art_e2e_tests;

use cover_art::cover_art as cover;
use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track::{Self, Track};
use release_cover_art::release_cover_art;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self, Scenario};

// ADMIN holds the release admin cap and performs every cap-gated write.
// READER owns nothing and proves the views are open to anyone. STRANGER
// holds a *different* release's admin cap and proves the cap gate rejects
// it against ADMIN's release.
const ADMIN: address = @0xAD;
const READER: address = @0xFA;
const STRANGER: address = @0x51;

// Mirrored from musicos::release::EUnauthorized (private there).
const EUnauthorized: u64 = 0;

// A 3-track tracklist. `release::new_for_testing` patches every track's
// target_release_id to match the release it constructs, so the placeholder
// id passed here never needs to predict anything.
fun mk_tracks(ctx: &mut TxContext): vector<Track> {
    let comp_id = test_helpers::fake_id(ctx);
    let placeholder = test_helpers::fake_id(ctx);
    vector[
        track::new_for_testing(comp_id, test_helpers::fake_id(ctx), placeholder, 4000u16),
        track::new_for_testing(comp_id, test_helpers::fake_id(ctx), placeholder, 3000u16),
        track::new_for_testing(comp_id, test_helpers::fake_id(ctx), placeholder, 3000u16),
    ]
}

// Creates, publishes, and shares a 3-track release as the scenario's current
// sender. Returns the admin cap (kept as a plain local across later
// transaction boundaries, same as the reference e2e suites).
fun setup_published_release(ts: &mut Scenario): ReleaseAdminCap {
    let (rel, rel_cap) = release::new_for_testing(
        b"Album".to_string(),
        mk_tracks(ts.ctx()),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rel.publish(&rel_cap, &clock); // shares the release
    clock.destroy_for_testing();
    rel_cap
}

/// The flagship path: ADMIN publishes the release, attaches an album cover
/// and a track override, a disinterested READER resolves the effective
/// cover for every track, and ADMIN then clears the override and the album
/// cover — all against the shared object, across five transactions, with
/// exact event payload assertions at each write.
#[test]
fun cover_art_lifecycle_against_published_shared_release() {
    let mut ts = test_scenario::begin(ADMIN);
    let rel_cap = setup_published_release(&mut ts);

    // === Tx 2 (ADMIN): attach the album cover and a track override ===
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    let rel_id = object::id(&rel).to_address();
    assert!(!release_cover_art::has_cover_art(&rel));

    let album_art = cover::new_for_testing();
    release_cover_art::set_cover(&mut rel, &rel_cap, album_art);
    assert!(release_cover_art::has_cover_art(&rel));
    assert_eq!(*release_cover_art::cover(&rel), option::some(album_art));

    let set_cover_events = event::events_by_type<release_cover_art::ReleaseCoverArtSetEvent>();
    assert_eq!(set_cover_events.length(), 1);
    let (event_rel_id, event_cap_id, event_track_count, event_field_before, event_field_after) =
        release_cover_art::release_cover_art_set_event_header(&set_cover_events[0]);
    assert_eq!(event_rel_id, rel_id);
    assert_eq!(event_cap_id, object::id(&rel_cap).to_address());
    assert_eq!(event_track_count, 3);
    assert!(!event_field_before);
    assert!(event_field_after);

    let track1_art = cover::new_for_testing();
    release_cover_art::set_track_cover(&mut rel, &rel_cap, 1, track1_art);

    let track_set_events = event::events_by_type<release_cover_art::ReleaseTrackCoverArtSetEvent>();
    assert_eq!(track_set_events.length(), 1);
    let (t_rel_id, t_cap_id, t_count, t_field_before, t_field_after, t_idx, t_recording_id, t_composition_id) =
        release_cover_art::release_track_cover_art_set_event_header(&track_set_events[0]);
    assert_eq!(t_rel_id, rel_id);
    assert_eq!(t_cap_id, object::id(&rel_cap).to_address());
    assert_eq!(t_count, 3);
    assert!(t_field_before);
    assert!(t_field_after);
    assert_eq!(t_idx, 1);
    assert_eq!(t_recording_id, rel.tracks()[1].recording_id().to_address());
    assert_eq!(t_composition_id, rel.tracks()[1].composition_id().to_address());

    test_scenario::return_shared(rel);

    // === Tx 3 (READER, owns nothing): resolution follows the override rule ===
    ts.next_tx(READER);
    let rel = ts.take_shared<Release>();
    assert_eq!(release_cover_art::track_cover(&rel, 0), option::some(album_art));
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::some(track1_art));
    assert_eq!(release_cover_art::track_cover(&rel, 2), option::some(album_art));
    test_scenario::return_shared(rel);

    // === Tx 4 (ADMIN): clear the track override, then the album cover ===
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    release_cover_art::unset_track_cover(&mut rel, &rel_cap, 1);
    // Track 1 falls back to the album cover now that its override is gone.
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::some(album_art));

    let track_unset_events = event::events_by_type<release_cover_art::ReleaseTrackCoverArtUnsetEvent>();
    assert_eq!(track_unset_events.length(), 1);
    let (u_rel_id, u_cap_id, u_count, u_field_before, u_field_after, u_idx, u_recording_id, u_composition_id) =
        release_cover_art::release_track_cover_art_unset_event_header(&track_unset_events[0]);
    assert_eq!(u_rel_id, rel_id);
    assert_eq!(u_cap_id, object::id(&rel_cap).to_address());
    assert_eq!(u_count, 3);
    assert!(u_field_before);
    assert!(u_field_after);
    assert_eq!(u_idx, 1);
    assert_eq!(u_recording_id, rel.tracks()[1].recording_id().to_address());
    assert_eq!(u_composition_id, rel.tracks()[1].composition_id().to_address());

    release_cover_art::unset_cover(&mut rel, &rel_cap);
    assert_eq!(release_cover_art::track_cover(&rel, 0), option::none());

    let cover_unset_events = event::events_by_type<release_cover_art::ReleaseCoverArtUnsetEvent>();
    assert_eq!(cover_unset_events.length(), 1);
    let (c_rel_id, c_cap_id, c_count, c_field_before, c_field_after) =
        release_cover_art::release_cover_art_unset_event_header(&cover_unset_events[0]);
    assert_eq!(c_rel_id, rel_id);
    assert_eq!(c_cap_id, object::id(&rel_cap).to_address());
    assert_eq!(c_count, 3);
    assert!(c_field_before);
    assert!(c_field_after);

    test_scenario::return_shared(rel);
    destroy(rel_cap);
    ts.end();
}

// === Adversarial: a stranger's unrelated cap ===

#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun set_cover_with_strangers_cap_aborts() {
    let mut ts = test_scenario::begin(ADMIN);
    let _admin_cap = setup_published_release(&mut ts);

    // === Tx 2 (STRANGER): owns a different release's cap, not this one's ===
    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = release::new_for_testing(
        b"Other".to_string(),
        mk_tracks(ts.ctx()),
        ts.ctx(),
    );
    let mut rel = ts.take_shared<Release>();
    release_cover_art::set_cover(&mut rel, &other_cap, cover::new_for_testing());
    abort
}

// Regression for the cap-gate-order finding: `unset_cover` checks the cap
// before checking attachment, so a stranger's cap aborts even when nothing
// is attached yet — the old existence-check-first code would have skipped
// the gate entirely and silently no-op'd.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun unset_cover_with_strangers_cap_aborts_when_unattached() {
    let mut ts = test_scenario::begin(ADMIN);
    let _admin_cap = setup_published_release(&mut ts);

    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = release::new_for_testing(
        b"Other".to_string(),
        mk_tracks(ts.ctx()),
        ts.ctx(),
    );
    let mut rel = ts.take_shared<Release>();
    release_cover_art::unset_cover(&mut rel, &other_cap);
    abort
}

#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun set_track_cover_with_strangers_cap_aborts() {
    let mut ts = test_scenario::begin(ADMIN);
    let _admin_cap = setup_published_release(&mut ts);

    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = release::new_for_testing(
        b"Other".to_string(),
        mk_tracks(ts.ctx()),
        ts.ctx(),
    );
    let mut rel = ts.take_shared<Release>();
    release_cover_art::set_track_cover(&mut rel, &other_cap, 0, cover::new_for_testing());
    abort
}

#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun unset_track_cover_with_strangers_cap_aborts_when_unattached() {
    let mut ts = test_scenario::begin(ADMIN);
    let _admin_cap = setup_published_release(&mut ts);

    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = release::new_for_testing(
        b"Other".to_string(),
        mk_tracks(ts.ctx()),
        ts.ctx(),
    );
    let mut rel = ts.take_shared<Release>();
    release_cover_art::unset_track_cover(&mut rel, &other_cap, 0);
    abort
}
