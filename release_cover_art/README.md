# `release_cover_art`

> Album-level cover art plus optional per-track cover overrides for a musicos release, stored off the frozen protocol core.

**Attaches to:** `Release` (musicos core) as a dynamic field on its `&mut UID`, reached through the release's cap-gated `uid_mut`.

Cover art is presentation, not objective recording data, so it lives on the **release** (the consumer object), not the recording — a recording carries only objective facts about its underlying sound file.

The release holds a single `ReleaseCoverArt` record: an **album-level cover** plus **per-track overrides**, a `PerTrack<Option<CoverArt>>` (one slot per track, aligned to the tracklist by construction). A track's effective cover resolves as its override if set, otherwise the album cover. All writes are gated by the `ReleaseAdminCap`; views are permissionless.

The `CoverArt` value type is provided by the independently versioned
[`misofm/cover-art`](https://github.com/misofm/cover-art) package.

## Entry points

- **`release_cover_art::set_cover`** — cap-gated; sets or replaces the album-level cover (lazily initializing the record).
- **`release_cover_art::unset_cover`** — cap-gated; clears the album-level cover; aborts if no record is attached.
- **`release_cover_art::set_track_cover`** — cap-gated; sets or replaces a track's cover override, aborting if the track index is out of range for the release.
- **`release_cover_art::unset_track_cover`** — cap-gated; removes a track's override (the track falls back to the album cover); aborts if no record is attached or the index is out of range.

## Events

Each successful write emits exactly one event after the storage write. The four
event types are `ReleaseCoverArtSetEvent`, `ReleaseCoverArtUnsetEvent`,
`ReleaseTrackCoverArtSetEvent`, and `ReleaseTrackCoverArtUnsetEvent`. Every
event begins with `release_id`, `admin_cap_id`, `track_count`,
`field_existed_before`, and `field_exists_after`. Track events then include
`track_index`, the immutable track `recording_id`, and `composition_id`.

Album events contain flat `previous_` and `current_` snapshots. Track events
contain flat `previous_`, `current_`, and unchanged `album_` snapshots. Each
snapshot contains `present`, the still blob ID, encryption flag, sealed-DEK
length and digest, then the corresponding five animation fields. A snapshot
uses zero IDs, false flags, zero lengths, and an empty digest when absent. A
present plaintext blob uses the same canonical encryption fields. For an
encrypted blob, the event retains the full blob ID and records the raw
sealed-DEK length and `blake2b256` digest; the sealed-DEK bytes remain in the
stored value and the digest cannot reconstruct them.

The track snapshots describe the stored override, not the resolved cover. A
consumer uses the override when `present` and otherwise the album snapshot.
Album and track unsets keep the dynamic-field record and emit even when the
value was already empty, so replay can observe those writes. `field_exists_after`
is always true; views do not emit events. The fixed BCS sizes are 246 bytes
for an album event with plaintext/absent snapshots and 404 bytes for a track
event, plus 32 bytes per encrypted blob (maximums are 374/310 for album
set/unset and 596/532 for track set/unset).

## Views

- **`release_cover_art::has_cover_art`** — whether a `ReleaseCoverArt` record is attached to the release.
- **`release_cover_art::cover`** — borrows the album-level cover `Option<CoverArt>`; aborts if no record is attached.
- **`release_cover_art::track_cover`** — a track's effective cover (override if set, else the album cover); aborts if no record is attached or the index is out of range.

## Dependencies

- **`cover_art`** — the external `CoverArt` value type package.
- **`musicos`** — core protocol; provides `Release` and its admin cap + `uid_mut`/`uid` accessors.
- **`per_track`** — the `PerTrack<Data>` primitive backing the per-track overrides.

## Build & test

```sh
sui move build
sui move test
sui move test --coverage
sui move coverage summary --summarize-functions
```
