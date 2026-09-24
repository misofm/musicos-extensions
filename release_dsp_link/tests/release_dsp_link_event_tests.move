// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Event payload tests: every variant and selector shape is carried verbatim
/// in the set events, and every event's BCS size is pinned at its bound.
#[test_only]
module release_dsp_link::release_dsp_link_event_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_dsp_link::release_dsp_link as links;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

fun release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let rec = test_helpers::fake_id(ctx);
    let rec2 = test_helpers::fake_id(ctx);
    let target = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(rec, target, 5000u16),
        track::new_for_testing(rec2, target, 5000u16),
    ];
    release::new_for_testing(tracks, ctx)
}

/// Every variant, including both selector shapes of Apple Music and Amazon
/// Music, round-trips through the set event: the layout is `release_id`
/// (32) then the link's own BCS encoding, whose variant names the platform.
#[test]
fun set_event_carries_every_variant_and_selector_shape() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = release(ctx);
    let release_id = object::id(&rel).to_address();
    let all = vector[
        links::new_spotify(b"s".to_string()),
        links::new_apple_music_album(b"us".to_string(), b"a".to_string()),
        links::new_apple_music_track(b"gb".to_string(), b"b".to_string(), b"c".to_string()),
        links::new_amazon_music_album(b"d".to_string()),
        links::new_amazon_music_track(b"e".to_string(), b"f".to_string()),
        links::new_bandcamp(b"artist".to_string(), b"slug".to_string()),
        links::new_deezer(b"g".to_string()),
        links::new_soundcloud(b"user".to_string(), b"h".to_string()),
        links::new_tidal(b"i".to_string()),
        links::new_youtube_music(b"j".to_string()),
    ];
    all.do_ref!(|link| links::set_release_link(&mut rel, &cap, *link));

    let events = event::events_by_type<links::ReleaseDspLinkSetEvent>();
    assert_eq!(events.length(), 10);
    let mut i = 0;
    while (i < events.length()) {
        let (id, link) = links::release_link_set_event_fields(&events[i]);
        assert_eq!(id, release_id);
        assert_eq!(link, all[i]);
        let mut expected = bcs::to_bytes(&release_id);
        expected.append(bcs::to_bytes(&all[i]));
        assert_eq!(bcs::to_bytes(&events[i]), expected);
        i = i + 1;
    };

    destroy(rel);
    destroy(cap);
}

/// The set event grows with the link it carries, up to a fixed bound: the
/// widest link is a 128-byte handle plus a 128-byte slug (261 BCS bytes), so
/// an album set event is at most 293 bytes and a track set event at most 301.
/// Clear events are fixed-size: 33 (album and bulk) and 41 (track).
#[test]
fun event_sizes_are_bounded_by_the_widest_link() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = release(ctx);
    let bandcamp = links::platform_bandcamp();
    let short = links::new_bandcamp(b"a".to_string(), b"b".to_string());
    let long_text = vector::tabulate!(128, |_| 97u8).to_string();
    let long = links::new_bandcamp(long_text, long_text);
    assert_eq!(bcs::to_bytes(&long).length(), 261);

    links::set_release_link(&mut rel, &cap, short);
    links::set_release_link(&mut rel, &cap, long);
    links::clear_release_link(&mut rel, &cap, bandcamp);
    let albums = event::events_by_type<links::ReleaseDspLinkSetEvent>();
    assert_eq!(bcs::to_bytes(&albums[0]).length(), 37);
    assert_eq!(bcs::to_bytes(&albums[1]).length(), 293);
    let cleared = event::events_by_type<links::ReleaseDspLinkClearedEvent>();
    assert_eq!(bcs::to_bytes(&cleared[0]).length(), 33);

    links::set_track_link(&mut rel, &cap, 0, short);
    links::set_track_link(&mut rel, &cap, 1, long);
    links::clear_track_link(&mut rel, &cap, bandcamp, 0);
    links::clear_track_links(&mut rel, &cap, bandcamp);
    let tracks = event::events_by_type<links::ReleaseTrackDspLinkSetEvent>();
    assert_eq!(bcs::to_bytes(&tracks[0]).length(), 45);
    assert_eq!(bcs::to_bytes(&tracks[1]).length(), 301);
    let track_cleared = event::events_by_type<links::ReleaseTrackDspLinkClearedEvent>();
    assert_eq!(bcs::to_bytes(&track_cleared[0]).length(), 41);
    let bulk = event::events_by_type<links::ReleaseTrackDspLinksClearedEvent>();
    assert_eq!(bcs::to_bytes(&bulk[0]).length(), 33);

    destroy(rel);
    destroy(cap);
}

/// The widest Apple Music link (three 64-byte identifiers) stays under the
/// Bandcamp/SoundCloud bound.
#[test]
fun apple_music_track_link_is_narrower_than_the_bound() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = release(ctx);
    let id_64 = vector::tabulate!(64, |_| 97u8).to_string();
    let link = links::new_apple_music_track(id_64, id_64, id_64);
    assert_eq!(bcs::to_bytes(&link).length(), 197);

    links::set_track_link(&mut rel, &cap, 1, link);
    let tracks = event::events_by_type<links::ReleaseTrackDspLinkSetEvent>();
    assert_eq!(bcs::to_bytes(&tracks[0]).length(), 237);

    destroy(rel);
    destroy(cap);
}

/// An event-only projection of the per-track slots for one platform matches
/// storage after every transition, including the bulk clear.
#[test]
fun track_events_replay_to_storage() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = release(ctx);
    let tidal = links::platform_tidal();
    let a = links::new_tidal(b"a".to_string());
    let b = links::new_tidal(b"b".to_string());

    links::set_track_link(&mut rel, &cap, 0, a);
    links::set_track_link(&mut rel, &cap, 1, a);
    links::set_track_link(&mut rel, &cap, 1, b);
    links::clear_track_link(&mut rel, &cap, tidal, 0);
    links::set_track_link(&mut rel, &cap, 0, b);
    links::clear_track_links(&mut rel, &cap, tidal);
    links::set_track_link(&mut rel, &cap, 1, a);

    let mut projected = vector[option::none<links::DspLinkData>(), option::none()];
    let sets = event::events_by_type<links::ReleaseTrackDspLinkSetEvent>();
    let clears = event::events_by_type<links::ReleaseTrackDspLinkClearedEvent>();
    let bulk = event::events_by_type<links::ReleaseTrackDspLinksClearedEvent>();
    assert_eq!(sets.length(), 5);
    assert_eq!(clears.length(), 1);
    assert_eq!(bulk.length(), 1);

    // Replay in emission order: sets 0..4 with the single clear after set 2
    // and the bulk clear after set 3.
    let (_, index, link) = links::track_link_set_event_fields(&sets[0]);
    *&mut projected[index] = option::some(link);
    let (_, index, link) = links::track_link_set_event_fields(&sets[1]);
    *&mut projected[index] = option::some(link);
    let (_, index, link) = links::track_link_set_event_fields(&sets[2]);
    *&mut projected[index] = option::some(link);
    let (_, _, index) = links::track_link_cleared_event_fields(&clears[0]);
    *&mut projected[index] = option::none();
    let (_, index, link) = links::track_link_set_event_fields(&sets[3]);
    *&mut projected[index] = option::some(link);
    let (_, platform) = links::track_links_cleared_event_fields(&bulk[0]);
    assert_eq!(platform, tidal);
    projected = vector[option::none(), option::none()];
    let (_, index, link) = links::track_link_set_event_fields(&sets[4]);
    *&mut projected[index] = option::some(link);

    assert_eq!(projected[0], links::track_link(&rel, tidal, 0));
    assert_eq!(projected[1], links::track_link(&rel, tidal, 1));
    assert!(projected[0].is_none());
    assert_eq!(projected[1].destroy_some(), a);

    destroy(rel);
    destroy(cap);
}
