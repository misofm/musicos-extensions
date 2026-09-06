# `release_credits`

> First-party credits extension that records top-line billing (Primary / Featured artists) for a Miso `Release`.

**Attaches to:** `miso::release::Release`, as a dynamic field on the release's `&mut UID`. The UID is obtained through `Release::uid_mut(cap)`, which is gated by a `ReleaseAdminCap`, so every mutation is authorized by the release's admin. The record is stored under the `ExtensionKey()` key.

Attribution (top-line billing) is display-oriented and varies across platforms, so it lives in this extension rather than in immutable Miso core. Credits are pure attribution — they are not read by the protocol's economics. Because this is an extension, other parties may publish their own competing release-credits standard against the same `Release`; this is Miso's canonical one.

The data model is a single `ReleaseCredits` record holding a `VecMap<ID, Credit<ReleasePartyRole>>` (party ID to credit). Key invariants: a party may hold at most one credit, each credit must carry exactly one role (`Primary` or `Featured`), and a release is capped at `MAX_CREDITS` (50). The record is lazily created on first `add_credit` and survives into any release lifecycle state (it may be attached before or after publication).

## Modules

- **`release_credits`** — the credits record, its dynamic-field storage, and the write/read API.
- **`release_party_role`** — the closed `ReleasePartyRole` enum (`Primary` / `Featured`) and its constructors.

## Entry points

- **`release_credits::add_credit`** — cap-gated. Adds a `Credit<ReleasePartyRole>` for a party, lazily creating the credits record on first use. Asserts the credit carries exactly one role, the party is not already credited, and the per-release cap is not exceeded.
- **`release_credits::remove_credit`** — cap-gated. Removes a party's credit by party ID; aborts if the party is not credited.
- **`release_party_role::new_primary_role`** — permissionless. Constructs a `Primary` role.
- **`release_party_role::new_featured_role`** — permissionless. Constructs a `Featured` role.

## Views

- **`release_credits::has_credits`** — whether a credits record has been attached to the release yet.
- **`release_credits::credits`** — borrows the party-ID-to-`Credit` map; aborts if no credits are attached.
- **`release_party_role::name`** — the role's canonical PascalCase identifier (`"Primary"` / `"Featured"`).

## Dependencies

- **`miso`** — provides `Release` / `ReleaseAdminCap` (the core object being extended and its admin gate).
- **`partyos`** — provides `Party` (credit subject) and `Credit<phantom T>` (the display-name + roles container parameterized over `ReleasePartyRole`).

## Build & test

```sh
sui move build
sui move test
```
