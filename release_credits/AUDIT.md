> Historical audit below predates the 2026-09-15 payload revision. Current event contracts and size bounds are documented in [EVENT_PAYLOADS.md](../EVENT_PAYLOADS.md). Storage, authority, and mutation behavior remain unchanged.

# Security review — `release_credits`

Reviewed 2026-09-11 for the rich primitive mutation events. The review covers
the existing cap-gated storage and guard order plus the bounded event
snapshots. Verdict: no exploitable findings in the reviewed source.

## Dependency provenance

`musicos` and `partyos` provide the release and credited `Party` identity,
while the direct `credit` dependency provides `Credit<ReleasePartyRole>` and
its display-name/role container. The checked-in manifest pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`, `partyos` at
`841a875a4989082a0ebeb1beb464b71f9ea2bd73`, and `credit` at
`0780d1d694a4d35315af20e1ea7d707558846024`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Add and remove require the matching ID-bound `ReleaseAdminCap`. Module-owned
keying and private fields protect the dynamic-field schema. The implementation
enforces one credit per Party, a bounded collection, and exactly one closed
`Primary` or `Featured` role per credit. Credits are administrator-authored
billing metadata; Release revenue follows immutable track splits and is not
read here. The package contains no Action, Plugin, Vault, or funds logic.

## Evidence

With Sui `1.79.0`, strict Testnet and Mainnet builds and tests pass: 20/20
tests. Both production modules report 100.00% coverage across local release
storage, authorization, exact role cardinality, bounds, duplicates, removal,
and event snapshots.

## 2026-09-24 — regeneration against musicos `6dff4de` and partyos `88c2e40`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c` (`release::new(registry, tracks,
nonce)`; `publish(self, cap)` takes no Clock; core stores no title) and
`partyos` at `88c2e40353dbee8d8f98272069b4d836b02b12ae` (`party::new(kind,
name, ctx)` and `share(self, cap)` take no Clock or ctx). `credit` stays at
`6c295ea10f796edfec18f54783733a35210f4b06`; both lock graphs now pin it there
(the Mainnet graph previously carried an older `credit`, `musicos`, and
`partyos`). Verdict unchanged: no exploitable findings.

Changes in this generation:

- Events slimmed to the release address, the party address, and — on add —
  `roles: vector<ReleasePartyRole>` exactly as stored:
  `ReleaseCreditAddedEvent` is exactly 66 BCS bytes (one unit-variant role)
  and `ReleaseCreditRemovedEvent` is 64 (both down from 123). Dropped: admin
  cap address (derived from the release), before/after counts, insertion
  index, role code, and record presence flags. The display name stays in
  storage.
- The `name()` token renderer and the package-private `event_kind` helper
  were removed: no consumer under `/home/bl/misofm` calls them, and a role is
  read from its BCS variant index. The `Primary` / `Featured` variants are
  unchanged.
- No silent no-op path exists: re-crediting a party (identical credit
  included) aborts `EPartyAlreadyCredited`, and removing an uncredited party
  aborts `EPartyNotCredited`, as before.
- Guard order is argument validation (`EInvalidCreditRoleCount`), then the
  cap (`uid_mut`, which enforces `release::EUnauthorized`), then stored-state
  checks with capacity before duplicate.

Storage key, value type, authorization, exact role cardinality, bounds, and
the retained empty record are unchanged.

Evidence: with Sui `1.79.0`, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean and all 21 tests pass on each network;
both production modules report 100.00% coverage.

Event `release_id`/`party_id` fields are typed `ID` rather than `address`, and
emit sites pass object ids directly; BCS layout and sizes are unchanged.
