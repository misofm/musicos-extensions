# Security review — `release_genre`

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
use `df::exists` directly against the release's `UID`.

## Dependency provenance

`Move.toml` pins `genre` at
`09f6882b57b19498f36fa15840cd7ed61094dc41` and `miso` at
`09f0dc699a112c37d8da8a765596cc1ed623fe79`. Both the Testnet and Mainnet lock
graphs resolve `bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` with no
duplicate package aliases.

## Threat model and findings

The relevant threat is an unauthorized change to a release's genre
assignment. Every write (`add_genre`, `remove_genre`, `clear_genres`)
requires the matching `ReleaseAdminCap` through `Release::uid_mut`, whose
`authorize` check rejects a cap for any other release before this package's
logic ever runs. Every id that enters the list is proven by a real `&Genre`
object from the shared vocabulary, so nothing outside it can be written
here; removal takes a bare `ID` since no proof is needed to take an entry
back out. The list is bounded at `MAX_GENRES` (6), rejects duplicates, and is
non-empty by construction — `remove_genre` drops the field the instant the
last entry leaves, so "the field exists" and "there is a primary" never
diverge, and no reader has to handle an attached-but-empty state.
`clear_genres` is cap-gated like every other write, only ever removes the
field it finds (or does nothing), and cannot abort — there is no assertion on
its path, so a caller can always reach the empty state regardless of the
list's current contents. Reordering, including changing which genre is
primary, is `clear_genres` followed by `add_genre` in the desired order
within one programmable transaction block; there is no dedicated
set-primary function, so there is no conditional-capacity branch to review
for that path. The dynamic-field key is module-owned (`ExtensionKey`), so no
other extension on the same release can collide with or overwrite this data.
The package moves no funds and contains no Vault, Action, or Plugin surface.

This source is intended for a new immutable package identity. It does not
claim compatibility with any retired deployment, including the prior
primary/secondary/per-track shape; clients migrate explicitly by selecting
the new package and its dynamic-field key type.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds pass clean, and tests pass 16/16. The production
module reports 100.00% coverage over its four public functions, including
published/shared Release lifecycle, authorization, the ordered-list
invariants (append, remove, clear, re-add after clear, reorder via
clear-and-re-add), bounds, duplicates, the clear-when-absent no-op, and event
behavior — each case now asserted directly against `genres()` rather than
through either of the two removed views.
