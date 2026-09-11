# `recording_credits`

> musicos's canonical attribution standard for recordings: per-party credits (display name + roles) plus primary/featured artist designations.

**Attaches to:** `musicos::recording::Recording` via a dynamic field on the recording's `&mut UID`. The credits record is stored under the `ExtensionKey()` key, reached through the recording's type-gated `uid_mut` with a `RecordingAdminCap<RecordingShare>`. In the pinned dependency this does not inspect cap identity, sender, or lifecycle. Read views use the recording's `uid`.

Attribution is display-oriented and varies across platforms, so it lives in this extension rather than in immutable core. A single `RecordingCredits` record holds a `VecMap<ID, Credit<RecordingPartyRole>>` (party ID to credit) plus two `VecSet<ID>` of primary and featured artist IDs. The record is created lazily on the first `add_credit`, and credits can be attached before or after the recording is published. Removing the last credit leaves the empty dynamic-field record attached: `has_credits` stays true and the collection views return empty collections. A later re-add therefore reports `credits_initialized: false`. Credits are pure attribution — they are not read by the protocol's economics.

Key invariants: a party holds at most one credit; `add_credit` checks only the upper bound of 10 roles because `credit::new` guarantees every `Credit` is nonempty; the primary and featured artist sets are always subsets of credited parties (removing a credit cascades into both sets); a party cannot be both primary and featured. Bounds are enforced on credits (max 150), primary artists (max 20), and featured artists (max 50). The companion `recording_party_role` module defines `RecordingPartyRole`, a closed enum of production/performance roles. Most roles accept an optional `RecordingPartyRoleLevel`, but `ArtistsAndRepertoire` and `Copyist` have no level field; `Instrumentalist` also stores a validated instrument string. `Custom` is the escape hatch.

## Entry points

All `recording_credits` write functions are cap-gated by `RecordingAdminCap`.

- **`recording_credits::add_credit`** — adds a party's credit (lazily initializing the credits record on first use); rejects duplicate parties, credits with >10 roles, and exceeding the 150-credit cap. The constructor in `credit` rejects an empty role vector before this function receives the value.
- **`recording_credits::remove_credit`** — removes a party's credit and cascades the removal into the primary and featured sets.
- **`recording_credits::add_primary_artist`** — designates an already-credited party as a primary artist; rejects uncredited parties, existing featured/primary artists, and exceeding the 20-artist cap.
- **`recording_credits::remove_primary_artist`** — removes a party from the primary set (leaves the credit intact).
- **`recording_credits::add_featured_artist`** — designates an already-credited party as a featured artist; rejects uncredited parties, existing primary/featured artists, and exceeding the 50-artist cap.
- **`recording_credits::remove_featured_artist`** — removes a party from the featured set (leaves the credit intact).
- **`recording_party_role::new_*_role`** — constructors for each role variant (e.g. `new_producer_role`, `new_vocalist_role`, `new_instrumentalist_role`, `new_custom_role`); instrument and custom names are validated (non-empty, ≤100 bytes). Permissionless — these build values consumed by `add_credit`.
- **`recording_party_role::new_*_role_level`** — constructors for each seniority level (e.g. `new_lead_role_level`, `new_featured_role_level`). Permissionless.

## Views

- **`recording_credits::has_credits`** — whether a credits record is attached to the recording.
- **`recording_credits::credits`** — the `&VecMap<ID, Credit<RecordingPartyRole>>` of party to credit (aborts if none attached).
- **`recording_credits::primary_artist_ids`** — the `&VecSet<ID>` of primary artists (aborts if none attached).
- **`recording_credits::featured_artist_ids`** — the `&VecSet<ID>` of featured artists (aborts if none attached).
- **`recording_credits::is_primary_artist`** — whether a party ID is a primary artist (false if no record attached).
- **`recording_credits::is_featured_artist`** — whether a party ID is a featured artist (false if no record attached).
- **`recording_party_role::name`** — the role's canonical PascalCase identifier (the user string for `Custom`, `"Instrumentalist"` for instrumentalists).
- **`recording_party_role::level`** — the role's optional `RecordingPartyRoleLevel`.

## Events

Every mutation emits only its corresponding rich event(s); all views and
constructors are silent. Credit events carry recording, composition, admin-cap,
and party addresses, display-name bytes, stable role kind/name/instrument/level
vectors, map index/counts, and initialization or cascade flags. Designation
events carry the display-name bytes, set index/counts, credit count, and the
cascade flag on removals. Event types retain both phantom recording and
composition share parameters without constraints. Role kinds use the stable
`Actor = 0` through `Custom = 31` codes; levels use `None = 0` through
`Principal = 9`, with clerical roles forced to level `0`.

Event BCS is field-order BCS with no phantom bytes. Addresses are 32-byte
values; `u64` values are little-endian; `bool` is one byte; strings are UTF-8
byte vectors with their BCS length prefix; and nested role vectors retain their
outer order and each inner vector's length prefix. The exact field order is:

- `CreditAddedEvent`: `recording_id`, `composition_id`, `admin_cap_id`,
  `party_id`, `display_name`, `role_kinds`, `role_names`, `role_instruments`,
  `role_levels`, `credit_index`, `credit_count_before`,
  `credit_count_after`, `credits_initialized`.
- `CreditRemovedEvent`: the same first twelve fields through
  `credit_count_after`, followed by `was_primary_artist`,
  `was_featured_artist`.
- `PrimaryArtistAddedEvent` and `FeaturedArtistAddedEvent`: recording ID,
  composition ID, admin-cap ID, party ID, display-name bytes, set index,
  set count before, set count after, and credit count after. The field name is
  `primary_artist_index` or `featured_artist_index` respectively.
- `PrimaryArtistRemovedEvent` and `FeaturedArtistRemovedEvent`: the matching
  added-event fields followed by `caused_by_credit_removal`.

The accepted primitive bounds are a 200-byte display name, at most 10 roles per
recording credit, and 100-byte instrument/custom-role names. The package-wide
collection bounds are 150 credits, 20 primary IDs, and 50 featured IDs. The
maximal tested BCS sizes are 1549 (`CreditAddedEvent`), 1550
(`CreditRemovedEvent`), 362 (either designation-added event), and 363 (either
designation-removed event).

`credit_index` and set indexes are insertion-order indexes at the mutation;
all before/after counts are exact deltas. Credit removal's event snapshots the
removed credit before map deletion, then emits primary and featured cascade
events in that mutation order. Explicit designation removal sets
`caused_by_credit_removal` to false. The test-only event accessors serialize
the complete event values, and tests compare those bytes with independently
assembled BCS payloads rather than checking lengths alone.

## Dependencies

- **`musicos`** — provides `Recording`, `RecordingAdminCap`, and the cap-gated `uid_mut`/`uid` access this extension attaches to.
- **`partyos`** — provides `Party` (the credited identity).
- **`credit`** — provides `Credit<RecordingPartyRole>` (display name + roles).

## Build & test

```sh
sui move build --build-env testnet --lint --warnings-are-errors
sui move test --build-env testnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env testnet
sui move build --build-env mainnet --lint --warnings-are-errors
sui move test --build-env mainnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env mainnet
```
