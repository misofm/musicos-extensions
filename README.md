# Miso Protocol Extensions

First-party data-model extensions for
[`misonetwork/protocol`](https://github.com/misonetwork/protocol) on Sui.

Miso keeps `Composition`, `Recording`, and `Release` focused on constitutive
protocol state. An extension adds optional typed data as a dynamic field on one
of those objects. Writes require the object's matching admin capability through
its cap-gated `uid_mut`; reads are permissionless.

Extensions do not custody capabilities, automate administrative authority, or
route economic value. Actions compose those workflows around a caller-supplied
raw capability, while optional platform adapters bridge Vault custody to an Action:

| Repository | Responsibility |
|------------|----------------|
| [`misonetwork/protocol`](https://github.com/misonetwork/protocol) | Core music objects and the canonical `ReleaseRegistry` namespace. |
| [`misonetwork/protocol-actions`](https://github.com/misonetwork/protocol-actions) | Custody-agnostic, return-oriented Composition, Recording, and Release workflows. |
| [`misonetwork/party-actions`](https://github.com/misonetwork/party-actions) | Custody-agnostic, return-oriented Party workflows. |
| [`misofm/vault`](https://github.com/misofm/vault) | Generic capability custody and temporary exact-return leases. |
| [`misofm/vault-plugins`](https://github.com/misofm/vault-plugins) | Thin installed adapters that borrow a custodied admin capability, call a matching Action, and return the capability. |

Each directory in this repository is an independently versioned and published
Move package. Applications should depend only on the extensions they use.

## Packages

| Package | Target | Purpose |
|---------|--------|---------|
| [`composition_credits`](./composition_credits) | Composition | Songwriting and publishing attribution keyed by Party ID. |
| [`recording_advisory`](./recording_advisory) | Recording | Explicit, not-explicit, or cleaned advisory classification. |
| [`recording_credits`](./recording_credits) | Recording | Performance and production credits with primary and featured artist designations. |
| [`recording_language`](./recording_language) | Recording | Ordered ISO 639-1 language metadata; an empty list explicitly denotes instrumental content. |
| [`release_cover_art`](./release_cover_art) | Release | Release-level cover art with optional per-track overrides. |
| [`release_credits`](./release_credits) | Release | Primary and featured top-line artist billing keyed by Party ID. |
| [`release_description`](./release_description) | Release | Bounded free-text editorial description. |
| [`release_genre`](./release_genre) | Release | Primary, secondary, and optional per-track genre metadata with no timing or economic policy. |
| [`release_kind`](./release_kind) | Release | Bounded free-text release classification such as Album, EP, or Mixtape. |

## Usage

Reference an extension by repository subdirectory and exact commit:

```toml
[dependencies]
release_genre = { git = "https://github.com/misonetwork/protocol-extensions.git", subdir = "release_genre", rev = "<40-character-commit>" }
```

Each package's `Move.toml` pins its own protocol and supporting dependencies.

Existing `Published.toml` files are retained as records of the currently
deployed, prior package generation. Some historical Mainnet records include an
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

Run commands from the extension package directory:

```sh
cd release_genre
sui move build
sui move test --coverage
```

The test suites include production-shaped `sui::test_scenario` flows for shared
protocol objects and focused invariant and authorization tests.

## License

[Apache-2.0](./LICENSE)
