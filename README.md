# MusicOS Extensions

Data-model extensions for
[`misofm/musicos`](https://github.com/misofm/musicos) on Sui.

Miso keeps `Composition`, `Recording`, and `Release` focused on constitutive
protocol state. An extension adds optional typed data as a dynamic field on one
of those objects. Writes require the object's matching admin capability through
its cap-gated `uid_mut`; reads are permissionless.

Extensions do not custody capabilities, automate administrative authority, or
route economic value. Actions compose those workflows around a caller-supplied
raw capability, while optional platform adapters bridge Vault custody to an Action:

| Repository | Responsibility |
|------------|----------------|
| [`misofm/musicos`](https://github.com/misofm/musicos) | Core music objects and the canonical `ReleaseRegistry` namespace. |
| [`misofm/musicos-actions`](https://github.com/misofm/musicos-actions) | Custody-agnostic, return-oriented Composition, Recording, and Release workflows. |
| [`misofm/partyos-actions`](https://github.com/misofm/partyos-actions) | Custody-agnostic, return-oriented Party workflows. |
| [`misofm/vault`](https://github.com/misofm/vault) | Generic capability custody and temporary exact-return leases. |
| [`misofm/vault-plugins`](https://github.com/misofm/vault-plugins) | Thin installed adapters that borrow a custodied admin capability, call a matching Action, and return the capability. |

Each directory in this repository is an independently versioned and published
Move package. Applications should depend only on the extensions they use.

This repository consolidates two families of extension:

- **Protocol extensions** are neutral, first-party metadata extensions with no
  platform-specific assumptions. They originated in
  `misonetwork/protocol-extensions`, which no longer exists.
- **Platform extensions** are shaped by Miso.fm product, storage, delivery, and
  distribution conventions.

## Packages

### Protocol extensions

First-party, platform-neutral metadata extensions.

| Package | Target | Purpose |
|---------|--------|---------|
| [`composition_credits`](./composition_credits) | Composition | Songwriting and publishing attribution keyed by Party ID. |
| [`composition_lyrics`](./composition_lyrics) | Composition | Zstd-compressed lyrics keyed by ISO 639-1 language code. |
| [`composition_metadata`](./composition_metadata) | Composition | Canonical descriptive metadata: the composition's title. |
| [`recording_credits`](./recording_credits) | Recording | Performance and production credits with primary and featured artist designations. |
| [`recording_metadata`](./recording_metadata) | Recording | Canonical descriptive metadata: ordered genres (primary first), ISO 639-1 languages (an empty list denotes instrumental), explicit/not-explicit/cleaned advisory, and version name (e.g. Live, Radio Edit). |
| [`release_cover_art`](./release_cover_art) | Release | Release-level cover art with optional per-track overrides. |
| [`release_credits`](./release_credits) | Release | Primary and featured top-line artist billing keyed by Party ID. |
| [`release_metadata`](./release_metadata) | Release | Canonical descriptive metadata: title, ordered genres (primary first), kind (e.g. Album, EP, Mixtape), and editorial description. |

Each `*_metadata` package stores one metadata record per object under a single
`ExtensionKey()`. They supersede the former single-attribute packages
`recording_genre`, `recording_language`, `recording_advisory`,
`release_genre`, `release_kind`, and `release_description`, whose deployment
records remain in this repository's history.

### Platform extensions

Platform-aware extensions shaped by Miso.fm product, storage, delivery, and
distribution conventions.

| Package | Target | Purpose |
|---------|--------|---------|
| [`recording_engine_session`](./recording_engine_session) | Recording | Bare Walrus blob IDs for a recording's Miso Engine session document and each stem it plays, paired with the stem's canonical PCM digest. |
| [`recording_master`](./recording_master) | Recording | Self-attested master Audio, including technical metadata and a bare Walrus blob ID. |
| [`recording_streaming_transcode`](./recording_streaming_transcode) | Recording | Walrus Quilt reference to a recording's streaming transcode package. |
| [`release_dsp_link`](./release_dsp_link) | Release | Typed release and per-track identifiers for supported streaming services. |

## Usage

Reference an extension by repository subdirectory and exact commit:

```toml
[dependencies]
release_metadata = { git = "https://github.com/misofm/musicos-extensions.git", subdir = "release_metadata", rev = "<40-character-commit>" }
```

Each package's `Move.toml` pins its own protocol and supporting dependencies.

Existing `Published.toml` files are retained as records of the currently
deployed, prior package generation, including the protocol extension packages'
deployment records from before they moved from
`misonetwork/protocol-extensions`. Some historical Mainnet records include an
`upgrade-capability`; that is provenance, not authorization to upgrade. Every
package in this repository is released by publishing a fresh package identity
and immediately making it immutable. After a successful publication, the admin
CLI replaces only that network's `Published.toml` block with the new immutable
generation. Clients migrate explicitly to the new package identity; these
packages are never upgraded in place.

When an admin capability is held in a Vault, applications should use the
matching custody-agnostic Action. A thin Vault plugin may borrow the capability,
call that Action, and return the capability within one programmable transaction
block.

## Development

Run build and test commands from an individual package directory:

```sh
cd release_metadata
sui move build
sui move test --coverage
```

The test suites include production-shaped `sui::test_scenario` flows for shared
protocol objects and focused invariant and authorization tests.

## License

[Apache-2.0](./LICENSE)

## Event payload policy

See [EVENT_PAYLOADS.md](EVENT_PAYLOADS.md) for the complete event inventory,
content omission policy, source-derived BCS bounds, and consumer migration notes.
