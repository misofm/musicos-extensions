# Security Audit — `release_dsp_link`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pins: `miso` @ `c23fe7f…` (bumped 2026-08-23 from `7c13e40a…`, carrying the `miso_share` treasury-cap hardening `d67ff8c`), `per_track` @ `e1bb40b…` (bumped 2026-08-23 alongside `miso`) (`Move.toml`); audited
dependency sources are the on-disk `../../protocol`, `../../per-track` trees.
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

Audit of `release_dsp_link` (530 LOC,
`sources/release_dsp_link.move`), the largest extension: per-DSP streaming
deep links — one album-level link per platform plus optional per-track links.
Verdict: **safe to publish — no exploitable findings; one informational
hardening note.**

## What it does

`DspLinkData` (`release_dsp_link.move:134-181`) is a closed enum with one
variant per DSP (Spotify, AppleMusic, AmazonMusic, Bandcamp, Deezer,
SoundCloud, Tidal, YouTubeMusic), each holding that DSP's native string
identifier(s), all constructor-validated non-empty and ≤ 64/128 bytes
(`release_dsp_link.move:229-334`). Storage is keyed per platform: a
`DspLinkData` under `ReleaseLinkKey(platform)` at album level and a
`PerTrack<Option<DspLinkData>>` under `TrackLinksKey(platform)` for per-track
overrides (`release_dsp_link.move:340-344`). Write API: `set_release_link`,
`clear_release_link`, `set_track_link`, `clear_track_link`,
`clear_track_links`; views are permissionless.

## Threat model

The threat is unauthorized attach/alter/removal of DSP links on someone else's
release (metadata integrity — clients build playable URLs from these). The
authorization chain:

- Every *state-changing* path passes through `self.uid_mut(cap)` before the
  write: `set_release_link` (`release_dsp_link.move:391`), `set_track_link`
  via `track_links_mut_or_init` (`release_dsp_link.move:503,505`), and the
  three clear functions inside their existence branches
  (`release_dsp_link.move:404,439,449-452`). `miso::release::uid_mut`
  (`protocol/sources/release.move:337-340`) enforces `cap.release_id ==
  object::id(self)` — ID-level binding. **No mutation is possible without the
  release's own cap.**
- **Key hygiene:** `ReleaseLinkKey(u8)` and `TrackLinksKey(u8)` are
  module-local and distinct types — album links and track-link arrays can
  never alias, and no other package's key can collide with either. Per-DSP
  isolation is real: each platform is an independent dynamic field, so
  touching Spotify's field never touches Deezer's.
- **Key/value type consistency:** the value under `ReleaseLinkKey` is always a
  `DspLinkData` whose `platform()` equals the key's `u8` — `set_release_link`
  derives the key from the link itself (`release_dsp_link.move:390-396`), so a
  mismatched pairing cannot be written through the public API. (Raw `df` calls
  could forge one, but those require the admin cap — already trusted.)
- **Alignment:** per-track arrays are sized to the frozen tracklist at first
  attach (`per_track::filled`, `release_dsp_link.move:502`) and all per-track
  accesses bounds-check against `tracks().length()`
  (`release_dsp_link.move:420,437,480`).
- **DoS:** no loops beyond `per_track::filled`'s ≤ 255 iterations;
  identifiers are length-capped; writer-paid gas.

## Findings

- **F1 (Informational): the three `clear_*` functions skip the cap check on
  their no-op paths.** `clear_release_link` (`release_dsp_link.move:401-407`),
  `clear_track_link` (`release_dsp_link.move:430-443`), and
  `clear_track_links` (`release_dsp_link.move:446-455`) check field existence
  first and only call `uid_mut(cap)` inside the branch. With nothing attached,
  anyone can call them — but the call is a guaranteed no-op: no state change,
  no event, nothing read that `has_release_link` doesn't already reveal. There
  is no exploitable impact; the note exists because sibling packages
  deliberately gate first even on no-op paths (`release_description.move:
  113-115`, `release_cover_art.move:83`), and that discipline is worth
  matching if the package is ever revised. Since all packages publish
  immutable, this stays as-is by design.

## Edge cases verified

- `platform` values outside 0–7 are harmless: `ReleaseLinkKey(200)` /
  `TrackLinksKey(200)` simply never exist, so clears and views are no-ops /
  `none`. Only constructors can mint `DspLinkData`, and their `platform()` is
  always in range.
- Track index `== tracks().length()` aborts `ETrackIndexOutOfBounds` in
  `set_track_link`, `clear_track_link` (when an array exists), and the
  `track_link` view.
- `clear_track_link` with no per-track array is a no-op even for an
  out-of-range index (existence check first) — consistent with its doc.
- Replace-over-existing overwrites in place at both levels; clearing one track
  slot emits `TrackLinkSetEvent { link: none }` so indexers drop the row.
- Events carry the full new value on every set
  (`release_dsp_link.move:397,424`), so indexers never re-read state.
- Enum variant order is load-bearing for the `platform()` discriminants and is
  documented as frozen (`release_dsp_link.move:128-133`); with an immutable
  republish this is permanently stable.

## Verification

- **51/51 tests pass** (`sui move test`, sui 1.77.2) — the largest extension
  suite, covering every constructor's validation, both storage levels, clear
  paths, and view behavior with nothing stored.
- Full source read; auth contract cross-checked against
  `miso::release::uid_mut`/`authorize`.
