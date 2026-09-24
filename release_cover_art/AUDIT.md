# Security review — `release_cover_art`

Reviewed 2026-09-11 for immutable publication and rich event payloads. Verdict:
no exploitable findings in the reviewed source.

## Dependency provenance

The Testnet manifest pins `cover_art` at
`603981fd563d10f3f89afe74851c1c4d3d50b0b4`, `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`, and `per_track` at
`cba820dec3e058a1c543d5e8595ba8aed32e9dc6`. The checked-in Mainnet lock
graph pins those packages at `21fb2c04417fb0075d47f20c28149100e90af2cb`,
`b3d5d4005fe36044d90e318f864dbc8b01de41da`, and
`95b9830bda45fd82412c7653711ce9a2044a8be8`, respectively. Both graphs
resolve `bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` and `ori` at
`367ed5fe92a8b62da02c1116537cf08d111e0789`, with no duplicate aliases.

## Threat model and findings

All release-level and track-level writes require the matching
`ReleaseAdminCap`. `PerTrack` fixes override-array length to the immutable
tracklist and every indexed path checks bounds. Module-owned keying and private
stored fields protect the schema. Cover references inherit their validation
from the exact `cover_art` and `ori` dependencies. This is presentation data;
it neither moves revenue nor authorizes another operation.

## Evidence

With `/tmp/routed-stake-audit.zf2B9E/sui` (Sui 1.78.1-722ac4fcf484), isolated
Testnet and Mainnet copies pass strict lint/warnings-as-errors builds and tests:
19/19 on each network. Coverage runs on both copies report 97.02% for the
production module; all public mutation/view functions are 100% covered, while
the remaining uncovered lines are the encrypted sealed-DEK snapshot branches,
which cannot be constructed from this package without adding the already
transitive `ori` package to the manifest. The exercised tests cover the
published/shared Release flow, wrong-cap attempts, album and track lifecycle,
bounds, fallback, canonical absent/plaintext/animated snapshots, BCS field
decoding, and event cardinality.

## 2026-09-24 — regeneration against musicos `6dff4de`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c`, where `release::new` takes no
title, `publish` takes no Clock, and `Track` carries no composition id.
`cover_art` stays at `8c2de9971e092ae98b042634893cb4791548ffd0`, `per_track`
at `949e35651858a8fc5fc5c4949ceaa890a571d278` (re-pinned to the same musicos), and `ori` (test only) at
`367ed5fe92a8b62da02c1116537cf08d111e0789`. Verdict on the reviewed source:
no exploitable findings.

Changes in this generation:

- `unset_cover` → `clear_cover`, `unset_track_cover` → `clear_track_cover`.
- Events renamed `Release{,Track}CoverArtUnsetEvent` →
  `Release{,Track}CoverArtClearedEvent` and slimmed to the release address,
  the track index on per-track events, and on set the still blob ID plus the
  optional animated blob ID: 65/97, 32, 73/105, and 40 BCS bytes (down from
  374, 310, 596, and 532 maximums). Dropped: admin cap address, track count,
  field-existence flags, the track's recording and composition ids (joinable
  via core's `ReleaseTrackAssignedEvent` on `(release_id, position)`),
  previous/current/album snapshots, encryption flags, sealed-DEK lengths and
  digests, and the nested `CoverSnapshot`. On-chain `blake2b256` hashing of
  sealed DEKs goes with them; a blob's confidentiality envelope is read from
  the release.
- Equal sets neither write nor emit (previously they rewrote silently);
  clears with no record attached are silent instead of aborting
  `ENoCoverArt`, which the views still raise.
- Guard order: track-index validation → cap check via `uid_mut` →
  stored-state. `clear_track_cover` therefore rejects an out-of-range index
  even with nothing attached, and `borrow_mut_or_init` gates before its
  existence check.

Storage key, record shape, `PerTrack` alignment, the override-then-album
resolution rule, and authorization are unchanged.

Evidence: with Sui `1.79.0`, strict lint and warnings-as-errors builds pass and all 21 tests
pass on Testnet and Mainnet (previously 20); the production module reports
100.00% coverage (up from 97.02%: the encrypted-blob paths are now exercised
and no longer branch).
