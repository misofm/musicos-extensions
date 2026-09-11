# Security review — `recording_language`

Reviewed 2026-09-11 for rich primitive language mutation events. Verdict: no
exploitable findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840` and `language_code` at
`61542357f3d2ff989d120185046def7cf6c8bdcb`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Writes require `RecordingAdminCap<RecordingShare>` for the matching
`RecordingShare` type; the composition-share type is phantom. `uid_mut` is
type-only and ignores the cap value, so there is no runtime cap-value
authentication: a different cap value with the same `RecordingShare` type is
observationally accepted, while a mismatched `RecordingShare` cannot compile.
The external value type validates ISO language codes; this extension bounds the
vector at ten entries and rejects duplicates, checking the count before
duplicates. An attached empty vector explicitly means instrumental, while
dynamic-field absence means unspecified. Module-owned keys protect the schema.
No economic, Vault, Action, or Plugin surface exists.

Set events are generic over both recording-share and composition-share types
and carry actual object addresses plus ordered raw two-byte code snapshots.
They include the prior vector only when a value was present, the post-write
vector, transition counts/flags, and the maximum bound. Clear events carry the
removed raw vector and its prior count/flag; a present empty value emits, while
an absent value is silent. The cap's `uid_mut` use remains type-only.

## Evidence

With Sui `1.79.0`, strict Testnet and Mainnet warnings-as-errors builds and
tests pass: 15/15 on each network. The production module reports 100.00%
coverage across published/shared operation, validation, bounds, duplicates,
instrumental semantics, absence, removal, phantom event streams, and exact
primitive event fields.
