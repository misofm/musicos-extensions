// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage: constructor validation (every error const), bounds, view
/// fallback semantics, platform mapping, and event payloads. `ReleaseAdminCap`
/// authorization is bound to the release's id at runtime (`uid_mut` calls
/// `authorize`, which checks `object::id(self) == cap.release_id`) rather than to
/// any sender/address, so single-transaction `tx_context::dummy()` tests
/// exercise the real authorization logic just as well as a multi-actor
/// scenario would — scenario mechanics (distinct senders, `next_tx`) add
/// nothing to these pure boundary/abort/math cases. The production shape —
/// create → publish → share → operate via `take_shared` across transactions
/// and distinct senders — is covered separately in
/// `release_dsp_link_e2e_tests.move`.
#[test_only]
module release_dsp_link::release_dsp_link_tests;

use release_dsp_link::release_dsp_link as links;
use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use std::string::String;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const A: address = @0xA1;

// Mirrors `release::EUnauthorized` (release.move:110). Unlike the type-bound
// recording caps, a `Release` binds its cap at runtime — `uid_mut` calls
// `authorize`, which asserts `object::id(self) == cap.release_id` — so a foreign cap
// is testable here.
const EUnauthorized: u64 = 0;

// A 3-track release: flat tracklist indices 0, 1, 2. `new_for_testing`
// patches every track's target_release_id to the freshly-minted release, so
// the placeholder passed here never surfaces.
fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let comp_id = test_helpers::fake_id(ctx);
    let rel_id = test_helpers::fake_id(ctx);
    let r0 = test_helpers::fake_id(ctx);
    let r1 = test_helpers::fake_id(ctx);
    let r2 = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(comp_id, r0, rel_id, 4000u16),
        track::new_for_testing(comp_id, r1, rel_id, 3000u16),
        track::new_for_testing(comp_id, r2, rel_id, 3000u16),
    ];
    release::new_for_testing(b"Album".to_string(), tracks, ctx)
}

/// 65 'a' bytes — one over every `MAX_*_LENGTH` bound in this module (all 64
/// or 128), so a single helper covers the tight-bound constructors.
fun overlong_64(): String { vector::tabulate!(65, |_| 97u8).to_string() }

/// 129 'a' bytes — one over the 128-byte handle/slug bound.
fun overlong_128(): String { vector::tabulate!(129, |_| 97u8).to_string() }

// === Album-level Link Lifecycle ===

#[test]
fun album_link_set_replace_clear_is_independent_per_platform() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());
    let spotify = links::platform_spotify();
    let tidal = links::platform_tidal();

    assert!(!links::has_release_link(&rel, spotify));
    assert!(links::release_link(&rel, spotify).is_none());

    links::set_release_link(&mut rel, &cap, links::new_spotify(b"3xTbtTM3BSRIGxzWSMaEpc".to_string()));
    links::set_release_link(&mut rel, &cap, links::new_tidal(b"12345".to_string()));

    assert!(links::has_release_link(&rel, spotify));
    assert!(links::has_release_link(&rel, tidal));
    assert_eq!(
        links::release_link(&rel, spotify).destroy_some(),
        links::new_spotify(b"3xTbtTM3BSRIGxzWSMaEpc".to_string()),
    );
    assert_eq!(links::release_link(&rel, tidal).destroy_some(), links::new_tidal(b"12345".to_string()));

    // Replacing Spotify's link leaves Tidal's untouched.
    links::set_release_link(&mut rel, &cap, links::new_spotify(b"6rqhFgbbKwnb9MLmUQDhG6".to_string()));
    assert_eq!(
        links::release_link(&rel, spotify).destroy_some(),
        links::new_spotify(b"6rqhFgbbKwnb9MLmUQDhG6".to_string()),
    );
    assert_eq!(links::release_link(&rel, tidal).destroy_some(), links::new_tidal(b"12345".to_string()));

    // Clearing Spotify leaves Tidal untouched.
    links::clear_release_link(&mut rel, &cap, spotify);
    assert!(!links::has_release_link(&rel, spotify));
    assert!(links::has_release_link(&rel, tidal));

    destroy(rel);
    destroy(cap);
    ts.end();
}

#[test]
fun clear_release_link_is_a_no_op_when_unset() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());

    // No-op: nothing was set, nothing aborts.
    links::clear_release_link(&mut rel, &cap, links::platform_deezer());
    assert!(!links::has_release_link(&rel, links::platform_deezer()));

    destroy(rel);
    destroy(cap);
    ts.end();
}

// === Per-track Link Lifecycle ===

#[test]
fun track_link_set_replace_clear_lifecycle() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());
    let bandcamp = links::platform_bandcamp();

    // No array yet: every index reads none, not an abort.
    assert!(links::track_link(&rel, bandcamp, 0).is_none());

    links::set_track_link(&mut rel, &cap, 1, links::new_bandcamp(b"anartist".to_string(), b"a-track".to_string()));
    assert_eq!(
        links::track_link(&rel, bandcamp, 1).destroy_some(),
        links::new_bandcamp(b"anartist".to_string(), b"a-track".to_string()),
    );
    assert!(links::track_link(&rel, bandcamp, 0).is_none());
    assert!(links::track_link(&rel, bandcamp, 2).is_none());

    // Setting again on the same slot replaces.
    links::set_track_link(&mut rel, &cap, 1, links::new_bandcamp(b"anartist".to_string(), b"b-track".to_string()));
    assert_eq!(
        links::track_link(&rel, bandcamp, 1).destroy_some(),
        links::new_bandcamp(b"anartist".to_string(), b"b-track".to_string()),
    );

    // Clearing the slot resets it to none; other slots and other platforms are
    // unaffected.
    links::clear_track_link(&mut rel, &cap, bandcamp, 1);
    assert!(links::track_link(&rel, bandcamp, 1).is_none());

    destroy(rel);
    destroy(cap);
    ts.end();
}

#[test]
fun clear_track_link_is_a_no_op_when_no_array_exists() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());

    links::clear_track_link(&mut rel, &cap, links::platform_soundcloud(), 0);
    assert!(links::track_link(&rel, links::platform_soundcloud(), 0).is_none());

    destroy(rel);
    destroy(cap);
    ts.end();
}

#[test]
fun clear_track_links_removes_the_whole_array() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());
    let deezer = links::platform_deezer();

    links::set_track_link(&mut rel, &cap, 0, links::new_deezer(b"10".to_string()));
    links::set_track_link(&mut rel, &cap, 2, links::new_deezer(b"12".to_string()));

    links::clear_track_links(&mut rel, &cap, deezer);

    // The array is gone: previously-set slots read none again.
    assert!(links::track_link(&rel, deezer, 0).is_none());
    assert!(links::track_link(&rel, deezer, 2).is_none());

    // A second bulk clear is a silent no-op.
    links::clear_track_links(&mut rel, &cap, deezer);

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
    // No-op check happens before the bounds assert, so an absent array never
    // aborts on a bad index.
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

#[test]
fun platform_matches_declared_variant_order() {
    assert_eq!(links::new_spotify(b"x".to_string()).platform(), links::platform_spotify());
    assert_eq!(
        links::new_apple_music_album(b"us".to_string(), b"x".to_string()).platform(),
        links::platform_apple_music(),
    );
    // The track-selector constructors are a distinct success branch (they
    // populate `track_id: option::some(..)` instead of `option::none()`) —
    // exercise both explicitly, not just their `expected_failure` siblings.
    assert_eq!(
        links::new_apple_music_track(b"us".to_string(), b"1".to_string(), b"2".to_string()).platform(),
        links::platform_apple_music(),
    );
    assert_eq!(
        links::new_amazon_music_album(b"x".to_string()).platform(),
        links::platform_amazon_music(),
    );
    assert_eq!(
        links::new_amazon_music_track(b"1".to_string(), b"2".to_string()).platform(),
        links::platform_amazon_music(),
    );
    assert_eq!(
        links::new_bandcamp(b"x".to_string(), b"y".to_string()).platform(),
        links::platform_bandcamp(),
    );
    assert_eq!(links::new_deezer(b"x".to_string()).platform(), links::platform_deezer());
    assert_eq!(
        links::new_soundcloud(b"x".to_string(), b"y".to_string()).platform(),
        links::platform_soundcloud(),
    );
    assert_eq!(links::new_tidal(b"x".to_string()).platform(), links::platform_tidal());
    assert_eq!(
        links::new_youtube_music(b"x".to_string()).platform(),
        links::platform_youtube_music(),
    );

    assert_eq!(links::platform_spotify(), 0);
    assert_eq!(links::platform_apple_music(), 1);
    assert_eq!(links::platform_amazon_music(), 2);
    assert_eq!(links::platform_bandcamp(), 3);
    assert_eq!(links::platform_deezer(), 4);
    assert_eq!(links::platform_soundcloud(), 5);
    assert_eq!(links::platform_tidal(), 6);
    assert_eq!(links::platform_youtube_music(), 7);
}

// === Authorization ===

/// A `Release` binds its cap at runtime (`uid_mut` calls `authorize`), so a
/// foreign cap is testable here — unlike the type-bound recording caps.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
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

#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun clear_release_link_requires_the_cap_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (mut release, _release_cap) = mk_release(ctx);
    let (_foreign_release, foreign_cap) = mk_release(ctx);

    links::clear_release_link(&mut release, &foreign_cap, links::platform_spotify());
    abort
}

#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun clear_track_link_requires_the_cap_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (mut release, _release_cap) = mk_release(ctx);
    let (_foreign_release, foreign_cap) = mk_release(ctx);

    links::clear_track_link(&mut release, &foreign_cap, links::platform_spotify(), 0);
    abort
}

#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
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
// identifier is needed for full branch coverage, not just one.
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

// The length checks are also separately compiled per constructor (not
// shared with the album variant), so each needs its own overlong test too.
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

// Same short-circuit reasoning as the Apple Music track constructor: each
// operand of the `&&` is its own branch.
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

// Also compiled separately from the album variant's length check.
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
fun set_release_link_emits_the_full_link() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);

    links::set_release_link(&mut rel, &cap, links::new_spotify(b"x".to_string()));

    let events = event::events_by_type<links::ReleaseLinkSetEvent>();
    assert_eq!(events.length(), 1);
    let (event_release_id, link) = links::release_link_set_event_fields(&events[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(link, links::new_spotify(b"x".to_string()));

    // Replacing emits the value actually written, not the stale one.
    links::set_release_link(&mut rel, &cap, links::new_spotify(b"y".to_string()));
    let events = event::events_by_type<links::ReleaseLinkSetEvent>();
    assert_eq!(events.length(), 2);
    let (_, replacement) = links::release_link_set_event_fields(&events[1]);
    assert_eq!(replacement, links::new_spotify(b"y".to_string()));

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_release_link_emits_only_when_a_link_was_set() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);
    let spotify = links::platform_spotify();

    // Nothing set — a no-op clear must stay silent.
    links::clear_release_link(&mut rel, &cap, spotify);
    assert_eq!(event::events_by_type<links::ReleaseLinkClearedEvent>().length(), 0);

    links::set_release_link(&mut rel, &cap, links::new_spotify(b"x".to_string()));
    links::clear_release_link(&mut rel, &cap, spotify);

    let events = event::events_by_type<links::ReleaseLinkClearedEvent>();
    assert_eq!(events.length(), 1);
    let (event_release_id, event_platform) = links::release_link_cleared_event_fields(&events[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_platform, spotify);

    destroy(rel);
    destroy(cap);
}

#[test]
fun set_track_link_emits_the_written_slot() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);
    let tidal = links::platform_tidal();

    links::set_track_link(&mut rel, &cap, 1, links::new_tidal(b"11".to_string()));

    let events = event::events_by_type<links::TrackLinkSetEvent>();
    assert_eq!(events.length(), 1);
    let (event_release_id, event_platform, track_index, link) =
        links::track_link_set_event_fields(&events[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_platform, tidal);
    assert_eq!(track_index, 1);
    assert_eq!(link.destroy_some(), links::new_tidal(b"11".to_string()));

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_track_link_emits_a_none_slot() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);
    let tidal = links::platform_tidal();

    links::set_track_link(&mut rel, &cap, 1, links::new_tidal(b"11".to_string()));
    links::clear_track_link(&mut rel, &cap, tidal, 1);

    // Same event type as the set; the payload says what the slot now holds.
    let events = event::events_by_type<links::TrackLinkSetEvent>();
    assert_eq!(events.length(), 2);
    let (_, _, _, set_link) = links::track_link_set_event_fields(&events[0]);
    assert!(set_link.is_some());
    let (event_release_id, event_platform, track_index, cleared_link) =
        links::track_link_set_event_fields(&events[1]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_platform, tidal);
    assert_eq!(track_index, 1);
    assert!(cleared_link.is_none());

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_track_links_emits_one_bulk_clear() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);
    let deezer = links::platform_deezer();

    links::set_track_link(&mut rel, &cap, 0, links::new_deezer(b"10".to_string()));
    links::set_track_link(&mut rel, &cap, 2, links::new_deezer(b"12".to_string()));

    links::clear_track_links(&mut rel, &cap, deezer);

    // Exactly one event for the whole array — not one per track.
    let events = event::events_by_type<links::TrackLinksClearedEvent>();
    assert_eq!(events.length(), 1);
    let (event_release_id, event_platform) = links::track_links_cleared_event_fields(&events[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_platform, deezer);

    // The array is gone: previously-set slots read none, and a second clear is
    // a silent no-op.
    assert!(links::track_link(&rel, deezer, 0).is_none());
    links::clear_track_links(&mut rel, &cap, deezer);
    assert_eq!(event::events_by_type<links::TrackLinksClearedEvent>().length(), 1);

    destroy(rel);
    destroy(cap);
}
