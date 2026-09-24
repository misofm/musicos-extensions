# `composition_credits`

Writing credits for a `musicos::composition::Composition<CompositionShare>`:
one `Credit<CompositionPartyRole>` (display name plus 1-5 roles) per credited
`partyos` `Party`, kept in a single `CompositionCredits` record stored as a
dynamic field on the composition and written through its cap-gated `uid_mut`.
Attribution is display-oriented and varies across platforms, so it lives here
rather than in immutable core; it is not read by any economics, and because it
is an extension, other parties may publish their own credits standard against
the same `Composition`.

## What it stores

- Key: `ExtensionKey()` — a unit struct local to this package.
- Value: one `CompositionCredits { credits: VecMap<ID, Credit<CompositionPartyRole>> }`,
  party ID to credit in insertion order. The record is created on the first
  `add_credit` and retained, empty, after the last `remove_credit`.

Invariants enforced on write: a credit carries 1-5 roles
(`MAX_ROLES_PER_CREDIT`; `credit::new` guarantees at least one), a party holds
at most one credit, and a composition holds at most 50 credits
(`MAX_CREDITS`). `composition_party_role` is a closed enum of six canonical
variants built only through `new_*_role`; a role is read from its BCS variant
index. Roles outside this vocabulary will arrive in a future package
generation.

## API

Writes require the composition's `&CompositionAdminCap<CompositionShare>` and
go through `composition::uid_mut(cap)`, which matches the cap by type only.
Views are permissionless. Guard order is argument validation, then the cap,
then stored state.

| Function | Description | Aborts |
|---|---|---|
| `add_credit(comp, cap, party, credit)` | Credits a party, creating the record on first use | `EExceedsMaxRoles` (30), `EMaxCreditsExceeded` (32), `EPartyAlreadyCredited` (40) |
| `remove_credit(comp, cap, party_id)` | Removes a party's credit; the empty record stays attached | `ENoCredits` (50), `EPartyNotCredited` (52) |
| `has_credits(comp)` | Whether a record is attached | none |
| `credits(comp)` | The `&VecMap<ID, Credit<CompositionPartyRole>>` | `ENoCredits` (50) when absent |
| `composition_party_role::new_*_role()` | Role constructors: Adapter, Arranger, Composer, Lyricist, Songwriter, Translator | none |

At capacity, a duplicate party reports `EMaxCreditsExceeded` rather than
`EPartyAlreadyCredited`. No write is a silent no-op: re-crediting a party
(even with an identical credit) and removing an uncredited party both abort.

## Events

Both events are generic over `CompositionShare` only and carry what an
event-only indexer would otherwise have to look up: the target, the party
that keys the entry, and — on add — the roles exactly as stored.

| Event | Fields | BCS bytes |
|---|---|---|
| `CompositionCreditAddedEvent<CompositionShare>` | `composition_id: address`, `party_id: address`, `roles: vector<CompositionPartyRole>` | 66 (one role) – 70 (five) |
| `CompositionCreditRemovedEvent<CompositionShare>` | `composition_id: address`, `party_id: address` | 64 |

`roles` is the credit's role vector in stored order; every
`CompositionPartyRole` is a unit variant, so each role is one byte (its
variant index in declaration order). The display name stays in storage (it
normally duplicates the party's own name from `partyos` events); the events
do not carry the admin cap (derived from the composition), counts or indices
(replayable from the ordered add/remove stream), or presence flags.

## Errors

| Code | Constant | Condition |
|---|---|---|
| 30 | `EExceedsMaxRoles` | More than five roles |
| 32 | `EMaxCreditsExceeded` | Fifty credits already held |
| 40 | `EPartyAlreadyCredited` | Party already credited |
| 50 | `ENoCredits` | No record attached |
| 52 | `EPartyNotCredited` | Party not credited |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Composition<CompositionShare>`
  and `CompositionAdminCap<CompositionShare>`.
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
