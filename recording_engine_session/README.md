# `recording_engine_session`

The Miso Engine session for a `musicos::recording::Recording`: the canonical
Session V1 document plus every stem it plays, stored as one `EngineSession`
value under a dynamic field on the recording and written through its
cap-gated `uid_mut`.

The Session V1 document references each source by the SHA-256 digest of its
canonical PCM (engine `STEM_IDENTITY_V1`) and carries no locator; Walrus
serves blobs by blob ID. `EngineSession` therefore pairs the session blob ID
with one `Stem` per source — that digest and the blob ID holding its FLAC
delivery object — so a client reads one value and can resolve every source
the session names. Every reference is a bare blob ID: the extension asserts
only which blobs the administrator chose, not storage availability, document
validity, or that a stem decodes to its digest.

## What it stores

- Key: `ExtensionKey()` — a unit struct local to this package.
- Value: one `EngineSession { blob_id: u256, stems: vector<Stem> }`, each
  `Stem { digest: vector<u8>, blob_id: u256 }` carrying a 32-byte digest.
  Stems are sorted by digest and unique, so a session has exactly one
  canonical form; session and stems are replaced together because adding a
  source changes the document. There is no stem-count cap.

## API

Writes require the recording's `&RecordingAdminCap<RecordingShare>` and go
through `recording::uid_mut(cap)`, which matches the cap by type only. Views
are permissionless.

| Function | Description | Aborts |
|---|---|---|
| `new_stem(digest, blob_id)` | Constructs a stem reference | `EInvalidStemDigest` (2) unless the digest is 32 bytes |
| `new(blob_id, stems)` | Constructs a session; an empty stem list is valid | `EUnsortedStems` (3) unless stems are in strictly increasing digest order |
| `set_engine_session(rec, cap, session)` | Sets or replaces the session; setting the value already held neither writes nor emits | none |
| `clear_engine_session(rec, cap)` | Removes the session; silent when absent | none |
| `has_engine_session(rec)` | Whether a session is attached | none |
| `engine_session(rec)` | The attached `&EngineSession` | `ENoEngineSession` (1) when absent |
| `blob_id(&s)`, `stems(&s)`, `stem_digest(&stem)`, `stem_blob_id(&stem)` | Value accessors | none |

## Events

Both events are generic over `RecordingShare` only and carry what an
event-only indexer would otherwise have to look up.

| Event | Fields | BCS bytes |
|---|---|---|
| `RecordingEngineSessionSetEvent<RecordingShare>` | `recording_id: address`, `blob_id: u256` | 64 |
| `RecordingEngineSessionClearedEvent<RecordingShare>` | `recording_id: address` | 32 |

The stem list is unbounded and stays in storage: a set event carries the
session document's blob ID, and a set event whose blob ID is unchanged means
the stems changed, so an indexer re-reads them from the recording. Event size
does not depend on the stem count. An equal set and an absent clear emit
nothing, so every event is a real state transition.

## Errors

| Code | Constant | Condition |
|---|---|---|
| 1 | `ENoEngineSession` | `engine_session` with nothing attached |
| 2 | `EInvalidStemDigest` | `new_stem` with a digest that is not 32 bytes |
| 3 | `EUnsortedStems` | `new` with stems out of digest order or duplicated |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Recording<RecordingShare>` and
  `RecordingAdminCap<RecordingShare>`.

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
