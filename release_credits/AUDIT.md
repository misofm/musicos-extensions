# Security review — `release_credits`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429`, `partyos` at
`ffb2915b9bb1802b4c160d3230c560e40bd2b063`, and `miso_credit` at
`fb0147ad5eba2e7cc41b5ee7344c6cf6840faad2`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Add and remove require the matching ID-bound `ReleaseAdminCap`. Module-owned
keying and private fields protect the dynamic-field schema. The implementation
enforces one credit per Party, a bounded collection, and exactly one closed
`Primary` or `Featured` role per credit. Credits are administrator-authored
billing metadata; Release revenue follows immutable track splits and is not
read here. The package contains no Action, Plugin, Vault, or funds logic.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 13/13 on each network. Both
production modules report 100.00% coverage across shared Releases,
authorization, exact role cardinality, bounds, duplicates, removal, and events.
