# `recording_streaming_transcode`

The streaming transcode package for a `musicos::recording::Recording`: one
`StreamingTranscode` wrapping an `ori::data::WalrusQuilt`, stored as a
dynamic field on the recording and written through its cap-gated `uid_mut`.
Clients combine the content-addressed Quilt ID with the package's
conventional item identifiers to locate the master HLS playlist, rendition
playlists, initialization maps, and media segments.

The extension asserts only which Quilt the administrator chose, not storage
availability, media conformance, or successful playback. Those checks belong
in the publication workflow before attachment.

## What it stores

- Key: `ExtensionKey()` — a unit struct local to this package.
- Value: one `StreamingTranscode { quilt: WalrusQuilt }`. The wrapper gives
  streaming transcodes their own domain type; standalone blobs and single
  Quilt patches cannot reach the API. The package does not hash, inspect, or
  validate the Quilt contents.

## API

Writes require the recording's `&RecordingAdminCap<RecordingShare>` and go
through `recording::uid_mut(cap)`, which matches the cap by type only. Views
are permissionless.

| Function | Description | Aborts |
|---|---|---|
| `new(quilt)` | Constructs the wrapper | none |
| `quilt(&t)` | The wrapped `&WalrusQuilt` | none |
| `set_streaming_transcode(rec, cap, transcode)` | Sets or replaces the transcode; setting the value already held neither writes nor emits | none |
| `clear_streaming_transcode(rec, cap)` | Removes the transcode; silent when absent | none |
| `has_streaming_transcode(rec)` | Whether a transcode is attached | none |
| `streaming_transcode(rec)` | The attached `&StreamingTranscode` | `ENoStreamingTranscode` (1) when absent |

## Events

Both events are generic over `RecordingShare` only and carry what an
event-only indexer would otherwise have to look up.

| Event | Fields | BCS bytes |
|---|---|---|
| `RecordingStreamingTranscodeSetEvent<RecordingShare>` | `recording_id: ID`, `quilt_id: u256` | 64 |
| `RecordingStreamingTranscodeClearedEvent<RecordingShare>` | `recording_id: ID` | 32 |

The Quilt ID is the stored value, serialized as 32 little-endian bytes after
the recording id. An equal set and an absent clear emit nothing, so every event is
a real state transition.

## Errors

| Code | Constant | Condition |
|---|---|---|
| 1 | `ENoStreamingTranscode` | `streaming_transcode` with nothing attached |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Recording<RecordingShare>` and
  `RecordingAdminCap<RecordingShare>`.
- [`ori`](https://github.com/unconfirmedlabs/ori) (`move` subdirectory) at
  `367ed5fe92a8b62da02c1116537cf08d111e0789` — `WalrusQuilt` and its Quilt ID.

## Publishing

Every change is published as a fresh, immutable package identity; nothing is
upgraded in place. `Published.toml` records the prior generation.

## Build and test

```sh
sui move build --lint --warnings-are-errors
sui move build --lint --warnings-are-errors --build-env mainnet
sui move test --coverage --lint --warnings-are-errors
sui move coverage summary
sui move test --build-env mainnet
```
