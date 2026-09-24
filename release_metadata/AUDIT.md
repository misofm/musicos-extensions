# Security review — `release_metadata`

Reviewed 2026-09-24 ahead of first publication. Unpublished: this package
has no `Published.toml` and no deployed identity. Verdict: no exploitable
findings in the reviewed source. This is a self-review and test record, not
an independent audit.

## Scope

One module, `release_metadata::release_metadata`, attaching one dynamic
field to a `musicos::release::Release` under its module-private
`ExtensionKey()`. The field holds one `ReleaseMetadata` record — `title:
Option<String>`, `genres: vector<ID>`, `kind: Option<String>`, `description:
Option<String>` — with only the `store` ability. The record is created by
the first write of any attribute and removed, by destructuring, by the
clear or genre removal that leaves every attribute unset; no path leaves an
empty record attached.

The package consolidates the previously separate `release_genre`,
`release_kind` and `release_description` packages (reviewed 2026-09-11 in
their own `AUDIT.md`s) and adds the title that musicos core dropped from
`Release`. The absorbed packages' validation rules, bounds and ordering
semantics are carried over; their storage layout (one field per attribute)
is replaced by the shared record, their error codes are renumbered, and two
behaviours change: `remove_genre` authorizes before it looks for the list,
and a final removal no longer cascades a Cleared event. This design and its
conventions are shared with `composition_metadata` and `recording_metadata`.
No Vault, Action, Plugin, custody or value-routing code is present.

## Dependency provenance

`Move.toml` pins `musicos` at `676dbd801583761b7e5ab53b4476e8606a12a8d7`
(`Release.title` was removed and `ReleasePublishedEvent` slimmed at
`8c3fd65f733d640c2b72c3a63b0a14f3953f396e`; core exposes `uid(&Release)` and cap-gated `uid_mut(&mut Release,
&ReleaseAdminCap)`) and `genre` at
`268d4bc45eecdaf7b75dc443e4974b9469912513`. Both are exact Git pins with no
local-path dependency; the checked-in `Move.lock` resolves both the Testnet
and Mainnet graphs, with `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` and `share` at
`6ac1dbf022e74957c5ec15ecf95890e28889cd62` through musicos, without
duplicate aliases.

## Threat model and findings

The relevant threat is an unauthorized write to a release's descriptive
metadata. Every write requires the matching `ReleaseAdminCap` through
core's `uid_mut`, which authenticates `object::id(self) == cap.release_id`
at runtime and aborts `EUnauthorized` (0) at `musicos::release`. Reads are
permissionless and emit nothing. The extension adds no cap-ID comparison of
its own and does not custody the cap. The cap holder is, by core's design,
permanent root over every dynamic field on the release; this package
inherits that and promises nothing beyond it.

Guard order, one rule for every function: validation that needs only the
argument runs before `uid_mut`; anything that reads stored state runs after
it.

- `set_title`, `set_kind`, `set_description` validate emptiness (11, 31, 41)
  and then the byte bound (12, 32, 42 at 300, 32 and 8192 bytes, inclusive)
  before `uid_mut`, so an invalid value reports the module's own code even
  with a foreign cap; a valid value with a foreign cap aborts 0 in core,
  including a value equal to the one attached. After `uid_mut`, setting the
  value already attached is a silent no-op — no write, no event — and, since
  only an attached value can be equalled, a no-op never creates the record.
- `clear_*` and `clear_genres` authorize before the existence check, so a
  wrong cap aborts even when nothing is attached; an authorized clear of
  nothing — record absent, or present for another attribute — is a silent
  no-op.
- `add_genre` authorizes, then rejects a duplicate (23) before capacity (22,
  at 6). It takes `&Genre`, so only ids the shared vocabulary minted can
  enter the list. `remove_genre` authorizes, then reports a missing list or
  member (24). The absorbed `release_genre` reported an absent list before
  authorization; here a foreign cap against an unclassified release aborts
  in core, like every other state-touching write.

Schema integrity: `ExtensionKey` and `ReleaseMetadata` can be constructed
only inside the module and the record's fields are private, so no other
extension can read, collide with or overwrite this field, and no write to
one attribute can reach another. Unrelated dynamic fields on the same
release are untouched by the record's creation and removal. Values are
stored as the supplied `String` or `ID` without normalisation. Absence is a
distinct state: the three string views abort when nothing is attached, and
`genres` returns an empty vector for both an absent record and an empty
list, which are the same claim.

Bounds: 300, 32 and 8192 bytes, and six genres. No path allocates
proportionally to caller input beyond those bounds. The record is taken out
with `df::remove` and destructured; no value is left orphaned under a key.

The values are descriptive and have no economic, consent or authorization
meaning in musicos: none is read by the economics, none is in the release
digest, and every one is admin-mutable before and after publish by design.

## Events

Nine monomorphic events, emitted only after their dynamic-field mutation
succeeds. Payloads follow the musicos rule that a field is carried only if
an indexer reading events alone would otherwise need an object lookup for
it: `release_id` on every event, plus the written value on set (`title`,
`kind`, `description` as `String`) and the `genre_id` on genre add and
remove. Dropped relative to the absorbed packages, as derivable or constant:
cap ids (the derived address of `release_id` under `ReleaseAdminCapKey`),
before-snapshots, existence flags before/after, lengths, counts, indices,
primary ids, "changed" flags, clear causes and trigger ids, the genre name
(resolvable from the frozen `Genre` or the vocabulary's `GenreCreatedEvent`),
and the cascaded Cleared event after a final removal (one transition, one
Removed event; the indexer's own list went empty).

Rules: a write that would leave the stored value unchanged is a no-op, so a
set emits only when the value changes and an equal set emits nothing; a clear
emits only when something was removed; views and failed guards are silent. Genre
add always appends and remove preserves order, so the list is exactly
reconstructible from the stream. Exact BCS sizes: title set `32 + ULEB128(n)
+ n` (maximum 334), kind set `33 + n` (maximum 65), description set `32 +
ULEB128(n) + n` (maximum 8226), genre Added/Removed 64, every Cleared 32 —
unchanged from the absorbed packages, since a `String` serialises exactly as
the raw bytes did.

## Evidence

With Sui 1.79.0, `sui move build --lint --warnings-are-errors` and
`sui move test --lint --warnings-are-errors` pass on both the Testnet and
Mainnet build environments with zero warnings:

```
Test result: OK. Total tests: 96; passed: 96; failed: 0
```

`sui move coverage summary` reports 100.00% for the production module. The
suite comprises per-attribute unit tests (validation before authorization,
byte bounds at and one past the limit, verbatim storage of case, whitespace,
NUL and multi-byte UTF-8, per-release isolation, silent equal sets (no
event, record and value unchanged, never a record created, a foreign cap
still rejected), silent views and absent clears, exact BCS decoding with empty-remainder assertions,
event-only projectors compared with storage after every transition, genre
ordering, promotion, capacity, duplicate precedence, final removal without a
cascade, and clear/re-add), record-lifecycle tests (absent before any write,
created by the first write of any attribute, kept while any attribute is
set, removed by the clear or removal that empties it, recreated by a later
write; clearing one attribute preserves the others; clearing an unset
attribute while others are set is silent; an unrelated dynamic field
survives), per-attribute `test_scenario` e2e flows on a published and shared
release across transactions and senders (permissionless reads, foreign-cap
rejection on set, on clear-of-nothing, on clear-of-present, and on
remove-of-absent), and a whole-package e2e flow proving the full profile,
the independence of each attribute's clear, and the record's removal from
the shared object.

Validation is local; no deployment, gas measurement or Mainnet publication
was performed.
