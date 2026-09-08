# Security review — `recording_language`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4fed48b2b5632122fb677d742881259c65b1bc78` and `language_code` at
`61542357f3d2ff989d120185046def7cf6c8bdcb`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Only the matching `RecordingAdminCap` can set or unset languages. The external
value type validates ISO language codes; this extension bounds the vector and
rejects duplicates. An attached empty vector explicitly means instrumental,
while dynamic-field absence means unspecified. Module-owned keys protect the
schema. No economic, Vault, Action, or Plugin surface exists.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 15/15 on each network. The production
module reports 100.00% coverage across published/shared operation, validation,
bounds, duplicates, instrumental semantics, absence, removal, and events.
