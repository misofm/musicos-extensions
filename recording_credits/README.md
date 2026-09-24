# `recording_credits`

Credits for a `musicos::recording::Recording<RecordingShare>`: one
`Credit<RecordingPartyRole>` (display name plus 1-10 roles) per credited
`partyos` `Party`, plus primary and featured artist designations, kept in a
single `RecordingCredits` record stored as a dynamic field on the recording
and written through its cap-gated `uid_mut`. Attribution is display-oriented
and varies across platforms, so it lives here rather than in immutable core;
it is not read by any economics, and because it is an extension, other
parties may publish their own credits standard against the same `Recording`.

## What it stores

- Key: `ExtensionKey()` — a unit struct local to this package.
- Value: one `RecordingCredits` holding `credits: VecMap<ID,
  Credit<RecordingPartyRole>>` (party ID to credit, in insertion order) and
  `primary_artist_ids` / `featured_artist_ids: VecSet<ID>`. The record is
  created on the first `add_credit` and retained, empty, after the last
  `remove_credit`.

Invariants enforced on write: a credit carries 1-10 roles
(`MAX_ROLES_PER_CREDIT`; `credit::new` guarantees at least one); a party holds
at most one credit; the primary and featured sets are disjoint subsets of the
credited parties, so removing a credit ends any designation; and bounds of 150
credits, 20 primary artists, and 50 featured artists apply.
`recording_party_role` is a closed enum of 31 canonical production and
performance roles. Most carry an optional `RecordingPartyRoleLevel`;
`ArtistsAndRepertoire` and `Copyist` carry none; `Instrumentalist` also
carries a validated instrument name (non-empty, at most 100 bytes). A role is
read from its BCS variant index and `level()`. Roles outside this vocabulary
will arrive in a future package generation.

## API

Writes require the recording's `&RecordingAdminCap<RecordingShare>` and go
through `recording::uid_mut(cap)`, which matches the cap by type only. Views
are permissionless. Guard order is argument validation, then the cap, then
stored state.

| Function | Description | Aborts |
|---|---|---|
| `add_credit(rec, cap, party, credit)` | Credits a party, creating the record on first use | `EExceedsMaxRoles` (30), `EMaxCreditsExceeded` (32), `EPartyAlreadyCredited` (40) |
| `remove_credit(rec, cap, party_id)` | Removes a party's credit and any designation it held; the empty record stays attached | `ENoCredits` (50), `EPartyNotCredited` (52) |
| `add_primary_artist(rec, cap, party)` | Designates a credited party as primary | `ENoCredits` (50), `EMaxPrimaryArtistsExceeded` (34), `EPartyNotCredited` (52), `EAlreadyFeaturedArtist` (42), `EAlreadyPrimaryArtist` (41) |
| `remove_primary_artist(rec, cap, party_id)` | Ends a primary designation; the credit stays | `ENoCredits` (50), `EPartyNotCredited` (52) when not primary |
| `add_featured_artist(rec, cap, party)` | Designates a credited party as featured | `ENoCredits` (50), `EMaxFeaturedArtistsExceeded` (35), `EPartyNotCredited` (52), `EAlreadyPrimaryArtist` (41), `EAlreadyFeaturedArtist` (42) |
| `remove_featured_artist(rec, cap, party_id)` | Ends a featured designation; the credit stays | `ENoCredits` (50), `EPartyNotCredited` (52) when not featured |
| `has_credits(rec)` | Whether a record is attached | none |
| `credits(rec)` | The `&VecMap<ID, Credit<RecordingPartyRole>>` | `ENoCredits` (50) when absent |
| `primary_artist_ids(rec)`, `featured_artist_ids(rec)` | The `&VecSet<ID>` of each designation | `ENoCredits` (50) when absent |
| `is_primary_artist(rec, party_id)`, `is_featured_artist(rec, party_id)` | Designation predicates; false when no record is attached | none |
| `recording_party_role::new_*_role(level)` | Role constructors (`new_instrumentalist_role(instrument, level)`; `new_artists_and_repertoire_role()` and `new_copyist_role()` take no level) | `EEmptyString` (35), `EMaxInstrumentLengthExceeded` (30) |
| `recording_party_role::new_*_role_level()` | Level constructors: Additional, Assistant, Associate, Backing, Executive, Featured, Lead, Primary, Principal | none |
| `recording_party_role::level(&role)` | The role's optional level | none |

At capacity, a duplicate party reports `EMaxCreditsExceeded` rather than
`EPartyAlreadyCredited`. No write is a silent no-op: re-crediting a party
(even with an identical credit), re-designating an artist, and removing an
absent credit or designation all abort.

## Events

All six events are generic over `RecordingShare` only and carry what an
event-only indexer would otherwise have to look up: the target, the party
that keys the entry, and — on credit add — the roles exactly as stored,
instrument names and levels included.

| Event | Fields | BCS bytes |
|---|---|---|
| `RecordingCreditAddedEvent<RecordingShare>` | `recording_id: address`, `party_id: address`, `roles: vector<RecordingPartyRole>` | 66 – 1105 (typically 67: one levelless role) |
| `RecordingCreditRemovedEvent<RecordingShare>` | `recording_id: address`, `party_id: address` | 64 |
| `RecordingPrimaryArtistAddedEvent<RecordingShare>` | `recording_id: address`, `party_id: address` | 64 |
| `RecordingPrimaryArtistRemovedEvent<RecordingShare>` | `recording_id: address`, `party_id: address` | 64 |
| `RecordingFeaturedArtistAddedEvent<RecordingShare>` | `recording_id: address`, `party_id: address` | 64 |
| `RecordingFeaturedArtistRemovedEvent<RecordingShare>` | `recording_id: address`, `party_id: address` | 64 |

`roles` is the credit's role vector in stored order, each role a BCS enum
value: the variant index in declaration order, then the instrument name for
`Instrumentalist` (ULEB128 length + bytes, at most 100), then the optional
`RecordingPartyRoleLevel` as a BCS `Option` (`0`, or `1` followed by the
level's variant index) for every role except the levelless
`ArtistsAndRepertoire` and `Copyist`. A levelless or level-free role is one
or two bytes; the worst case is ten instrumentalists each with a 100-byte
instrument name and a level (104 bytes apiece), 1105 in total. The display
name stays in storage (it normally duplicates the party's own name from
`partyos` events).

Removing a credit that held a designation emits only
`RecordingCreditRemovedEvent`: the designation sets are subsets of the
credits by invariant, so the cascade is inferable and the artist-removed
events are reserved for explicit `remove_primary_artist` /
`remove_featured_artist` calls. The events do not carry the composition id
(joinable via core's `RecordingPublishedEvent`), the admin cap (derived from
the recording), counts or indices (replayable from the ordered add/remove
stream), or presence and cascade flags.

## Errors

| Code | Constant | Module | Condition |
|---|---|---|---|
| 30 | `EExceedsMaxRoles` | `recording_credits` | More than ten roles |
| 32 | `EMaxCreditsExceeded` | `recording_credits` | 150 credits already held |
| 34 | `EMaxPrimaryArtistsExceeded` | `recording_credits` | 20 primary artists already designated |
| 35 | `EMaxFeaturedArtistsExceeded` | `recording_credits` | 50 featured artists already designated |
| 40 | `EPartyAlreadyCredited` | `recording_credits` | Party already credited |
| 41 | `EAlreadyPrimaryArtist` | `recording_credits` | Party already primary |
| 42 | `EAlreadyFeaturedArtist` | `recording_credits` | Party already featured |
| 50 | `ENoCredits` | `recording_credits` | No record attached |
| 52 | `EPartyNotCredited` | `recording_credits` | Party not credited, or not holding the designation being removed |
| 30 | `EMaxInstrumentLengthExceeded` | `recording_party_role` | Instrument name over 100 bytes |
| 35 | `EEmptyString` | `recording_party_role` | Empty instrument name |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Recording<RecordingShare>` and
  `RecordingAdminCap<RecordingShare>`.
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
