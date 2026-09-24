# Security review — `recording_version`

Reviewed 2026-09-24 ahead of first publication. Verdict: no exploitable
findings in the reviewed source. Not yet published; no `Published.toml`.

## Reviewed surface

Four public functions: `set_version`, `clear_version`, `has_version`, and
`version`. No function is derivable by composing the others.

## Dependency provenance

`Move.toml` pins `musicos` at `6dff4deca5ced186989c064e152c92a06384750c`
(`Recording<phantom RecordingShare>`, `publish(self, cap)` without a Clock,
no titles in core). The Testnet and Mainnet lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` and `share` at
`6ac1dbf022e74957c5ec15ecf95890e28889cd62` with no duplicate aliases.

## Threat model and findings

The relevant threat is an unauthorized change to a recording's version name.
Both writes require the typed `RecordingAdminCap<RecordingShare>` through
`Recording::uid_mut`. This is type-only authorization: one share type backs
exactly one recording, so a cap for another recording is a different type and
cannot compile; no runtime cap-value check exists or is needed.

Guard order is argument-only validation (`EEmptyVersion`, then
`EVersionTooLong` at 300 bytes), then the cap check, then stored-state
comparison. An invalid replacement therefore aborts before touching storage.
A set equal to the stored value neither writes nor emits; a clear of an absent
value is silent. `ExtensionKey` is module-owned, so the field cannot collide
with any other extension on the same recording. The package moves no funds and
contains no Vault, Action, or Plugin surface.

Events carry only the recording address and, on set, the new `String`: 34 to
334 BCS bytes for set, 32 for clear. Event streams are typed by
`RecordingShare` only.

## Evidence

With Sui `1.79.0`, strict Testnet and Mainnet lint and warnings-as-errors
builds pass clean and all 16 tests pass on each network. The production module
reports 100.00% coverage, including the published/shared-object lifecycle,
inclusive 1- and 300-byte bounds, the 301-byte and empty aborts, validation
before stored-state checks, equal-set silence, absent-clear silence, exact
event payloads at the minimum, multi-byte UTF-8, and maximum sizes, and
per-recording isolation of both storage and event streams.
