# Security review — `release_credits`

Reviewed 2026-09-11 for the rich primitive mutation events. The review covers
the existing cap-gated storage and guard order plus the bounded event
snapshots. Verdict: no exploitable findings in the reviewed source.

## Dependency provenance

`musicos` and `partyos` provide the release and credited `Party` identity,
while the direct `credit` dependency provides `Credit<ReleasePartyRole>` and
its display-name/role container. The checked-in manifest pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`, `partyos` at
`841a875a4989082a0ebeb1beb464b71f9ea2bd73`, and `credit` at
`0780d1d694a4d35315af20e1ea7d707558846024`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Add and remove require the matching ID-bound `ReleaseAdminCap`. Module-owned
keying and private fields protect the dynamic-field schema. The implementation
enforces one credit per Party, a bounded collection, and exactly one closed
`Primary` or `Featured` role per credit. Credits are administrator-authored
billing metadata; Release revenue follows immutable track splits and is not
read here. The package contains no Action, Plugin, Vault, or funds logic.

## Evidence

With Sui `1.79.0`, strict Testnet and Mainnet builds and tests pass: 20/20
tests. Both production modules report 100.00% coverage across local release
storage, authorization, exact role cardinality, bounds, duplicates, removal,
and event snapshots.
