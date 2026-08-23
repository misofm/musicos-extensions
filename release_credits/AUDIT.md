# Security Audit — `release_credits`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pins: `miso` @ `7c13e40a…`, `partyos` (`miso_party`) @ `0127a150…`,
`miso_credit` @ `76a1afc7…` (`Move.toml`); audited dependency sources are the
on-disk `../../protocol`, `../../party`, `../../credit` working trees.
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

Audit of `release_credits` (`sources/release_credits.move`, 166 LOC, plus
`sources/release_party_role.move`, 57 LOC), the canonical top-line-billing
extension for releases. Verdict: **safe to publish — no exploitable
findings.**

## What it does

Stores one `ReleaseCredits` record per release as a dynamic field under
`ExtensionKey()` (`release_credits.move:57`): a `VecMap<ID,
Credit<ReleasePartyRole>>` (`release_credits.move:61-64`). Each credit must
carry **exactly one** role — `Primary` or `Featured`, the only two variants
(`release_party_role.move:29-34`). Two cap-gated mutators (`add_credit`,
`remove_credit`) and permissionless views. Bounds: ≤ 50 credits
(`release_credits.move:52`).

## Threat model

Same shape as `recording_credits` (see its audit for the full analysis): the
core threat is unauthorized attach/modify/remove of billing on someone else's
release. **Credits carry no royalty weight** — verified by workspace-wide
`grep`: nothing outside the three credits extensions imports `miso_credit`;
`royalty-pool` never references credits. A release's revenue splits live in
the immutable `Track.split_bps` values in `miso::release` (separately
audited), and are untouched by this extension.

### Authorization chain (verified)

Both mutators call `self.uid_mut(cap)` before touching the field
(`release_credits.move:101,112`). `miso::release::uid_mut`
(`protocol/sources/release.move:337-340`) calls `authorize`
(`release.move:303-305`), which asserts `object::id(self) ==
cap.release_id` — an ID-level binding, stronger than the recording/composition
type-level one: a cap minted for release A can never authorize release B. The
cap itself is minted once per release in `release::new` via derived `claim`
(`release.move:244-247`); there is no other constructor, and the test-only
`new_for_testing` is stripped from published bytecode.

Notably, the role-count assert (`release_credits.move:97`) runs *before* the
cap gate — no state is read or written before authorization, so this ordering
leaks nothing and changes nothing.

### Key/invariant/DoS hygiene

- `ExtensionKey()` is module-local — no cross-package key collision; lazy
  init via `borrow_mut_or_init` (`release_credits.move:143-154`) with
  `df::add` abort-on-re-add.
- `ReleaseCredits` is `store`-only, private fields, no external constructor.
- One credit per party: `contains` before `insert`
  (`release_credits.move:103`).
- Exactly-one-role invariant: `credit.roles().length() == 1` asserted in
  `add_credit` (`release_credits.move:97`), and the role enum is closed with
  no `Custom` escape hatch (`release_party_role.move:29-34`) — release billing
  can only ever be `Primary`/`Featured`, with no free-text strings stored at
  all beyond `miso_credit`'s ≤ 200-byte display name.
- Loops bounded by the 50-credit cap; writer-paid gas.

## Findings

None. Design note (not a vulnerability):

- **N1 (Informational): attribution without the credited party's consent.**
  `add_credit` takes `&Party` read-only (`release_credits.move:94`); a party
  cannot remove false billing naming it. Documented design; integrators should
  not treat billing as the party's own claim.

## Edge cases verified

- Zero-role or two-role credit aborts (`EInvalidCreditRoleCount`) — the
  `== CREDIT_ROLE_COUNT` check is exact, not a bound.
- Duplicate credit aborts (`EPartyAlreadyCredited`); removing an uncredited
  party or double removal aborts (`EPartyNotCredited`).
- 50th-credit boundary aborts (`EMaxCreditsExceeded`).
- Events carry the full `Credit` payload on add and remove
  (`release_credits.move:106,115`).
- Views: `credits()` aborts `ENoCredits` when unattached
  (`release_credits.move:134-137`); `has_credits` is the safe probe.

## Verification

- **13/13 tests pass** (`sui move test`, sui 1.77.2), including e2e tests on
  shared published releases.
- Full source read of both modules; cross-package verification of the
  `uid_mut`/`authorize` auth contract in `miso::release`.
