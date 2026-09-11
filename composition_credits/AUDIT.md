# Security review — `composition_credits`

Reviewed 2026-09-11 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`, `partyos` at
`841a875a4989082a0ebeb1beb464b71f9ea2bd73`, and `credit` at
`0780d1d694a4d35315af20e1ea7d707558846024`. The generated Testnet and
Mainnet lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` with no duplicate package aliases.

## Threat model and findings

The security boundary is attribution integrity. Both mutations require a typed
`CompositionAdminCap` through `Composition::uid_mut`; the cap address in an
event is provenance and is not separately runtime-matched to the composition.
Module-owned `ExtensionKey` and private stored fields prevent cross-extension
key or value confusion. Duplicate parties, credit count, and roles-per-credit
are bounded. Credits are descriptive data only: this package contains no funds
movement, Vault borrowing, Action, or Plugin logic. A Composition administrator
can name a Party without that Party's consent; this is the documented meaning
of an administrator-authored credit, not a royalty authorization. Event role
snapshots use bounded primitive bytes and preserve role order without invoking
the public role-name view.

## Evidence

With `sui 1.79.0`, strict lint and warnings-as-errors builds and tests pass on
Testnet and Mainnet: 16/16 tests. The suite covers shared published objects,
authorization, limits, duplicate rejection, role validation, insertion-order
indices, retained empty records, generic event streams, and primitive event
fields.
