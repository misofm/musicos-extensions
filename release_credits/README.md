# `release_credits`

Top-line billing for a `musicos::release::Release`: one
`Credit<ReleasePartyRole>` (display name plus exactly one role, `Primary` or
`Featured`) per credited `partyos` `Party`, kept in a single `ReleaseCredits`
record stored as a dynamic field on the release and written through its
cap-gated `uid_mut`. Attribution is display-oriented and varies across
platforms, so it lives here rather than in immutable core; it is not read by
any economics (release revenue follows the immutable track splits), and
because it is an extension, other parties may publish their own credits
standard against the same `Release`.

## What it stores

- Key: `ExtensionKey()` — a unit struct local to this package.
- Value: one `ReleaseCredits { credits: VecMap<ID, Credit<ReleasePartyRole>> }`,
  party ID to credit in insertion order. The record is created on the first
  `add_credit` and retained, empty, after the last `remove_credit`.

Invariants enforced on write: a credit carries exactly one role
(`CREDIT_ROLE_COUNT`), a party holds at most one credit, and a release holds
at most 50 credits (`MAX_CREDITS`). `release_party_role` is a closed enum
with no level axis; a role is read from its BCS variant index.

## API

Writes require the release's `&ReleaseAdminCap` and go through
`release::uid_mut(cap)`, which checks that the cap's `release_id` matches the
release. Views are permissionless. Guard order is argument validation, then
the cap, then stored state.

| Function | Description | Aborts |
|---|---|---|
| `add_credit(rel, cap, party, credit)` | Credits a party, creating the record on first use | `EInvalidCreditRoleCount` (53), `release::EUnauthorized`, `EMaxCreditsExceeded` (32), `EPartyAlreadyCredited` (40) |
| `remove_credit(rel, cap, party_id)` | Removes a party's credit; the empty record stays attached | `release::EUnauthorized`, `ENoCredits` (50), `EPartyNotCredited` (52) |
| `has_credits(rel)` | Whether a record is attached | none |
| `credits(rel)` | The `&VecMap<ID, Credit<ReleasePartyRole>>` | `ENoCredits` (50) when absent |
| `release_party_role::new_primary_role()`, `new_featured_role()` | Role constructors | none |

At capacity, a duplicate party reports `EMaxCreditsExceeded` rather than
`EPartyAlreadyCredited`. No write is a silent no-op: re-crediting a party
(even with an identical credit) and removing an uncredited party both abort.

## Events

Both events are monomorphic and carry what an event-only indexer would
otherwise have to look up: the target, the party that keys the entry, and —
on add — the role exactly as stored.

| Event | Fields | BCS bytes |
|---|---|---|
| `ReleaseCreditAddedEvent` | `release_id: address`, `party_id: address`, `roles: vector<ReleasePartyRole>` | 66 |
| `ReleaseCreditRemovedEvent` | `release_id: address`, `party_id: address` | 64 |

`roles` is the credit's one-element role vector; `ReleasePartyRole` is a unit
variant (`Primary = 0`, `Featured = 1` by declaration order), so every add
event is exactly 66 bytes. The display name stays in storage (it normally
duplicates the party's own name from `partyos` events); the events do not
carry the admin cap (derived from the release), counts or indices (replayable
from the ordered add/remove stream), or presence flags.

## Errors

| Code | Constant | Condition |
|---|---|---|
| 32 | `EMaxCreditsExceeded` | Fifty credits already held |
| 40 | `EPartyAlreadyCredited` | Party already credited |
| 50 | `ENoCredits` | No record attached |
| 52 | `EPartyNotCredited` | Party not credited |
| 53 | `EInvalidCreditRoleCount` | Credit does not carry exactly one role |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Release` and
  `ReleaseAdminCap`.
- [`partyos`](https://github.com/misofm/partyos) at
  `88c2e40353dbee8d8f98272069b4d836b02b12ae` — `Party`, the credited identity.
- [`credit`](https://github.com/misofm/credit) at
  `6c295ea10f796edfec18f54783733a35210f4b06` — the generic `Credit<Role>`.

## Publishing

Every change is published as a fresh, immutable package identity; nothing is
upgraded in place. `Published.toml` records the prior generation.

## Build and test

```sh
sui move build --lint --warnings-are-errors
sui move build --lint --warnings-are-errors --build-env mainnet
sui move test --coverage --lint --warnings-are-errors
sui move coverage summary
sui move test --build-env mainnet
```
