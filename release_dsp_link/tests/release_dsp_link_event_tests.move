// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_dsp_link::release_dsp_link_event_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_dsp_link::release_dsp_link as links;
use std::unit_test::{assert_eq, destroy};
use sui::event;

fun release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let comp = test_helpers::fake_id(ctx);
    let rec = test_helpers::fake_id(ctx);
    let rec2 = test_helpers::fake_id(ctx);
    let target = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(comp, rec, target, 5000u16),
        track::new_for_testing(comp, rec2, target, 5000u16),
    ];
    release::new_for_testing(b"Events".to_string(), tracks, ctx)
}

#[test]
fun set_event_projection_covers_every_variant_and_selector_shape() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = release(ctx);
    links::set_release_link(&mut rel, &cap, links::new_spotify(b"s".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_apple_music_album(b"us".to_string(), b"a".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_apple_music_track(b"gb".to_string(), b"b".to_string(), b"c".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_amazon_music_album(b"d".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_amazon_music_track(b"e".to_string(), b"f".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_bandcamp(b"artist".to_string(), b"slug".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_deezer(b"g".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_soundcloud(b"user".to_string(), b"h".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_tidal(b"i".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_youtube_music(b"j".to_string()));

    let events = event::events_by_type<links::ReleaseDspLinkSetEvent>();
    assert_eq!(events.length(), 10);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[0]);
    assert_eq!(fields, vector[b"s"]);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[1]);
    assert_eq!(fields, vector[b"us", b"a"]);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[2]);
    assert_eq!(fields, vector[b"gb", b"b", b"c"]);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[3]);
    assert_eq!(fields, vector[b"d"]);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[4]);
    assert_eq!(fields, vector[b"e", b"f"]);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[5]);
    assert_eq!(fields, vector[b"artist", b"slug"]);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[6]);
    assert_eq!(fields, vector[b"g"]);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[7]);
    assert_eq!(fields, vector[b"user", b"h"]);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[8]);
    assert_eq!(fields, vector[b"i"]);
    let (_, _, _, _, _, _, _, _, _, fields) = links::release_link_set_event_fields(&events[9]);
    assert_eq!(fields, vector[b"j"]);

    destroy(rel);
    destroy(cap);
}

#[test]
fun track_events_snapshot_override_album_and_track_identity() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = release(ctx);
    let rid = object::id(&rel).to_address();
    let aid = object::id(&cap).to_address();
    let platform = links::platform_tidal();
    links::set_release_link(&mut rel, &cap, links::new_tidal(b"album".to_string()));
    links::set_track_link(&mut rel, &cap, 1, links::new_tidal(b"track".to_string()));

    let events = event::events_by_type<links::ReleaseTrackDspLinkSetEvent>();
    let (erid, eaid, p, count, before, after, index, recording, composition, previous, previous_fields, current, current_fields, album, album_fields) =
        links::track_link_set_event_fields(&events[0]);
    assert_eq!(erid, rid);
    assert_eq!(eaid, aid);
    assert_eq!(p, platform);
    assert_eq!(count, 2);
    assert!(!before);
    assert!(after);
    assert_eq!(index, 1);
    assert_eq!(recording, track::recording_id(&rel.tracks()[1]).to_address());
    assert_eq!(composition, track::composition_id(&rel.tracks()[1]).to_address());
    assert!(!previous);
    assert_eq!(previous_fields, vector[]);
    assert!(current);
    assert_eq!(current_fields, vector[b"track"]);
    assert!(album);
    assert_eq!(album_fields, vector[b"album"]);

    links::clear_track_link(&mut rel, &cap, platform, 1);
    let events = event::events_by_type<links::ReleaseTrackDspLinkClearedEvent>();
    let (_, _, _, _, before, after, _, _, _, previous, previous_fields, current, current_fields, _, _) =
        links::track_link_cleared_event_fields(&events[0]);
    assert!(before);
    assert!(after);
    assert!(previous);
    assert_eq!(previous_fields, vector[b"track"]);
    assert!(!current);
    assert_eq!(current_fields, vector[]);

    destroy(rel);
    destroy(cap);
}
