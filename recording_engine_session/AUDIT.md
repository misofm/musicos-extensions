# Security review — `recording_engine_session`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429` and `ori` at
`1ca4e5016848bd946072db19415086a309b9930f`. Both network lock graphs resolve
`bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Only the matching `RecordingAdminCap` can attach, replace, or unset the one
module-keyed `EngineSession`. Attach never silently overwrites; replacement is
explicit. The outer `WalrusData` must be a standalone, unencrypted blob, so the
root delivery graph is publicly discoverable; separately referenced audio may
still use independent encryption policy. On-chain validation proves reference
shape, not the truth, availability, or semantics of off-chain blob contents.
This data extension contains no custody or economic logic.

The package is published immutably. Changed validation or schema requires a
new package identity and an explicit client/data migration path.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 9/9 on each network. The production
module reports 100.00% coverage, including a published/shared Recording flow,
wrong shape and encryption rejection, attach/replace/unset, scoping, and events.
