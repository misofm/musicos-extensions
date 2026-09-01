# Security review — `recording_credits`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429`, `partyos` at
`ffb2915b9bb1802b4c160d3230c560e40bd2b063`, and `miso_credit` at
`fb0147ad5eba2e7cc41b5ee7344c6cf6840faad2`. Both network lock graphs resolve
`bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

All six mutations require the matching `RecordingAdminCap` through
`Recording::uid_mut`. Module-owned keys and private stored fields protect the
dynamic-field schema. The implementation enforces unique credited Parties,
bounded credits and roles, primary/featured membership within the credited
set, and disjoint primary and featured sets; credit removal cascades through
both designations. Credits are administrator-authored attribution and never
drive royalty accounting in this package. No Vault, Action, Plugin, or funds
movement exists here.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 39/39 on each network. Both
production modules report 100.00% coverage, including cross-release behavior,
all collection limits, designation invariants, cascades, roles, and events.
