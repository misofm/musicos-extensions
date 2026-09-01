# Security review — `recording_preview`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429` and `ori` at
`1ca4e5016848bd946072db19415086a309b9930f`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Only the matching `RecordingAdminCap` can set or unset the preview dynamic
field. Standalone Walrus blobs are accepted and quilt patches rejected; the
pointer may carry encryption metadata. The extension authenticates the
administrator writing the pointer, not off-chain availability or contents.
Module-owned keying prevents cross-extension collisions. No value or custody
logic exists.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 9/9 on each network. The production
module reports 100.00% coverage across shared-object set/replace/unset, absence,
encryption, invalid shape, no-op removal, and events.
