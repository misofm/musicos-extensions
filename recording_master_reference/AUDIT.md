# Security review — `recording_master_reference`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429` and `ori` at
`1ca4e5016848bd946072db19415086a309b9930f`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Only the matching `RecordingAdminCap` can set or unset the module-keyed master
reference. The extension accepts standalone Walrus blob references, including
encrypted blobs, and rejects quilt patches. It attests only to the Recording
administrator's chosen pointer; it cannot prove off-chain blob availability,
authenticity, decoding, or key delivery. It contains no funds or custody logic.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 13/13 on each network. The production
module reports 100.00% coverage across public/encrypted references, invalid
shape rejection, replacement/unset, shared-object flow, isolation, and events.
