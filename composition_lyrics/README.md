# composition_lyrics

Language-specific song lyrics stored on Sui as compressed bytes attached to a
`musicos::composition::Composition<CompositionShare>`.

## Storage and encoding

Each entry is a dynamic field:

```text
ExtensionKey(LanguageCode) -> vector<u8>
```

`LanguageCode` is the same validated ISO 639-1 type used by `recording_language`.
The module-owned wrapper supplies the namespace and the language selects one
entry. Each language can be added, replaced, or removed independently. There
is one version per language, with no preferred-language ordering or onchain
language index. Clients can discover entries through dynamic-field queries or
project the events. Regional and script variants are not represented by this
ISO 639-1 key. Timing belongs to a recording rather than this composition text.

The payload convention is **UTF-8 lyrics compressed into one standard,
self-contained Zstandard frame without an external dictionary**. Compression
level is a client choice; level 9 is a starting default, not part of the schema.
Clients preserve whitespace, line breaks, punctuation, and text exactly.

Move treats the payload as opaque bytes. It does not check zstd headers,
decompress, validate UTF-8, judge lyrics, or verify their language. Empty and
malformed byte vectors can be stored. Clients must bound decoder memory and
output, handle decoding failures, and interpret the resulting text.

The maximum is **32,768 stored bytes per language**. This is a compressed
storage bound, not a limit on decoded text. No codec flag, uncompressed size,
external blob reference, or dictionary is stored. Absence means no entry has
been supplied; an attached empty payload is distinct and does not imply an
instrumental composition.

## API

| Function | Behavior |
|---|---|
| `set_lyrics(composition, cap, language, bytes)` | Add or replace one entry; an event is emitted only when the complete byte payload changes. |
| `clear_lyrics(composition, cap, language)` | Remove one entry; authorized absent clears are silent no-ops. |
| `has_lyrics(composition, language)` | Test for presence. |
| `lyrics(composition, language)` | Borrow stored bytes; abort if absent. |
| `max_lyrics_length()` | Return the compressed-byte limit. |

Writes use the core's cap-gated `uid_mut` in every lifecycle state, including
after publication. The pinned core matches `CompositionShare` types; it does
not compare cap IDs at runtime. Production construction consumes the share
TreasuryCap, and the extension inherits that core uniqueness/trust model.
There is no additional capability custody or authorization policy here.
Reads are permissionless.

## Events

Set carries composition/admin-cap IDs, the two-byte ISO language key, and prior presence (68 BCS bytes). Clear carries the same IDs and language key (67 bytes). Compressed lyrics stay in the dynamic field. Empty lyrics remain distinct from absence; equal replacement and absent clear remain silent.

See [the repository payload inventory](../EVENT_PAYLOADS.md) for byte bounds and retained context.

## Development

```sh
sui move build --warnings-are-errors --lint
sui move test --coverage --warnings-are-errors --lint
python3 tests/check_cap_types.py
sui move coverage summary
```

Dependencies are pinned to the same exact revisions as `recording_language`.
This is an independent package intended for fresh immutable publication under
the repository's release policy. No publication has been performed.
