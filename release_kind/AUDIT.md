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
change flag. Equal replacements still assign and emit with `kind_changed =
false`; views do not emit. There is no value or custody surface.

## Evidence

With the available Sui toolchain, strict Testnet and Mainnet lint,
warnings-as-errors builds and tests pass: 19/19 on each network. The production
module reports 100.00% raw coverage across shared Release lifecycle, wrong caps,
validation-before-authorization precedence, absence, byte bounds, equal and
changed replacement, raw UTF-8 preservation, event-only BCS replay, silent
views, unset, and exact maximum event sizes.
