# Security review — `release_kind`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4fed48b2b5632122fb677d742881259c65b1bc78`. Both network lock graphs resolve
`bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Set and unset require the matching `ReleaseAdminCap`, including the empty
unset path. A module-owned key stores one bounded, non-empty UTF-8 String.
Case and vocabulary are intentionally administrator-defined; clients must not
treat this presentation label as a protocol-enforced classification. There is
no value or custody surface.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 14/14 on each network. The production
module reports 100.00% coverage across shared Release lifecycle, wrong caps,
absence, length bounds, case preservation, replacement, unset, and events.
