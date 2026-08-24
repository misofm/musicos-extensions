# Security Audit — `release_genre`

**Revision:** working tree @ 2026-08-24. Dependency pins: `genre` @
`2a90a48a…`, `miso` @ `7bda0bb7…`, `per_track` @ `49d6e374…`
(`Move.toml`). **Date:** 2026-08-24 ·
**Toolchain:** sui 1.77.2-51d177ad7d65

Audit of `release_genre` (270 LOC, `sources/release_genre.move`), the
extension assigning album-level primary/secondary genres plus per-track
primary overrides to a release. Verdict: **safe to publish — no findings.**

## What it does

One dynamic field under `ExtensionKey()` (`release_genre.move:58`) holding a
`ReleaseGenre { primary: ID, secondary: vector<ID>, track_primary:
PerTrack<Option<ID>> }` (`release_genre.move:63-67`) — genre *object IDs* from
the canonical `genre` vocabulary, not strings. Mutators: `set_primary_genre`,
`add_secondary_genre`, `remove_secondary_genre`, `set_track_primary_genre`,
`unset_track_primary_genre`; views are permissionless with
override-then-primary resolution (`track_primary_genre`,
`release_genre.move:232-239`). Bounds: ≤ 5 secondaries
(`release_genre.move:53`).

## Threat model

The threat is unauthorized genre assignment on someone else's release —
metadata integrity with mild financial adjacency (discovery/reward
eligibility may key off genre, per the module doc's contrast with
`release_kind` at `release_kind.move:19-22`). The authorization chain:

- Every mutator calls `self.uid_mut(cap)` before the write
  (`release_genre.move:118,125,145,160,183,196`).
  `miso::release::uid_mut` (`protocol/sources/release.move:337-340`) enforces
  `cap.release_id == object::id(self)` — ID-level binding; no cap, no write.
- **Genre IDs are real vocabulary members:** all mutators take `&Genre` and
  store `object::id(genre)` (`release_genre.move:115` etc.). `Genre` objects
  are frozen, name-derived singletons. Creation is permissionless, but the
  validated name fixes both id and contents (see the `genre` audit); a caller
  cannot forge arbitrary fields or point a release at an id without the
  canonical object existing.
- **Primary/secondary disjointness** is enforced both directions:
  `set_primary_genre` rejects a current secondary (`EPrimaryIsSecondary`,
  `release_genre.move:119`); `add_secondary_genre` rejects the current primary
  and duplicates (`release_genre.move:146-147`). A genre can never be both.
- **Structural preconditions:** secondaries and track overrides require the
  record (hence a primary) to exist first (`ENoPrimaryGenre`,
  `release_genre.move:144,159,181,194`); `ReleaseGenre.primary` is non-optional
  so a stored record always has a primary.
- **Alignment:** `track_primary` is sized to the frozen tracklist at first
  attach (`per_track::filled`, `release_genre.move:123`) and all per-track
  accesses bounds-check (`release_genre.move:182,195,235`).
- **Key hygiene:** `ExtensionKey()` is module-local; `ReleaseGenre` is
  `store`-only with private fields; `df::add` aborts on re-add.
- **DoS:** secondaries capped at 5 (`release_genre.move:148`); per-track array
  ≤ 255 slots; no unbounded loops.

## Findings

None. (Design note, not a vulnerability: a *track* override may name the
album primary or a current secondary — redundant but harmless presentation
data; the disjointness invariant governs only the album-level pair.)

## Edge cases verified

- Replacing the primary with a current secondary aborts; the reverse
  (adding the primary as secondary) aborts; duplicate secondary aborts; 6th
  secondary aborts.
- Removing a non-secondary aborts (`EGenreNotSecondary`,
  `release_genre.move:161-162`).
- Track index `== tracks().length()` aborts in all three per-track entry
  points.
- Views before any assignment: `primary_genre` → `none`, `secondary_genres` →
  empty, `track_primary_genre` → `none` without aborting
  (`release_genre.move:210-239`; test `views_before_assignment_are_empty`).
- `track_primary_genre` with an existing record but out-of-range index aborts;
  with a `none` slot it falls back to the album primary.

## Verification

- **20/20 tests pass** (`sui move test`, sui 1.77.2), including e2e tests on
  shared published releases and the disjointness matrix.
- Full source read; auth contract cross-checked against
  `miso::release::uid_mut`/`authorize`; `Genre` non-forgery verified in the
  `genre` audit; `PerTrack` alignment verified in the `per_track` audit.
