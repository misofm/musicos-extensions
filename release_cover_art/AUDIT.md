# Security review — `release_cover_art`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `cover_art` at
`7672ad1c656c23bb6dda20a62661d83a6c9e75bd`, `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429`, and `per_track` at
`547befbb33be14ac7400fabc01962a96bd54fb1e`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` and `ori` at
`1ca4e5016848bd946072db19415086a309b9930f`, with no duplicate aliases.

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
