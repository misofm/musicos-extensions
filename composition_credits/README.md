# `composition_credits`

> Miso's canonical writing-credits (attribution) standard for Miso `Composition` objects.

**Attaches to:** `miso::composition::Composition<CompositionShare>` via the object's cap-gated `uid_mut`. A single `CompositionCredits` record is stored as a dynamic field under the `ExtensionKey()` key, gated by `CompositionAdminCap<CompositionShare>`.

Writing credits are display-oriented and vary across platforms, so they live in this extension rather than in immutable core. A credit maps a `partyos` `Party` ID to a `Credit<CompositionPartyRole>` (a display name plus 1-5 roles). Credits are pure attribution — they are NOT read by any economics. The record is lazily created on the first `add_credit` and survives into any composition lifecycle state (it may be attached before or after publish). Because this is an extension, other parties may publish their own competing composition-credits standard against the same `Composition`.

Invariants enforced on write: each credit must carry 1-5 roles (`MIN_ROLES_PER_CREDIT`..`MAX_ROLES_PER_CREDIT`); a `Party` may hold at most one credit; and a composition may hold at most 50 credits (`MAX_CREDITS`). `composition_party_role` is a closed enum — variants can only be constructed via the `new_*_role` functions and read via `name()` — with a length-validated `Custom(String)` escape hatch (max 100 bytes, non-empty) for roles outside the canonical vocabulary.

## Entry points

### `composition_credits`

- **`add_credit`** — cap-gated. Adds a `Credit<CompositionPartyRole>` for a `Party`, lazily initializing the credits record on first use. Asserts the 1-5 role bound, the 50-credit cap, and one-credit-per-party.
- **`remove_credit`** — cap-gated. Removes a party's credit by `Party` ID; aborts if the party is not credited.

### `composition_party_role`

- **`new_adapter_role` / `new_arranger_role` / `new_composer_role` / `new_lyricist_role` / `new_songwriter_role` / `new_translator_role`** — permissionless constructors for the canonical `CompositionPartyRole` variants.
- **`new_custom_role`** — permissionless constructor for a user-defined `Custom(name)` role; validates the name is non-empty and ≤ 100 bytes.

## Views

- **`composition_credits::has_credits`** — whether a credits record has been attached to the composition yet.
- **`composition_credits::credits`** — the `&VecMap<ID, Credit<CompositionPartyRole>>` (party ID → credit); aborts if no record is attached.
- **`composition_party_role::name`** — the role's canonical PascalCase identifier (e.g. `"Songwriter"`), or the user-supplied string for `Custom`.

## Dependencies

- **`miso`** — provides `Composition` and `CompositionAdminCap`; the host object this extension attaches to and the cap that authorizes mutations.
- **`partyos`** — provides `Party` (credited identity) and the generic `Credit<T>` (display name + roles) wrapped over `CompositionPartyRole`.

## Build & test

```sh
sui move build
sui move test
```
