# Security Audit — `composition_credits`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pins: `miso` @ `7c13e40a…`, `partyos` (`miso_party`) @ `0127a150…`,
`miso_credit` @ `76a1afc7…` (`Move.toml`); audited dependency sources are the
on-disk `../../protocol`, `../../party`, `../../credit` working trees.
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

Audit of `composition_credits` (`sources/composition_credits.move`, 171 LOC,
plus `sources/composition_party_role.move`, 119 LOC), the canonical
writing-credits extension for compositions. Verdict: **safe to publish — no
exploitable findings.**

## What it does

Stores one `CompositionCredits` record per composition as a dynamic field
under `ExtensionKey()` (`composition_credits.move:54`): a `VecMap<ID,
Credit<CompositionPartyRole>>` (`composition_credits.move:58-61`). Two
cap-gated mutators (`add_credit`, `remove_credit`) and permissionless views.
Bounds: ≤ 50 credits, ≤ 5 roles per credit
(`composition_credits.move:47-49`).

## Threat model

Identical shape to `recording_credits` (see its audit for the full analysis):
the core threat is unauthorized attach/modify/remove of attribution on someone
else's composition. **Credits carry no royalty weight** — verified by
workspace-wide `grep`: nothing outside the three credits extensions imports
`miso_credit`, and `royalty-pool` never references credits. The composition's
actual revenue share is its immutable `royalty_rate` in
`miso::composition` plus share ownership settled at recording creation — both
in the separately-audited protocol.

### Authorization chain (verified)

Both mutators call `self.uid_mut(cap)` before touching the field
(`composition_credits.move:100,115`). `miso::composition::uid_mut`
(`protocol/sources/composition.move:217-222`) requires a
`&CompositionAdminCap<CompositionShare>` whose phantom matches. Type-level
binding is sound because exactly one `Composition` exists per
`CompositionShare` (`composition::new` consumes the unique canonical treasury
cap via `share::initialize`) and exactly one cap exists per composition
(derived `claim` under `CompositionAdminCapKey()`, `composition.move:155-157`;
a second claim aborts). No third party can attach or strip credits.

### Key/invariant/DoS hygiene

- `ExtensionKey()` is module-local — no cross-package key collision;
  `borrow_mut_or_init` (`composition_credits.move:148-159`) lazy-adds and
  `df::add` aborts on re-add.
- `CompositionCredits` is `store`-only with private fields — the value type
  under the key cannot be swapped by outsiders.
- One credit per party: `contains` before `insert`
  (`composition_credits.move:102`).
- Roles: closed enum (`composition_party_role.move:45-61`); `Custom` names
  validated non-empty and ≤ 100 bytes
  (`composition_party_role.move:100-101`); per-credit role count ≤ 5
  (`composition_credits.move:96`); 1-role floor guaranteed by
  `miso_credit::credit::new` (verified there).
- All loops bounded by the 50-credit cap; writer-paid gas.

## Findings

None. Design note (not a vulnerability):

- **N1 (Informational): attribution without the credited party's consent.**
  `add_credit` takes `&Party` read-only (`composition_credits.move:91`); a
  party cannot veto or remove a credit naming it. Documented design (the
  rights holder's statement, attributable via events), but integrators should
  not treat a credit as the party's own claim.

## Edge cases verified

- Duplicate credit for the same party aborts (`EPartyAlreadyCredited`);
  removing an uncredited party or a second removal aborts
  (`EPartyNotCredited`).
- 6-role credit aborts (`EExceedsMaxRoles`); a `Credit` with 0 roles cannot be
  constructed at all.
- Events carry the full `Credit` payload on both add and remove
  (`composition_credits.move:105,119`), so indexers never re-read state.
- Views: `credits()` aborts `ENoCredits` when unattached
  (`composition_credits.move:138-141`); `has_credits` is the safe probe.

## Verification

- **16/16 tests pass** (`sui move test`, sui 1.77.2), covering both mutators,
  all abort gates, event payloads, and the role vocabulary.
- Full source read of both modules; cross-package verification of the
  `uid_mut` auth contract in `miso::composition`.
