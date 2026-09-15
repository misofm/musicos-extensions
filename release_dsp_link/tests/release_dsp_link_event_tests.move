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
    let platforms = vector[0u8, 1, 1, 2, 2, 3, 4, 5, 6, 7];
    let mut i = 0;
    while (i < events.length()) {
        let (id, admin, platform, count, _, after, _, present) =
            links::release_link_set_event_fields(&events[i]);
        assert_eq!(id, object::id(&rel).to_address());
        assert_eq!(admin, object::id(&cap).to_address());
        assert_eq!(platform, platforms[i]);
        assert_eq!(count, 2);
        assert!(after && present);
        assert_eq!(sui::bcs::to_bytes(&events[i]).length(), 77);
        i = i + 1;
    };

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
    let (erid, eaid, p, count, before, after, index, recording, composition, previous, current, album) = links::track_link_set_event_fields(&events[0]);
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
    assert!(current);
    assert!(album);

    links::clear_track_link(&mut rel, &cap, platform, 1);
    let events = event::events_by_type<links::ReleaseTrackDspLinkClearedEvent>();
    let (_, _, _, _, before, after, _, _, _, previous, current, _) = links::track_link_cleared_event_fields(&events[0]);
    assert!(before);
    assert!(after);
    assert!(previous);
    assert!(!current);

    destroy(rel);
    destroy(cap);
}

#[test]
fun content_length_and_cleared_slot_count_do_not_inflate_events() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = release(ctx);
    let short = links::new_bandcamp(b"a".to_string(), b"b".to_string());
    let long_text = vector::tabulate!(128, |_| 97u8).to_string();
    let long = links::new_bandcamp(long_text, long_text);
    links::set_release_link(&mut rel, &cap, short);
    links::set_release_link(&mut rel, &cap, long);
    let albums = event::events_by_type<links::ReleaseDspLinkSetEvent>();
    assert_eq!(sui::bcs::to_bytes(&albums[0]).length(), 77);
    assert_eq!(sui::bcs::to_bytes(&albums[1]).length(), 77);
    links::set_track_link(&mut rel, &cap, 0, short);
    links::clear_track_links(&mut rel, &cap, links::platform_bandcamp());
    links::set_track_link(&mut rel, &cap, 0, long);
    links::set_track_link(&mut rel, &cap, 1, long);
    links::clear_track_links(&mut rel, &cap, links::platform_bandcamp());
    let tracks = event::events_by_type<links::ReleaseTrackDspLinkSetEvent>();
    assert_eq!(sui::bcs::to_bytes(&tracks[0]).length(), 150);
    assert_eq!(sui::bcs::to_bytes(&tracks[1]).length(), 150);
    let clears = event::events_by_type<links::ReleaseTrackDspLinksClearedEvent>();
    assert_eq!(sui::bcs::to_bytes(&clears[0]).length(), 84);
    assert_eq!(sui::bcs::to_bytes(&clears[1]).length(), 84);
    let (_, _, _, _, _, _, first_count, _) = links::track_links_cleared_event_fields(&clears[0]);
    let (_, _, _, _, _, _, second_count, _) = links::track_links_cleared_event_fields(&clears[1]);
    assert_eq!(first_count, 1);
    assert_eq!(second_count, 2);
    destroy(rel);
    destroy(cap);
}
