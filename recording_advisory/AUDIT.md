# Security review — `recording_advisory`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429`. The generated Testnet and
Mainnet lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` with no duplicate package aliases.

## Threat model and findings

The relevant threat is an unauthorized rating change. Set and unset require
the matching `RecordingAdminCap` through `Recording::uid_mut`, including the
unset no-op path. `ExtensionKey` is module-owned and the stored rating is a
closed enum, so malformed or cross-extension values cannot enter through this
API. Absence, `NotExplicit`, and `Cleaned` remain distinct. The package moves no
funds and contains no Vault, Action, or Plugin logic.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 10/10 on each network. The production
module reports 100.00% coverage, including published/shared-object lifecycle,
absence, replacement, removal, authorization, and event behavior.
