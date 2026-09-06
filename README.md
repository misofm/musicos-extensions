# Miso.fm Protocol Extensions

Platform-aware data-model extensions for
[`misonetwork/protocol`](https://github.com/misonetwork/protocol) on Sui.

This repository contains optional extensions shaped by Miso.fm product,
storage, delivery, and distribution conventions. Neutral first-party metadata
extensions live in
[`misonetwork/protocol-extensions`](https://github.com/misonetwork/protocol-extensions).

Each directory is an independently versioned and published Move package.
Applications should depend only on the extensions they use.

## Packages

| Package | Target | Purpose |
|---------|--------|---------|
| [`recording_master_reference`](./recording_master_reference) | Recording | Transitional Walrus reference to a recording's master-audio blob. |
| [`recording_streaming_transcode`](./recording_streaming_transcode) | Recording | Walrus Quilt reference to a recording's streaming transcode package. |
| [`release_dsp_link`](./release_dsp_link) | Release | Typed release and per-track identifiers for supported streaming services. |

## Usage

Reference an extension by repository subdirectory and exact commit:

```toml
[dependencies]
recording_master_reference = { git = "https://github.com/misofm/protocol-extensions.git", subdir = "recording_master_reference", rev = "<40-character-commit>" }
```

Existing `Published.toml` files preserve the deployment records created before
these packages moved from `misonetwork/protocol-extensions`.

## Development

Run build and test commands from an individual package directory:

```sh
cd recording_master_reference
sui move build
sui move test --coverage
```

## License

[Apache-2.0](./LICENSE)
