> Historical audit below predates the 2026-09-15 payload revision. Current event contracts and size bounds are documented in [EVENT_PAYLOADS.md](../EVENT_PAYLOADS.md). Storage, authority, and mutation behavior remain unchanged.

# Security review — `release_description`

Reviewed 2026-09-11 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`. Both network lock graphs resolve
`bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Set and clear require the release core's cap-gated `uid_mut`, including the
empty clear path. Set validates empty input, then the byte maximum, before cap
authorization. The module-owned key stores one private bounded, non-empty
UTF-8 `String` exactly as supplied; the event carries raw before/after bytes.
Event cap IDs are provenance only, and the extension adds no separate
cap-equality check. The value is descriptive and has no economic or
authorization meaning. No Vault, Action, or Plugin code is present.

## Evidence

With `sui 1.79.0`, strict Testnet and Mainnet lint, warnings-as-errors builds,
and tests pass: 22/22 on each network. The production module reports 100.00%
coverage across published/shared lifecycle, wrong caps, validation precedence,
absence, byte bounds and exact BCS boundaries, raw UTF-8 replacement, clearing,
and silent views. The tests also apply an event-only optional-byte projector
through initial, different, equal, and clear transitions and compare it with
storage after each transition.

## 2026-09-24 — new generation against musicos `6dff4de`

Reviewed for a fresh immutable publication; `Published.toml` remains the
record of the prior deployment. Changes in this generation:

- `musicos` re-pinned to `6dff4deca5ced186989c064e152c92a06384750c`
  (`Release` carries no title; `publish` takes no `Clock`).
- Error constants converted from `#[error]` strings to numeric `u64`:
  `ENoDescription` (1), `EEmptyDescription` (2), `EDescriptionTooLong` (3,
  formerly `EMaxDescriptionLengthExceeded`).
- Events slimmed to what an event-only indexer needs:
  `ReleaseDescriptionSetEvent { release_id, description: String }` (at most
  8226 BCS bytes) and `ReleaseDescriptionClearedEvent { release_id }`
  (32 bytes). Admin cap ids and the prior-presence flag were dropped.
- Setting the value already stored is now a true no-op: no write, no event.
- Guard order unchanged: argument validation (2, 3), then cap (0), then
  stored state.

Evidence: with Sui 1.79.0, default and Mainnet builds and tests pass with no
warnings, 19/19 on each environment, covering the published/shared lifecycle,
wrong caps on set and on clear (absent and present), validation precedence,
exact 8192-byte and byte-versus-character bounds, verbatim storage, equal-set
silence, silent views, per-release isolation, and exact event BCS layouts.
