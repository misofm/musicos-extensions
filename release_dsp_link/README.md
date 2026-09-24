# release_dsp_link

`release_dsp_link` stores raw native identifiers for eight streaming services
(DSPs) on a `musicos::release::Release`: one album-level link per DSP and an
optional per-track link per DSP. URLs are never stored; a client rebuilds
them from the variant it reads back.

## Storage

Two module-owned dynamic-field keys on the release's `UID`, both keyed by
`Platform`:

```text
ReleaseLinkKey(Platform) -> DspLinkData
TrackLinksKey(Platform)  -> PerTrack<Option<DspLinkData>>
```

`Platform` is a unit enum with one variant per service, in the same order as
`DspLinkData`: `Spotify`, `AppleMusic`, `AmazonMusic`, `Bandcamp`, `Deezer`,
`SoundCloud`, `Tidal`, `YouTubeMusic`. Callers obtain a value through the
matching `platform_*()` constructor or from a link's `platform()`.

Each DSP occupies its own fields, so setting or clearing one DSP never
touches another. The per-track array is sized to the tracklist on first use
(`per_track::filled`), one slot per track; a `none` slot means the track
inherits the album-level link at the frontend. `track_link` returns the raw
slot and applies no fallback.

The variant order of both enums is part of this immutable package's BCS
contract. Supporting another DSP requires a new package identity and an
explicit client/data migration; existing variants are never reordered.

## API

Constructors validate non-empty identifiers against per-field byte bounds
(ids 64 bytes; Bandcamp and SoundCloud handles and slugs 128 bytes) and abort
with the constants listed under Errors. All writes require the release's
`ReleaseAdminCap` and go through the cap-gated `release::uid_mut`; views are
permissionless.

| Function | Description | Aborts |
|---|---|---|
| `set_release_link(release, cap, link)` | Sets or replaces the album-level link for `link`'s platform. Setting the value already stored neither writes nor emits. | wrong cap (`release::EUnauthorized`, 0) |
| `clear_release_link(release, cap, platform)` | Removes the album-level link; an unset link is a silent no-op | wrong cap (0), even when unset |
| `set_track_link(release, cap, track_index, link)` | Sets or replaces one track's link for `link`'s platform, attaching the per-track array on first use. Setting the value already stored neither writes nor emits. | wrong cap (0), then `ETrackIndexOutOfBounds` (0, this module) past the tracklist |
| `clear_track_link(release, cap, platform, track_index)` | Empties one track's slot; with no array for this platform, or an already-empty slot, a silent no-op | wrong cap (0), then `ETrackIndexOutOfBounds` when an array exists |
| `clear_track_links(release, cap, platform)` | Removes the whole per-track array; emits only if at least one slot held a link | wrong cap (0), even when absent |
| `has_release_link(release, platform): bool` | Whether an album-level link is set | — |
| `release_link(release, platform): Option<DspLinkData>` | The album-level link, if set | — |
| `track_link(release, platform, track_index): Option<DspLinkData>` | One track's raw slot; `none` with no array | `ETrackIndexOutOfBounds` when an array exists |
| `platform(link): Platform`, `platform_*(): Platform` | The link's platform; the eight platform constructors | — |
| `new_spotify`, `new_apple_music_album`, `new_apple_music_track`, `new_amazon_music_album`, `new_amazon_music_track`, `new_bandcamp`, `new_deezer`, `new_soundcloud`, `new_tidal`, `new_youtube_music` | Validated constructors | see Errors |

## Events

All events are monomorphic and carry only what an event-only indexer would
otherwise have to look up: the release, the track index where one applies,
and either the new link itself (whose variant identifies the platform) or,
on clear, the `Platform`. Replaying them per
`(release_id, platform[, track_index])` yields every link currently set;
the tracklist itself is known from core's `ReleaseTrackAssignedEvent`.

| Event | Fields | BCS size |
|---|---|---|
| `ReleaseDspLinkSetEvent` | `release_id: address`, `link: DspLinkData` | 32 + link; at most 293 |
| `ReleaseDspLinkClearedEvent` | `release_id: address`, `platform: Platform` | 33 |
| `ReleaseTrackDspLinkSetEvent` | `release_id: address`, `track_index: u64`, `link: DspLinkData` | 40 + link; at most 301 |
| `ReleaseTrackDspLinkClearedEvent` | `release_id: address`, `platform: Platform`, `track_index: u64` | 41 |
| `ReleaseTrackDspLinksClearedEvent` | `release_id: address`, `platform: Platform` | 33 |

A `Platform` encodes as its one-byte variant tag. A `DspLinkData` encodes as
its variant tag followed by its `String` fields (and `Option<String>`
selector); the widest is a 128-byte Bandcamp or SoundCloud handle plus slug
at 261 bytes. Set events are emitted only when
the stored value actually changes; cleared events only when a link was
actually removed. `ReleaseTrackDspLinksClearedEvent` means every track's slot
for that platform is now empty. Views emit nothing.

## Errors

| Code | Constant | Location | Condition |
|---|---|---|---|
| 0 | `ETrackIndexOutOfBounds` | `release_dsp_link::release_dsp_link` | track index past the tracklist |
| 10, 11 | `EEmptySpotifyId`, `EMaxSpotifyIdLengthExceeded` | same | Spotify id empty / over 64 bytes |
| 20–23 | `EEmptyAppleMusicIdentifier`, `EMaxAppleMusicStorefrontLengthExceeded`, `EMaxAppleMusicAlbumIdLengthExceeded`, `EMaxAppleMusicTrackIdLengthExceeded` | same | Apple Music identifier empty / over 64 bytes |
| 30–32 | `EEmptyAmazonMusicIdentifier`, `EMaxAmazonMusicAlbumIdLengthExceeded`, `EMaxAmazonMusicTrackIdLengthExceeded` | same | Amazon Music ASIN empty / over 64 bytes |
| 40–42 | `EEmptyBandcampIdentifier`, `EMaxBandcampSubdomainLengthExceeded`, `EMaxBandcampSlugLengthExceeded` | same | Bandcamp identifier empty / over 128 bytes |
| 50, 51 | `EEmptyDeezerId`, `EMaxDeezerIdLengthExceeded` | same | Deezer id empty / over 64 bytes |
| 60–62 | `EEmptySoundCloudIdentifier`, `EMaxSoundCloudUserLengthExceeded`, `EMaxSoundCloudSlugLengthExceeded` | same | SoundCloud identifier empty / over 128 bytes |
| 70, 71 | `EEmptyTidalId`, `EMaxTidalIdLengthExceeded` | same | Tidal id empty / over 64 bytes |
| 80, 81 | `EEmptyYouTubeMusicId`, `EMaxYouTubeMusicIdLengthExceeded` | same | YouTube Music id empty / over 64 bytes |
| 0 | `EUnauthorized` | `musicos::release` | any write with a cap for a different release |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Release`, `ReleaseAdminCap`,
  the tracklist, and cap-gated `uid_mut`.
- [`per_track`](https://github.com/misofm/per-track) at
  `949e35651858a8fc5fc5c4949ceaa890a571d278` — the tracklist-aligned
  `PerTrack` array, pinned to the same musicos.

## Publishing

`Published.toml` records the previously deployed generation. This generation
is published as a fresh immutable package identity and never upgraded in
place; clients migrate explicitly.

## Build and test

Run from this directory:

```sh
sui move build
sui move build --build-env mainnet
sui move test
sui move test --build-env mainnet
```
