// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage: constructor validation (every error const), bounds, view
/// fallback semantics, platform mapping, guard order, and event payloads.
/// `ReleaseAdminCap` authorization is bound to the release's id at runtime
/// (`uid_mut` calls `authorize`), not to a sender, so single-transaction
/// `tx_context::dummy()` tests exercise the real authorization logic. The
/// production shape — create → publish → share → operate via `take_shared`
/// across transactions and senders — is covered in
/// `release_dsp_link_e2e_tests.move`.
#[test_only]
module release_dsp_link::release_dsp_link_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_dsp_link::release_dsp_link as links;
use std::string::String;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;
use sui::test_scenario;

const A: address = @0xA1;

// A 3-track release: flat tracklist indices 0, 1, 2. `new_for_testing`
// retargets every track at the freshly-minted release, so the placeholder
// target passed here never surfaces.
fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let rel_id = test_helpers::fake_id(ctx);
    let r0 = test_helpers::fake_id(ctx);
    let r1 = test_helpers::fake_id(ctx);
    let r2 = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(r0, rel_id, 4000u16),
        track::new_for_testing(r1, rel_id, 3000u16),
        track::new_for_testing(r2, rel_id, 3000u16),
    ];
    release::new_for_testing(tracks, ctx)
}

/// 65 'a' bytes — one over every 64-byte id bound.
fun overlong_64(): String { vector::tabulate!(65, |_| 97u8).to_string() }

/// 129 'a' bytes — one over the 128-byte handle/slug bound.
fun overlong_128(): String { vector::tabulate!(129, |_| 97u8).to_string() }

/// Asserts an album set event's fields and exact BCS layout: `release_id`
/// (32), then the link's own BCS encoding.
fun assert_release_link_set(
    e: &links::ReleaseDspLinkSetEvent,
    release_id: address,
    link: links::DspLinkData,
) {
    let (event_release_id, event_link) = links::release_link_set_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_link, link);

    let mut expected = bcs::to_bytes(&release_id);
    expected.append(bcs::to_bytes(&link));
    assert_eq!(bcs::to_bytes(e), expected);
}

/// Asserts an album cleared event's fields and exact 33-byte BCS layout.
fun assert_release_link_cleared(
    e: &links::ReleaseDspLinkClearedEvent,
    release_id: address,
    platform: links::Platform,
) {
    let (event_release_id, event_platform) = links::release_link_cleared_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_platform, platform);

    let mut expected = bcs::to_bytes(&release_id);
    expected.append(bcs::to_bytes(&platform));
    assert_eq!(bcs::to_bytes(e), expected);
    assert_eq!(expected.length(), 33);
}

/// Asserts a track set event's fields and exact BCS layout: `release_id`
/// (32), `track_index` (8), then the link's own encoding.
fun assert_track_link_set(
    e: &links::ReleaseTrackDspLinkSetEvent,
    release_id: address,
    track_index: u64,
    link: links::DspLinkData,
) {
    let (event_release_id, event_index, event_link) = links::track_link_set_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_index, track_index);
    assert_eq!(event_link, link);

    let mut expected = bcs::to_bytes(&release_id);
    expected.append(bcs::to_bytes(&track_index));
    expected.append(bcs::to_bytes(&link));
    assert_eq!(bcs::to_bytes(e), expected);
}

/// Asserts a track cleared event's fields and exact 41-byte BCS layout.
fun assert_track_link_cleared(
    e: &links::ReleaseTrackDspLinkClearedEvent,
    release_id: address,
    platform: links::Platform,
    track_index: u64,
) {
    let (event_release_id, event_platform, event_index) = links::track_link_cleared_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_platform, platform);
    assert_eq!(event_index, track_index);

    let mut expected = bcs::to_bytes(&release_id);
    expected.append(bcs::to_bytes(&platform));
    expected.append(bcs::to_bytes(&track_index));
    assert_eq!(bcs::to_bytes(e), expected);
    assert_eq!(expected.length(), 41);
}

/// Asserts a bulk cleared event's fields and exact 33-byte BCS layout.
fun assert_track_links_cleared(
    e: &links::ReleaseTrackDspLinksClearedEvent,
    release_id: address,
    platform: links::Platform,
) {
    let (event_release_id, event_platform) = links::track_links_cleared_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_platform, platform);

    let mut expected = bcs::to_bytes(&release_id);
    expected.append(bcs::to_bytes(&platform));
    assert_eq!(bcs::to_bytes(e), expected);
    assert_eq!(expected.length(), 33);
}

// === Album-level Link Lifecycle ===

#[test]
fun album_link_set_replace_clear_is_independent_per_platform() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());
    let release_id = object::id(&rel).to_address();
    let spotify = links::platform_spotify();
    let tidal = links::platform_tidal();
    let first = links::new_spotify(b"3xTbtTM3BSRIGxzWSMaEpc".to_string());
    let second = links::new_spotify(b"6rqhFgbbKwnb9MLmUQDhG6".to_string());
    let tidal_link = links::new_tidal(b"12345".to_string());

    assert!(!links::has_release_link(&rel, spotify));
    assert!(links::release_link(&rel, spotify).is_none());

    links::set_release_link(&mut rel, &cap, first);
    links::set_release_link(&mut rel, &cap, tidal_link);

    assert!(links::has_release_link(&rel, spotify));
    assert!(links::has_release_link(&rel, tidal));
    assert_eq!(links::release_link(&rel, spotify).destroy_some(), first);
    assert_eq!(links::release_link(&rel, tidal).destroy_some(), tidal_link);

    let set_events = event::events_by_type<links::ReleaseDspLinkSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_release_link_set(&set_events[0], release_id, first);
    assert_release_link_set(&set_events[1], release_id, tidal_link);

    // An equal replacement is silent.
    links::set_release_link(&mut rel, &cap, first);
    assert_eq!(event::events_by_type<links::ReleaseDspLinkSetEvent>().length(), 2);

    // Replacing Spotify's link leaves Tidal's untouched.
    links::set_release_link(&mut rel, &cap, second);
    assert_eq!(links::release_link(&rel, spotify).destroy_some(), second);
    assert_eq!(links::release_link(&rel, tidal).destroy_some(), tidal_link);

    let set_events = event::events_by_type<links::ReleaseDspLinkSetEvent>();
    assert_eq!(set_events.length(), 3);
    assert_release_link_set(&set_events[2], release_id, second);

    // Clearing Spotify leaves Tidal untouched.
    links::clear_release_link(&mut rel, &cap, spotify);
    assert!(!links::has_release_link(&rel, spotify));
    assert!(links::has_release_link(&rel, tidal));

    let cleared_events = event::events_by_type<links::ReleaseDspLinkClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_release_link_cleared(&cleared_events[0], release_id, spotify);

    // Clearing again is silent.
    links::clear_release_link(&mut rel, &cap, spotify);
    assert_eq!(event::events_by_type<links::ReleaseDspLinkClearedEvent>().length(), 1);

    destroy(rel);
    destroy(cap);
    ts.end();
}

#[test]
fun clear_release_link_is_a_no_op_when_unset() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());

    let events_before = event::num_events();
    links::clear_release_link(&mut rel, &cap, links::platform_deezer());
    assert!(!links::has_release_link(&rel, links::platform_deezer()));
    assert_eq!(event::num_events(), events_before);

    destroy(rel);
    destroy(cap);
    ts.end();
}

/// Setting the album link already stored neither emits nor changes it.
#[test]
fun equal_release_link_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let link = links::new_youtube_music(b"PLx".to_string());

    links::set_release_link(&mut rel, &cap, link);
    let events_after_first = event::num_events();
    links::set_release_link(&mut rel, &cap, link);
    assert_eq!(event::num_events(), events_after_first);
    assert_eq!(links::release_link(&rel, links::platform_youtube_music()).destroy_some(), link);

    let set_events = event::events_by_type<links::ReleaseDspLinkSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_release_link_set(&set_events[0], release_id, link);

    destroy(rel);
    destroy(cap);
}

// === Per-track Link Lifecycle ===

#[test]
fun track_link_set_replace_clear_lifecycle() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());
    let release_id = object::id(&rel).to_address();
    let bandcamp = links::platform_bandcamp();
    let first = links::new_bandcamp(b"anartist".to_string(), b"a-track".to_string());
    let second = links::new_bandcamp(b"anartist".to_string(), b"b-track".to_string());

    // No array yet: every index reads none, not an abort.
    assert!(links::track_link(&rel, bandcamp, 0).is_none());

    links::set_track_link(&mut rel, &cap, 1, first);
    assert_eq!(links::track_link(&rel, bandcamp, 1).destroy_some(), first);
    assert!(links::track_link(&rel, bandcamp, 0).is_none());
    assert!(links::track_link(&rel, bandcamp, 2).is_none());

    // Setting again on the same slot replaces.
    links::set_track_link(&mut rel, &cap, 1, second);
    assert_eq!(links::track_link(&rel, bandcamp, 1).destroy_some(), second);
    let set_events = event::events_by_type<links::ReleaseTrackDspLinkSetEvent>();
    assert_eq!(set_events.length(), 2);
    assert_track_link_set(&set_events[0], release_id, 1, first);
    assert_track_link_set(&set_events[1], release_id, 1, second);

    // An equal replacement is silent.
    links::set_track_link(&mut rel, &cap, 1, second);
    assert_eq!(event::events_by_type<links::ReleaseTrackDspLinkSetEvent>().length(), 2);

    // Clearing the slot resets it to none; other slots and other platforms are
    // unaffected.
    links::clear_track_link(&mut rel, &cap, bandcamp, 1);
    assert!(links::track_link(&rel, bandcamp, 1).is_none());
    let cleared_events = event::events_by_type<links::ReleaseTrackDspLinkClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_track_link_cleared(&cleared_events[0], release_id, bandcamp, 1);

    // Clearing an already-empty slot is silent.
    links::clear_track_link(&mut rel, &cap, bandcamp, 1);
    assert_eq!(event::events_by_type<links::ReleaseTrackDspLinkClearedEvent>().length(), 1);

    destroy(rel);
    destroy(cap);
    ts.end();
}

#[test]
fun clear_track_link_is_a_no_op_when_no_array_exists() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());

    let events_before = event::num_events();
    links::clear_track_link(&mut rel, &cap, links::platform_soundcloud(), 0);
    assert!(links::track_link(&rel, links::platform_soundcloud(), 0).is_none());
    assert_eq!(event::num_events(), events_before);

    destroy(rel);
    destroy(cap);
    ts.end();
}

/// Setting the track link already stored neither emits nor changes it.
#[test]
fun equal_track_link_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let link = links::new_deezer(b"77".to_string());

    links::set_track_link(&mut rel, &cap, 2, link);
    let events_after_first = event::num_events();
    links::set_track_link(&mut rel, &cap, 2, link);
    assert_eq!(event::num_events(), events_after_first);
    assert_eq!(links::track_link(&rel, links::platform_deezer(), 2).destroy_some(), link);

    let set_events = event::events_by_type<links::ReleaseTrackDspLinkSetEvent>();
    assert_eq!(set_events.length(), 1);
    assert_track_link_set(&set_events[0], release_id, 2, link);

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_track_links_removes_the_whole_array() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());
    let release_id = object::id(&rel).to_address();
    let deezer = links::platform_deezer();

    links::set_track_link(&mut rel, &cap, 0, links::new_deezer(b"10".to_string()));
    links::set_track_link(&mut rel, &cap, 2, links::new_deezer(b"12".to_string()));

    links::clear_track_links(&mut rel, &cap, deezer);

    // The array is gone: previously-set slots read none again.
    assert!(links::track_link(&rel, deezer, 0).is_none());
    assert!(links::track_link(&rel, deezer, 2).is_none());
    let cleared_events = event::events_by_type<links::ReleaseTrackDspLinksClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_track_links_cleared(&cleared_events[0], release_id, deezer);

    // A second bulk clear is a silent no-op.
    links::clear_track_links(&mut rel, &cap, deezer);
    assert_eq!(event::events_by_type<links::ReleaseTrackDspLinksClearedEvent>().length(), 1);

    // Reclaiming an attached all-empty array is also silent.
    links::set_track_link(&mut rel, &cap, 0, links::new_deezer(b"10".to_string()));
    links::clear_track_link(&mut rel, &cap, deezer, 0);
    links::clear_track_links(&mut rel, &cap, deezer);
    assert_eq!(event::events_by_type<links::ReleaseTrackDspLinksClearedEvent>().length(), 1);

    destroy(rel);
    destroy(cap);
    ts.end();
}

// === Bounds ===

#[test, expected_failure(abort_code = links::ETrackIndexOutOfBounds)]
fun set_track_link_rejects_out_of_bounds() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx); // 3 tracks → index 3 is invalid
    links::set_track_link(&mut rel, &cap, 3, links::new_deezer(b"1".to_string()));
    abort
}

#[test, expected_failure(abort_code = links::ETrackIndexOutOfBounds)]
fun clear_track_link_rejects_out_of_bounds_when_array_exists() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    links::set_track_link(&mut rel, &cap, 0, links::new_deezer(b"1".to_string()));
    links::clear_track_link(&mut rel, &cap, links::platform_deezer(), 3);
    abort
}

#[test]
fun clear_track_link_out_of_bounds_is_fine_when_no_array_exists() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    // The absent-array no-op precedes the bounds check, so an absent array
    // never aborts on a bad index.
    links::clear_track_link(&mut rel, &cap, links::platform_deezer(), 99);
    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = links::ETrackIndexOutOfBounds)]
fun track_link_view_rejects_out_of_bounds_when_array_exists() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    links::set_track_link(&mut rel, &cap, 0, links::new_deezer(b"1".to_string()));
    let _ = links::track_link(&rel, links::platform_deezer(), 3);
    abort
}

// === View Fallback Semantics ===

#[test]
fun views_read_none_when_nothing_is_stored() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = mk_release(ctx);

    assert!(!links::has_release_link(&rel, links::platform_spotify()));
    assert!(links::release_link(&rel, links::platform_spotify()).is_none());
    assert!(links::track_link(&rel, links::platform_spotify(), 0).is_none());

    destroy(rel);
    destroy(cap);
}

// === Platform Mapping ===

/// Each constructor's link reports the matching `Platform`, and the two
/// enums share one variant order: a link's BCS tag is its platform's tag.
#[test]
fun platform_matches_declared_variant_order() {
    let all = vector[
        links::new_spotify(b"x".to_string()),
        links::new_apple_music_album(b"us".to_string(), b"x".to_string()),
        // The track-selector constructors are a distinct success branch (they
        // populate `track_id: option::some(..)`), so exercise both.
        links::new_apple_music_track(b"us".to_string(), b"1".to_string(), b"2".to_string()),
        links::new_amazon_music_album(b"x".to_string()),
        links::new_amazon_music_track(b"1".to_string(), b"2".to_string()),
        links::new_bandcamp(b"x".to_string(), b"y".to_string()),
        links::new_deezer(b"x".to_string()),
        links::new_soundcloud(b"x".to_string(), b"y".to_string()),
        links::new_tidal(b"x".to_string()),
        links::new_youtube_music(b"x".to_string()),
    ];
    let platforms = vector[
        links::platform_spotify(),
        links::platform_apple_music(),
        links::platform_apple_music(),
        links::platform_amazon_music(),
        links::platform_amazon_music(),
        links::platform_bandcamp(),
        links::platform_deezer(),
        links::platform_soundcloud(),
        links::platform_tidal(),
        links::platform_youtube_music(),
    ];
    let mut i = 0;
    while (i < all.length()) {
        assert_eq!(all[i].platform(), platforms[i]);
        let tag = bcs::to_bytes(&platforms[i]);
        assert_eq!(tag.length(), 1);
        assert_eq!(tag[0], bcs::to_bytes(&all[i])[0]);
        i = i + 1;
    };
}

// === Authorization ===

/// A `Release` binds its cap at runtime (`uid_mut` calls `authorize`), so a
/// foreign cap is testable here — unlike the type-bound recording caps.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun another_releases_cap_is_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut a, _a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    links::set_release_link(&mut a, &b_cap, links::new_spotify(b"x".to_string()));

    destroy(a);
    destroy(_a_cap);
    destroy(b);
    destroy(b_cap);
}

/// Event suppression for an equal value must not bypass the release's
/// authorization gate.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun equal_release_link_still_requires_the_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut release, release_cap) = mk_release(ctx);
    let (_foreign_release, foreign_cap) = mk_release(ctx);

    links::set_release_link(&mut release, &release_cap, links::new_spotify(b"same".to_string()));
    links::set_release_link(&mut release, &foreign_cap, links::new_spotify(b"same".to_string()));
    abort
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun equal_track_link_still_requires_the_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut release, release_cap) = mk_release(ctx);
    let (_foreign_release, foreign_cap) = mk_release(ctx);

    links::set_track_link(&mut release, &release_cap, 0, links::new_spotify(b"same".to_string()));
    links::set_track_link(&mut release, &foreign_cap, 0, links::new_spotify(b"same".to_string()));
    abort
}

/// The cap check precedes the tracklist bounds check, so a foreign cap
/// observes `EUnauthorized`, never `ETrackIndexOutOfBounds`.
#[test, expected_failure(abort_code = release::EUnauthorized)]
fun wrong_cap_precedes_out_of_bounds_on_set_track_link() {
    let ctx = &mut tx_context::dummy();
    let (mut release, _release_cap) = mk_release(ctx);
    let (_foreign_release, foreign_cap) = mk_release(ctx);

    links::set_track_link(&mut release, &foreign_cap, 99, links::new_spotify(b"x".to_string()));
    abort
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun wrong_cap_precedes_out_of_bounds_on_clear_track_link() {
    let ctx = &mut tx_context::dummy();
    let (mut release, release_cap) = mk_release(ctx);
    let (_foreign_release, foreign_cap) = mk_release(ctx);

    links::set_track_link(&mut release, &release_cap, 0, links::new_spotify(b"x".to_string()));
    links::clear_track_link(&mut release, &foreign_cap, links::platform_spotify(), 99);
    abort
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun clear_release_link_requires_the_cap_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (mut release, _release_cap) = mk_release(ctx);
    let (_foreign_release, foreign_cap) = mk_release(ctx);

    links::clear_release_link(&mut release, &foreign_cap, links::platform_spotify());
    abort
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun clear_track_link_requires_the_cap_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (mut release, _release_cap) = mk_release(ctx);
    let (_foreign_release, foreign_cap) = mk_release(ctx);

    links::clear_track_link(&mut release, &foreign_cap, links::platform_spotify(), 0);
    abort
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun clear_track_links_requires_the_cap_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (mut release, _release_cap) = mk_release(ctx);
    let (_foreign_release, foreign_cap) = mk_release(ctx);

    links::clear_track_links(&mut release, &foreign_cap, links::platform_spotify());
    abort
}

// === Constructor Validation ===

#[test, expected_failure(abort_code = links::EEmptySpotifyId)]
fun new_spotify_rejects_empty_id() {
    let _ = links::new_spotify(b"".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxSpotifyIdLengthExceeded)]
fun new_spotify_rejects_overlong_id() {
    let _ = links::new_spotify(overlong_64());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyAppleMusicIdentifier)]
fun new_apple_music_album_rejects_empty_storefront() {
    let _ = links::new_apple_music_album(b"".to_string(), b"1".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyAppleMusicIdentifier)]
fun new_apple_music_album_rejects_empty_album_id() {
    let _ = links::new_apple_music_album(b"us".to_string(), b"".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxAppleMusicStorefrontLengthExceeded)]
fun new_apple_music_album_rejects_overlong_storefront() {
    let _ = links::new_apple_music_album(overlong_64(), b"1".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxAppleMusicAlbumIdLengthExceeded)]
fun new_apple_music_album_rejects_overlong_album_id() {
    let _ = links::new_apple_music_album(b"us".to_string(), overlong_64());
    abort
}

// The three-way `&&` in `new_apple_music_track`'s empty check
// short-circuits, so each operand is its own bytecode branch — one test per
// identifier is needed for full branch coverage.
#[test, expected_failure(abort_code = links::EEmptyAppleMusicIdentifier)]
fun new_apple_music_track_rejects_empty_storefront() {
    let _ = links::new_apple_music_track(b"".to_string(), b"1".to_string(), b"2".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyAppleMusicIdentifier)]
fun new_apple_music_track_rejects_empty_album_id() {
    let _ = links::new_apple_music_track(b"us".to_string(), b"".to_string(), b"2".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyAppleMusicIdentifier)]
fun new_apple_music_track_rejects_empty_track_id() {
    let _ = links::new_apple_music_track(b"us".to_string(), b"1".to_string(), b"".to_string());
    abort
}

// The length checks are compiled per constructor (not shared with the album
// variant), so each needs its own overlong test too.
#[test, expected_failure(abort_code = links::EMaxAppleMusicStorefrontLengthExceeded)]
fun new_apple_music_track_rejects_overlong_storefront() {
    let _ = links::new_apple_music_track(overlong_64(), b"1".to_string(), b"2".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxAppleMusicAlbumIdLengthExceeded)]
fun new_apple_music_track_rejects_overlong_album_id() {
    let _ = links::new_apple_music_track(b"us".to_string(), overlong_64(), b"2".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxAppleMusicTrackIdLengthExceeded)]
fun new_apple_music_track_rejects_overlong_track_id() {
    let _ = links::new_apple_music_track(b"us".to_string(), b"1".to_string(), overlong_64());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyAmazonMusicIdentifier)]
fun new_amazon_music_album_rejects_empty_album_id() {
    let _ = links::new_amazon_music_album(b"".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxAmazonMusicAlbumIdLengthExceeded)]
fun new_amazon_music_album_rejects_overlong_album_id() {
    let _ = links::new_amazon_music_album(overlong_64());
    abort
}

// Same short-circuit reasoning as the Apple Music track constructor.
#[test, expected_failure(abort_code = links::EEmptyAmazonMusicIdentifier)]
fun new_amazon_music_track_rejects_empty_album_id() {
    let _ = links::new_amazon_music_track(b"".to_string(), b"2".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyAmazonMusicIdentifier)]
fun new_amazon_music_track_rejects_empty_track_id() {
    let _ = links::new_amazon_music_track(b"1".to_string(), b"".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxAmazonMusicAlbumIdLengthExceeded)]
fun new_amazon_music_track_rejects_overlong_album_id() {
    let _ = links::new_amazon_music_track(overlong_64(), b"2".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxAmazonMusicTrackIdLengthExceeded)]
fun new_amazon_music_track_rejects_overlong_track_id() {
    let _ = links::new_amazon_music_track(b"1".to_string(), overlong_64());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyBandcampIdentifier)]
fun new_bandcamp_rejects_empty_subdomain() {
    let _ = links::new_bandcamp(b"".to_string(), b"y".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyBandcampIdentifier)]
fun new_bandcamp_rejects_empty_slug() {
    let _ = links::new_bandcamp(b"x".to_string(), b"".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxBandcampSubdomainLengthExceeded)]
fun new_bandcamp_rejects_overlong_subdomain() {
    let _ = links::new_bandcamp(overlong_128(), b"y".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxBandcampSlugLengthExceeded)]
fun new_bandcamp_rejects_overlong_slug() {
    let _ = links::new_bandcamp(b"x".to_string(), overlong_128());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyDeezerId)]
fun new_deezer_rejects_empty_id() {
    let _ = links::new_deezer(b"".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxDeezerIdLengthExceeded)]
fun new_deezer_rejects_overlong_id() {
    let _ = links::new_deezer(overlong_64());
    abort
}

#[test, expected_failure(abort_code = links::EEmptySoundCloudIdentifier)]
fun new_soundcloud_rejects_empty_user() {
    let _ = links::new_soundcloud(b"".to_string(), b"y".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EEmptySoundCloudIdentifier)]
fun new_soundcloud_rejects_empty_slug() {
    let _ = links::new_soundcloud(b"x".to_string(), b"".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxSoundCloudUserLengthExceeded)]
fun new_soundcloud_rejects_overlong_user() {
    let _ = links::new_soundcloud(overlong_128(), b"y".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxSoundCloudSlugLengthExceeded)]
fun new_soundcloud_rejects_overlong_slug() {
    let _ = links::new_soundcloud(b"x".to_string(), overlong_128());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyTidalId)]
fun new_tidal_rejects_empty_id() {
    let _ = links::new_tidal(b"".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxTidalIdLengthExceeded)]
fun new_tidal_rejects_overlong_id() {
    let _ = links::new_tidal(overlong_64());
    abort
}

#[test, expected_failure(abort_code = links::EEmptyYouTubeMusicId)]
fun new_youtube_music_rejects_empty_id() {
    let _ = links::new_youtube_music(b"".to_string());
    abort
}

#[test, expected_failure(abort_code = links::EMaxYouTubeMusicIdLengthExceeded)]
fun new_youtube_music_rejects_overlong_id() {
    let _ = links::new_youtube_music(overlong_64());
    abort
}

// === Event Emissions ===

#[test]
fun clear_track_links_emits_one_bulk_clear() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();
    let deezer = links::platform_deezer();

    links::set_track_link(&mut rel, &cap, 0, links::new_deezer(b"10".to_string()));
    links::set_track_link(&mut rel, &cap, 2, links::new_deezer(b"12".to_string()));

    links::clear_track_links(&mut rel, &cap, deezer);

    let events = event::events_by_type<links::ReleaseTrackDspLinksClearedEvent>();
    assert_eq!(events.length(), 1);
    assert_track_links_cleared(&events[0], release_id, deezer);

    // The array is gone: previously-set slots read none, and a second clear is
    // a silent no-op.
    assert!(links::track_link(&rel, deezer, 0).is_none());
    links::clear_track_links(&mut rel, &cap, deezer);
    assert_eq!(event::events_by_type<links::ReleaseTrackDspLinksClearedEvent>().length(), 1);

    destroy(rel);
    destroy(cap);
}
