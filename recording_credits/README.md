# `recording_credits`

> Miso's canonical attribution standard for recordings: per-party credits (display name + roles) plus primary/featured artist designations.

**Attaches to:** `miso::recording::Recording` via a dynamic field on the recording's `&mut UID`. The credits record is stored under the `ExtensionKey()` key, reached through the recording's cap-gated `uid_mut`, so every mutation is authorized by a `RecordingAdminCap`. Read views use the recording's `uid`.

Attribution is display-oriented and varies across platforms, so it lives in this extension rather than in immutable core. A single `RecordingCredits` record holds a `VecMap<ID, Credit<RecordingPartyRole>>` (party ID to credit) plus two `VecSet<ID>` of primary and featured artist IDs. The record is created lazily on the first `add_credit`, and credits can be attached before or after the recording is published. Credits are pure attribution — they are not read by the protocol's economics.

Key invariants: a party holds at most one credit; each credit carries 1-10 roles; the primary and featured artist sets are always subsets of credited parties (removing a credit cascades into both sets); a party cannot be both primary and featured. Bounds are enforced on credits (max 150), primary artists (max 20), and featured artists (max 50). The companion `recording_party_role` module defines `RecordingPartyRole`, a closed enum of production/performance roles (each with an optional `RecordingPartyRoleLevel` seniority), plus a `Custom` escape hatch.

## Entry points

All `recording_credits` write functions are cap-gated by `RecordingAdminCap`.

- **`recording_credits::add_credit`** — adds a party's credit (lazily initializing the credits record on first use); rejects duplicate parties, credits with <1 or >10 roles, and exceeding the 150-credit cap.
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

## Dependencies

- **`miso`** — provides `Recording`, `RecordingAdminCap`, and the cap-gated `uid_mut`/`uid` access this extension attaches to.
- **`partyos`** — provides `Party` (credited identity) and `Credit<RecordingPartyRole>` (display name + roles).

## Build & test

```sh
sui move build
sui move test
```
