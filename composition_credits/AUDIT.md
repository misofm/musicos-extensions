# Security review — `composition_credits`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4fed48b2b5632122fb677d742881259c65b1bc78`, `partyos` at
`819fde6f34c0bc7eeb57ec7340cdf13dc56b3fca`, and `credit` at
`b96fae3faf8836e5ad718b1a7700fbd11e07708b`. The generated Testnet and
Mainnet lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` with no duplicate package aliases.

## Threat model and findings

The security boundary is attribution integrity. Both mutations require the
matching `CompositionAdminCap` through `Composition::uid_mut`; module-owned
`ExtensionKey` and private stored fields prevent cross-extension key or value
confusion. Duplicate parties, credit count, and roles-per-credit are bounded.
Credits are descriptive data only: this package contains no funds movement,
Vault borrowing, Action, or Plugin logic. A Composition administrator can name
a Party without that Party's consent; this is the documented meaning of an
administrator-authored credit, not a royalty authorization.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict lint and warnings-as-errors builds and
tests pass on Testnet and Mainnet: 16/16 tests on each network. Both production
modules report 100.00% coverage. The suite covers shared published objects,
authorization, limits, duplicate rejection, role validation, and event fields.
