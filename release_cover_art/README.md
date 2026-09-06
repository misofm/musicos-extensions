# `release_cover_art`

> Album-level cover art plus optional per-track cover overrides for a Miso release, stored off the frozen protocol core.

**Attaches to:** `Release` (Miso core) as a dynamic field on its `&mut UID`, reached through the release's cap-gated `uid_mut`.

Cover art is presentation, not objective recording data, so it lives on the **release** (the consumer object), not the recording — a recording carries only objective facts about its underlying sound file.

The release holds a single `ReleaseCoverArt` record: an **album-level cover** plus **per-track overrides**, a `PerTrack<Option<CoverArt>>` (one slot per track, aligned to the tracklist by construction). A track's effective cover resolves as its override if set, otherwise the album cover. All writes are gated by the `ReleaseAdminCap`; views are permissionless.

The `CoverArt` value type is provided by the independently versioned
[`misonetwork/cover-art`](https://github.com/misonetwork/cover-art) package.

## Entry points

- **`release_cover_art::set_cover`** — cap-gated; sets or replaces the album-level cover (lazily initializing the record).
- **`release_cover_art::unset_cover`** — cap-gated; clears the album-level cover; aborts if no record is attached.
- **`release_cover_art::set_track_cover`** — cap-gated; sets or replaces a track's cover override, aborting if the track index is out of range for the release.
- **`release_cover_art::unset_track_cover`** — cap-gated; removes a track's override (the track falls back to the album cover); aborts if no record is attached or the index is out of range.

## Views

- **`release_cover_art::has_cover_art`** — whether a `ReleaseCoverArt` record is attached to the release.
- **`release_cover_art::cover`** — borrows the album-level cover `Option<CoverArt>`; aborts if no record is attached.
- **`release_cover_art::track_cover`** — a track's effective cover (override if set, else the album cover); aborts if no record is attached or the index is out of range.

## Dependencies

- **`cover_art`** — the external `CoverArt` value type package.
- **`miso`** — core protocol; provides `Release` and its admin cap + `uid_mut`/`uid` accessors.
- **`per_track`** — the `PerTrack<Data>` primitive backing the per-track overrides.

## Build & test

```sh
sui move build
sui move test
```
