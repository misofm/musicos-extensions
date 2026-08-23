# Security Audit — `recording_credits`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pins: `miso` @ `7c13e40a…`, `partyos` (`miso_party`) @ `0127a150…`,
`miso_credit` @ `76a1afc7…` (`Move.toml`); audited dependency sources are the
on-disk `../../protocol`, `../../party`, `../../credit` working trees.
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

Audit of `recording_credits` (`sources/recording_credits.move`, 346 LOC, plus
`sources/recording_party_role.move`, 449 LOC), the canonical attribution
extension for recordings. Verdict: **safe to publish — no exploitable
findings.**

## What it does

Stores one `RecordingCredits` record per recording as a dynamic field under
`ExtensionKey()` (`recording_credits.move:67`): a `VecMap<ID,
Credit<RecordingPartyRole>>` plus `primary_artist_ids` / `featured_artist_ids`
`VecSet<ID>`s (`recording_credits.move:71-78`). Six cap-gated mutators
(`add_credit`, `remove_credit`, `add/remove_primary_artist`,
`add/remove_featured_artist`) and permissionless views. Bounds: ≤ 150 credits,
≤ 10 roles per credit, ≤ 20 primary / ≤ 50 featured artists
(`recording_credits.move:56-62`).

## Threat model and the money question

**Credits do not move money.** Royalties in this system flow through share
ownership (the composition's cut is settled as recording-share ownership at
`miso::recording::new`) and per-track splits embedded in `Release` — both in
the separately-audited protocol. Verified directly: `grep` across all
workspace Move sources shows only the three credits extensions (and their
tests) import `miso_credit`; `royalty-pool/sources/pool.move` never references
any credits module. The module doc states the same
(`recording_credits.move:15`). So credit manipulation is an *attribution
integrity* threat, not a royalty-redirection path. The residual threat model:

1. **Unauthorized attach/modify/remove of credits on someone else's
   recording** — the core threat.
2. **Invariant corruption** (primary/featured sets escaping the credited set;
   duplicate credits) confusing indexers.
3. **DoS / storage bloat** on the shared recording object.

### Why (1) fails — authorization chain

Every mutator funnels through `self.uid_mut(cap)` before touching the dynamic
field (`recording_credits.move:142,159,186,203,219,236`).
`miso::recording::uid_mut` (`protocol/sources/recording.move:306-311`)
requires a `&RecordingAdminCap<RecordingShare>` whose phantom type matches the
recording's. The binding is type-level rather than ID-level, and it is sound:

- **One recording per `RecordingShare`:** `recording::new` consumes the
  treasury cap via `miso_share::share::initialize`, which enforces the unique
  canonical cap and consumes it (`make_supply_fixed`) — a second `Recording`
  with the same share type can never be created (see the `miso_share` audit
  for the cap-uniqueness proof).
- **One cap per recording:** the cap UID is `derived_object::claim`ed under
  `RecordingAdminCapKey()` from the recording's own UID
  (`recording.move:217-219`); a second claim aborts, and there is no other
  constructor. The test-only `new_for_testing` (`recording.move:336`) is
  stripped from published bytecode.
- **No cross-type confusion:** `RecordingAdminCap<RS>` cannot be presented
  against a `Composition` or `Release` — distinct types.

So no one without the recording's own admin cap can attach, alter, or remove
credits. The cap *holder* can mutate or delete any extension data forever —
that is the protocol's documented, permanent trust assumption
(`recording.move:40-46`), not a bug.

### Key hygiene

`ExtensionKey()` is a module-local type — no other package's key can collide
with it, and `df::add` aborts on re-add so the lazy-init in
`borrow_mut_or_init` (`recording_credits.move:301-314`) is race-free within a
transaction. `RecordingCredits` has only `store`, private fields, and no
public constructor outside this module, so the value type under the key is
always the expected one. A *third-party* extension could attach a
type-conflicting value under a key of its own definition, but never under
this module's `ExtensionKey` type with a wrong value type without this
module's cooperation — and any raw `df` manipulation requires the admin cap
anyway.

### Invariants checked

- **primary/featured ⊆ credited:** `add_primary_artist` /
  `add_featured_artist` assert `credits.contains(&party_id)`
  (`recording_credits.move:188,221`); `remove_credit` cascades the party out
  of both sets with per-set events (`recording_credits.move:167-174`).
- **primary ∩ featured = ∅:** enforced both directions
  (`recording_credits.move:189-190,222-223`).
- **one credit per party:** `contains` check before `insert`
  (`recording_credits.move:144`).
- **role validity:** roles come from the closed enum
  `recording_party_role.move:56-123`; `Custom`/`Instrumentalist` name strings
  are non-empty and ≤ 100 bytes (`recording_party_role.move:227-228,319-320`);
  per-credit role count ≤ 10 asserted in `add_credit`
  (`recording_credits.move:138`) on top of `miso_credit`'s 1–50 guarantee.

### DoS

All loops are in framework `VecMap`/`VecSet` operations over collections
capped at 150/20/50 entries. Worst-case storage per recording: 150 credits ×
(200-byte name + ≤ 10 roles) — bounded, writer-paid.

## Findings

None. Two design notes (not vulnerabilities):

- **N1 (Informational): attribution without the credited party's consent.**
  `add_credit` takes `&Party` read-only (`recording_credits.move:132`); the
  recording admin can credit any party, and a party cannot remove a false
  credit about itself. This matches the documented design (attribution is the
  rights holder's signed statement, and every write emits an attributable
  event carrying the full payload), but integrators should not treat a credit
  as the party's own claim.
- **N2 (Informational): view functions abort on unattached records.**
  `credits()`/`primary_artist_ids()`/`featured_artist_ids()` abort with
  `ENoCredits` when nothing is attached (`recording_credits.move:291-294`);
  `is_primary_artist`/`is_featured_artist` return `false` instead. Callers
  composing on-chain should check `has_credits` first. Documented behavior.

## Edge cases verified

- Re-crediting the same party aborts (`EPartyAlreadyCredited`); removing an
  uncredited party aborts (`EPartyNotCredited`); double removal aborts (test
  `remove_credit_rejects_double_removal`).
- Making a primary artist featured (or vice versa) aborts; re-adding an
  existing primary aborts.
- `remove_credit` emits `CreditRemovedEvent` carrying the removed record
  *before* the cascade events — indexers see the full payload even though the
  write already landed (`recording_credits.move:163`).
- Cap checks fire before any state read that could leak: the asserts in
  `add_credit` run against the record only *after* `uid_mut(cap)` succeeds.
- Boundary counts: the 150th/20th/50th additions abort at the limit (`<`
  comparisons at `recording_credits.move:143,187,220`).
- `CreditAddedEvent`/`CreditRemovedEvent` carry the full `Credit` value so an
  indexer never needs to re-read the object.

## Verification

- **39/39 tests pass** (`sui move test`, sui 1.77.2): unit tests for every
  abort gate and invariant, plus e2e tests driving real `Recording` objects
  through create → publish → credit lifecycle on shared objects.
- Full source read of both modules; cross-package verification of the
  `uid_mut` auth contract in `miso::recording` and cap-uniqueness chain in
  `miso_share`.
