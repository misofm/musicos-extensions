# Security review — `release_dsp_link`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429` and `per_track` at
`547befbb33be14ac7400fabc01962a96bd54fb1e`. Both network lock graphs resolve
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
warnings-as-errors builds, and tests pass: 54/54 on each network. The production
module reports 100.00% coverage across every constructor, both storage levels,
authorization, bounds, replacement/clear paths, absence, events, and a shared
Release end-to-end lifecycle.
