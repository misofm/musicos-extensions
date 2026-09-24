// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Streaming deep links for a musicos release, one Digital Service Provider
/// (DSP) at a time: an album-level link per DSP, plus an optional per-track
/// link per DSP, attached to a `musicos::release::Release`.
///
/// `DspLinkData` is a single enum with one variant per DSP holding that DSP's
/// native identifier(s); URLs are never stored, a client rebuilds them from
/// the variant it reads back. Storage is keyed by the variant's `Platform`
/// (`platform()`), so each DSP occupies its own dynamic field: the album-level link under `ReleaseLinkKey`, the
/// per-track links as a `PerTrack<Option<DspLinkData>>` under `TrackLinksKey`
/// (one slot per track, aligned to the tracklist by construction). A track
/// whose slot is `none` inherits the album-level link at the frontend.
///
/// Streaming presence is presentation, not protocol state, so it lives on the
/// release (the consumer object), not the recording. Writes are gated by the
/// `ReleaseAdminCap` via `uid_mut`; views are permissionless.
module release_dsp_link::release_dsp_link;

use musicos::release::{Release, ReleaseAdminCap};
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
/// **Variant order is frozen** and shared with `Platform`: it is the BCS tag
/// order of both enums. Supporting another platform requires a new immutable
/// package identity and an explicit client/data migration; existing variants
/// are never reordered.
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

// === Platforms ===

/// The DSP a link belongs to: the storage key and event key for one service.
/// Variants are constructed through the `platform_*` functions.
public enum Platform has copy, drop, store {
    Spotify,
    AppleMusic,
    AmazonMusic,
    Bandcamp,
    Deezer,
    SoundCloud,
    Tidal,
    YouTubeMusic,
}

/// The platform this link belongs to.
public fun platform(self: &DspLinkData): Platform {
    match (self) {
        DspLinkData::Spotify { .. } => Platform::Spotify,
        DspLinkData::AppleMusic { .. } => Platform::AppleMusic,
        DspLinkData::AmazonMusic { .. } => Platform::AmazonMusic,
        DspLinkData::Bandcamp { .. } => Platform::Bandcamp,
        DspLinkData::Deezer { .. } => Platform::Deezer,
        DspLinkData::SoundCloud { .. } => Platform::SoundCloud,
        DspLinkData::Tidal { .. } => Platform::Tidal,
        DspLinkData::YouTubeMusic { .. } => Platform::YouTubeMusic,
    }
}

public fun platform_spotify(): Platform { Platform::Spotify }

public fun platform_apple_music(): Platform { Platform::AppleMusic }

public fun platform_amazon_music(): Platform { Platform::AmazonMusic }

public fun platform_bandcamp(): Platform { Platform::Bandcamp }

public fun platform_deezer(): Platform { Platform::Deezer }

public fun platform_soundcloud(): Platform { Platform::SoundCloud }

public fun platform_tidal(): Platform { Platform::Tidal }

public fun platform_youtube_music(): Platform { Platform::YouTubeMusic }

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

/// Dynamic-field key for a DSP's album-level link — each platform occupies
/// its own field on the release's `UID`.
public struct ReleaseLinkKey(Platform) has copy, drop, store;

/// Dynamic-field key for a DSP's per-track links: a `PerTrack` of optional
/// links, one slot per track.
public struct TrackLinksKey(Platform) has copy, drop, store;

// === Events ===
//
// Each event carries the release, the track index where one applies, and
// either the new link (whose variant identifies the platform) or, on clear,
// the platform, so an event-only indexer can maintain which
// (release, platform[, track]) slots are set and what they hold.

/// Emitted when a DSP's album-level link is set or replaced with a different
/// value.
public struct ReleaseDspLinkSetEvent has copy, drop {
    release_id: address,
    link: DspLinkData,
}

/// Emitted when a DSP's album-level link is removed.
public struct ReleaseDspLinkClearedEvent has copy, drop {
    release_id: address,
    platform: Platform,
}

/// Emitted when a DSP's link for one track is set or replaced with a
/// different value.
public struct ReleaseTrackDspLinkSetEvent has copy, drop {
    release_id: address,
    track_index: u64,
    link: DspLinkData,
}

/// Emitted when a DSP's link for one track is removed (the track falls back
/// to the album-level link).
public struct ReleaseTrackDspLinkClearedEvent has copy, drop {
    release_id: address,
    platform: Platform,
    track_index: u64,
}

/// Emitted when a DSP's per-track links are removed all at once; every track
/// of the release is cleared for this platform.
public struct ReleaseTrackDspLinksClearedEvent has copy, drop {
    release_id: address,
    platform: Platform,
}

// === Album-level Write API ===

/// Sets (or replaces) a DSP's album-level link; the platform is derived from
/// `link`. Per-track links are untouched. Setting the value already stored
/// neither writes nor emits.
public fun set_release_link(self: &mut Release, cap: &ReleaseAdminCap, link: DspLinkData) {
    let release_id = object::id(self).to_address();
    let platform = link.platform();
    let uid = self.uid_mut(cap);
    let key = ReleaseLinkKey(platform);
    if (df::exists(uid, key)) {
        let stored: &mut DspLinkData = df::borrow_mut(uid, key);
        if (*stored == link) return;
        *stored = link;
    } else {
        df::add(uid, key, link);
    };
    emit(ReleaseDspLinkSetEvent { release_id, link });
}

/// Clears a DSP's album-level link. Authorizes first; an unset link is a
/// silent no-op.
public fun clear_release_link(self: &mut Release, cap: &ReleaseAdminCap, platform: Platform) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    let key = ReleaseLinkKey(platform);
    if (df::exists(uid, key)) {
        let _: DspLinkData = df::remove(uid, key);
        emit(ReleaseDspLinkClearedEvent { release_id, platform });
    }
}

// === Per-track Write API ===

/// Sets (or replaces) a DSP's link for one track (by tracklist index); the
/// platform is derived from `link`. Authorizes first, then aborts
/// `ETrackIndexOutOfBounds` past the tracklist. Setting the value already
/// stored neither writes nor emits.
public fun set_track_link(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    track_index: u64,
    link: DspLinkData,
) {
    self.authorize(cap);
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);

    let release_id = object::id(self).to_address();
    let platform = link.platform();
    let slot = track_slot_mut_or_init(self, cap, platform, track_index);
    if (slot.contains(&link)) return;
    slot.swap_or_fill(link);
    emit(ReleaseTrackDspLinkSetEvent { release_id, track_index, link });
}

/// Clears a DSP's link for one track (the track falls back to the album-level
/// link). Authorizes first; with no per-track array for this platform it is a
/// silent no-op, otherwise aborts `ETrackIndexOutOfBounds` past the tracklist
/// and is silent when the slot is already empty.
public fun clear_track_link(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    platform: Platform,
    track_index: u64,
) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    let key = TrackLinksKey(platform);
    if (!df::exists(uid, key)) return;
    let slots: &mut PerTrack<Option<DspLinkData>> = df::borrow_mut(uid, key);
    assert!(track_index < slots.length(), ETrackIndexOutOfBounds);
    let slot = slots.borrow_mut(track_index);
    if (slot.is_none()) return;
    *slot = option::none();
    emit(ReleaseTrackDspLinkClearedEvent { release_id, platform, track_index });
}

/// Removes a DSP's entire per-track array. Authorizes first; reclaims an
/// attached but empty array without emitting, and emits only when one or
/// more links were removed.
public fun clear_track_links(self: &mut Release, cap: &ReleaseAdminCap, platform: Platform) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    let key = TrackLinksKey(platform);
    if (!df::exists(uid, key)) return;
    let removed: PerTrack<Option<DspLinkData>> = df::remove(uid, key);
    let mut any_link = false;
    let mut track_index = 0;
    while (track_index < removed.length()) {
        if (removed.borrow(track_index).is_some()) any_link = true;
        track_index = track_index + 1;
    };
    if (any_link) emit(ReleaseTrackDspLinksClearedEvent { release_id, platform });
}

// === Views ===

/// Whether a DSP's album-level link is set.
public fun has_release_link(self: &Release, platform: Platform): bool {
    df::exists(self.uid(), ReleaseLinkKey(platform))
}

/// A DSP's album-level link, if set.
public fun release_link(self: &Release, platform: Platform): Option<DspLinkData> {
    let uid = self.uid();
    if (df::exists(uid, ReleaseLinkKey(platform))) {
        option::some(*df::borrow(uid, ReleaseLinkKey(platform)))
    } else {
        option::none()
    }
}

/// A DSP's link for one track, if set. An unset slot — or no array at all —
/// yields `none`, meaning the track inherits the album-level link. Aborts
/// `ETrackIndexOutOfBounds` past the tracklist when an array exists.
public fun track_link(self: &Release, platform: Platform, track_index: u64): Option<DspLinkData> {
    let uid = self.uid();
    if (!df::exists(uid, TrackLinksKey(platform))) return option::none();
    let slots: &PerTrack<Option<DspLinkData>> = df::borrow(uid, TrackLinksKey(platform));
    assert!(track_index < slots.length(), ETrackIndexOutOfBounds);
    *slots.borrow(track_index)
}

// === Private Functions ===

/// Borrows one track's slot, attaching an all-empty array for this platform
/// first if none exists. The caller has authorized and bounds-checked.
fun track_slot_mut_or_init(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    platform: Platform,
    track_index: u64,
): &mut Option<DspLinkData> {
    let key = TrackLinksKey(platform);
    if (!df::exists(self.uid(), key)) {
        // Sized to the tracklist up front; a release's track count is fixed.
        let slots = per_track::filled(self, option::none<DspLinkData>());
        df::add(self.uid_mut(cap), key, slots);
    };
    let slots: &mut PerTrack<Option<DspLinkData>> = df::borrow_mut(self.uid_mut(cap), key);
    slots.borrow_mut(track_index)
}

// === Test Functions ===

#[test_only]
public fun release_link_set_event_fields(e: &ReleaseDspLinkSetEvent): (address, DspLinkData) {
    (e.release_id, e.link)
}

#[test_only]
public fun release_link_cleared_event_fields(e: &ReleaseDspLinkClearedEvent): (address, Platform) {
    (e.release_id, e.platform)
}

#[test_only]
public fun track_link_set_event_fields(
    e: &ReleaseTrackDspLinkSetEvent,
): (address, u64, DspLinkData) {
    (e.release_id, e.track_index, e.link)
}

#[test_only]
public fun track_link_cleared_event_fields(
    e: &ReleaseTrackDspLinkClearedEvent,
): (address, Platform, u64) {
    (e.release_id, e.platform, e.track_index)
}

#[test_only]
public fun track_links_cleared_event_fields(e: &ReleaseTrackDspLinksClearedEvent): (address, Platform) {
    (e.release_id, e.platform)
}
