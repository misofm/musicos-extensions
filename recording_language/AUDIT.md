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

## 2026-09-24 — regeneration against musicos `6dff4de`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c`, where `Recording` takes a single
`RecordingShare` parameter and `publish` no longer takes a Clock.
`language_code` remains at `61542357f3d2ff989d120185046def7cf6c8bdcb`.
Verdict unchanged: no exploitable findings.

Changes in this generation:

- `unset_languages` renamed `clear_languages`. The `set_instrumental` and
  `is_instrumental` wrappers were dropped: an instrumental claim is
  `set_languages(rec, cap, vector[])` and reads as `has_languages(rec) &&
  languages(rec).is_empty()`. `languages` now returns `&vector<LanguageCode>`.
- Events are now `<phantom RecordingShare>` only and slimmed to the recording
  address plus, on set, the new ordered codes as `vector<String>` (`33 + 3n`
  BCS bytes, 33 to 63, down from 125 to 185; clear is 32, down from 106 to
  136). Dropped: composition id, admin cap address, prior-value snapshots,
  counts, instrumental flags, and the `max_languages` bound.
- An equal set now neither writes nor emits; previously it rewrote the field
  silently. Absent clears remain silent.
- Guard order is argument validation (count, then duplicates), then the cap
  check, then stored-state comparison; an invalid replacement aborts before
  touching storage.

Storage key, value type, the ten-code bound, duplicate rejection, and the
instrumental-versus-absent distinction are unchanged.

Evidence: with Sui `1.79.0`, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean and all 19 tests pass on each network;
the production module reports 100.00% coverage.
