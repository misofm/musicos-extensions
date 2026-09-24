> Historical audit below predates the 2026-09-15 payload revision. Current event contracts and size bounds are documented in [EVENT_PAYLOADS.md](../EVENT_PAYLOADS.md). Storage, authority, and mutation behavior remain unchanged.

# Security review — `recording_credits`

Reviewed 2026-09-11 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`, `partyos` at
`841a875a4989082a0ebeb1beb464b71f9ea2bd73`, and `credit` at
`0780d1d694a4d35315af20e1ea7d707558846024`. The direct `credit` dependency
provides `Credit<RecordingPartyRole>`; `partyos` provides only the credited
`Party` identity. Both network lock graphs resolve `bps` without duplicate
aliases.

## Threat model and findings

All six mutations require a `RecordingAdminCap<RecordingShare>` through
`Recording::uid_mut`; “matching” means the `RecordingShare` type parameter
only. In the pinned `musicos` dependency, `uid_mut` ignores the cap's object ID,
sender, and recording lifecycle, so this package does not claim a per-recording
cap-identity or caller check. Module-owned keys and private stored fields
protect the dynamic-field schema. The implementation enforces unique credited
Parties, bounded credits and roles, primary/featured membership within the
credited set, and disjoint primary and featured sets; credit removal cascades
through both designations. Credits are administrator-authored attribution and
never drive royalty accounting in this package. The six generic rich events
carry only bounded primitive snapshots and identifiers; credit removal emits
its event immediately after map removal, followed by designation cascade events
in set-mutation order. Views and constructors are silent. No Vault, Action,
Plugin, or funds movement exists here.

## Evidence

With Sui 1.79.0, strict Testnet and Mainnet lint, warnings-as-errors builds,
and tests pass: 44/44 on each network. Production coverage is checked for both
modules, including collection limits, designation invariants, cascades, roles,
and rich event payload serialization.

## 2026-09-24 — regeneration against musicos `6dff4de` and partyos `88c2e40`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c` (`Recording<RecordingShare>` takes
a single type parameter; `publish(self, cap)` takes no Clock) and `partyos`
at `88c2e40353dbee8d8f98272069b4d836b02b12ae` (`party::new(kind, name, ctx)`
takes no Clock). `credit` stays at `6c295ea10f796edfec18f54783733a35210f4b06`;
both lock graphs now pin it there (the Mainnet graph previously carried an
older `credit`, `musicos`, and `partyos`). Verdict unchanged: no exploitable
findings.

Changes in this generation:

- Every function and event is generic over `RecordingShare` only, following
  core. Events renamed with the `Recording` prefix used by the sibling credits
  packages: `RecordingCredit{Added,Removed}Event`,
  `RecordingPrimaryArtist{Added,Removed}Event`,
  `RecordingFeaturedArtist{Added,Removed}Event`.
- `RecordingPartyRole::Custom` removed with `new_custom_role`,
  `MAX_CUSTOM_NAME_LENGTH` and `EMaxCustomNameLengthExceeded` (31);
  `EEmptyString` (35) and `EMaxInstrumentLengthExceeded` (30) remain for the
  unchanged `Instrumentalist` validation. Roles outside the 31 canonical
  variants will arrive in a future package generation. The `name()` token
  renderer and the package-private `event_fields` helper were removed: no
  consumer under `/home/bl/misofm` calls them, and a role is read from its
  BCS variant index and `level()`.
- Events slimmed to the recording address, the party address, and — on
  credit add — `roles: vector<RecordingPartyRole>` exactly as stored,
  instrument names and levels included: `RecordingCreditAddedEvent` is
  66–1105 BCS bytes (typically 67; the maximum is ten instrumentalists each
  with a 100-byte instrument name and a level, tested), down from at most
  175 for a payload that omitted the strings; the other five events are 64
  bytes (down from 176, 160, and 161). Dropped: composition address
  (joinable via core's `RecordingPublishedEvent`), admin cap address (derived
  from the recording), before/after counts, indices, role-code vectors,
  presence flags, and the `was_primary_artist` / `was_featured_artist` /
  `caused_by_credit_removal` cascade flags. The display name stays in
  storage.
- Removing a credit that held a designation no longer emits an artist-removed
  event: the designation sets are subsets of the credits by invariant, so the
  cascade is inferable from `RecordingCreditRemovedEvent` alone. The
  artist-removed events now mark explicit un-designation only.
- No silent no-op path exists: re-crediting a party (identical credit
  included), re-designating an artist, and removing an absent credit or
  designation all abort, as before.
- Guard order is argument validation (`EExceedsMaxRoles`), then the cap
  (`uid_mut`), then stored-state checks in the previous order.

Storage key, value type, authorization, bounds, the disjoint-subset
invariant, and the retained empty record are unchanged.

Evidence: with Sui `1.79.0`, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean and all 40 tests pass on each network;
both production modules report 100.00% coverage.
