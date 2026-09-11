# release_genre

The genre(s) a musicos `Release` is classified under as a product: an ordered
list of `genre::Genre` object ids, primary first, attached to the release
through its cap-gated `&mut UID`. It does not carry per-track genre — a
recording's own intrinsic classification lives in the sibling package
`recording_genre`, on the recording itself, because one `Recording` can be a
track on many releases and carries no back-reference to any of them. This
package holds the different claim: a compilation can be "Jazz" as a released
product even when its individual tracks are not, and that classification
belongs only to the release. Resolve a track's genre client-side by checking
the recording's own genre first (`recording_genre`) and falling back to this
release's primary when the recording has none.

## What it stores

- Key: `ExtensionKey()` — a unit struct local to this package, so no other
  consumer's data collides with it on the release's `UID`.
- Value: a bare `vector<ID>` of `genre::Genre` object ids under that key — no
  wrapper struct. Index 0 is the primary; the rest are unranked.
- Capacity: `MAX_GENRES` = 6 genres per release (the primary plus up to five
  more).
- Reclamation: removing the last genre drops the whole dynamic field. The
  field's existence and "there is a primary" are the same fact — the list is
  non-empty by construction.

## API

All writes require `&ReleaseAdminCap` and go through `release::uid_mut(cap)`.
The upstream cap check is type-only and rejects a cap for another release with
`EUnauthorized` (0) at `musicos::release`. `remove_genre` checks field
presence first, so an absent field reports `EGenreNotPresent` (42) before cap
authorization; `clear_genres` authorizes even when the field is absent. Views
are permissionless.

### Writes

| Function | Description | Aborts |
|---|---|---|
| `add_genre(release, cap, &Genre)` | Appends a genre; the first ever added becomes the primary | wrong cap; `EDuplicateGenre` (40) if already assigned, `EMaxGenres` (41) at 6 genres |
| `remove_genre(release, cap, genre_id)` | Removes a genre by id; if it was the primary, the next entry is promoted; removing the last one drops the field | `EGenreNotPresent` (42) before authorization if no field or member; wrong cap (0) once a member field exists |
| `clear_genres(release, cap)` | Removes the entire genre list; no-op when absent | wrong cap |

### Views

| Function | Returns |
|---|---|
| `genres(release)` | The release's genre ids, in order, primary first (empty when none) |

## Events

Events are monomorphic and are emitted only after their corresponding dynamic
field mutation succeeds. BCS follows the declaration order below; vectors are
ordered primitive address snapshots, so a consumer can replay the list and
field lifecycle without rereading the release.

`ReleaseGenreAddedEvent` fields:

```text
release_id: address
admin_cap_id: address
genre_id: address
genre_name: vector<u8>
genre_index: u64
genres_before: vector<address>
genres_after: vector<address>
genre_count_before: u64
genre_count_after: u64
field_existed_before: bool
field_exists_after: bool
had_primary_before: bool
has_primary_after: bool
primary_genre_id_before: address
primary_genre_id_after: address
primary_changed: bool
```

`ReleaseGenreRemovedEvent` has the same order except that it omits
`genre_name`. `ReleaseGenresClearedEvent` fields are:

```text
release_id: address
admin_cap_id: address
clear_cause: u8
trigger_genre_id: address
genres_before: vector<address>
genres_after: vector<address>
genre_count_before: u64
genre_count_after: u64
field_existed_before: bool
field_exists_after: bool
had_primary_before: bool
has_primary_after: bool
primary_genre_id_before: address
primary_genre_id_after: address
primary_changed: bool
```

`clear_cause = 0` is explicit `clear_genres` and uses `@0x0` as its trigger;
`clear_cause = 1` is the cascade after removing the last genre and carries the
removed genre id. The last removal emits `ReleaseGenreRemovedEvent` first,
with the field still represented as `true -> true` and `[A] -> []`, then
deletes the field and emits the cause-1 cleared event with `[] -> []` and
`true -> false`. An absent explicit clear is silent. Added events carry the
raw `Genre.name()` bytes; IDs and cap IDs are the actual object addresses.

## Event bounds

For `b` and `a` snapshot lengths and an `n`-byte raw genre name:

- Added is `192 + n + 32*(b + a)` bytes, with maximum `608` bytes at `n = 64`,
  `b = 5`, `a = 6`.
- Removed is `191 + 32*(b + a)` bytes, with maximum `543` bytes for six items
  removing one.
- Cleared is `184 + 32*(b + a)` bytes, with maximum `376` bytes for six items
  cleared to empty.

The final-removal pair is `223` bytes for Removed (`b = 1`, `a = 0`) plus
`184` bytes for the cascading Cleared event. These are serialized event bounds;
the list and name still affect transaction gas.

## Errors

| Code | Constant | Location | Condition |
|---|---|---|---|
| 40 | `EDuplicateGenre` | `release_genre::release_genre` | `add_genre` with a genre already assigned |
| 41 | `EMaxGenres` | `release_genre::release_genre` | `add_genre` when the release already holds 6 genres |
| 42 | `EGenreNotPresent` | `release_genre::release_genre` | `remove_genre` with an id not currently assigned |
| 0 | `EUnauthorized` | `musicos::release` | any write with a cap for a different release |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840` — `Release` authorization
  through `uid`/`uid_mut`.
- [`genre`](https://github.com/misofm/genre) at
  `cddf9491426723e2c468cebf40fb4231d9fb0d5a` — the canonical shared genre
  vocabulary.

Both are exact Git pins; this manifest has no local-path dependencies.

## Integrator notes

- **The list stores ids, never names.** Resolve display names client-side
  from the `Genre` objects — they are frozen, so globally readable by
  reference.
- **Ids are name-derived.** `genre::derive_address(registry, name)` computes
  the address a genre name would have without creating it, so clients can
  resolve or check a genre id offline.
- **Every stored id is proven.** `add_genre` takes a real `&Genre`, so nothing
  outside the vocabulary can enter the list; `remove_genre` intentionally takes
  a bare `ID` because membership is already established by the stored list.
  Readers can trust that every retained id resolves to a real entry.
- **Events are replayable transitions.** Added, Removed, and Cleared carry
  ordered address snapshots, counts, field lifecycle flags, primary metadata,
  and the actual release/cap IDs. Added also carries the raw canonical genre
  name, so clients may replay directly or reread `genres()`.
- **Primary is protocol state here.** Unlike `party_genre`'s tag set, index 0
  in this list is not a client convention — it is the release's asserted
  primary genre, set and read through this API.
- **Resolution order for a track.** A track's own recording may carry a
  genre through `recording_genre`; check that first, and fall back to this
  release's primary — `genres(release)[0]` — only when the recording has
  none. A release's genre is a product-level default, not a per-track value.
- **Reordering, including changing the primary.** There is no dedicated
  set-primary function. Call `clear_genres` followed by `add_genre` in the
  desired order — primary first — in one programmable transaction block, so
  the reorder is atomic and the client expresses its intended final order
  directly.
- **No derived views.** The two obvious predicates over `genres()` are left
  out on purpose: emptiness is `genres(release).is_empty()`, and the primary
  is `genres(release)[0]` (valid whenever the vector is non-empty — see
  "What it stores"). Neither composes anything `genres()` doesn't already
  give you, and this package is never upgraded, so every public function is
  permanent surface that has to be re-published and re-audited for the life
  of the deployment. Compute both client-side.

## Publishing

This data layout is intentionally distinct from the historical version 1
package. It is published as a fresh immutable package identity and is never
upgraded from that deployment. Clients migrate explicitly by selecting the
new package and its dynamic-field key type.

## Build and test

Run from this directory:

```sh
sui move build --lint --warnings-are-errors
sui move build --lint --warnings-are-errors --build-env mainnet
sui move test --coverage --lint --warnings-are-errors
sui move coverage summary
sui move test --build-env mainnet
```
