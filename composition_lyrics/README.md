# composition_lyrics

`composition_lyrics` stores language-specific song lyrics as compressed bytes
on a `musicos::composition::Composition<CompositionShare>`, one entry per ISO
639-1 language code.

## Storage and encoding

Each entry is a dynamic field on the composition's `UID`:

```text
ExtensionKey(LanguageCode) -> vector<u8>
```

`LanguageCode` is the validated ISO 639-1 type from `language_code`. The
module-owned wrapper supplies the namespace and the language selects one
entry. Each language is added, replaced, or removed independently; there is
no preferred-language ordering or on-chain language index. Regional and
script variants are not represented by this key. Timing belongs to a
recording rather than this composition text.

The payload convention is **UTF-8 lyrics compressed into one standard,
self-contained Zstandard frame without an external dictionary**. Compression
level is a client choice. Clients preserve whitespace, line breaks,
punctuation, and text exactly.

Move treats the payload as opaque bytes. It does not check zstd headers,
decompress, validate UTF-8, judge lyrics, or verify their language. Empty and
malformed byte vectors can be stored. Clients must bound decoder memory and
output, handle decoding failures, and interpret the resulting text.

The maximum is **32,768 stored bytes per language**: a compressed storage
bound, not a limit on decoded text. Absence means no entry has been supplied;
an attached empty payload is distinct and does not imply an instrumental
composition.

## API

All writes require the composition's `CompositionAdminCap<CompositionShare>`
and go through the cap-gated `composition::uid_mut`; views are permissionless.

| Function | Description | Aborts |
|---|---|---|
| `set_lyrics(composition, cap, language, bytes)` | Adds or replaces one language's entry, bytes preserved exactly. Setting the bytes already stored neither writes nor emits. | `ELyricsTooLong` (2) past 32,768 bytes, before cap authorization |
| `clear_lyrics(composition, cap, language)` | Removes one language's entry; an absent entry is a silent no-op | — |
| `has_lyrics(composition, language): bool` | Whether an entry exists for this language | — |
| `lyrics(composition, language): &vector<u8>` | Borrows the stored bytes | `ENoLyrics` (1) when absent |
| `max_lyrics_length(): u64` | The compressed-byte limit (32,768) | — |

The core matches `CompositionShare` types: a cap for another share type is
rejected at compile time (`tests/check_cap_types.py`), and the core compares
no cap ids at runtime.

## Events

Both events carry `<phantom CompositionShare>` and only what an event-only
indexer would otherwise have to look up: the composition and the language
key. The compressed body stays in the dynamic field.

| Event | Fields | BCS size |
|---|---|---|
| `CompositionLyricsSetEvent<CompositionShare>` | `composition_id: address`, `language: String` | 35 |
| `CompositionLyricsClearedEvent<CompositionShare>` | `composition_id: address`, `language: String` | 35 |

A set event is emitted only when the stored bytes actually change; a cleared
event only when an entry was actually removed. Views emit nothing. Replaying
set and cleared events per `(composition_id, language)` yields the set of
languages currently attached.

## Errors

| Code | Constant | Location | Condition |
|---|---|---|---|
| 1 | `ENoLyrics` | `composition_lyrics::composition_lyrics` | `lyrics` with no entry for the language |
| 2 | `ELyricsTooLong` | `composition_lyrics::composition_lyrics` | `set_lyrics` with more than 32,768 bytes |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Composition`,
  `CompositionAdminCap`, and cap-gated `uid_mut`.
- [`language_code`](https://github.com/unconfirmedlabs/language_code) at
  `61542357f3d2ff989d120185046def7cf6c8bdcb` — the validated ISO 639-1 key.

## Publishing

`Published.toml` records the previously deployed generation. This generation
is published as a fresh immutable package identity and never upgraded in
place; clients migrate explicitly.

## Build and test

Run from this directory:

```sh
sui move build
sui move build --build-env mainnet
sui move test
sui move test --build-env mainnet
python3 tests/check_cap_types.py
```
