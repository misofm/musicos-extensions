# `release_credits`

> First-party credits extension that records top-line billing (Primary / Featured artists) for a musicos `Release`.

**Attaches to:** `musicos::release::Release`, as a dynamic field on the release's `&mut UID`. The UID is obtained through `Release::uid_mut(cap)`, which is gated by a `ReleaseAdminCap`, so every mutation is authorized by the release's admin. The record is stored under the `ExtensionKey()` key.

Attribution (top-line billing) is display-oriented and varies across platforms, so it lives in this extension rather than in immutable musicos core. Credits are pure attribution — they are not read by the protocol's economics. Because this is an extension, other parties may publish their own competing release-credits standard against the same `Release`; this is musicos's canonical one.

The data model is a single `ReleaseCredits` record holding a `VecMap<ID, Credit<ReleasePartyRole>>` (party ID to credit). Key invariants: a party may hold at most one credit, each credit must carry exactly one role (`Primary` or `Featured`), and a release is capped at `MAX_CREDITS` (50). The record is lazily created on first `add_credit` and survives into any release lifecycle state (it may be attached before or after publication).

## Modules

- **`release_credits`** — the credits record, its dynamic-field storage, and the write/read API.
- **`release_party_role`** — the closed `ReleasePartyRole` enum (`Primary` / `Featured`) and its constructors.

## Entry points

- **`release_credits::add_credit`** — cap-gated. Adds a `Credit<ReleasePartyRole>` for a party, lazily creating the credits record on first use. Asserts the credit carries exactly one role, the party is not already credited, and the per-release cap is not exceeded.
- **`release_credits::remove_credit`** — cap-gated. Removes a party's credit by party ID; aborts if the party is not credited.
- **`release_party_role::new_primary_role`** — permissionless. Constructs a `Primary` role.
- **`release_party_role::new_featured_role`** — permissionless. Constructs a `Featured` role.

## Mutation event payloads

Each successful mutation emits exactly one monomorphic `copy, drop` event:
`ReleaseCreditAddedEvent` for an add and `ReleaseCreditRemovedEvent` for a
remove. In both declarations, fields appear in this exact order:

```text
release_id: address
release_admin_cap_id: address
party_id: address
display_name: vector<u8>
role_kind: u8
credit_count_before: u64
credit_count_after: u64
credit_index: u64
credits_record_existed_before: bool
credits_record_exists_after: bool
```

`role_kind` is the stable role tag: `Primary = 0`, `Featured = 1`. The
`display_name` bytes are the UTF-8 bytes stored in the `Credit` value itself;
they are not read from the Party object. `credit_index` is the insertion-order
index after an add and the pre-removal index on a remove. Since `VecMap` keeps
the remaining entries ordered, an indexer can replay removals and re-adds by
shifting later entries and appending the re-added party.

The first add reports `credits_record_existed_before = false` and
`credits_record_exists_after = true`. Later adds and re-adds report
`true / true`. Every successful removal also reports `true / true`, including
removal of the final credit: the empty credits dynamic-field record is retained.

For a display name of `n` bytes, the BCS payload size is
`123 + ULEB128(n) + n` bytes. With the `Credit` maximum of 200 display-name
bytes, the largest event is 325 bytes; useful boundaries are 125 bytes at
`n = 1`, 251 bytes at `n = 127`, and 253 bytes at `n = 128`.

## Views

- **`release_credits::has_credits`** — whether a credits record has been attached to the release yet.
- **`release_credits::credits`** — borrows the party-ID-to-`Credit` map; aborts if no credits are attached.
- **`release_party_role::name`** — the role's canonical PascalCase identifier (`"Primary"` / `"Featured"`).

## Dependencies

- **`musicos`** — provides `Release` / `ReleaseAdminCap` (the core object being extended and its admin gate).
- **`partyos`** — provides `Party`, the credited identity.
- **`credit`** — provides `Credit<ReleasePartyRole>`, including the display name and role container used by this extension.

## Build & test

```sh
sui move build
sui move test
```
