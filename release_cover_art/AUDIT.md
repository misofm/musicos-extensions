# Security review — `release_cover_art`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `cover_art` at
`21fb2c04417fb0075d47f20c28149100e90af2cb`, `musicos` at
`4fed48b2b5632122fb677d742881259c65b1bc78`, and `per_track` at
`8d6dfdd3955b2f0e3d0e9651802ec49d30197da1`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` and `ori` at
`367ed5fe92a8b62da02c1116537cf08d111e0789`, with no duplicate aliases.

## Threat model and findings

All release-level and track-level writes require the matching
`ReleaseAdminCap`. `PerTrack` fixes override-array length to the immutable
tracklist and every indexed path checks bounds. Module-owned keying and private
stored fields protect the schema. Cover references inherit their validation
from the exact `cover_art` and `ori` dependencies. This is presentation data;
it neither moves revenue nor authorizes another operation.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 18/18 on each network. The production
module reports 100.00% coverage, including a published/shared Release flow,
wrong-cap attempts, album and track lifecycle, bounds, fallback, and events.
