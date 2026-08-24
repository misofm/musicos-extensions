// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Streaming deep links for a Miso release, one Digital Service Provider (DSP)
/// at a time. Attaches `DspLinkData` records to a `miso::release::Release`: an
/// album-level link per DSP, plus an optional per-track link per DSP.
///
/// `DspLinkData` is a single built-in enum with one variant per DSP, holding
/// that DSP's native identifier(s) — e.g. a Spotify album id, or Apple Music's
/// `(storefront, album_id, track_id)`. URLs are never stored: a client rebuilds
/// the public URL from the variant it reads back, so a DSP reshaping its URLs
/// needs no on-chain change. Storage is keyed by the variant's platform code (a
/// `u8` discriminant matching declaration order, via `platform()`), so each DSP
/// occupies its own independent dynamic field on the release's `UID` — adding
/// or clearing one DSP's link never touches another's.
///
/// Two levels per DSP: the album-level link is the single `DspLinkData` stored
/// under `ReleaseLinkKey(platform)`; the per-track links are a
/// `PerTrack<Option<DspLinkData>>` stored under `TrackLinksKey(platform)` (one
/// slot per track, aligned to the tracklist by construction). A track whose
/// slot is `none` inherits the album-level link at the frontend.
///
/// Streaming presence is presentation, not protocol-verifiable state, so it
/// lives on the release (the consumer object), not the recording. All writes
/// are gated by the `ReleaseAdminCap` via `uid_mut`; views are permissionless.
module release_dsp_link::release_dsp_link;

use miso::release::{Release, ReleaseAdminCap};
use per_track::per_track::{Self, PerTrack};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

// Reference errors (0-9)
/// Track index is out of bounds for this release's track count.
const ETrackIndexOutOfBounds: u64 = 0;

// Spotify validation (10-19)
/// The Spotify id was empty.
const EEmptySpotifyId: u64 = 10;
/// The Spotify id exceeded `MAX_SPOTIFY_ID_LENGTH`.
const EMaxSpotifyIdLengthExceeded: u64 = 11;

// Apple Music validation (20-29)
/// A required Apple Music identifier was empty.
const EEmptyAppleMusicIdentifier: u64 = 20;
/// `storefront` exceeded `MAX_APPLE_MUSIC_STOREFRONT_LENGTH`.
const EMaxAppleMusicStorefrontLengthExceeded: u64 = 21;
/// `album_id` exceeded `MAX_APPLE_MUSIC_ALBUM_ID_LENGTH`.
const EMaxAppleMusicAlbumIdLengthExceeded: u64 = 22;
/// `track_id` exceeded `MAX_APPLE_MUSIC_TRACK_ID_LENGTH`.
const EMaxAppleMusicTrackIdLengthExceeded: u64 = 23;

// Amazon Music validation (30-39)
/// A required Amazon Music identifier was empty.
const EEmptyAmazonMusicIdentifier: u64 = 30;
/// `album_id` exceeded `MAX_AMAZON_MUSIC_ALBUM_ID_LENGTH`.
const EMaxAmazonMusicAlbumIdLengthExceeded: u64 = 31;
/// `track_id` exceeded `MAX_AMAZON_MUSIC_TRACK_ID_LENGTH`.
const EMaxAmazonMusicTrackIdLengthExceeded: u64 = 32;

// Bandcamp validation (40-49)
/// A required Bandcamp identifier was empty.
const EEmptyBandcampIdentifier: u64 = 40;
/// `subdomain` exceeded `MAX_BANDCAMP_SUBDOMAIN_LENGTH`.
const EMaxBandcampSubdomainLengthExceeded: u64 = 41;
/// `slug` exceeded `MAX_BANDCAMP_SLUG_LENGTH`.
const EMaxBandcampSlugLengthExceeded: u64 = 42;

// Deezer validation (50-59)
/// The Deezer id was empty.
const EEmptyDeezerId: u64 = 50;
/// The Deezer id exceeded `MAX_DEEZER_ID_LENGTH`.
const EMaxDeezerIdLengthExceeded: u64 = 51;

// SoundCloud validation (60-69)
/// A required SoundCloud identifier was empty.
const EEmptySoundCloudIdentifier: u64 = 60;
/// `user` exceeded `MAX_SOUNDCLOUD_USER_LENGTH`.
const EMaxSoundCloudUserLengthExceeded: u64 = 61;
/// `slug` exceeded `MAX_SOUNDCLOUD_SLUG_LENGTH`.
const EMaxSoundCloudSlugLengthExceeded: u64 = 62;

// Tidal validation (70-79)
/// The Tidal id was empty.
const EEmptyTidalId: u64 = 70;
/// The Tidal id exceeded `MAX_TIDAL_ID_LENGTH`.
const EMaxTidalIdLengthExceeded: u64 = 71;

// YouTube Music validation (80-89)
/// The YouTube Music id was empty.
const EEmptyYouTubeMusicId: u64 = 80;
/// The YouTube Music id exceeded `MAX_YOUTUBE_MUSIC_ID_LENGTH`.
const EMaxYouTubeMusicIdLengthExceeded: u64 = 81;

// === Constants ===
//
// Maximum byte lengths of stored identifiers — storage backstops, not format
// validation (see each field's real-world shape in `DspLinkData`'s doc
// comments). Ids get the tight 64-byte bound; free-text handles/slugs
// (Bandcamp, SoundCloud) get the looser 128-byte bound matching the rest of
// the stack's handle/id fields.

const MAX_SPOTIFY_ID_LENGTH: u64 = 64;
const MAX_APPLE_MUSIC_STOREFRONT_LENGTH: u64 = 64;
const MAX_APPLE_MUSIC_ALBUM_ID_LENGTH: u64 = 64;
const MAX_APPLE_MUSIC_TRACK_ID_LENGTH: u64 = 64;
const MAX_AMAZON_MUSIC_ALBUM_ID_LENGTH: u64 = 64;
const MAX_AMAZON_MUSIC_TRACK_ID_LENGTH: u64 = 64;
const MAX_BANDCAMP_SUBDOMAIN_LENGTH: u64 = 128;
const MAX_BANDCAMP_SLUG_LENGTH: u64 = 128;
const MAX_DEEZER_ID_LENGTH: u64 = 64;
const MAX_SOUNDCLOUD_USER_LENGTH: u64 = 128;
const MAX_SOUNDCLOUD_SLUG_LENGTH: u64 = 128;
const MAX_TIDAL_ID_LENGTH: u64 = 64;
const MAX_YOUTUBE_MUSIC_ID_LENGTH: u64 = 64;

// === Enums ===

/// A link to a release (or one of its tracks) on a single DSP, one variant per
/// platform. Which slot a value is stored in — the album-level slot or a
/// per-track slot — decides whether it addresses the release or one track;
/// most DSPs use the same identifier shape for both, which is why a variant
/// doesn't carry an explicit album/track flag.
///
/// **Variant order is frozen.** Storage keys off `platform()`, a `u8`
/// discriminant matching declaration order (`Spotify = 0` … `YouTubeMusic =
/// 7`). Sui's compatible-upgrade policy allows appending new enum variants but
/// not reordering or removing existing ones, so a new platform is always
/// appended at the end in a package upgrade — existing BCS variant indices,
/// and therefore existing dynamic-field keys, stay stable.
public enum DspLinkData has copy, drop, store {
    /// Spotify addresses both albums and tracks by a single 22-char base62 id
    /// (`open.spotify.com/album/{id}` or `/track/{id}`); album-vs-track is
    /// chosen by where the link is stored, so one `id` field serves both.
    Spotify { id: String },
    /// Apple Music: an album is
    /// `music.apple.com/{storefront}/album/{album_id}`; a track within it adds
    /// the `?i={track_id}` selector. `storefront` is the two-letter region
    /// (e.g. `us`), and because a track link still needs the album id, the
    /// album id is always present. The optional `track_id` distinguishes the
    /// two forms — clients emit the track URL when it is set, the album URL
    /// otherwise. The canonical web URL carries a cosmetic name slug
    /// (`/album/{slug}/{album_id}`); only the trailing numeric `album_id` is
    /// stored, and Apple resolves the slug-less form.
    AppleMusic { storefront: String, album_id: String, track_id: Option<String> },
    /// Amazon Music: an album is `music.amazon.com/albums/{album_id}`; a track
    /// within it adds the `?trackAsin={track_id}` selector. Ids are ASINs
    /// (e.g. `B0064UPU4G`). The optional `track_id` distinguishes the two
    /// forms — clients emit the track URL when it is set, the album URL
    /// otherwise.
    AmazonMusic { album_id: String, track_id: Option<String> },
    /// Bandcamp addresses by artist subdomain + slug: an album is
    /// `{subdomain}.bandcamp.com/album/{slug}` and a track is
    /// `{subdomain}.bandcamp.com/track/{slug}`. Album-vs-track is chosen by
    /// where the link is stored, so one `(subdomain, slug)` pair serves both.
    Bandcamp { subdomain: String, slug: String },
    /// Deezer addresses albums and tracks by a numeric id
    /// (`www.deezer.com/album/{id}` / `www.deezer.com/track/{id}`; a
    /// `/{locale}/` segment may appear but is optional). Album-vs-track is
    /// chosen by where the link is stored, so one `id` field serves both.
    Deezer { id: String },
    /// SoundCloud is slug-addressed, not numeric: an album/playlist is
    /// `soundcloud.com/{user}/sets/{slug}` and a track is
    /// `soundcloud.com/{user}/{slug}`. Album-vs-track is chosen by where the
    /// link is stored, so one `(user, slug)` pair serves both.
    SoundCloud { user: String, slug: String },
    /// Tidal addresses albums and tracks by a numeric id
    /// (`tidal.com/album/{id}` / `tidal.com/track/{id}`; the older
    /// `tidal.com/browse/album/{id}` form also resolves). Album-vs-track is
    /// chosen by where the link is stored, so one `id` field serves both.
    Tidal { id: String },
    /// YouTube Music: an album is a playlist
    /// (`music.youtube.com/playlist?list={id}`) and a track is a video
    /// (`music.youtube.com/watch?v={id}`). The `id` holds the playlist id at
    /// the release level and the video id per track; album-vs-track is chosen
    /// by where the link is stored, so one `id` field serves both.
    YouTubeMusic { id: String },
}

// === Platform Codes ===

/// The link's platform code — the `u8` discriminant clients pass to
/// `clear_release_link`, `clear_track_link`, `clear_track_links`, and the view
/// functions below.
public fun platform(self: &DspLinkData): u8 {
    match (self) {
        DspLinkData::Spotify { .. } => 0,
        DspLinkData::AppleMusic { .. } => 1,
        DspLinkData::AmazonMusic { .. } => 2,
        DspLinkData::Bandcamp { .. } => 3,
        DspLinkData::Deezer { .. } => 4,
        DspLinkData::SoundCloud { .. } => 5,
        DspLinkData::Tidal { .. } => 6,
        DspLinkData::YouTubeMusic { .. } => 7,
    }
}

/// Platform code for `Spotify`.
public fun platform_spotify(): u8 { 0 }

/// Platform code for `AppleMusic`.
public fun platform_apple_music(): u8 { 1 }

/// Platform code for `AmazonMusic`.
public fun platform_amazon_music(): u8 { 2 }

/// Platform code for `Bandcamp`.
public fun platform_bandcamp(): u8 { 3 }

/// Platform code for `Deezer`.
public fun platform_deezer(): u8 { 4 }

/// Platform code for `SoundCloud`.
public fun platform_soundcloud(): u8 { 5 }

/// Platform code for `Tidal`.
public fun platform_tidal(): u8 { 6 }

/// Platform code for `YouTubeMusic`.
public fun platform_youtube_music(): u8 { 7 }

// === Constructors ===

/// Builds a Spotify link from its id. Aborts if `id` is empty or exceeds
/// `MAX_SPOTIFY_ID_LENGTH`.
public fun new_spotify(id: String): DspLinkData {
    assert!(!id.is_empty(), EEmptySpotifyId);
    assert!(id.length() <= MAX_SPOTIFY_ID_LENGTH, EMaxSpotifyIdLengthExceeded);
    DspLinkData::Spotify { id }
}

/// Builds an Apple Music album link (no track selector). Aborts if
/// `storefront` or `album_id` is empty or exceeds its maximum length.
public fun new_apple_music_album(storefront: String, album_id: String): DspLinkData {
    assert!(!storefront.is_empty() && !album_id.is_empty(), EEmptyAppleMusicIdentifier);
    assert!(
        storefront.length() <= MAX_APPLE_MUSIC_STOREFRONT_LENGTH,
        EMaxAppleMusicStorefrontLengthExceeded,
    );
    assert!(album_id.length() <= MAX_APPLE_MUSIC_ALBUM_ID_LENGTH, EMaxAppleMusicAlbumIdLengthExceeded);
    DspLinkData::AppleMusic { storefront, album_id, track_id: option::none() }
}

/// Builds an Apple Music track link — addresses `track_id` within its
/// `album_id`. Aborts if any identifier is empty or exceeds its maximum
/// length.
public fun new_apple_music_track(
    storefront: String,
    album_id: String,
    track_id: String,
): DspLinkData {
    assert!(
        !storefront.is_empty() && !album_id.is_empty() && !track_id.is_empty(),
        EEmptyAppleMusicIdentifier,
    );
    assert!(
        storefront.length() <= MAX_APPLE_MUSIC_STOREFRONT_LENGTH,
        EMaxAppleMusicStorefrontLengthExceeded,
    );
    assert!(album_id.length() <= MAX_APPLE_MUSIC_ALBUM_ID_LENGTH, EMaxAppleMusicAlbumIdLengthExceeded);
    assert!(track_id.length() <= MAX_APPLE_MUSIC_TRACK_ID_LENGTH, EMaxAppleMusicTrackIdLengthExceeded);
    DspLinkData::AppleMusic { storefront, album_id, track_id: option::some(track_id) }
}

/// Builds an Amazon Music album link (no track selector). Aborts if
/// `album_id` is empty or exceeds `MAX_AMAZON_MUSIC_ALBUM_ID_LENGTH`.
public fun new_amazon_music_album(album_id: String): DspLinkData {
    assert!(!album_id.is_empty(), EEmptyAmazonMusicIdentifier);
    assert!(
        album_id.length() <= MAX_AMAZON_MUSIC_ALBUM_ID_LENGTH,
        EMaxAmazonMusicAlbumIdLengthExceeded,
    );
    DspLinkData::AmazonMusic { album_id, track_id: option::none() }
}

/// Builds an Amazon Music track link — addresses `track_id` within its
/// `album_id`. Aborts if either ASIN is empty or exceeds its maximum length.
public fun new_amazon_music_track(album_id: String, track_id: String): DspLinkData {
    assert!(!album_id.is_empty() && !track_id.is_empty(), EEmptyAmazonMusicIdentifier);
    assert!(
        album_id.length() <= MAX_AMAZON_MUSIC_ALBUM_ID_LENGTH,
        EMaxAmazonMusicAlbumIdLengthExceeded,
    );
    assert!(
        track_id.length() <= MAX_AMAZON_MUSIC_TRACK_ID_LENGTH,
        EMaxAmazonMusicTrackIdLengthExceeded,
    );
    DspLinkData::AmazonMusic { album_id, track_id: option::some(track_id) }
}

/// Builds a Bandcamp link. Aborts if `subdomain` or `slug` is empty or exceeds
/// its maximum length.
public fun new_bandcamp(subdomain: String, slug: String): DspLinkData {
    assert!(!subdomain.is_empty() && !slug.is_empty(), EEmptyBandcampIdentifier);
    assert!(subdomain.length() <= MAX_BANDCAMP_SUBDOMAIN_LENGTH, EMaxBandcampSubdomainLengthExceeded);
    assert!(slug.length() <= MAX_BANDCAMP_SLUG_LENGTH, EMaxBandcampSlugLengthExceeded);
    DspLinkData::Bandcamp { subdomain, slug }
}

/// Builds a Deezer link from its id. Aborts if `id` is empty or exceeds
/// `MAX_DEEZER_ID_LENGTH`.
public fun new_deezer(id: String): DspLinkData {
    assert!(!id.is_empty(), EEmptyDeezerId);
    assert!(id.length() <= MAX_DEEZER_ID_LENGTH, EMaxDeezerIdLengthExceeded);
    DspLinkData::Deezer { id }
}

/// Builds a SoundCloud link. Aborts if `user` or `slug` is empty or exceeds
/// its maximum length.
public fun new_soundcloud(user: String, slug: String): DspLinkData {
    assert!(!user.is_empty() && !slug.is_empty(), EEmptySoundCloudIdentifier);
    assert!(user.length() <= MAX_SOUNDCLOUD_USER_LENGTH, EMaxSoundCloudUserLengthExceeded);
    assert!(slug.length() <= MAX_SOUNDCLOUD_SLUG_LENGTH, EMaxSoundCloudSlugLengthExceeded);
    DspLinkData::SoundCloud { user, slug }
}

/// Builds a Tidal link from its id. Aborts if `id` is empty or exceeds
/// `MAX_TIDAL_ID_LENGTH`.
public fun new_tidal(id: String): DspLinkData {
    assert!(!id.is_empty(), EEmptyTidalId);
    assert!(id.length() <= MAX_TIDAL_ID_LENGTH, EMaxTidalIdLengthExceeded);
    DspLinkData::Tidal { id }
}

/// Builds a YouTube Music link from its id. Aborts if `id` is empty or
/// exceeds `MAX_YOUTUBE_MUSIC_ID_LENGTH`.
public fun new_youtube_music(id: String): DspLinkData {
    assert!(!id.is_empty(), EEmptyYouTubeMusicId);
    assert!(id.length() <= MAX_YOUTUBE_MUSIC_ID_LENGTH, EMaxYouTubeMusicIdLengthExceeded);
    DspLinkData::YouTubeMusic { id }
}

// === Structs ===

/// Dynamic-field key for a DSP's album-level link, keyed by platform code —
/// each platform occupies its own field on the release's `UID`.
public struct ReleaseLinkKey(u8) has copy, drop, store;

/// Dynamic-field key for a DSP's per-track links: a `PerTrack` of optional
/// links, one slot per track, keyed by platform code.
public struct TrackLinksKey(u8) has copy, drop, store;

// === Events ===

/// Emitted when a DSP's album-level link is set or replaced. Carries the full
/// new link (platform code included, via `link.platform()`), so an indexer
/// upserts its row straight from the event.
public struct ReleaseLinkSetEvent has copy, drop {
    release_id: ID,
    link: DspLinkData,
}

/// Emitted when a DSP's album-level link is cleared. The removed record is the
/// one the last `ReleaseLinkSetEvent` for this platform carried, so the
/// release id + platform is all an indexer needs to drop the row.
public struct ReleaseLinkClearedEvent has copy, drop {
    release_id: ID,
    platform: u8,
}

/// Emitted when a DSP's link for one track is set, replaced, or cleared. The
/// payload is the value written to the slot: `some(link)` on a set or replace,
/// `none` on a clear (the track falls back to the album-level link, and the
/// indexer drops the per-track row).
public struct TrackLinkSetEvent has copy, drop {
    release_id: ID,
    platform: u8,
    track_index: u64,
    link: Option<DspLinkData>,
}

/// Emitted when a DSP's entire per-track link array is removed. The removed
/// slots are the ones the stream's `TrackLinkSetEvent`s carried, so the
/// release id + platform is all an indexer needs to drop every per-track row
/// for the pair.
public struct TrackLinksClearedEvent has copy, drop {
    release_id: ID,
    platform: u8,
}

// === Album-level Write API ===

/// Sets (or replaces) a DSP's album-level link. The platform is derived from
/// `link` itself. Per-track links are untouched.
public fun set_release_link(self: &mut Release, cap: &ReleaseAdminCap, link: DspLinkData) {
    let release_id = object::id(self);
    let platform = link.platform();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ReleaseLinkKey(platform))) {
        *df::borrow_mut(uid, ReleaseLinkKey(platform)) = link;
    } else {
        df::add(uid, ReleaseLinkKey(platform), link);
    };
    emit(ReleaseLinkSetEvent { release_id, link });
}

/// Clears a DSP's album-level link. No-op if unset.
public fun clear_release_link(self: &mut Release, cap: &ReleaseAdminCap, platform: u8) {
    self.authorize(cap);
    if (df::exists(self.uid(), ReleaseLinkKey(platform))) {
        let release_id = object::id(self);
        let _: DspLinkData = df::remove(self.uid_mut(cap), ReleaseLinkKey(platform));
        emit(ReleaseLinkClearedEvent { release_id, platform });
    }
}

// === Per-track Write API ===

/// Sets (or replaces) a DSP's link for one track (by tracklist index). The
/// platform is derived from `link` itself. Aborts if the index is out of
/// range.
public fun set_track_link(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    track_index: u64,
    link: DspLinkData,
) {
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    let release_id = object::id(self);
    let platform = link.platform();
    *track_links_mut_or_init(self, cap, platform).borrow_mut(track_index) = option::some(link);
    emit(TrackLinkSetEvent { release_id, platform, track_index, link: option::some(link) });
}

/// Clears a DSP's link for one track (the track falls back to the album-level
/// link). No-op if no per-track array exists for this platform. Aborts if the
/// index is out of range (when an array exists).
public fun clear_track_link(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    platform: u8,
    track_index: u64,
) {
    self.authorize(cap);
    if (df::exists(self.uid(), TrackLinksKey(platform))) {
        assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
        let release_id = object::id(self);
        *borrow_track_links_mut(self.uid_mut(cap), platform).borrow_mut(track_index) =
            option::none();
        emit(TrackLinkSetEvent { release_id, platform, track_index, link: option::none() });
    }
}

/// Removes a DSP's entire per-track array. No-op if absent.
public fun clear_track_links(self: &mut Release, cap: &ReleaseAdminCap, platform: u8) {
    self.authorize(cap);
    if (df::exists(self.uid(), TrackLinksKey(platform))) {
        let release_id = object::id(self);
        let _: PerTrack<Option<DspLinkData>> = df::remove(
            self.uid_mut(cap),
            TrackLinksKey(platform),
        );
        emit(TrackLinksClearedEvent { release_id, platform });
    }
}

// === Views ===

/// Whether a DSP's album-level link is set.
public fun has_release_link(self: &Release, platform: u8): bool {
    df::exists(self.uid(), ReleaseLinkKey(platform))
}

/// A DSP's album-level link, if set.
public fun release_link(self: &Release, platform: u8): Option<DspLinkData> {
    let uid = self.uid();
    if (df::exists(uid, ReleaseLinkKey(platform))) {
        option::some(*df::borrow(uid, ReleaseLinkKey(platform)))
    } else {
        option::none()
    }
}

/// A DSP's link for one track, if set. An unset slot — or no array at all —
/// yields `none`, meaning the track inherits the album-level link. Aborts if
/// the index is out of range (when an array exists).
public fun track_link(self: &Release, platform: u8, track_index: u64): Option<DspLinkData> {
    let uid = self.uid();
    if (!df::exists(uid, TrackLinksKey(platform))) return option::none();
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    *borrow_track_links(uid, platform).borrow(track_index)
}

// === Private Functions ===

fun borrow_track_links(uid: &UID, platform: u8): &PerTrack<Option<DspLinkData>> {
    df::borrow(uid, TrackLinksKey(platform))
}

fun borrow_track_links_mut(uid: &mut UID, platform: u8): &mut PerTrack<Option<DspLinkData>> {
    df::borrow_mut(uid, TrackLinksKey(platform))
}

fun track_links_mut_or_init(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    platform: u8,
): &mut PerTrack<Option<DspLinkData>> {
    if (!df::exists(self.uid(), TrackLinksKey(platform))) {
        // Size the array to the tracklist up front (all empty); the release's
        // track count is fixed at creation, so this stays valid.
        let tracks = per_track::filled(self, option::none<DspLinkData>());
        df::add(self.uid_mut(cap), TrackLinksKey(platform), tracks);
    };
    borrow_track_links_mut(self.uid_mut(cap), platform)
}

// === Test Functions ===

#[test_only]
public fun release_link_set_event_fields(event: &ReleaseLinkSetEvent): (ID, DspLinkData) {
    (event.release_id, event.link)
}

#[test_only]
public fun release_link_cleared_event_fields(event: &ReleaseLinkClearedEvent): (ID, u8) {
    (event.release_id, event.platform)
}

#[test_only]
public fun track_link_set_event_fields(
    event: &TrackLinkSetEvent,
): (ID, u8, u64, Option<DspLinkData>) {
    (event.release_id, event.platform, event.track_index, event.link)
}

#[test_only]
public fun track_links_cleared_event_fields(event: &TrackLinksClearedEvent): (ID, u8) {
    (event.release_id, event.platform)
}
