# Security review — `recording_advisory`

Reviewed 2026-09-11 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`. The generated Testnet and
Mainnet lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` with no duplicate package aliases.

## Threat model and findings

The relevant threat is an unauthorized rating change. Set and unset require the
typed `RecordingAdminCap` through `Recording::uid_mut`, including the unset
no-op path. The cap address carried by an event is provenance; there is no
additional runtime cap-ID equality check. `ExtensionKey` is module-owned and
the stored rating is a closed enum, so malformed or cross-extension values
cannot enter through this API. Absence, `NotExplicit`, and `Cleaned` remain
distinct. The package moves no funds and contains no Vault, Action, or Plugin
logic. Primitive event snapshots use stable compact codes and preserve both
phantom share dimensions.

## Evidence

With `sui 1.79.0`, strict Testnet and Mainnet lint, warnings-as-errors builds,
and tests pass: 12/12 on each network. The production module reports 100.00%
coverage, including published/shared-object lifecycle, all rating transitions,
equal replacement, absent/repeated clears, both phantom dimensions, exact
primitive event payloads, silent views/constructors, and the existing absence
abort.
