# recording_genre

The ordered list of genres that classify a `Recording`, primary first: a
small, bounded `vector<ID>` of `genre::Genre` object ids drawn from the shared
Miso genre vocabulary, so a recording's genres are exactly the ids everything
else uses.

Genre lives here, on the recording, rather than on the release. `miso::track`
embeds only facts "genuinely release-specific and not derivable from the
recording" — title and cover art were excluded on the same principle — and
genre is a fact about the audio, not the product. One published `Recording`
can be a track on many releases (`track::new` may be called repeatedly against
one recording, and `Recording` carries no back-reference to any release), so a
per-track genre override written from the release side would be N independent
classifications of one master, made by whichever compilation curator holds
that release's cap. The recording's own admin is the party entitled to
classify it, and does so once, here.

`release_genre` keeps the product-level claim: a compilation can be "Jazz" as
a release even when its individual recordings are not. A client resolving a
track's genre should read this package first — the recording's own
classification — and fall back to the release's primary genre only when the
recording has none.

## What it stores

- Key: `ExtensionKey()` — a unit struct local to this package, so no other
  consumer's data collides with it on the recording's `UID`.
- Value: a bare `vector<ID>` of `genre::Genre` object ids under that key — no
  wrapper struct. Index 0 is the primary; the rest keep the caller's order.
- Capacity: `MAX_GENRES` = 6 genres per recording (the primary plus up to five
  more).
- Reclamation: removing the last genre drops the whole dynamic field. Non-empty
  by construction — the field is attached if and only if there is a primary.

## API

All writes require the recording's `&RecordingAdminCap<RecordingShare>` and go
through `recording::uid_mut(cap)`; the cap is bound to its recording by type,
so there is no runtime authorization abort — a cap for another recording is a
different type and does not compile. Views are permissionless.

### Writes

| Function | Description | Aborts |
|---|---|---|
| `add_genre(rec, cap, &Genre)` | Appends a genre; creates the field on first use, making that genre the primary | `EDuplicateGenre` (40) if already assigned, `EMaxGenres` (41) at 6 genres |
| `remove_genre(rec, cap, genre_id)` | Removes a genre by id; the next genre becomes primary if the primary was removed; dropping the last genre removes the field | `EGenreNotPresent` (42) if not assigned, or nothing is attached |
| `clear_genres(rec, cap)` | Removes the entire genre list; no-op when absent | none |

### Views

| Function | Returns |
|---|---|
| `genres(rec)` | The genre ids in order, primary first (empty when nothing is attached) |

## Events

| Event | When | Payload |
|---|---|---|
| `GenreAddedEvent` | A genre is appended (`add_genre`) | `recording_id`, `genre_id` |
| `GenreRemovedEvent` | A genre is removed (`remove_genre`) | `recording_id`, `genre_id` |
| `GenresClearedEvent` | The last genre is removed and the field is dropped, or `clear_genres` removes an attached list outright | `recording_id` |

## Errors

| Code | Constant | Location | Condition |
|---|---|---|---|
| 40 | `EDuplicateGenre` | `recording_genre::recording_genre` | `add_genre` with a genre already assigned |
| 41 | `EMaxGenres` | `recording_genre::recording_genre` | `add_genre` when the recording already holds `MAX_GENRES` (6) genres |
| 42 | `EGenreNotPresent` | `recording_genre::recording_genre` | `remove_genre` with an id not assigned (including when nothing is attached) |

## Dependencies

- [`miso`](https://github.com/misofm/protocol) at
  `09f0dc699a112c37d8da8a765596cc1ed623fe79` — `Recording` and
  `RecordingAdminCap`.
- [`genre`](https://github.com/misofm/genre) at
  `09f6882b57b19498f36fa15840cd7ed61094dc41` — the canonical shared genre
  vocabulary.

Both are exact Git pins; this manifest has no local-path dependencies.

## Integrator notes

- **The list stores ids, never names.** Resolve display names client-side from
  the frozen `Genre` objects, globally readable by reference.
- **Ids are name-derived.** `genre::derive_address(registry, name)` computes
  the address a genre name would have without creating it, so clients can
  resolve or check a genre id offline.
- **Every stored id is proven.** Every write takes the `&Genre` object, so
  nothing outside the vocabulary can ever enter the list — readers can trust
  each id resolves to a real entry. These are the same ids `release_genre`
  and `party_genre` use, so recording genres join cleanly against release and
  party metadata.
- **Events are change signals.** Re-read `genres()` on any of the four events;
  `genre_id` rides along as a small stable pointer, but the payload is not the
  state.
- **Primary is index 0, and it is protocol state here** — unlike `party_genre`,
  which has no ranking concept at all, index 0 of `genres()` is a first-class,
  cap-written fact, not a client convention over insertion order.
- **Resolution order for a track's genre**: read this package against the
  recording first; fall back to `release_genre`'s primary only when the
  recording has none.
- **Reordering, including changing the primary.** There is no dedicated
  set-primary function. Call `clear_genres` followed by `add_genre` in the
  desired order — primary first — in one programmable transaction block, so
  the reorder is atomic and the client expresses its intended final order
  directly.
- **No derived views.** The two obvious predicates over `genres()` are left
  out on purpose: emptiness is `genres(rec).is_empty()`, and the primary is
  `genres(rec)[0]` (valid whenever the vector is non-empty — see "What it
  stores"). Neither composes anything `genres()` doesn't already give you,
  and this package is never upgraded, so every public function is permanent
  surface that has to be re-published and re-audited for the life of the
  deployment. Compute both client-side.

## Publishing

This package is published as a fresh, immutable package identity and is never
upgraded — the repository's policy is a new publish at a new address for every
change. Clients migrate explicitly by selecting the new package id and its key
type; there is no in-place upgrade path to depend on.

## Build and test

Run from this directory:

```sh
sui move build --lint --warnings-are-errors
sui move build --lint --warnings-are-errors --build-env mainnet
sui move test --coverage --lint --warnings-are-errors
sui move coverage summary
sui move test --build-env mainnet
```
