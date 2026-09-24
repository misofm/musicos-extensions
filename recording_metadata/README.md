# `recording_metadata`

The canonical, platform-neutral home for a `musicos::recording::Recording`'s
basic descriptive metadata: **genres**, **languages**, **advisory** advisory
and **version**, held in one record under one dynamic field on the
recording's `UID`, written through core's cap-gated `uid_mut` and readable by
anyone. musicos core keeps only a recording's identity and what the
economics read; everything that describes the take lives here.

This package **supersedes** three standalone protocol extensions, with their
rules carried over:

| Attribute | Superseded package | What moved |
|---|---|---|
| genres | `recording_genre` | Ordered `vector<ID>` of `genre::Genre` ids, primary first, at most 6, proven by `&Genre` on write |
| languages | `recording_language` | Ordered `vector<LanguageCode>` (ISO 639-1), at most 10, no duplicates; an attached empty vector explicitly means instrumental |
| advisory | `recording_advisory` | `Advisory`: `Explicit`, `NotExplicit` or `Cleaned`; absence is a distinct fourth state |

and adds one attribute that had no home before:

| Attribute | What it stores |
|---|---|
| version | A bounded, non-empty UTF-8 `String` naming this take — "Live", "Radio Edit", "Acoustic" — at most 300 bytes |

A recording carries no name of its own in core, and neither does its
composition. A recording is a take of its composition, so its display title is
the composition's title (from `composition_metadata`) plus whatever names this
take; `version` is that remainder. The separator ("Song (Live)", "Song — Radio
Edit") is presentation and is not stored.

What changed from the superseded packages: one record replaces one field
per attribute; `unset_*` is `clear_*` (one verb for "remove" across every
attribute); `recording_language::set_instrumental` and `is_instrumental`,
and `recording_advisory::name`, are not carried, since each is derivable
from the others (`set_languages(vector[])`; `has_languages(r) &&
languages(r).is_empty()`; the event carries the advisory itself); error codes
are renumbered into one scheme; removing the last genre emits only
`RecordingGenreRemovedEvent`; event payloads are slimmed to musicos's
current policy; and every type takes the single `RecordingShare` parameter
of the pinned core. Each superseded package remains published at its own
identity; clients migrate explicitly, and data attached under the
superseded packages' keys is not read by this one.

## Storage

One dynamic field under the module's one key, holding one record whose
fields are the attributes:

```text
ExtensionKey() -> RecordingMetadata {
    genres: vector<ID>,                        // genre::Genre ids, primary first, at most 6
    languages: Option<vector<LanguageCode>>,   // at most 10, no duplicates; Some(empty) = instrumental
    advisory: Option<Advisory>,          // Explicit | NotExplicit | Cleaned
    version: Option<String>,                   // non-empty, at most 300 bytes, verbatim
}
```

The record is created by the first write of any attribute and removed by
the clear (or genre removal) that leaves every attribute unset, so "the field
is absent" and "no metadata is attached" are the same fact. Each attribute is
set and cleared independently: clearing the languages never touches the
advisory. The record has only `store` and is taken out by destructuring. The
genre list is empty, not absent, when no genre is assigned; `genres()`
returns it as such. Languages have three distinct states that never
collapse: absent (no claim), instrumental (`Some` and empty), and sung.
Absence of an advisory is never `NotExplicit`.

## Authorization

All writes take `&RecordingAdminCap<RecordingShare>` and go through
`recording::uid_mut(cap)`. Core binds the cap to its recording by type — one
share currency backs exactly one recording — and performs no runtime cap-id
check; a cap of another share type is a compile error. Writes work in every
lifecycle state, before and after publish. Reads are permissionless. The
package custodies no capability, routes no value and contains no Vault,
Action or Plugin logic.

**Guard order** (shared with `composition_metadata` and `release_metadata`):
validation that needs only the argument — emptiness, byte bounds, language
count and duplicates — runs before `uid_mut`; anything that reads stored
state — existence on clear, and genre duplicate, capacity and membership —
runs after it.

## API

`R` abbreviates `Recording<RecordingShare>` and `Cap` abbreviates
`RecordingAdminCap<RecordingShare>` throughout.

| Function | Behavior | Aborts |
|---|---|---|
| `add_genre(&mut R, &Cap, &Genre)` | Appends; the first genre added becomes the primary | `EDuplicateGenre` (13) if already assigned, then `EMaxGenres` (12) at 6 |
| `remove_genre(&mut R, &Cap, ID)` | Removes by id; the next entry becomes primary if the primary was removed | `EGenreNotPresent` (14) if not assigned, including when nothing is attached |
| `clear_genres(&mut R, &Cap)` | Removes the whole list; silent no-op when empty or absent | — |
| `genres(&R): vector<ID>` | Ids in order, primary first; empty when none | — |
| `set_languages(&mut R, &Cap, vector<LanguageCode>)` | Sets or replaces the ordered list; an empty vector asserts the recording is instrumental; silent no-op when the same list is already attached | `ETooManyLanguages` (22) above 10, then `EDuplicateLanguage` (23) |
| `clear_languages(&mut R, &Cap)` | Removes the record's language claim, instrumental included; silent no-op when absent | — |
| `has_languages(&R): bool` | Whether a language claim is attached | — |
| `languages(&R): vector<LanguageCode>` | The list in the order given; empty means instrumental | `ENoLanguages` (20) when absent |
| `explicit()`, `not_explicit()`, `cleaned()` | The three `Advisory` values | — |
| `set_advisory(&mut R, &Cap, Advisory)` | Sets or replaces; silent no-op when the same advisory is already attached | — |
| `clear_advisory(&mut R, &Cap)` | Removes; silent no-op when absent | — |
| `has_advisory(&R): bool` | Whether an advisory is attached | — |
| `advisory(&R): Advisory` | The advisory | `ENoAdvisory` (30) when absent |
| `is_explicit`, `is_not_explicit`, `is_cleaned` on `&Advisory` | Predicates | — |
| `set_version(&mut R, &Cap, String)` | Sets or replaces, stored exactly as given; silent no-op when the same version is already attached | `EEmptyVersion` (41) for `""`, then `EVersionTooLong` (42) above 300 bytes |
| `clear_version(&mut R, &Cap)` | Removes; silent no-op when absent | — |
| `has_version(&R): bool` | Whether a version is attached | — |
| `version(&R): &String` | The version | `ENoVersion` (40) when absent |

Error codes are numeric `u64` constants, one decade per attribute in field
order (genres 10s, languages 20s, advisory 30s, version 40s), with a fixed
digit per kind: `x0` nothing attached, `x1` empty input, `x2` bound
exceeded, `x3` duplicate, `x4` not present.

Emptiness of the genre list is `genres(r).is_empty()` and the primary is
`genres(r)[0]`. Reordering, including changing the primary, is `clear_genres`
followed by `add_genre` in the desired order within one programmable
transaction block. The write surface is add/remove/clear rather than a single
`set` because Move cannot pass a `vector<&Genre>`, and taking bare ids would
give up the proof that every stored id resolves to a real vocabulary entry.
`LanguageCode` is valid ISO 639-1 by construction, so only count and
duplicates are checked here. The `Advisory` variants are private to the
module, as Move requires, so the constructors and predicates are the whole
vocabulary a caller needs. The version bound is in UTF-8 bytes, not
characters, and no normalisation is applied: "Live", "live" and " Live " are
three values.

## Events

Every event is phantom-typed by `RecordingShare` alone, like `Recording`
itself, and is emitted after the dynamic-field write succeeds. Payloads follow
musicos core's rule: a field is carried only if an indexer reading events
alone would otherwise need an object lookup for it. That is the recording's
id and, on a set, the value now attached — nothing derivable from the
envelope (the sender), from constants (the bounds), from the event's type
argument (the share type), from other events (the recording's composition from
`RecordingPublishedEvent`; the genre's name from `genre::GenreCreatedEvent`;
the previous value from the previous event) or from a derived address (the
admin cap id under `RecordingAdminCapKey`).

A write that would leave the stored value unchanged is a no-op: it performs
no write and emits no event. Set events therefore fire only when the value
changes — setting the languages, advisory or version already attached is
silent, after argument validation and the cap check — and clear events fire
only when something was actually removed; an absent clear is silent. A no-op
never creates the record: with nothing attached there is nothing to equal, so
a first set always writes and emits. Views and constructors are silent.

| Event | Fields (BCS order) | Size |
|---|---|---|
| `RecordingGenreAddedEvent<RS>` | `recording_id: address`, `genre_id: address` | 64 |
| `RecordingGenreRemovedEvent<RS>` | `recording_id: address`, `genre_id: address` | 64 |
| `RecordingGenresClearedEvent<RS>` | `recording_id: address` | 32 |
| `RecordingLanguagesSetEvent<RS>` | `recording_id: address`, `languages: vector<LanguageCode>` (each its two-byte code) | `33 + 3n`, at most 63 |
| `RecordingLanguagesClearedEvent<RS>` | `recording_id: address` | 32 |
| `RecordingAdvisorySetEvent<RS>` | `recording_id: address`, `advisory: Advisory` (variant index: `Explicit = 0`, `NotExplicit = 1`, `Cleaned = 2`) | 33 |
| `RecordingAdvisoryClearedEvent<RS>` | `recording_id: address` | 32 |
| `RecordingVersionSetEvent<RS>` | `recording_id: address`, `version: String` | `32 + ULEB128(n) + n`, at most 334 |
| `RecordingVersionClearedEvent<RS>` | `recording_id: address` | 32 |

Genre events are replayable transitions: an added genre lands at the end of
the indexer's list (so its index, and whether it became primary, follow from
the list); a removed genre leaves survivors in order; and removing the last
genre is one `RecordingGenreRemovedEvent`, not a Removed-then-Cleared pair.
`RecordingGenresClearedEvent` is emitted only by `clear_genres` on a non-empty
list.

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `676dbd801583761b7e5ab53b4476e8606a12a8d7` — single-parameter
  `Recording<RecordingShare>`, `RecordingAdminCap<RecordingShare>`, `uid` and
  `uid_mut`.
- [`genre`](https://github.com/misofm/genre) at
  `268d4bc45eecdaf7b75dc443e4974b9469912513` — the canonical shared genre
  vocabulary.
- [`language_code`](https://github.com/unconfirmedlabs/language_code) at
  `61542357f3d2ff989d120185046def7cf6c8bdcb` — ISO 639-1 codes valid by
  construction.

All three are exact Git pins; this manifest has no local-path dependencies.

## Publishing

Unpublished. This package is intended for a fresh, immutable package
identity under the repository's release policy and is never upgraded in
place. Clients migrate explicitly from the superseded packages by selecting
this package id and its key type; there is no in-place upgrade path from
`recording_genre`, `recording_language` or `recording_advisory`, and data
attached under their keys is not read by this package.

## Build and test

Run from this directory with Sui 1.79.0:

```sh
sui move build --lint --warnings-are-errors
sui move build --lint --warnings-are-errors --build-env mainnet
sui move test --coverage --lint --warnings-are-errors
sui move coverage summary
sui move test --build-env mainnet --lint --warnings-are-errors
```

The suite has a unit and an `*_e2e_tests.move` scenario file per attribute,
`metadata_tests.move` for the record's lifecycle, and
`metadata_e2e_tests.move`, which drives all four attributes on one published,
shared recording to show they are set and cleared independently.
