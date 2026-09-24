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

## 2026-09-24 — regeneration against musicos `6dff4de`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c`, where `Recording` takes a single
`RecordingShare` parameter and `publish` no longer takes a Clock. Verdict
unchanged: no exploitable findings.

Changes in this generation:

- Enum renamed `ExplicitRating` → `Advisory`; functions renamed `set_rating` →
  `set_advisory`, `unset_rating` → `clear_advisory`, `has_rating` →
  `has_advisory`, `rating` → `advisory`; error `ENoRating` → `ENoAdvisory`
  (still 1). The `name()` view was dropped: the variant is available through
  the predicates and the set event.
- Events renamed `RecordingAdvisoryRating{Set,Cleared}Event` →
  `RecordingAdvisory{Set,Cleared}Event`, now `<phantom RecordingShare>` only,
  and slimmed to the recording address plus, on set, the new `Advisory` value
  (33 and 32 BCS bytes, down from 99 and 97). Dropped: composition id
  (joinable via `RecordingPublishedEvent`), admin cap address (derived from
  the recording), prior-value snapshots and presence flags.
- An equal set now neither writes nor emits; previously it rewrote the field
  silently. Absent clears remain silent.
- Guard order is cap check then stored-state comparison; the function takes no
  validatable argument.

Storage key, value type, authorization, the three variants, and the
absence-is-not-`NotExplicit` rule are unchanged.

Evidence: with Sui `1.79.0`, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean and all 13 tests pass on each network;
the production module reports 100.00% coverage.
