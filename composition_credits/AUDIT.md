> Historical audit below predates the 2026-09-15 payload revision. Current event contracts and size bounds are documented in [EVENT_PAYLOADS.md](../EVENT_PAYLOADS.md). Storage, authority, and mutation behavior remain unchanged.

# Security review — `composition_credits`

Reviewed 2026-09-11 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`, `partyos` at
`841a875a4989082a0ebeb1beb464b71f9ea2bd73`, and `credit` at
`0780d1d694a4d35315af20e1ea7d707558846024`. The generated Testnet and
Mainnet lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` with no duplicate package aliases.

## Threat model and findings

The security boundary is attribution integrity. Both mutations require a typed
`CompositionAdminCap` through `Composition::uid_mut`; the cap address in an
event is provenance and is not separately runtime-matched to the composition.
Module-owned `ExtensionKey` and private stored fields prevent cross-extension
key or value confusion. Duplicate parties, credit count, and roles-per-credit
are bounded. Credits are descriptive data only: this package contains no funds
movement, Vault borrowing, Action, or Plugin logic. A Composition administrator
can name a Party without that Party's consent; this is the documented meaning
of an administrator-authored credit, not a royalty authorization. Event role
snapshots use bounded primitive bytes and preserve role order without invoking
the public role-name view.

## Evidence

With `sui 1.79.0`, strict lint and warnings-as-errors builds and tests pass on
Testnet and Mainnet: 16/16 tests. The suite covers shared published objects,
authorization, limits, duplicate rejection, role validation, insertion-order
indices, retained empty records, generic event streams, and primitive event
fields.

## 2026-09-24 — regeneration against musicos `6dff4de` and partyos `88c2e40`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c` (`publish(self, cap)` takes no
Clock; core stores no title) and `partyos` at
`88c2e40353dbee8d8f98272069b4d836b02b12ae` (`party::new(kind, name, ctx)`
takes no Clock). `credit` stays at `6c295ea10f796edfec18f54783733a35210f4b06`;
both lock graphs now pin it there (the Mainnet graph previously carried an
older `credit`, `musicos`, and `partyos`). Verdict unchanged: no exploitable
findings.

Changes in this generation:

- `CompositionPartyRole::Custom` removed with `new_custom_role`,
  `MAX_CUSTOM_NAME_LENGTH`, `EEmptyString` (35) and
  `EMaxCustomNameLengthExceeded` (31); the module now has no error
  constants. Roles outside the six canonical variants will arrive in a future
  package generation. The `name()` token renderer and the package-private
  `event_encoding` helper were removed: no consumer under `/home/bl/misofm`
  calls them, and a role is read from its BCS variant index.
- Events slimmed to the composition address, the party address, and — on
  add — `roles: vector<CompositionPartyRole>` exactly as stored:
  `CompositionCreditAddedEvent` is 66–70 BCS bytes (one byte per unit-variant
  role) and `CompositionCreditRemovedEvent` is 64 (both down from 128).
  Dropped: admin cap address (derived from the composition), before/after
  counts, insertion index, role-code vector, and record presence flags. The
  display name stays in storage; an indexer reconstructs membership, order,
  and roles from the ordered add/remove stream.
- No silent no-op path exists: re-crediting a party (identical credit
  included) aborts `EPartyAlreadyCredited`, and removing an uncredited party
  aborts `EPartyNotCredited`, as before.
- Guard order is argument validation (`EExceedsMaxRoles`), then the cap
  (`uid_mut`), then stored-state checks with capacity before duplicate.

Storage key, value type, authorization, bounds, and the retained empty record
are unchanged.

Evidence: with Sui `1.79.0`, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean and all 13 tests pass on each network;
both production modules report 100.00% coverage.

Event `composition_id`/`party_id` fields are typed `ID` rather than `address`,
and emit sites pass object ids directly; BCS layout and sizes are unchanged.
