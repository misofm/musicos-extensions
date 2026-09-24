// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenarios for `release_cover_art` under `sui::test_scenario`:
/// the release is created and published (shared) in one admin transaction —
/// core's create-and-publish is atomic in production — then the extension
/// operates on the shared object via `take_shared` across later
/// transactions. Distinct senders prove the cap gate: the admin's own cap
/// succeeds, a stranger holding an unrelated release's cap aborts, and public
/// reads are open to anyone.
#[test_only]
module release_cover_art::cover_art_e2e_tests;

use cover_art::cover_art as cover;
use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::track::{Self, Track};
use release_cover_art::cover_art_fixtures as fixtures;
use release_cover_art::release_cover_art::{
    Self,
    ReleaseCoverArtSetEvent,
    ReleaseCoverArtClearedEvent,
    ReleaseTrackCoverArtSetEvent,
    ReleaseTrackCoverArtClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;
use sui::test_scenario::{Self as ts, Scenario};

// ADMIN holds the release admin cap and performs every cap-gated write.
// READER owns nothing and proves the views are open to anyone. STRANGER
// holds a *different* release's admin cap and proves the cap gate rejects
// it against ADMIN's release.
const ADMIN: address = @0xAD;
const READER: address = @0xFA;
const STRANGER: address = @0x51;

// A 3-track tracklist. `release::new_for_testing` retargets every track at
// the release it constructs, so the placeholder id never needs to predict
// anything.
fun mk_tracks(): vector<Track> {
    let placeholder = object::id_from_address(@0xB0B);
    vector[
        track::new_for_testing(object::id_from_address(@0xA0), placeholder, 4000u16),
        track::new_for_testing(object::id_from_address(@0xA1), placeholder, 3000u16),
        track::new_for_testing(object::id_from_address(@0xA2), placeholder, 3000u16),
    ]
}

// Creates, publishes, and shares a 3-track release as the scenario's current
// sender, returning its admin cap.
fun setup_published_release(ts: &mut Scenario): ReleaseAdminCap {
    let (rel, rel_cap) = release::new_for_testing(mk_tracks(), ts.ctx());
    rel.publish(&rel_cap); // shares the release
    rel_cap
}

/// The flagship path: ADMIN publishes the release, attaches an album cover
/// and a track override, a disinterested READER resolves the effective cover
/// for every track, and ADMIN then clears the override and the album cover —
/// all against the shared object, across four transactions, with exact event
/// payload assertions at each write.
/// Event fields, compared one at a time.
fun assert_set_event(
    e: &ReleaseCoverArtSetEvent,
    release_id: address,
    still_blob_id: u256,
    animated_blob_id: Option<u256>,
) {
    let (event_release_id, event_still, event_animated) = release_cover_art::set_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_still, still_blob_id);
    assert_eq!(event_animated, animated_blob_id);
}

fun assert_track_set_event(
    e: &ReleaseTrackCoverArtSetEvent,
    release_id: address,
    track_index: u64,
    still_blob_id: u256,
    animated_blob_id: Option<u256>,
) {
    let (event_release_id, event_index, event_still, event_animated) =
        release_cover_art::track_set_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_index, track_index);
    assert_eq!(event_still, still_blob_id);
    assert_eq!(event_animated, animated_blob_id);
}

fun assert_track_cleared_event(
    e: &ReleaseTrackCoverArtClearedEvent,
    release_id: address,
    track_index: u64,
) {
    let (event_release_id, event_index) = release_cover_art::track_cleared_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_index, track_index);
}

#[test]
fun cover_art_lifecycle_against_published_shared_release() {
    let mut ts = ts::begin(ADMIN);
    let rel_cap = setup_published_release(&mut ts);

    // === Tx 2 (ADMIN): attach the album cover and a track override ===
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    let rel_id = object::id(&rel).to_address();
    assert!(!release_cover_art::has_cover_art(&rel));

    let album_art = fixtures::plain(100);
    release_cover_art::set_cover(&mut rel, &rel_cap, album_art);
    assert!(release_cover_art::has_cover_art(&rel));
    assert_eq!(*release_cover_art::cover(&rel), option::some(album_art));

    let set_cover_events = events_by_type<ReleaseCoverArtSetEvent>();
    assert_eq!(set_cover_events.length(), 1);
    assert_set_event(&set_cover_events[0], rel_id, 100, option::none());
    assert_eq!(to_bytes(&set_cover_events[0]).length(), 65);

    let track1_art = fixtures::plain(200);
    release_cover_art::set_track_cover(&mut rel, &rel_cap, 1, track1_art);

    let track_set_events = events_by_type<ReleaseTrackCoverArtSetEvent>();
    assert_eq!(track_set_events.length(), 1);
    assert_track_set_event(&track_set_events[0], rel_id, 1, 200, option::none());
    assert_eq!(to_bytes(&track_set_events[0]).length(), 73);
    ts::return_shared(rel);

    // === Tx 3 (READER, owns nothing): resolution follows the override rule ===
    ts.next_tx(READER);
    let rel = ts.take_shared<Release>();
    assert_eq!(release_cover_art::track_cover(&rel, 0), option::some(album_art));
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::some(track1_art));
    assert_eq!(release_cover_art::track_cover(&rel, 2), option::some(album_art));
    ts::return_shared(rel);

    // === Tx 4 (ADMIN): equal sets are silent; clear the override, then the
    // album cover ===
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    release_cover_art::set_cover(&mut rel, &rel_cap, album_art);
    release_cover_art::set_track_cover(&mut rel, &rel_cap, 1, track1_art);
    assert_eq!(events_by_type<ReleaseCoverArtSetEvent>().length(), 0);
    assert_eq!(events_by_type<ReleaseTrackCoverArtSetEvent>().length(), 0);

    release_cover_art::clear_track_cover(&mut rel, &rel_cap, 1);
    // Track 1 falls back to the album cover now that its override is gone.
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::some(album_art));

    let track_cleared = events_by_type<ReleaseTrackCoverArtClearedEvent>();
    assert_eq!(track_cleared.length(), 1);
    assert_track_cleared_event(&track_cleared[0], rel_id, 1);
    assert_eq!(to_bytes(&track_cleared[0]).length(), 40);

    release_cover_art::clear_cover(&mut rel, &rel_cap);
    assert_eq!(release_cover_art::track_cover(&rel, 0), option::none());

    let cover_cleared = events_by_type<ReleaseCoverArtClearedEvent>();
    assert_eq!(cover_cleared.length(), 1);
    assert_eq!(release_cover_art::cleared_event_fields(&cover_cleared[0]), rel_id);
    assert_eq!(to_bytes(&cover_cleared[0]).length(), 32);
    ts::return_shared(rel);

    // === Tx 5 (READER): the cleared state is visible to anyone ===
    ts.next_tx(READER);
    let rel = ts.take_shared<Release>();
    assert!(release_cover_art::has_cover_art(&rel));
    assert!(release_cover_art::cover(&rel).is_none());
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::none());
    ts::return_shared(rel);

    destroy(rel_cap);
    ts.end();
}

// === Adversarial: a stranger's unrelated cap ===

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun set_cover_with_strangers_cap_aborts() {
    let mut ts = ts::begin(ADMIN);
    let _admin_cap = setup_published_release(&mut ts);

    // === Tx 2 (STRANGER): owns a different release's cap, not this one's ===
    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = release::new_for_testing(mk_tracks(), ts.ctx());
    let mut rel = ts.take_shared<Release>();
    release_cover_art::set_cover(&mut rel, &other_cap, cover::new_for_testing());
    abort
}

// The cap gate precedes the attachment check: a stranger's cap aborts even
// when nothing is attached, where the admin's own cap would silently no-op.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun clear_cover_with_strangers_cap_aborts_when_unattached() {
    let mut ts = ts::begin(ADMIN);
    let _admin_cap = setup_published_release(&mut ts);

    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = release::new_for_testing(mk_tracks(), ts.ctx());
    let mut rel = ts.take_shared<Release>();
    release_cover_art::clear_cover(&mut rel, &other_cap);
    abort
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun set_track_cover_with_strangers_cap_aborts() {
    let mut ts = ts::begin(ADMIN);
    let _admin_cap = setup_published_release(&mut ts);

    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = release::new_for_testing(mk_tracks(), ts.ctx());
    let mut rel = ts.take_shared<Release>();
    release_cover_art::set_track_cover(&mut rel, &other_cap, 0, cover::new_for_testing());
    abort
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun clear_track_cover_with_strangers_cap_aborts_when_unattached() {
    let mut ts = ts::begin(ADMIN);
    let _admin_cap = setup_published_release(&mut ts);

    ts.next_tx(STRANGER);
    let (_other_rel, other_cap) = release::new_for_testing(mk_tracks(), ts.ctx());
    let mut rel = ts.take_shared<Release>();
    release_cover_art::clear_track_cover(&mut rel, &other_cap, 0);
    abort
}
