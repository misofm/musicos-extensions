# Security review — `release_genre`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `genre` at
`069fee03d7cae357d5a805e28eeb24171f10c303`, `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429`, and `per_track` at
`547befbb33be14ac7400fabc01962a96bd54fb1e`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Every mutation requires the matching `ReleaseAdminCap`. Stored IDs come from
typed `&Genre` objects. The package enforces one primary, bounded unique
secondaries disjoint from the primary, and bounds-checked per-track overrides
aligned by `PerTrack`. Module-owned keying and private stored fields protect the
schema. Genre classification is data only and has no on-chain economic effect.

This source is intended for a new immutable package identity. It does not claim
compatibility with any retired deployment; clients migrate explicitly by
selecting the new package and its dynamic-field key type.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 20/20 on each network. The production
module reports 100.00% coverage across shared Releases, authorization,
primary/secondary invariants, bounds, overrides, fallback, and events.
