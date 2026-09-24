> Historical audit below predates the 2026-09-15 payload revision. Current event contracts and size bounds are documented in [EVENT_PAYLOADS.md](../EVENT_PAYLOADS.md). Storage, authority, and mutation behavior remain unchanged.

# Security review — `release_dsp_link`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840` and `per_track` at
`cba820dec3e058a1c543d5e8595ba8aed32e9dc6`. Both network lock graphs resolve
`bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Every set and clear path authenticates the matching `ReleaseAdminCap` before
mutation or no-op return. Distinct typed keys separate release links from each
platform's per-track array; key platform codes are derived from the closed
`DspLinkData` value on writes. Constructors validate non-empty bounded native
identifiers, and `PerTrack` plus explicit checks enforce track alignment.
Links are presentation data and move no value.

Platform discriminants 0 through 7 are part of this immutable package's BCS
contract. Supporting another DSP requires a new immutable package identity and
an explicit client/data migration; existing enum variants are never reordered.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 52/52 on each network. The production
module reports 100.00% coverage across every constructor, both storage levels,
authorization, bounds, replacement/clear paths, absence, events, and a shared
Release end-to-end lifecycle.

## 2026-09-24 — new generation against musicos `6dff4de`

Reviewed for a fresh immutable publication; `Published.toml` remains the
record of the prior deployment. Changes in this generation:

- `musicos` re-pinned to `6dff4deca5ced186989c064e152c92a06384750c`
  (`Release` carries no title; `publish` takes no `Clock`; `Track` carries
  no composition id). `per_track` re-pinned to
  `949e35651858a8fc5fc5c4949ceaa890a571d278`, which pins the same musicos.
- The `u8` platform codes are replaced by a `Platform` unit enum (`Spotify`,
  `AppleMusic`, `AmazonMusic`, `Bandcamp`, `Deezer`, `SoundCloud`, `Tidal`,
  `YouTubeMusic`, in `DspLinkData`'s order). `platform()` and the
  `platform_*()` constructors return `Platform`; storage keys, clear and view
  parameters, and cleared events take `Platform`. No out-of-range value can
  exist any more; none was validated before either, since an unknown code
  merely addressed an empty field.
- Events slimmed to what an event-only indexer needs, all monomorphic:
  `ReleaseDspLinkSetEvent { release_id, link }` (at most 293 BCS bytes),
  `ReleaseDspLinkClearedEvent { release_id, platform }` (33),
  `ReleaseTrackDspLinkSetEvent { release_id, track_index, link }` (at most
  301), `ReleaseTrackDspLinkClearedEvent { release_id, platform, track_index }`
  (41), and `ReleaseTrackDspLinksClearedEvent { release_id, platform }` (33).
  Admin cap ids, track counts, field lifecycle and presence flags, recording
  and composition ids, album-fallback flags, and the removed-link count were
  dropped; set events carry the new link, whose variant identifies the
  platform and whose identifiers are bounded by the constructors.
- Setting the value already stored, on the album or a track slot, is now a
  true no-op: no write, no event. Clearing an empty track slot no longer
  writes.
- Guard order: `set_track_link` now authorizes the cap before checking the
  track index (previously the reverse); the other writes already authorized
  first. Constructor validation is argument-only and precedes every call.
- Error constants are unchanged.

Evidence: with Sui 1.79.0, Testnet and Mainnet builds and tests pass with no
warnings, the lockfile pins musicos `6dff4de` and per_track `949e356` for
both environments, and the suite passes 60/60 on each environment (54
before): every constructor bound, both storage levels, per-platform
isolation, the shared variant order of `Platform` and `DspLinkData`,
equal-set and empty-clear silence, wrong caps on every write including
before the bounds check, view fallback, exact event BCS layouts at the
widest link, an event-only replay of per-track slots against storage, and
the published/shared lifecycle across senders.
