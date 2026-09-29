# `recording_master`

The self-attested master for a `musicos::recording::Recording`: one
`audio::audio::Audio` value stored as a dynamic field on the recording and
written through its cap-gated `uid_mut`. The metadata is structurally
validated by `audio::new` and not externally verified: the extension asserts
which blob the administrator chose and what they say is in it, not that the
blob is stored, decodes, or matches its PCM digest. Nautilus-attested audio
belongs in a separate package.

## What it stores

- Key: `ExtensionKey()` — a unit struct local to this package.
- Value: one `Audio` under that key: format (a lowercase short name of at
  most 16 bytes), channels, bit depth, sample rate, sample count, 32-byte
  unkeyed BLAKE3 PCM digest, and a bare `u256` Walrus blob ID. `Audio` has
  `copy`, so copying it duplicates a reference, not the audio bytes.

## API

Writes require the recording's `&RecordingAdminCap` and go
through `recording::uid_mut(cap)`, which checks that the cap belongs to the recording object. Views
are permissionless.

| Function | Description | Aborts |
|---|---|---|
| `set_master(rec, cap, audio)` | Sets or replaces the master; setting the value already held neither writes nor emits | none |
| `clear_master(rec, cap)` | Removes the master; silent when absent | none |
| `has_master(rec)` | Whether a master is attached | none |
| `master(rec)` | The attached `&Audio` | `ENoMaster` (1) when absent |

## Events

Both events carry what an
event-only indexer would otherwise have to look up.

| Event | Fields | BCS bytes |
|---|---|---|
| `RecordingMasterSetEvent` | `recording_id: ID`, `master: Audio` | 112 + format length; 116 for `flac`, 128 maximum |
| `RecordingMasterClearedEvent` | `recording_id: ID` | 32 |

`Audio` serializes as `format` (one length byte plus the name), `channels: u8`,
`bit_depth: u8`, `sample_rate_hz: u32`, `samples: u64`, `pcm_digest` (one
length byte plus 32), and `blob_id: u256`: 80 bytes plus the format name. It
is bounded technical metadata plus a blob reference, so it is the value the
set event carries. An equal set and an absent clear emit nothing, so every
event is a real state transition.

## Errors

| Code | Constant | Condition |
|---|---|---|
| 1 | `ENoMaster` | `master` with nothing attached |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `0b3eb07c9cb1af29c877b66cddfdcc9ef32fc721` — concrete `Recording` and object-bound `RecordingAdminCap`.
- [`audio`](https://github.com/misofm/audio) at
  `f8dec25997691a9604f568fda6c4515c98299e70` — `Audio` and its validating
  constructor `audio::new`.

## Publishing

Every change is published as a fresh, immutable package identity; nothing is
upgraded in place. `Published.toml` records the prior generation, including
the `recording_master_reference` predecessor whose blob-only field does not
migrate automatically.

## Build and test

```sh
sui move build --lint --warnings-are-errors
sui move build --lint --warnings-are-errors --build-env mainnet
sui move test --coverage --lint --warnings-are-errors
sui move coverage summary
sui move test --build-env mainnet
```
