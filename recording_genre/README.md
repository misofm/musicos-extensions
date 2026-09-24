# `recording_genre`

The ordered genres that classify a `musicos::recording::Recording`, primary
first: one bounded `vector<ID>` of `genre::Genre` object ids stored as a
dynamic field on the recording and written through its cap-gated `uid_mut`.

Genre lives on the recording, not the release, because it is a fact about the
audio: one published `Recording` can be a track on many releases, and only the
recording's own admin has standing to classify it. `release_genre` keeps the
separate product-level claim (a compilation can be "Jazz" as a release even
when its recordings are not). A client resolving a track's genre reads this
package first and falls back to the release's primary only when the recording
has none.

## What it stores

- Key: `ExtensionKey()` — a unit struct local to this package.
- Value: a bare `vector<ID>` of `genre::Genre` ids under that key. Index 0 is
  the primary; the rest keep the caller's order.
- Capacity: `MAX_GENRES` = 6 (the primary plus up to five more).
- Non-empty by construction: removing the last genre drops the field, so
  `genres(rec)[0]` is the primary whenever `genres(rec)` is non-empty.

## API

Writes require the recording's `&RecordingAdminCap<RecordingShare>` and go
through `recording::uid_mut(cap)`, which matches the cap by type only. Views
are permissionless.

| Function | Description | Aborts |
|---|---|---|
| `add_genre(rec, cap, &Genre)` | Appends a genre; the first add creates the field and makes that genre the primary | `EDuplicateGenre` (40) if already assigned, then `EMaxGenres` (41) at 6 |
| `remove_genre(rec, cap, genre_id)` | Removes a genre by id; the next genre becomes primary if the primary was removed; the last removal drops the field | `EGenreNotPresent` (42) if not assigned, including when nothing is attached |
| `clear_genres(rec, cap)` | Removes the whole list; silent when absent | none |
| `genres(rec)` | The genre ids in order, primary first; empty when nothing is attached | none |

Every add takes the `&Genre` object, so only ids that resolve to a real entry
in the shared vocabulary can enter the list. Reordering, including changing
the primary, is `clear_genres` followed by `add_genre` in the desired order
within one programmable transaction block. Emptiness and the primary are
computed client-side from `genres()`.

## Events

All events are generic over `RecordingShare` only.

| Event | Fields | BCS bytes |
|---|---|---|
| `RecordingGenreAddedEvent<RecordingShare>` | `recording_id: address`, `genre_id: address` | 64 |
| `RecordingGenreRemovedEvent<RecordingShare>` | `recording_id: address`, `genre_id: address` | 64 |
| `RecordingGenresClearedEvent<RecordingShare>` | `recording_id: address` | 32 |

Removing the last genre emits only `Removed`; `Cleared` is emitted only by
`clear_genres` on an attached list. An absent clear emits nothing. Genre names
resolve client-side from the frozen `Genre` objects.

## Errors

| Code | Constant | Condition |
|---|---|---|
| 40 | `EDuplicateGenre` | `add_genre` with a genre already assigned |
| 41 | `EMaxGenres` | `add_genre` when the recording already holds 6 genres |
| 42 | `EGenreNotPresent` | `remove_genre` with an id not assigned |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Recording<RecordingShare>` and
  `RecordingAdminCap<RecordingShare>`.
- [`genre`](https://github.com/misofm/genre) at
  `90baae2919f7272f6d4bbb245b643f7dba5dc0ba` — the canonical shared genre
  vocabulary.

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
