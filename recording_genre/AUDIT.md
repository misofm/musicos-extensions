> Historical audit below predates the 2026-09-15 payload revision. Current event contracts and size bounds are documented in [EVENT_PAYLOADS.md](../EVENT_PAYLOADS.md). Storage, authority, and mutation behavior remain unchanged.

# Security review — `recording_genre`

Reviewed 2026-09-11 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Reviewed surface

The public API is four functions: `add_genre`, `remove_genre`,
`clear_genres`, and the single view `genres`. Two prior views — an emptiness
predicate and a primary-genre accessor — were removed, since both were pure
client-side derivations of `genres()` (`!genres(x).is_empty()` and
`genres(x)[0]` respectively), and this package is never upgraded, so no
function that composes from the others is carried as permanent surface.
Neither writer ever called either removed view internally; all three writes
use `df::exists` directly against the recording's `UID`.

## Dependency provenance

`Move.toml` pins `genre` at `cddf9491426723e2c468cebf40fb4231d9fb0d5a` and
`musicos` at `4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`. The checked-in lock
graph is retained byte-for-byte from the publication baseline; no manifest,
lock, or publication metadata was changed for this event-only revision.

## Threat model and findings

The relevant threat is an unauthorized change to a recording's genre list.
`add_genre`, `remove_genre`, and `clear_genres` all require the matching
`RecordingAdminCap<RecordingShare>` through `Recording::uid_mut`. This is
type-only authorization: the cap type must match, while the cap object's
runtime value or id is not authenticated by `uid_mut`.

Vocabulary integrity: every write that adds a genre to the list takes the
corresponding `&Genre` object by reference, so only ids that resolve to a real
entry in the shared, permissionless `genre::GenreRegistry` can ever enter.
`remove_genre` takes a bare `ID` deliberately — no vocabulary proof is needed
to drop a reference the recording already holds.

Bounded, ordered, non-empty state: the list is capped at `MAX_GENRES` (6),
duplicates are rejected on `add_genre`, and `remove_genre` drops the whole
dynamic field the moment the list would otherwise become empty — there is no
reachable state where the field exists and is empty, so a caller reading
`genres(x)[0]` for the primary is always indexing a non-empty vector whenever
`genres(x)` is non-empty. `clear_genres` is cap-gated like every other write,
only ever removes the field it finds (or does nothing when absent), and has
no assertion on its path, so it cannot abort. Reordering, including changing
which genre is primary, is `clear_genres` followed by `add_genre` in the
desired order within one programmable transaction block; there is no
dedicated set-primary function, so there is no conditional-capacity branch to
review for that path.

`ExtensionKey` is a module-owned, zero-field key type, so this package's field
cannot collide with, be read as, or be overwritten by any other extension
attached to the same recording. The package moves no funds and contains no
Vault, Action, or Plugin surface.

## Evidence

With the available Sui toolchain, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean, and all 25 tests pass in both networks.
The production module (`recording_genre::recording_genre`) reports 100.00%
raw coverage over its four public functions, including exact full-payload BCS
peeling/replay, append and order-preserving removal, primary promotion,
last-removal cleanup with one final-state Removed event, explicit/absent clear separation,
64-byte names, six-item bounds, duplicate-before-capacity and seventh-item
guards, same-type foreign-cap transitions with target/cap identity checks,
type-only cap semantics, unrelated dynamic-field preservation,
phantom event isolation, the published/shared-object lifecycle, and
post-clear re-attachment.

## 2026-09-24 — regeneration against musicos `6dff4de`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c`, where `Recording` takes a single
`RecordingShare` parameter and `publish` no longer takes a Clock. `genre`
remains at `90baae2919f7272f6d4bbb245b643f7dba5dc0ba`. Verdict unchanged: no
exploitable findings.

Changes in this generation:

- Events are now `<phantom RecordingShare>` only and slimmed: `Added` and
  `Removed` carry the recording and genre ids (64 BCS bytes, down from
  221); `Cleared` carries the recording id (32, down from up to 407).
  Dropped: composition id, admin cap address, indices, counts, field and
  primary flags, before/after primary ids, clear cause, and the removed-id
  list. Removing the last genre still emits only `Removed` and drops the
  field.
- Guard order is cap check then stored-state checks, with the duplicate check
  still preceding the capacity check. The functions take no validatable
  argument beyond the `&Genre` proof itself.
- The test-only `add_empty_field_for_testing` hook was removed along with the
  primary-transition event logic it exercised.

Public API (`add_genre`, `remove_genre`, `clear_genres`, `genres`), error
codes 40–42, the six-genre bound, vocabulary proof on add, and
remove-promotes-next behavior are unchanged.

Evidence: with Sui `1.79.0`, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean and all 17 tests pass on each network;
the production module reports 100.00% coverage.

Event `recording_id`/`genre_id` fields are typed `ID` rather than `address`,
and emit sites pass object ids directly; BCS layout and sizes are unchanged.
