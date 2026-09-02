# Security review — `recording_preview`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429` and `ori` at
`367ed5fe92a8b62da02c1116537cf08d111e0789`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Only the matching `RecordingAdminCap` can set or unset the preview dynamic
field. `WalrusBlob` references are accepted and incompatible quilt and
quilt-patch types cannot reach the API; the pointer may carry confidentiality
metadata. The extension authenticates the
administrator writing the pointer, not off-chain availability or contents.
Module-owned keying prevents cross-extension collisions. No value or custody
logic exists.

## Evidence

With `sui 1.78.1-722ac4fcf484`, Testnet and Mainnet builds pass, and the default
Testnet test run passes 8/8 tests covering shared-object set/replace/unset,
absence, encryption, no-op removal, and events.
