# Security Audit — `release_cover_art`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pins: `cover_art` @ `5f927785…`, `miso` @ `7c13e40a…`, `per_track` @
`cae740f1…` (`Move.toml`); audited dependency sources are the on-disk
`../../cover-art`, `../../protocol`, `../../per-track` trees. **Date:**
2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

Audit of `release_cover_art` (181 LOC,
`sources/release_cover_art.move`), the extension storing an album-level
`CoverArt` plus per-track overrides on a release. Verdict: **safe to publish —
no findings.**

## What it does

One dynamic field under `ExtensionKey()` (`release_cover_art.move:31`) holding
a `ReleaseCoverArt { cover: Option<CoverArt>, track_covers:
PerTrack<Option<CoverArt>> }` (`release_cover_art.move:35-38`). The per-track
array is sized to the release's tracklist at first attach via
`per_track::filled` (`release_cover_art.move:151`), so index alignment is an
invariant of construction. Four cap-gated mutators (`set_cover`,
`unset_cover`, `set_track_cover`, `unset_track_cover`) and permissionless
views including effective-cover resolution (`track_cover`,
`release_cover_art.move:133-138`).

## Threat model

The threat is unauthorized attach/alter/removal of artwork on someone else's
release (metadata integrity; storefronts display this). It fails on the
authorization chain:

- **Cap gate on every path.** `set_cover`/`set_track_cover` go through
  `borrow_mut_or_init`, which calls `self.uid_mut(cap)` on both the add and
  the borrow path (`release_cover_art.move:153,160`). `unset_cover` and
  `unset_track_cover` gate *first*, before the existence check
  (`release_cover_art.move:83,109`) — a wrong cap aborts even against an
  unattached release. `miso::release::uid_mut`
  (`protocol/sources/release.move:337-340`) enforces `cap.release_id ==
  object::id(self)` via `authorize` (`release.move:303-305`) — an ID-level
  binding; a cap for release A can never touch release B.
- **Key hygiene:** `ExtensionKey()` is module-local; `ReleaseCoverArt` is
  `store`-only with private fields, constructible only here — the value type
  under the key cannot be swapped by outsiders, and `df::add` aborts on
  re-add.
- **Alignment invariant:** `track_covers` is created with exactly
  `tracks().length()` slots, and a release's tracklist is frozen at creation
  (no add/remove API in `miso::release`), so a stored array can never drift
  out of alignment. Per-track accessors bounds-check twice — against the
  tracklist at the extension layer (`release_cover_art.move:97,111,134`) and
  against the array inside `per_track` (`per_track.move:64`).
- **Value hygiene:** `CoverArt` values are constructor-validated blob
  references (see the `cover_art` audit); nothing malformed can be stored
  beyond "points at a blob that may or may not exist" (client-side concern by
  design).
- **DoS:** no loops; storage bounded by one album cover + ≤ 255 option slots;
  writer-paid.

## Findings

None. (Ordering note: `set_track_cover` checks the index bound before the cap
gate, `release_cover_art.move:97` — a pure input validation that reads no
state and reveals nothing; the cap gate still precedes every field access.)

## Edge cases verified

- `unset_cover` / `unset_track_cover` on an unattached release abort
  `ENoCoverArt` — *after* the cap gate (test
  `unset_track_cover_without_attachment_aborts`).
- Track index `== tracks().length()` aborts `ETrackIndexOutOfBounds`.
- Effective-cover resolution falls back override → album cover → `none`
  (`release_cover_art.move:136-137`).
- Unsetting the album cover leaves per-track overrides untouched
  (`release_cover_art.move:81-87`), and vice versa.
- First attach via `set_track_cover` alone correctly initializes an all-`none`
  array plus a `none` album cover (the `borrow_mut_or_init` path,
  `release_cover_art.move:147-161`).

## Verification

- **18/18 tests pass** (`sui move test`, sui 1.77.2), including e2e tests on
  shared published releases.
- Full source read; auth contract cross-checked against
  `miso::release::uid_mut`/`authorize`; `PerTrack` alignment verified in the
  `per_track` audit.
