# Security review — `recording_genre`

Reviewed 2026-09-08 for immutable publication. Verdict: no exploitable
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

`Move.toml` pins `genre` at `09f6882b57b19498f36fa15840cd7ed61094dc41` and
`musicos` at `4fed48b2b5632122fb677d742881259c65b1bc78`. The generated Testnet and
Mainnet lock graphs agree on every transitive dependency (`bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b`, `miso_share` at
`4999b7d639131fbd5b416b14ca798c28c0a6107d`) with no duplicate package aliases.

## Threat model and findings

The relevant threat is an unauthorized change to a recording's genre list.
`add_genre`, `remove_genre`, and `clear_genres` all require the matching
`RecordingAdminCap<RecordingShare>` through `Recording::uid_mut`, and the cap
is bound to its recording by type — one share currency is minted per
recording, so a cap for a different recording is a different type and cannot
be substituted at compile time.

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

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds pass clean, and tests pass 18/18. The production
module (`recording_genre::recording_genre`) reports 100.00% coverage over its
four public functions, including the published/shared-object lifecycle,
first-add, append-order, capacity and duplicate aborts, absent-genre removal
aborts (with and without an attached field), primary-promotion-on-removal,
field reclamation on last-removal, the clear-when-absent no-op, reorder via
clear-and-re-add, post-clear re-attachment, and per-recording isolation —
each case now asserted directly against `genres()` rather than through
either of the two removed views.
