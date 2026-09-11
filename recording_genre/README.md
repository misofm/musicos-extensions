# recording_genre

The ordered list of genres that classify a `Recording`, primary first: a
small, bounded `vector<ID>` of `genre::Genre` object ids drawn from the shared
Miso genre vocabulary, so a recording's genres are exactly the ids everything
else uses.

Genre lives here, on the recording, rather than on the release. `musicos::track`
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
through `recording::uid_mut(cap)`. This matches the cap's `RecordingShare` type
only; it does not authenticate a cap object's runtime value or id. Views are
permissionless.

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

All events are phantom-typed as
`<RecordingShare, CompositionShare>`, use actual primitive addresses, and are
emitted only after the corresponding dynamic-field write succeeds. Their BCS
fields are declared in this exact order.

`RecordingGenreAddedEvent`:

```text
recording_id: address
composition_id: address
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

`RecordingGenreRemovedEvent` has the same fields except `genre_name`, in this
order: `recording_id`, `composition_id`, `admin_cap_id`, `genre_id`,
`genre_index`, `genres_before`, `genres_after`, `genre_count_before`,
`genre_count_after`, `field_existed_before`, `field_exists_after`,
`had_primary_before`, `has_primary_after`, `primary_genre_id_before`,
`primary_genre_id_after`, `primary_changed`.

`RecordingGenresClearedEvent`:

```text
recording_id: address
composition_id: address
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

`clear_cause = 0` is explicit `clear_genres` with `trigger_genre_id = @0x0`.
`clear_cause = 1` is the cascade after removing the last genre, with the
removed id as `trigger_genre_id`. The last removal emits `Removed` first with
`field_existed_before = field_exists_after = true` and snapshots `[A] -> []`,
then emits the cause-1 `Cleared` event after deleting the field. An absent
explicit clear is silent. `primary_changed` is true exactly when primary
presence or primary id changes.

## Event bounds

For `b` and `a` snapshot lengths and an `n`-byte raw genre name:

- Added is `224 + n + 32(b + a)` bytes; its maximum is 640 bytes at `n = 64`,
  `b = 5`, `a = 6`.
- Removed is `223 + 32(b + a)` bytes; its maximum is 575 bytes for a six-item
  list removing one entry.
- Cleared is `216 + 32(b + a)` bytes; its maximum is 408 bytes for a six-item
  list cleared to empty.

The last-removal pair is 255 bytes for Removed (`b = 1`, `a = 0`) plus 216
bytes for the cascading Cleared event. These are event-payload bounds; the
full snapshots intentionally add serialization and transaction gas, so clients
should budget for the list size and name length.

## Errors

| Code | Constant | Location | Condition |
|---|---|---|---|
| 40 | `EDuplicateGenre` | `recording_genre::recording_genre` | `add_genre` with a genre already assigned |
| 41 | `EMaxGenres` | `recording_genre::recording_genre` | `add_genre` when the recording already holds `MAX_GENRES` (6) genres |
| 42 | `EGenreNotPresent` | `recording_genre::recording_genre` | `remove_genre` with an id not assigned (including when nothing is attached) |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840` — `Recording` and
  `RecordingAdminCap`.
- [`genre`](https://github.com/misofm/genre) at
  `cddf9491426723e2c468cebf40fb4231d9fb0d5a` — the canonical shared genre
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
- **Events are replayable transitions.** The Added, Removed, and Cleared
  payloads carry ordered primitive snapshots, counts, field lifecycle flags,
  and primary metadata. Consumers can replay them directly or re-read
  `genres()` after any event; Added also carries the raw canonical name.
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
