# Client contract matrix

This is the source-level contract for the coordinated Miso client update. It
describes the checked-out Move sources only, deliberately contains no package,
object, upgrade-capability, or signer addresses, and is not a deployment plan.
Concrete IDs belong in the later post-publish address-injection task.

## Scope and status

Reviewed packages:

| Layer | Packages |
| --- | --- |
| Core | `miso` |
| Data extensions | 14 packages in this repository |
| Revenue primitives | `royalty_pool`, `routed_stake` |
| Composable actions | `protocol-actions`, `party-actions` |
| Custody and automation | `vault` and three `vault-plugins` packages |

The canonical `ReleaseRegistry` is part of `miso`, and the canonical
`VaultRegistry` is part of `vault`. Each package initializer creates and shares
its registry. Discover both registry object IDs from successful publish effects;
only `ReleaseRegistry` also emits a registry-created event.

## Client-wide rules

- Every `ctx: &mut TxContext` below is runtime-injected. Do **not** add a
  transaction argument for it in TypeScript.
- Core, data-extension, primitive, Action, and vault functions are `public`.
  Actions take the raw core capability and remain custody-agnostic and
  return-oriented. The automated vault-plugin operations are **private `entry`
  endpoints**: transactions may use them as commands in multi-command PTBs,
  but other Move packages cannot call them and they return no PTB value.
- A `&mut` parameter is a mutable transaction object input. Published core
  objects, registries, pools, routed stakes, and vaults are shared objects.
  An uncustodied matching `*AdminCap` is address-owned and must be selected
  from the caller's owned objects. Once it is passed with the shared
  `VaultRegistry` to `vault::new`, that core cap is held inside the shared
  vault; the distinct `VaultAdminCap` is the address-owned administrator
  credential.
- `Balance<T>`, fresh core objects, `Stake<T>`, `RoyaltyPool<...>`,
  `RoutedStake<...>`, `Vault<T>`, and `Borrow` receipts are non-drop values.
  A PTB must consume each one as noted below. Never use a plain move call that
  leaves one unconsumed.

### Move references are not TypeScript results

The source exposes both transaction/value functions and Move-to-Move helpers.
Any signature returning a reference—such as `&UID`, `&String`, `&vector<T>`,
`&VecMap<...>`, `&Balance<T>`, `&Stake<T>`, or a mutable reference—is only
usable inside Move. A TypeScript PTB cannot receive that reference as a result,
and no direct RPC "view" call exists for it. Generate no client helper that
expects these reference-returning functions to yield a JavaScript value.

Functions returning value types (`ID`, `bool`, integers, `String`,
`Option<T>`, and copyable value structs) can be transaction command results,
but are still not synchronous TypeScript return values. Clients normally read
shared object JSON/BCS, dynamic fields, and events; use simulation only where a
specific value-returning Move call is deliberately part of the client design.
Keep `u64`, `u128`, and `u256` lossless as strings/bigints at the SDK boundary.

### Publication dependency order

The source graph—not a set of concrete IDs—is:

1. Pre-existing reusable dependencies must resolve first: `bps`, `miso_share`,
   `partyos`, `miso_credit`, `language_code`, `ori`, `cover_art`, `per_track`,
   `genre`, and `hikida` as applicable.
2. Publish `miso`; it is the direct source dependency of every data
   extension and creates the canonical `ReleaseRegistry` singleton in its
   package initialization.
3. `royalty_pool` and `vault` are independent of `miso` (apart from their own
   reusable dependencies) and may be published in parallel with step 2.
4. Publish the 14 data extensions after `miso`.
5. Publish `routed_stake` after `royalty_pool`.
6. Publish the custody-agnostic Actions after their core and primitive
   dependencies: `party_wallet`, `composition_royalty_pool`,
   `recording_royalty_pool`, `composition_routed_stake`, and
   `release_revenue_distributor`.
7. Publish only the three automation adapters last:
   `composition_royalty_pool_plugin`, `recording_royalty_pool_plugin`, and
   `release_revenue_distributor_plugin`. There is no Party wallet or routed
   stake plugin.

The deployment layer must fail closed until every package in the selected
feature set has a real ID for the target network. It must record both singleton
registries created by package initialization—`ReleaseRegistry` and
`VaultRegistry`—from the actual publish effects rather than guessing them.

## Core: `miso`

`Composition<CS>`, `Recording<RS, CS>`, and `Release` are key-only during
construction. Their creation and `publish` call must be in one PTB; `publish`
consumes and shares the object. `Track` has `drop, store` and is an ephemeral
input to release creation.

### `miso::composition`

Public types:

- `Composition<phantom CompositionShare> has key`
- `CompositionAdminCap<phantom CompositionShare> has key, store`
- `CompositionState = Initialized | Published(u64)`
- `CompositionPublishedEvent<phantom CompositionShare> { composition_id: ID }`

```move
new<CS>(
  title: String,
  royalty_rate_bps: u16,
  share_currency: &mut Currency<CS>,
  share_treasury_cap: TreasuryCap<CS>,
  ctx: &mut TxContext,
) -> (Composition<CS>, CompositionAdminCap<CS>, Balance<CS>)

publish<CS>(Composition<CS>, &CompositionAdminCap<CS>, &Clock)
title<CS>(&Composition<CS>) -> &String
royalty_rate<CS>(&Composition<CS>) -> BPS
uid<CS>(&Composition<CS>) -> &UID
uid_mut<CS>(&mut Composition<CS>, &CompositionAdminCap<CS>) -> &mut UID
```

The returned composition and its admin cap are PTB-local. Publish the former,
then either transfer the **core** admin cap to its owner or pass that cap by
value with the shared `VaultRegistry` to `vault::new`; the latter puts the core
cap inside the permanent vault shell and returns a distinct `VaultAdminCap` for
the owner. Consume the returned share balance
(for example, convert it to a coin and transfer it). The royalty rate is
immutable after `new`; `bps::new` permits `0..=10_000`.

### `miso::recording`

Public types and events:

- `Recording<phantom RecordingShare, phantom CompositionShare> has key`
- `RecordingAdminCap<phantom RecordingShare> has key, store`
- `RecordingState = Initialized | Published(u64)`
- `RecordingPublishedEvent<RS, CS> { recording_id: ID }`
- `CompositionSharesGrantedEvent<RS, CS> { recording_id: ID, composition_id:
  ID, value: u64, rate_bps: u16, granted_by: address }`

```move
new<RS, CS>(
  composition: &Composition<CS>,
  share_currency: &mut Currency<RS>,
  share_treasury_cap: TreasuryCap<RS>,
  ctx: &mut TxContext,
) -> (Recording<RS, CS>, RecordingAdminCap<RS>, Balance<RS>)

publish<RS, CS>(Recording<RS, CS>, &RecordingAdminCap<RS>, &Clock)
composition_id<RS, CS>(&Recording<RS, CS>) -> ID
uid<RS, CS>(&Recording<RS, CS>) -> &UID
uid_mut<RS, CS>(&mut Recording<RS, CS>, &RecordingAdminCap<RS>) -> &mut UID
```

The new recording is paired to its composition by phantom type and now embeds
the composition ID. It has no `max_royalty_rate_bps` argument.

### `miso::track`

`Track has drop, store` has embedded `composition_id`, `recording_id`, and
`split_bps` fields. Its state is `TrackState = Unassigned(ID) | Assigned`.

```move
new<RS, CS>(
  &RecordingAdminCap<RS>,
  &Recording<RS, CS>,
  target_release_id: ID,
  track_split_bps_value: u16,
) -> Track

recording_id(&Track) -> ID
composition_id(&Track) -> ID
split_bps(&Track) -> BPS
target_release_id(&Track) -> ID
```

Clients must compute the same target release ID, create all tracks with that
ID, and pass all resulting PTB values directly to release creation.

### `miso::release`

Public types and event:

- `Release has key`, with ordered `vector<Track>`
- `ReleaseAdminCap has key, store`, bound to `release_id`
- `ReleaseRegistry has key`, the canonical shared release-ID namespace
- `ReleaseState = Initialized | Published(u64)`
- `ReleasePublishedEvent { release_id: ID }`
- `ReleaseRegistryCreatedEvent { registry_id: ID, created_by: address }`

```move
new(
  &mut ReleaseRegistry,
  title: String,
  tracks: vector<Track>,
  nonce: u256,
) -> (Release, ReleaseAdminCap)

publish(Release, &ReleaseAdminCap, &Clock)
authorize(&Release, &ReleaseAdminCap)
derive_target_release_id(
  &ReleaseRegistry,
  vector<ID>,
  vector<u64>,
  u256,
) -> ID
release_registry_id(&ReleaseRegistry) -> ID
title(&Release) -> &String
tracks(&Release) -> &vector<Track>
release_admin_cap_release_id(&ReleaseAdminCap) -> ID
uid(&Release) -> &UID
uid_mut(&mut Release, &ReleaseAdminCap) -> &mut UID
```

`miso::release` package initialization creates and shares exactly one
`ReleaseRegistry`, emitting `ReleaseRegistryCreatedEvent`; record the object
ID from publish effects. The PTB sequence is: derive the target ID using the
shared registry and exactly ordered recording IDs/split values, make tracks
against that target, call `release::new`, publish the returned release, then
transfer or custody the returned admin cap. `release::new` is the only
production release constructor: there is no `new_release`, standalone registry
package, or arbitrary-parent constructor. The Move-2024 convenience method
`registry.id()` maps to the callable `release_registry_id` ABI function.

## Data extensions

All metadata is a dynamic field on the core object's UID. With one exception,
the field name is the `ExtensionKey` defined by that specific extension
package, so clients must construct dynamic-field queries with that package's
eventual type ID. Absence is meaningful: guard reads that the source marks as
aborting with a corresponding `has_*` call. Every mutator below returns `()`.

`release_dsp_link` does **not** use `ExtensionKey`. Its parent for both query
families is the Release UID (therefore the Release object ID), and its dynamic
field names/values are:

```move
ReleaseLinkKey(platform: u8) -> DspLinkData
TrackLinksKey(platform: u8) -> PerTrack<Option<DspLinkData>>
```

Use the eventual `release_dsp_link` package ID in either key type. The track
value is one inline `PerTrack<Option<DspLinkData>>` dynamic-field value; it is
not a second dynamic-field collection, so do not query it under a collection
UID. `release_link` and `track_link` are Move value helpers, while off-chain
clients should query/decode these dynamic fields or consume their events.

Abbreviations used only in this table:

```move
C<CS> = Composition<CS>
CA<CS> = CompositionAdminCap<CS>
R<RS, CS> = Recording<RS, CS>
RA<RS> = RecordingAdminCap<RS>
L = Release
LA = ReleaseAdminCap
```

| Package / module | State-changing public ABI | Read/type surface | Events (exact fields) |
| --- | --- | --- | --- |
| `composition_credits::composition_credits` | `add_credit<CS>(&mut C<CS>, &CA<CS>, &Party, Credit<CompositionPartyRole>)`; `remove_credit<CS>(&mut C<CS>, &CA<CS>, party_id: ID)` | `has_credits<CS>(&C<CS>) -> bool`; `credits<CS>(&C<CS>) -> &VecMap<ID, Credit<CompositionPartyRole>>`; `CompositionCredits has store` | `CreditAddedEvent { composition_id, party_id, credit: Credit<CompositionPartyRole> }`; `CreditRemovedEvent { composition_id, party_id, credit: Credit<CompositionPartyRole> }` |
| `recording_advisory::recording_advisory` | `set_rating<RS,CS>(&mut R<RS,CS>, &RA<RS>, ExplicitRating)`; `unset_rating<RS,CS>(&mut R<RS,CS>, &RA<RS>)` | constructors `explicit()`, `not_explicit()`, `cleaned()`; `has_rating`; `rating -> ExplicitRating`; `is_explicit`, `is_not_explicit`, `is_cleaned`; `name(&ExplicitRating) -> vector<u8>`; `ExplicitRating = Explicit \| NotExplicit \| Cleaned` | `AdvisoryRatingSetEvent { recording_id, rating: ExplicitRating }`; `AdvisoryRatingUnsetEvent { recording_id }` |
| `recording_credits::recording_credits` | `add_credit<RS,CS>(&mut R<RS,CS>, &RA<RS>, &Party, Credit<RecordingPartyRole>)`; `remove_credit(..., party_id: ID)`; `add_primary_artist(..., &Party)` / `remove_primary_artist(..., party_id: ID)`; `add_featured_artist(..., &Party)` / `remove_featured_artist(..., party_id: ID)` | `has_credits`; `credits -> &VecMap<ID, Credit<RecordingPartyRole>>`; `primary_artist_ids -> &VecSet<ID>`; `featured_artist_ids -> &VecSet<ID>`; `is_primary_artist(..., ID)`; `is_featured_artist(..., ID)`; `RecordingCredits has store` | `CreditAddedEvent` / `CreditRemovedEvent` `{ recording_id, party_id, credit: Credit<RecordingPartyRole> }`; `PrimaryArtistAddedEvent` / `PrimaryArtistRemovedEvent` `{ recording_id, party_id }`; `FeaturedArtistAddedEvent` / `FeaturedArtistRemovedEvent` `{ recording_id, party_id }` |
| `recording_engine_session::recording_engine_session` | `attach_engine_session<RS,CS>(&mut R<RS,CS>, &RA<RS>, WalrusData)`; `replace_engine_session<RS,CS>(&mut R<RS,CS>, &RA<RS>, WalrusData)`; `unset_engine_session<RS,CS>(&mut R<RS,CS>, &RA<RS>)` | `has_engine_session`; `engine_session -> &EngineSession`; `reference(&EngineSession) -> &WalrusData`; outer reference must be a standalone plaintext blob | `EngineSessionAttachedEvent` / `EngineSessionReplacedEvent` `{ recording_id, reference: WalrusData }`; `EngineSessionUnsetEvent { recording_id }` |
| `recording_language::recording_language` | `set_languages<RS,CS>(&mut R<RS,CS>, &RA<RS>, vector<LanguageCode>)`; `set_instrumental<RS,CS>(&mut R<RS,CS>, &RA<RS>)`; `unset_languages<RS,CS>(&mut R<RS,CS>, &RA<RS>)` | `has_languages`; `languages -> vector<LanguageCode>`; `is_instrumental`; an attached empty vector means instrumental, absence does not | `LanguagesSetEvent { recording_id, languages: vector<LanguageCode> }`; `LanguagesUnsetEvent { recording_id }` |
| `recording_master_reference::recording_master_reference` | `set_master_reference<RS,CS>(&mut R<RS,CS>, &RA<RS>, WalrusData)`; `unset_master_reference<RS,CS>(&mut R<RS,CS>, &RA<RS>)` | `has_master_reference`; `master_reference -> &WalrusData` | `MasterReferenceSetEvent { recording_id, reference: WalrusData }`; `MasterReferenceUnsetEvent { recording_id }` |
| `recording_preview::recording_preview` | `set_preview<RS,CS>(&mut R<RS,CS>, &RA<RS>, WalrusData)`; `unset_preview<RS,CS>(&mut R<RS,CS>, &RA<RS>)` | `has_preview`; `preview -> &WalrusData` | `PreviewSetEvent { recording_id, preview: WalrusData }`; `PreviewUnsetEvent { recording_id }` |
| `release_cover_art::release_cover_art` | `set_cover(&mut L, &LA, CoverArt)`; `unset_cover(&mut L, &LA)`; `set_track_cover(&mut L, &LA, track_index: u64, CoverArt)`; `unset_track_cover(&mut L, &LA, track_index: u64)` | `has_cover_art`; `cover -> &Option<CoverArt>`; `track_cover(..., u64) -> Option<CoverArt>`; `ReleaseCoverArt has store` | `CoverSetEvent { release_id, art: CoverArt }`; `CoverUnsetEvent { release_id }`; `TrackCoverSetEvent { release_id, track_index, art: CoverArt }`; `TrackCoverUnsetEvent { release_id, track_index }` |
| `release_credits::release_credits` | `add_credit(&mut L, &LA, &Party, Credit<ReleasePartyRole>)`; `remove_credit(&mut L, &LA, party_id: ID)` | `has_credits`; `credits -> &VecMap<ID, Credit<ReleasePartyRole>>`; `ReleaseCredits has store` | `CreditAddedEvent { release_id, party_id, credit: Credit<ReleasePartyRole> }`; `CreditRemovedEvent { release_id, party_id, credit: Credit<ReleasePartyRole> }` |
| `release_description::release_description` | `set_description(&mut L, &LA, String)`; `clear_description(&mut L, &LA)` | `has_description`; `description -> &String` | `DescriptionSetEvent { release_id, description: String }`; `DescriptionClearedEvent { release_id }` |
| `release_dsp_link::release_dsp_link` | `set_release_link(&mut L, &LA, DspLinkData)`; `clear_release_link(&mut L, &LA, platform: u8)`; `set_track_link(&mut L, &LA, track_index: u64, DspLinkData)`; `clear_track_link(&mut L, &LA, platform: u8, track_index: u64)`; `clear_track_links(&mut L, &LA, platform: u8)` | `platform(&DspLinkData) -> u8`; constructors listed below; `has_release_link`; `release_link -> Option<DspLinkData>`; `track_link -> Option<DspLinkData>` | `ReleaseLinkSetEvent { release_id, link: DspLinkData }`; `ReleaseLinkClearedEvent { release_id, platform }`; `TrackLinkSetEvent { release_id, platform, track_index, link: Option<DspLinkData> }`; `TrackLinksClearedEvent { release_id, platform }` |
| `release_genre::release_genre` | `set_primary_genre(&mut L, &LA, &Genre)`; `add_secondary_genre(&mut L, &LA, &Genre)`; `remove_secondary_genre(&mut L, &LA, &Genre)`; `set_track_primary_genre(&mut L, &LA, track_index: u64, &Genre)`; `unset_track_primary_genre(&mut L, &LA, track_index: u64)` | `has_genre`; `primary_genre -> Option<ID>`; `secondary_genres -> vector<ID>`; `track_primary_genre(..., u64) -> Option<ID>`; `ReleaseGenre has store` | `PrimaryGenreSetEvent`, `SecondaryGenreAddedEvent`, `SecondaryGenreRemovedEvent` `{ release_id, genre_id }`; `TrackPrimaryGenreSetEvent { release_id, track_index, genre_id }`; `TrackPrimaryGenreUnsetEvent { release_id, track_index }` |
| `release_kind::release_kind` | `set_kind(&mut L, &LA, String)`; `unset_kind(&mut L, &LA)` | `has_kind`; `kind -> String` | `KindSetEvent { release_id, kind: String }`; `KindUnsetEvent { release_id }` |
| `release_mix_reference::release_mix_reference` | `attach_mix_reference(&mut L, &LA, track_index: u64, WalrusData)`; `replace_mix_reference(&mut L, &LA, track_index: u64, WalrusData)` | `has_mix_reference(&L, u64) -> bool`; `mix_reference(&L, u64) -> &WalrusData`; one optional plaintext standalone-blob descriptor per immutable track | `MixReferenceAttachedEvent` / `MixReferenceReplacedEvent` `{ release_id, track_index, recording_id, descriptor_reference: WalrusData }` |

### Role/value APIs

These types are BCS values passed inside `Credit<T>`; their fields are not
arbitrary client strings.

```move
// composition_credits::composition_party_role
CompositionPartyRole = Adapter | Arranger | Composer | Lyricist | Songwriter
  | Translator | Custom(String)
new_adapter_role(); new_arranger_role(); new_composer_role();
new_lyricist_role(); new_songwriter_role(); new_translator_role();
new_custom_role(String); name(&CompositionPartyRole) -> String

// release_credits::release_party_role
ReleasePartyRole = Primary | Featured
new_primary_role(); new_featured_role(); name(&ReleasePartyRole) -> String
```

`recording_credits::recording_party_role` exposes these public constructors:

```move
new_actor_role(Option<RecordingPartyRoleLevel>)
new_arranger_role(Option<RecordingPartyRoleLevel>)
new_artists_and_repertoire_role()
new_band_leader_role(Option<RecordingPartyRoleLevel>)
new_choir_role(Option<RecordingPartyRoleLevel>)
new_choir_master_role(Option<RecordingPartyRoleLevel>)
new_concert_master_role(Option<RecordingPartyRoleLevel>)
new_conductor_role(Option<RecordingPartyRoleLevel>)
new_contractor_role(Option<RecordingPartyRoleLevel>)
new_copyist_role()
new_dj_role(Option<RecordingPartyRoleLevel>)
new_editor_role(Option<RecordingPartyRoleLevel>)
new_engineer_role(Option<RecordingPartyRoleLevel>)
new_ensemble_role(Option<RecordingPartyRoleLevel>)
new_instrumentalist_role(String, Option<RecordingPartyRoleLevel>)
new_mastering_engineer_role(Option<RecordingPartyRoleLevel>)
new_mixing_engineer_role(Option<RecordingPartyRoleLevel>)
new_music_director_role(Option<RecordingPartyRoleLevel>)
new_music_supervisor_role(Option<RecordingPartyRoleLevel>)
new_narrator_role(Option<RecordingPartyRoleLevel>)
new_orchestra_role(Option<RecordingPartyRoleLevel>)
new_orchestrator_role(Option<RecordingPartyRoleLevel>)
new_performer_role(Option<RecordingPartyRoleLevel>)
new_producer_role(Option<RecordingPartyRoleLevel>)
new_programmer_role(Option<RecordingPartyRoleLevel>)
new_recording_engineer_role(Option<RecordingPartyRoleLevel>)
new_remixing_engineer_role(Option<RecordingPartyRoleLevel>)
new_soloist_role(Option<RecordingPartyRoleLevel>)
new_sound_designer_role(Option<RecordingPartyRoleLevel>)
new_speaker_role(Option<RecordingPartyRoleLevel>)
new_vocalist_role(Option<RecordingPartyRoleLevel>)
new_custom_role(String, Option<RecordingPartyRoleLevel>)
level(&RecordingPartyRole) -> Option<RecordingPartyRoleLevel>
name(&RecordingPartyRole) -> String
```

`RecordingPartyRoleLevel` values are `Additional`, `Assistant`, `Associate`,
`Backing`, `Executive`, `Featured`, `Lead`, `Primary`, and `Principal`; each
has its corresponding zero-argument constructor:
`new_additional_role_level`, `new_assistant_role_level`,
`new_associate_role_level`, `new_backing_role_level`,
`new_executive_role_level`, `new_featured_role_level`,
`new_lead_role_level`, `new_primary_role_level`, and
`new_principal_role_level`.

`DspLinkData` has frozen platform codes: Spotify `0`, Apple Music `1`, Amazon
Music `2`, Bandcamp `3`, Deezer `4`, SoundCloud `5`, Tidal `6`, YouTube Music
`7`. The exact enum shape is:

```move
Spotify { id: String }
AppleMusic { storefront: String, album_id: String, track_id: Option<String> }
AmazonMusic { album_id: String, track_id: Option<String> }
Bandcamp { subdomain: String, slug: String }
Deezer { id: String }
SoundCloud { user: String, slug: String }
Tidal { id: String }
YouTubeMusic { id: String }
```

Its constructors are `new_spotify`, `new_apple_music_album`,
`new_apple_music_track`, `new_amazon_music_album`, `new_amazon_music_track`,
`new_bandcamp`, `new_deezer`, `new_soundcloud`, `new_tidal`, and
`new_youtube_music`, with the field arguments shown by the enum form.
The exact zero-argument code accessors are `platform_spotify() -> u8`,
`platform_apple_music() -> u8`, `platform_amazon_music() -> u8`,
`platform_bandcamp() -> u8`, `platform_deezer() -> u8`,
`platform_soundcloud() -> u8`, `platform_tidal() -> u8`, and
`platform_youtube_music() -> u8`.

## Revenue primitives

### `royalty_pool::stake`

```move
new<Share>(Balance<Share>, ctx: &mut TxContext) -> Stake<Share>
destroy<Share>(Stake<Share>) -> Balance<Share>
balance(&Stake<Share>) -> &Balance<Share>
value(&Stake<Share>) -> u64
registration_count(&Stake<Share>) -> u64
has_registration(&Stake<Share>, &TypeName) -> bool
get_registration(&Stake<Share>, &TypeName) -> &Registration
registration_pool_id(&Registration) -> ID
registration_last_claim_index(&Registration) -> u256
```

`Stake<Share> has key, store`; `Registration has copy, drop, store` with
`pool_id: ID` and `last_claim_index: u256`. Events are
`StakeCreatedEvent<Share> { stake_id, amount }` and
`StakeDestroyedEvent<Share> { stake_id, amount }`. A fresh `Stake` returned by
`new` is a non-drop owned object: register it with a pool and then transfer it
to its holder in the same PTB, or transfer it directly. Do not leave it as an
unused move-call result. Conversely, `destroy` returns a non-drop balance that
must be consumed (for example, converted to a coin or deposited) in that PTB.

### `royalty_pool::pool`

```move
new<Share, Currency>(&mut UID) -> RoyaltyPool<Share, Currency>
share<Share, Currency>(RoyaltyPool<Share, Currency>)
deposit<Share, Currency>(&mut RoyaltyPool<Share, Currency>, Balance<Currency>)
receive_and_deposit<Share, Currency>(
  &mut RoyaltyPool<Share, Currency>, vector<Receiving<Coin<Currency>>>
)
sweep_and_deposit<Share, Currency>(
  &mut RoyaltyPool<Share, Currency>, &AccumulatorRoot
)
register_stake<Share, Currency>(&mut RoyaltyPool<Share, Currency>, &mut Stake<Share>)
unregister_stake<Share, Currency>(&mut RoyaltyPool<Share, Currency>, &mut Stake<Share>)
claim_rewards<Share, Currency>(
  &mut RoyaltyPool<Share, Currency>, &mut Stake<Share>
) -> Balance<Currency>
pending_rewards<Share, Currency>(&RoyaltyPool<Share, Currency>, &Stake<Share>) -> u64
balance(&RoyaltyPool<Share, Currency>) -> &Balance<Currency>
staked_shares(&RoyaltyPool<Share, Currency>) -> u64
cumulative_reward_per_share(&RoyaltyPool<Share, Currency>) -> u256
cumulative_deposits(&RoyaltyPool<Share, Currency>) -> u128
derived_address<Share, Currency>(parent_id: ID) -> address
assert_derived_from<Share, Currency>(&RoyaltyPool<Share, Currency>, parent_id: ID)
```

`new` returns a PTB-local pool, which `share` must consume. `claim_rewards`
returns a non-drop balance; convert/transfer/deposit it in the same PTB.
`sweep_and_deposit` uses the consensus `AccumulatorRoot` to redeem all positive
funds settled for the pool address (up to the framework's `u64::MAX` per call)
and aborts when no positive amount is settled. There is no amount-selecting
`royalty_pool::pool::redeem_and_deposit` API.
Events are:

```move
RoyaltyPoolCreatedEvent<Share, Currency> { pool_id, parent_id }
RoyaltyDepositedEvent<Share, Currency> { pool_id, value }
StakeRegisteredEvent<Share, Currency> { pool_id, stake_id, staked_amount }
StakeUnregisteredEvent<Share, Currency> { pool_id, stake_id, unstaked_amount }
RoyaltyClaimedEvent<Share, Currency> { pool_id, stake_id, reward_amount }
```

### `routed_stake::routed_stake`

```move
new<StakeShare, PoolShare>(
  parent: &mut UID, balance: Balance<StakeShare>, ctx: &mut TxContext
) -> RoutedStake<StakeShare, PoolShare>
share<StakeShare, PoolShare>(RoutedStake<StakeShare, PoolShare>)
register<StakeShare, PoolShare, Currency>(
  &mut RoutedStake<StakeShare, PoolShare>, &mut UID,
  &mut RoyaltyPool<StakeShare, Currency>
)
unregister<StakeShare, PoolShare, Currency>(
  &mut RoutedStake<StakeShare, PoolShare>, &mut UID,
  &mut RoyaltyPool<StakeShare, Currency>
)
unstake<StakeShare, PoolShare>(
  &mut RoutedStake<StakeShare, PoolShare>, &mut UID
) -> Balance<StakeShare>
restake<StakeShare, PoolShare>(
  &mut RoutedStake<StakeShare, PoolShare>, &mut UID,
  Balance<StakeShare>, ctx: &mut TxContext
)
sweep<StakeShare, PoolShare, Currency>(
  &mut RoutedStake<StakeShare, PoolShare>,
  &mut RoyaltyPool<StakeShare, Currency>,
  &mut RoyaltyPool<PoolShare, Currency>,
  parent_id: ID
)
has_stake(&RoutedStake<StakeShare, PoolShare>) -> bool
value(&RoutedStake<StakeShare, PoolShare>) -> u64
stake(&RoutedStake<StakeShare, PoolShare>) -> &Stake<StakeShare>
derived_address<StakeShare>(parent_id: ID) -> address
assert_derived_from<StakeShare, PoolShare>(&RoutedStake<StakeShare, PoolShare>, ID)
```

`new` returns a key-only, non-drop routed stake. Its only public by-value
consumer is `share`, so a direct client call must share it in the same PTB.
The `composition_routed_stake` Action also returns the routed stake unshared;
the caller must finish any setup and call `routed_stake::share` in that PTB.
`unstake` returns a non-drop balance. `sweep` is permissionless but can only
route rewards to the specified parent-derived pool. Events are
`RoutedStakeCreatedEvent { routed_stake_id, parent_id, staked_value }`,
`RoutedStakeSweptEvent { routed_stake_id, parent_id, value }`,
`RoutedStakeUnstakedEvent { routed_stake_id, parent_id, unstaked_value }`, and
`RoutedStakeRestakedEvent { routed_stake_id, parent_id, staked_value }`, with
the respective phantom type parameters from the source.

## Authority: actions, vault, and plugins

The boundary is deliberately three-layered:

1. An **Extension** adds data to a core object's dynamic-field model. The 14
   packages in this repository are data-only and contain no vault borrowing,
   funds movement, or automation policy.
2. An **Action** is a normal `public` Move API that takes the raw matching core
   admin cap. It captures the composable operation independently of whether
   that cap is address-owned, temporarily borrowed from a vault, or supplied
   by another custody system.
3. A **Plugin** is an installed, permissionless automation adapter. Its
   operation is private `entry`, returns `()`, borrows the cap with its witness,
   invokes exactly one Action with fixed destinations, then puts the exact cap
   back. Installation and revocation remain ordinary public admin calls.

Admin-controlled clients do not need a Plugin: in one PTB they call
`borrow_as_admin`, pass the raw cap to any Action, and call `put_back`. Party
wallet operations and routed-stake lifecycle operations intentionally remain
Actions only because their caller-selected outputs or governance timing are
not safe or appropriate as permissionless automation.

### Custody-agnostic Actions

Every Action below is a normal public Move API and takes the raw domain admin
cap. None imports `vault` or defines a plugin witness.

#### `party_wallet::party_wallet`

```move
receive<T: key + store>(
  &mut Party, &PartyAdminCap, Receiving<T>
) -> T
receive_balance<Currency>(
  &mut Party, &PartyAdminCap, vector<Receiving<Coin<Currency>>>
) -> Balance<Currency>
redeem_balance<Currency>(
  &mut Party, &PartyAdminCap, value: u64
) -> Balance<Currency>
inbox_address(&Party) -> address
```

Events are `ObjectReceivedEvent { party_id, object_id }`,
`CoinsReceivedEvent<Currency> { party_id, amount, coins }`, and
`FundsRedeemedEvent<Currency> { party_id, amount }`. Returned objects and
balances are deliberately caller-controlled PTB values, which is why this
Action has no permissionless Vault plugin.

#### `composition_royalty_pool::composition_royalty_pool`

```move
new_pool<CS, Currency>(
  &mut Composition<CS>, &CompositionAdminCap<CS>
) -> RoyaltyPool<CS, Currency>
receive_and_deposit<CS, Currency>(
  &mut Composition<CS>, &CompositionAdminCap<CS>,
  &mut RoyaltyPool<CS, Currency>, vector<Receiving<Coin<Currency>>>
)
redeem_and_deposit<CS, Currency>(
  &mut Composition<CS>, &CompositionAdminCap<CS>,
  &mut RoyaltyPool<CS, Currency>, value: u64
)
pool_address<CS, Currency>(&Composition<CS>) -> address
```

#### `recording_royalty_pool::recording_royalty_pool`

```move
new_pool<RS, CS, Currency>(
  &mut Recording<RS, CS>, &RecordingAdminCap<RS>
) -> RoyaltyPool<RS, Currency>
receive_and_deposit<RS, CS, Currency>(
  &mut Recording<RS, CS>, &RecordingAdminCap<RS>,
  &mut RoyaltyPool<RS, Currency>, vector<Receiving<Coin<Currency>>>
)
redeem_and_deposit<RS, CS, Currency>(
  &mut Recording<RS, CS>, &RecordingAdminCap<RS>,
  &mut RoyaltyPool<RS, Currency>, value: u64
)
pool_address<RS, CS, Currency>(&Recording<RS, CS>) -> address
```

Both `new_pool` functions return the canonical pool unshared. The caller must
complete setup and call `royalty_pool::pool::share` in the same PTB.

#### `composition_routed_stake::composition_routed_stake`

```move
create_stake<RS, CS>(
  &mut Composition<CS>, &CompositionAdminCap<CS>,
  &Recording<RS, CS>, value: u64, ctx: &mut TxContext
) -> RoutedStake<RS, CS>
register<RS, CS, Currency>(
  &mut Composition<CS>, &CompositionAdminCap<CS>, &Recording<RS, CS>,
  &mut RoutedStake<RS, CS>, &mut RoyaltyPool<RS, Currency>
)
unregister<RS, CS, Currency>(
  &mut Composition<CS>, &CompositionAdminCap<CS>, &Recording<RS, CS>,
  &mut RoutedStake<RS, CS>, &mut RoyaltyPool<RS, Currency>
)
unstake<RS, CS>(
  &mut Composition<CS>, &CompositionAdminCap<CS>,
  &mut RoutedStake<RS, CS>
) -> Balance<RS>
restake<RS, CS>(
  &mut Composition<CS>, &CompositionAdminCap<CS>,
  &mut RoutedStake<RS, CS>, Balance<RS>, ctx: &mut TxContext
)
stake_address<RS, CS>(&Composition<CS>) -> address
```

`create_stake` returns the canonical routed stake unshared. The caller may
register it, but must ultimately call `routed_stake::share` in the same PTB.
There is no routed-stake plugin; lifecycle timing and returned principal remain
administrator-controlled.

#### `release_revenue_distributor::release_revenue_distributor`

```move
redeem_and_distribute<Currency>(
  &mut Release, &ReleaseAdminCap, value: u64
)
redeem_all_and_distribute<Currency>(
  &mut Release, &ReleaseAdminCap, &AccumulatorRoot
)
receive_and_distribute<Currency>(
  &mut Release, &ReleaseAdminCap, vector<Receiving<Coin<Currency>>>
)
```

`redeem_all_and_distribute` reads the settled address-balance snapshot and is
an authenticated no-op when it is zero. Funds arriving after the snapshot and
per-track flooring remainder settle for a later call. The Action emits
`ReleaseTrackRevenueDistributedEvent<Currency>` per track and one
`ReleaseRevenueDistributedEvent<Currency>` whenever distribution executes;
the zero-settled full-redemption no-op emits nothing.

### `vault::vault`

```move
new<Cap: key + store>(
  &mut VaultRegistry, Cap, ctx: &mut TxContext
) -> (Vault<Cap>, VaultAdminCap<Cap>)
share<Cap: key + store>(Vault<Cap>)
withdraw_cap<Cap: key + store>(
  &mut Vault<Cap>, &VaultAdminCap<Cap>
) -> Cap
restore_cap<Cap: key + store>(
  &mut Vault<Cap>, &VaultAdminCap<Cap>, Cap, ctx: &mut TxContext
)
authorize_plugin<Cap: key + store, Witness: drop>(
  &mut Vault<Cap>, &VaultAdminCap<Cap>, Witness
)
revoke_plugin<Cap: key + store, Witness: drop>(&mut Vault<Cap>, &VaultAdminCap<Cap>)
borrow_as_plugin<Cap: key + store, Witness: drop>(&mut Vault<Cap>, Witness) -> (Cap, Borrow)
borrow_as_admin<Cap: key + store>(&mut Vault<Cap>, &VaultAdminCap<Cap>) -> (Cap, Borrow)
put_back<Cap: key + store>(&mut Vault<Cap>, Cap, Borrow)
derived_address<Cap: key + store>(&VaultRegistry, cap_id: ID) -> address
cap_id<Cap: key + store>(&Vault<Cap>) -> ID
is_active<Cap: key + store>(&Vault<Cap>) -> bool
authorized_plugins<Cap: key + store>(&Vault<Cap>) -> &Bag
is_plugin_authorized<Cap: key + store, Witness: drop>(&Vault<Cap>) -> bool
```

Package initialization shares one `VaultRegistry`; it emits no registry event,
so capture that object from the publish effects. `vault::new` derives the one
canonical vault from `(registry, Cap type, cap object ID)`. `Vault<Cap>` is a
permanent key-only shell: there is no production destroy function. It retains
the immutable `cap_id` and its `VaultAdminCap` while `withdraw_cap` temporarily
empties custody. Withdrawal requires every plugin to be revoked; `restore_cap`
accepts only the exact capability object originally assigned to the shell.

Both borrow functions return a `(Cap, Borrow)` hot-potato pair that must go
directly to `put_back` in the same PTB. Events are exactly:

```move
VaultCreatedEvent<Cap> { vault_id, cap_id }
PluginAuthorizedEvent<Cap, Witness> { vault_id }
PluginRevokedEvent<Cap, Witness> { vault_id }
VaultCapabilityWithdrawnEvent<Cap> { vault_id }
VaultCapabilityRestoredEvent<Cap> { vault_id }
```

There is deliberately no public Vault, VaultRegistry, or VaultAdminCap ID
getter. Clients already have object IDs from owned/shared object references and
publish effects. Core authorization is enforced inside `withdraw_cap`,
`restore_cap`, `authorize_plugin`, `revoke_plugin`, and `borrow_as_admin`;
downstream Actions receive the raw capability, whose core object performs its
normal binding checks. A `Borrow` proves custody continuity and exact return,
not authorization for arbitrary work performed while the raw cap is borrowed.

### Vault-plugin transaction endpoints

Each automated operation below is a **private `entry` function** returning
`()`. A plugin `Witness` is constructed package-internally. These endpoints may
be commands in a multi-command PTB, but cannot be Move-called by another
package and produce no result for a subsequent PTB command. `install`,
`uninstall`, and `is_installed` are ordinary `public` functions; installation
changes require the matching address-owned `VaultAdminCap`. Automated
operations do not take it, but require an installed plugin and the specified
shared objects.

#### `composition_royalty_pool_plugin::composition_royalty_pool_plugin`

```move
install<CS>(
  &mut Vault<CompositionAdminCap<CS>>,
  &VaultAdminCap<CompositionAdminCap<CS>>
)
uninstall<CS>(
  &mut Vault<CompositionAdminCap<CS>>,
  &VaultAdminCap<CompositionAdminCap<CS>>
)
receive_and_deposit<CS, Currency>(
  &mut Vault<CompositionAdminCap<CS>>,
  &mut Composition<CS>,
  &mut RoyaltyPool<CS, Currency>,
  vector<Receiving<Coin<Currency>>>
)
redeem_and_deposit<CS, Currency>(
  &mut Vault<CompositionAdminCap<CS>>,
  &mut Composition<CS>,
  &mut RoyaltyPool<CS, Currency>,
  value: u64
)

is_installed<CS>(&Vault<CompositionAdminCap<CS>>) -> bool
```

Pool creation is intentionally not automated. Use the raw-cap
`composition_royalty_pool` Action through `borrow_as_admin`.

#### `recording_royalty_pool_plugin::recording_royalty_pool_plugin`

```move
install<RS>(
  &mut Vault<RecordingAdminCap<RS>>,
  &VaultAdminCap<RecordingAdminCap<RS>>
)
uninstall<RS>(
  &mut Vault<RecordingAdminCap<RS>>,
  &VaultAdminCap<RecordingAdminCap<RS>>
)
receive_and_deposit<RS, CS, Currency>(
  &mut Vault<RecordingAdminCap<RS>>,
  &mut Recording<RS, CS>,
  &mut RoyaltyPool<RS, Currency>,
  vector<Receiving<Coin<Currency>>>
)
redeem_and_deposit<RS, CS, Currency>(
  &mut Vault<RecordingAdminCap<RS>>,
  &mut Recording<RS, CS>,
  &mut RoyaltyPool<RS, Currency>,
  value: u64
)

is_installed<RS>(&Vault<RecordingAdminCap<RS>>) -> bool
```

Pool creation is intentionally not automated. Use the raw-cap
`recording_royalty_pool` Action through `borrow_as_admin`.

#### `release_revenue_distributor_plugin::release_revenue_distributor_plugin`

```move
install(&mut Vault<ReleaseAdminCap>, &VaultAdminCap<ReleaseAdminCap>)
uninstall(&mut Vault<ReleaseAdminCap>, &VaultAdminCap<ReleaseAdminCap>)
redeem_all_and_distribute<Currency>(
  &mut Vault<ReleaseAdminCap>, &mut Release, &AccumulatorRoot
)
receive_and_distribute<Currency>(
  &mut Vault<ReleaseAdminCap>, &mut Release,
  vector<Receiving<Coin<Currency>>>
)

is_installed(&Vault<ReleaseAdminCap>) -> bool
```

The automated redemption endpoint deliberately has no caller-selected amount:
it can redeem only the full settled snapshot supplied by `AccumulatorRoot`.
The plugin itself adds no domain events; the called Action emits the Release
distribution events described above.

## Removed and superseded client surface

Remove these from clients, generated bindings, event subscriptions, tests, and
documentation:

| Old surface | Current contract |
| --- | --- |
| `composition::set_royalty_rate` | Removed. The rate is fixed by `composition::new`; rate policy is client-side. |
| `CompositionRoyaltySetEvent` and its parser/subscription | Removed. A composition has only `CompositionPublishedEvent`; index its immutable object data once. |
| `recording::new(..., max_royalty_rate_bps, ctx)` | Removed the slippage argument. The exact current signature has only composition, share currency, treasury cap, then implicit context. |
| Resolving composition lineage only from historical publish events | Superseded. Use `recording::composition_id` and `track::composition_id` (both are immutable source fields/accessors). |
| Standalone `release_registry::new_release` or arbitrary-parent `release::new` helper | Superseded by `miso::release::new(&mut ReleaseRegistry, ...)` and `miso::release::derive_target_release_id(&ReleaseRegistry, ...)`. |
| Authority/revenue calls under `protocol-extensions` | Superseded. This repository is data-only; use raw-cap `protocol-actions`/`party-actions`, and use the three `vault-plugins` only for installed automation. |
| Party wallet or Composition routed-stake vault plugin | Removed. These remain admin-controlled raw-cap Actions and compose through `borrow_as_admin` when the cap is vaulted. |
| Release plugin `redeem_and_distribute(..., value)` | Removed. Permissionless automation exposes only fixed `redeem_all_and_distribute(..., &AccumulatorRoot)`; amount selection remains on the admin-controlled raw-cap Action. |

## Address-injection handoff

Source is ready for the client update when bindings match this matrix and their
deployment configuration rejects missing IDs. It is **not** readiness to submit
a transaction. The immutable `admin-cli` publication task must:

1. Publish a fresh package in the dependency order above, immediately consume
   its `UpgradeCap` with `package::make_immutable`, and retain the actual package
   ID and init-created object IDs from transaction effects. Never upgrade a
   prior package generation.
2. Only after that transaction succeeds, replace the selected network block in
   that package's `Published.toml`. Existing blocks are deployment records and
   remain untouched until their replacement publish succeeds.
3. Update only the deployment-address configuration with those verified values.
4. Regenerate/check event type strings and dynamic-field key type strings from
   that configuration, then run the SDK/client tests again.
5. Every later source change requires another fresh immutable package identity
   and explicit client/data migration; repeat address injection rather than
   embedding fallback or guessed IDs.
