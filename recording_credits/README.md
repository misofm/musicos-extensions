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

Credit added/removed events retain recording/composition/admin-cap/party IDs, ordered compact role kinds and levels (at most 10 each), credit index/counts, and lifecycle or artist-membership flags. Maximum sizes are 175/176 BCS bytes. Primary and featured artist added/removed events retain the four IDs, ordered-set index/counts, and removal cause (160/161 bytes). Display names, custom labels, and instruments stay in storage. Custom-role kind is retained, but the exact custom label requires reading the credit while present. Credit removal and primary/featured cascade events remain distinct and are all retained.

See [the repository payload inventory](../EVENT_PAYLOADS.md) for byte bounds and retained context.

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
