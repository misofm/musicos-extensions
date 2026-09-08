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
| [`recording_advisory`](./recording_advisory) | Recording | Explicit, not-explicit, or cleaned advisory classification. |
| [`recording_credits`](./recording_credits) | Recording | Performance and production credits with primary and featured artist designations. |
| [`recording_genre`](./recording_genre) | Recording | Ordered genre classification of the master, primary first. |
| [`recording_language`](./recording_language) | Recording | Ordered ISO 639-1 language metadata; an empty list explicitly denotes instrumental content. |
| [`release_cover_art`](./release_cover_art) | Release | Release-level cover art with optional per-track overrides. |
| [`release_credits`](./release_credits) | Release | Primary and featured top-line artist billing keyed by Party ID. |
| [`release_description`](./release_description) | Release | Bounded free-text editorial description. |
| [`release_genre`](./release_genre) | Release | Ordered release-level genre classification, primary first, with no timing or economic policy. |
| [`release_kind`](./release_kind) | Release | Bounded free-text release classification such as Album, EP, or Mixtape. |

### Platform extensions

Platform-aware extensions shaped by Miso.fm product, storage, delivery, and
distribution conventions.

| Package | Target | Purpose |
|---------|--------|---------|
| [`recording_engine_session`](./recording_engine_session) | Recording | Unencrypted Walrus references to a recording's Miso Engine session document and each stem it plays, paired with the stem's canonical PCM digest. |
| [`recording_master_reference`](./recording_master_reference) | Recording | Transitional Walrus reference to a recording's master-audio blob. |
| [`recording_streaming_transcode`](./recording_streaming_transcode) | Recording | Walrus Quilt reference to a recording's streaming transcode package. |
| [`release_dsp_link`](./release_dsp_link) | Release | Typed release and per-track identifiers for supported streaming services. |

## Usage

Reference an extension by repository subdirectory and exact commit:

```toml
[dependencies]
release_genre = { git = "https://github.com/misofm/musicos-extensions.git", subdir = "release_genre", rev = "<40-character-commit>" }
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
cd release_genre
sui move build
sui move test --coverage
```

The test suites include production-shaped `sui::test_scenario` flows for shared
protocol objects and focused invariant and authorization tests.

## License

[Apache-2.0](./LICENSE)
