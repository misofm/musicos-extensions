# `release_metadata`

The canonical, platform-neutral home for a musicos `Release`'s basic
descriptive metadata: its **title**, **genre** classification, **kind**
(Album, EP, Mixtape, ...) and editorial **description**, held in one record
under one dynamic field on the release's `UID`, written through the
release's cap-gated `uid_mut` and readable by anyone.

Core stores what a release *is* — identity and everything the economics
read — and embeds nothing outside the release digest. Everything that
*describes* a release is presentation: it has more than one correct
rendering, the economics never read it, and no track signer consented to it.
It lives here, is chosen by the cap holder before or after publish, and stays
admin-mutable for the release's whole life.

## Supersedes

This package consolidates three earlier single-attribute packages and adds
the title, which core no longer carries (musicos
`8c3fd65f733d640c2b72c3a63b0a14f3953f396e` removed `Release.title`):

| Attribute | Formerly |
|---|---|
| title | `musicos::release` (embedded `title` field, 300-byte bound) |
| genres | [`release_genre`](../release_genre) |
| kind | [`release_kind`](../release_kind) |
| description | [`release_description`](../release_description) |

The absorbed packages' validation rules, bounds, vocabulary proof and
ordering semantics are carried over. What changed: one record replaces one
field per attribute; `release_kind::unset_kind` is `clear_kind` (one verb
for "remove" across every attribute); error codes are renumbered into one
scheme (below); `remove_genre` authorizes before it looks for the list;
removing the last genre emits only `ReleaseGenreRemovedEvent`, with no
cascaded `ReleaseGenresClearedEvent`; and event payloads are slimmed to
musicos's current policy. Each absorbed package remains published at its own
identity; clients migrate explicitly, and data attached under the absorbed
packages' keys is not read by this one.

## Storage

One dynamic field under the module's one key, holding one record whose
fields are the attributes:

```text
ExtensionKey() -> ReleaseMetadata {
    title: Option<String>,        // non-empty, at most 300 bytes, verbatim
    genres: vector<ID>,           // genre::Genre ids, primary first, at most 6
    kind: Option<String>,         // non-empty, at most 32 bytes, verbatim
    description: Option<String>,  // non-empty, at most 8192 bytes, verbatim
}
```

The record is created by the first write of any attribute and removed by
the clear (or genre removal) that leaves every attribute unset, so "the field
is absent" and "no metadata is attached" are the same fact. Each attribute is
set and cleared independently: clearing the kind never touches the title.
The record has only `store` and is taken out by destructuring. The genre
list is empty, not absent, when no genre is assigned; `genres()` returns it
as such.

Bounds are on bytes, not characters. Strings are stored exactly as given:
case, whitespace, line breaks, NUL and multi-byte UTF-8 are not normalised.
Attaching nothing and attaching a value are distinct states — an empty string
is rejected rather than stored, and a value view aborts when nothing is
attached.

## API

All writes take `&mut Release` and `&ReleaseAdminCap` and go through
`musicos::release::uid_mut`, which authenticates the cap against the release
(`EUnauthorized`, code 0, at `musicos::release`) and works in any lifecycle
state. Views take `&Release` and are permissionless.

**Guard order** (shared with `composition_metadata` and
`recording_metadata`): validation that needs only the argument — emptiness
and byte bounds — runs before `uid_mut`, so an invalid value reports this
module's code even with a foreign cap. Anything that reads stored state —
existence on clear, and genre duplicate, capacity and membership — runs after
`uid_mut`, so a foreign cap is rejected by core first. A write that would
leave the stored value unchanged — an equal set, or a clear of nothing — is a
no-op after the cap check: no write, no event.

| Function | Description | Aborts |
|---|---|---|
| `set_title(release, cap, String)` | Sets or replaces the title; silent no-op when the same title is already attached | `EEmptyTitle` (11), `ETitleTooLong` (12); then wrong cap |
| `clear_title(release, cap)` | Removes the title; authorized no-op when absent | wrong cap |
| `has_title(release): bool` | Whether a title is attached | — |
| `title(release): &String` | The title | `ENoTitle` (10) when absent |
| `add_genre(release, cap, &Genre)` | Appends a genre; the first ever added becomes the primary | wrong cap; then `EDuplicateGenre` (23), `EMaxGenres` (22) at 6 |
| `remove_genre(release, cap, ID)` | Removes a genre by id; a removed primary promotes the next entry | wrong cap; then `EGenreNotPresent` (24), including when nothing is attached |
| `clear_genres(release, cap)` | Removes the whole list; authorized no-op when empty or absent | wrong cap |
| `genres(release): vector<ID>` | The ids in order, primary first; empty when none | — |
| `set_kind(release, cap, String)` | Sets or replaces the kind; silent no-op when the same kind is already attached | `EEmptyKind` (31), `EKindTooLong` (32); then wrong cap |
| `clear_kind(release, cap)` | Removes the kind; authorized no-op when absent | wrong cap |
| `has_kind(release): bool` | Whether a kind is attached | — |
| `kind(release): &String` | The kind | `ENoKind` (30) when absent |
| `set_description(release, cap, String)` | Sets or replaces the description; silent no-op when the same description is already attached | `EEmptyDescription` (41), `EDescriptionTooLong` (42); then wrong cap |
| `clear_description(release, cap)` | Removes the description; authorized no-op when absent | wrong cap |
| `has_description(release): bool` | Whether a description is attached | — |
| `description(release): &String` | The description | `ENoDescription` (40) when absent |

Error codes are numeric `u64` constants, one decade per attribute in field
order (title 10s, genres 20s, kind 30s, description 40s), with a fixed digit
per kind: `x0` nothing attached, `x1` empty input, `x2` bound exceeded, `x3`
duplicate, `x4` not present.

There is no set-primary or reorder function: `clear_genres` followed by
`add_genre` in the desired order, in one programmable transaction block, is
the atomic reorder. Emptiness is `genres(release).is_empty()` and the primary
is `genres(release)[0]` — neither is offered on-chain, since this package is
never upgraded and every public function is permanent surface. `add_genre`
takes a real `&Genre`, so only an id the shared vocabulary minted can enter
the list; Move cannot pass a `vector<&Genre>`, which is why the write surface
is add/remove/clear rather than a single `set`.

## Events

Events are monomorphic and are emitted only after their dynamic-field
mutation succeeds. Payloads follow musicos's current policy: a field is
carried only if an indexer reading events alone would otherwise need an
object lookup for it. That is the release's identity plus, on a write, the
value written. Everything else is derivable — the admin cap id is the derived
address of the release id under `ReleaseAdminCapKey`; the sender is in the
transaction envelope; prior values, existence flags, counts, indices and
"changed" flags follow from the indexer's own history of the same stream; a
genre's name resolves from the frozen `Genre` object or the vocabulary's own
`GenreCreatedEvent`.

| Event | Fields (BCS order) | Size |
|---|---|---|
| `ReleaseTitleSetEvent` | `release_id: address`, `title: String` | 32 + ULEB128(n) + n; at most 334 |
| `ReleaseTitleClearedEvent` | `release_id: address` | 32 |
| `ReleaseGenreAddedEvent` | `release_id: address`, `genre_id: address` | 64 |
| `ReleaseGenreRemovedEvent` | `release_id: address`, `genre_id: address` | 64 |
| `ReleaseGenresClearedEvent` | `release_id: address` | 32 |
| `ReleaseKindSetEvent` | `release_id: address`, `kind: String` | 33 + n; at most 65 |
| `ReleaseKindClearedEvent` | `release_id: address` | 32 |
| `ReleaseDescriptionSetEvent` | `release_id: address`, `description: String` | 32 + ULEB128(n) + n; at most 8226 |
| `ReleaseDescriptionClearedEvent` | `release_id: address` | 32 |

Rules common to every attribute: a write that would leave the stored value
unchanged is a no-op — no write, no event. A set therefore emits only when
the value changes (setting the title, kind or description already attached
is silent, after argument validation and the cap check) and never creates
the record as a no-op, since only an attached value can be equalled; a clear
emits only when something was actually removed; views emit nothing. For genres, an add always appends at the end and a remove
preserves the remaining order, so replaying Added/Removed/Cleared in sequence
reproduces the exact list; removing the last genre is one
`ReleaseGenreRemovedEvent` (the indexer's own list went empty), and
`ReleaseGenresClearedEvent` is emitted only by `clear_genres` on a non-empty
list.

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `676dbd801583761b7e5ab53b4476e8606a12a8d7` — `Release` authorization
  through `uid`/`uid_mut`.
- [`genre`](https://github.com/misofm/genre) at
  `268d4bc45eecdaf7b75dc443e4974b9469912513` — the canonical shared genre
  vocabulary; `add_genre` takes a real `&Genre` so nothing outside it can
  enter the list.

Both are exact Git pins; this manifest has no local-path dependencies.

## Integrator notes

- **Titles are presentation.** Core never reads one, and the title is not in
  the release digest. Localized, alternate and edition titles are separate
  concerns for separate extensions; this is the one preferred rendering.
- **Genre ids, never names.** Resolve display names client-side from the
  frozen `Genre` objects; `genre::derive_address(registry, name)` computes an
  id offline. A track's genre is the recording's own (`recording_metadata`)
  first, falling back to `genres(release)[0]`.
- **Kind is free text.** "EP", "ep" and "Extended Play" are three distinct
  values; clients that facet by kind should case-fold.
- **The cap holder is permanent root** over every dynamic field on the
  release, this package's included. Model extension data as admin-mutable
  forever.

## Publishing

Unpublished. When published, it will be a fresh immutable package identity,
never upgraded in place; clients migrate explicitly by selecting the new
package and its key type.

## Build and test

Run from this directory with Sui 1.79.0:

```sh
sui move build --lint --warnings-are-errors
sui move test --coverage --lint --warnings-are-errors
sui move coverage summary
sui move test --build-env mainnet --lint --warnings-are-errors
```

The suite has a unit and an `*_e2e_tests.move` scenario file per attribute,
`metadata_tests.move` for the record's lifecycle, and
`metadata_e2e_tests.move`, which drives all four attributes on one published,
shared release to show they are set and cleared independently.
