# release_genre

The genre(s) a musicos `Release` is classified under as a product: an ordered
list of `genre::Genre` object ids, primary first, attached to the release
through its cap-gated `&mut UID`. A recording's own intrinsic classification
lives in the sibling package `recording_genre`; this package holds the
different, product-level claim (a compilation can be "Jazz" as a released
product even when its individual tracks are not). Resolve a track's genre
client-side by checking the recording's own genre first and falling back to
this release's primary.

## Storage

- Key: `ExtensionKey()` — a unit struct local to this package.
- Value: a bare `vector<ID>` of `genre::Genre` object ids under that key.
  Index 0 is the primary; the rest are unranked.
- Capacity: `MAX_GENRES` = 6 (the primary plus up to five more).
- Reclamation: removing the last genre drops the field. The field's existence
  and "there is a primary" are the same fact — the list is non-empty by
  construction.

## API

All writes require the release's `ReleaseAdminCap` and go through the
cap-gated `release::uid_mut`, which rejects a cap for another release with
`release::EUnauthorized` (0) before any stored-state check. Views are
permissionless.

| Function | Description | Aborts |
|---|---|---|
| `add_genre(release, cap, &Genre)` | Appends a genre; the first ever added becomes the primary | wrong cap (0); then `EDuplicateGenre` (40) if already assigned; then `EMaxGenres` (41) at 6 genres |
| `remove_genre(release, cap, genre_id: ID)` | Removes a genre by id; if it was the primary, the next entry is promoted; removing the last one drops the field | wrong cap (0); then `EGenreNotPresent` (42) when the id is not assigned, including when nothing is attached |
| `clear_genres(release, cap)` | Removes the entire genre list; an absent list is a silent no-op | wrong cap (0), even when nothing is attached |
| `genres(release): vector<ID>` | The release's genre ids, in order, primary first (empty when none) | — |

Emptiness is `genres(release).is_empty()` and the primary is
`genres(release)[0]`; neither is exposed as a separate function. Reordering,
including changing the primary, is `clear_genres` followed by `add_genre` in
the desired order within one programmable transaction block.

## Events

All events are monomorphic and carry only what an event-only indexer would
otherwise have to look up; the ordered list is replayed from them.

| Event | Fields | BCS size |
|---|---|---|
| `ReleaseGenreAddedEvent` | `release_id: address`, `genre_id: address` | 64 |
| `ReleaseGenreRemovedEvent` | `release_id: address`, `genre_id: address` | 64 |
| `ReleaseGenresClearedEvent` | `release_id: address` | 32 |

Removing the last genre emits only `ReleaseGenreRemovedEvent`; there is no
cascaded cleared event. A cleared event is emitted only when a list was
actually removed. Views emit nothing. Genre names are resolved client-side
from the frozen `Genre` objects, or derived offline with
`genre::derive_address(registry, name)`.

## Errors

| Code | Constant | Location | Condition |
|---|---|---|---|
| 40 | `EDuplicateGenre` | `release_genre::release_genre` | `add_genre` with a genre already assigned |
| 41 | `EMaxGenres` | `release_genre::release_genre` | `add_genre` when the release already holds 6 genres |
| 42 | `EGenreNotPresent` | `release_genre::release_genre` | `remove_genre` with an id not currently assigned |
| 0 | `EUnauthorized` | `musicos::release` | any write with a cap for a different release |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Release`, `ReleaseAdminCap`,
  and cap-gated `uid_mut`.
- [`genre`](https://github.com/misofm/genre) at
  `90baae2919f7272f6d4bbb245b643f7dba5dc0ba` — the canonical shared genre
  vocabulary; `add_genre` takes a real `&Genre`, so only minted ids enter the
  list.

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
```
