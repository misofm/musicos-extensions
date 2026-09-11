# Security review — `recording_credits`

Reviewed 2026-09-11 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`, `partyos` at
`841a875a4989082a0ebeb1beb464b71f9ea2bd73`, and `credit` at
`0780d1d694a4d35315af20e1ea7d707558846024`. The direct `credit` dependency
provides `Credit<RecordingPartyRole>`; `partyos` provides only the credited
`Party` identity. Both network lock graphs resolve `bps` without duplicate
aliases.

## Threat model and findings

All six mutations require a `RecordingAdminCap<RecordingShare>` through
`Recording::uid_mut`; “matching” means the `RecordingShare` type parameter
only. In the pinned `musicos` dependency, `uid_mut` ignores the cap's object ID,
sender, and recording lifecycle, so this package does not claim a per-recording
cap-identity or caller check. Module-owned keys and private stored fields
protect the dynamic-field schema. The implementation enforces unique credited
Parties, bounded credits and roles, primary/featured membership within the
credited set, and disjoint primary and featured sets; credit removal cascades
through both designations. Credits are administrator-authored attribution and
never drive royalty accounting in this package. The six generic rich events
carry only bounded primitive snapshots and identifiers; credit removal emits
its event immediately after map removal, followed by designation cascade events
in set-mutation order. Views and constructors are silent. No Vault, Action,
Plugin, or funds movement exists here.

## Evidence

With Sui 1.79.0, strict Testnet and Mainnet lint, warnings-as-errors builds,
and tests pass: 44/44 on each network. Production coverage is checked for both
modules, including collection limits, designation invariants, cascades, roles,
and rich event payload serialization.
