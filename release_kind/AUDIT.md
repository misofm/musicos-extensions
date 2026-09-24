# Security review — `release_kind`

Reviewed 2026-09-11 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`. The checked-in Testnet lock
resolves that revision; the checked-in Mainnet lock retains its pinned
`b3d5d4005fe36044d90e318f864dbc8b01de41da` revision. Both graphs resolve
`bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Set and unset require the matching `ReleaseAdminCap`; even an absent unset
authorizes before silently returning. Set validates emptiness (2) and the
32-byte bound (3) before `uid_mut` authorization (0), preserving the required
abort precedence. A module-owned key stores one bounded UTF-8 String exactly as
provided. The monomorphic set and unset events carry both actual object IDs,
raw previous/current bytes and lengths, record existence before/after, and the
change flag. Equal replacements still assign but emit no event; every emitted
set event has `kind_changed = true`. Views do not emit. There is no value or
custody surface.

## Evidence

With the available Sui toolchain, strict Testnet and Mainnet lint,
warnings-as-errors builds and tests pass: 19/19 on each network. The production
module reports 100.00% raw coverage across shared Release lifecycle, wrong caps,
validation-before-authorization precedence, absence, byte bounds, equal and
changed replacement, raw UTF-8 preservation, event-only BCS replay, silent
views, unset, and exact maximum event sizes.

## 2026-09-24 — new generation against musicos `6dff4de`

Reviewed for a fresh immutable publication; `Published.toml` above remains
the record of the prior deployment. Changes in this generation:

- `musicos` re-pinned to `6dff4deca5ced186989c064e152c92a06384750c`
  (`Release` carries no title; `publish` takes no `Clock`).
- `unset_kind` renamed `clear_kind`; `kind()` now returns `&String`.
- Events slimmed to what an event-only indexer needs: `ReleaseKindSetEvent
  { release_id, kind: String }` (at most 65 BCS bytes) and
  `ReleaseKindClearedEvent { release_id }` (32 bytes). Admin cap ids,
  before/after snapshots, lengths and flags were dropped.
- Setting the value already stored is now a true no-op: no write, no event.
- Guard order unchanged: argument validation (2, 3), then cap (0), then
  stored state.

Evidence: with Sui 1.79.0, default and Mainnet builds and tests pass with no
warnings, 20/20 on each environment, covering the published/shared lifecycle,
wrong caps on set and absent clear, validation precedence, exact 32-byte and
byte-versus-character bounds, verbatim storage, equal-set silence, silent
views, per-release isolation, and exact event BCS layouts.
