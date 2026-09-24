# Security review — `recording_metadata`

Reviewed 2026-09-24, unpublished, ahead of a fresh immutable publication.
Verdict: no exploitable findings in the reviewed source. This is a
self-review and test record, not an independent audit.

## Reviewed surface

One module, `recording_metadata::recording_metadata`, attaching one dynamic
field to a `musicos::recording::Recording<RecordingShare>` under its
module-private `ExtensionKey()`. The field holds one `RecordingMetadata`
record — `genres: vector<ID>`, `languages: Option<vector<LanguageCode>>`,
`advisory: Option<Advisory>`, `version: Option<String>` — with only
the `store` ability. The record is created by the first write of any
attribute and removed, by destructuring, by the clear or genre removal that
leaves every attribute unset; no path leaves an empty record attached. The
public API is `add_genre`, `remove_genre`, `clear_genres`, `genres`;
`set_languages`, `clear_languages`, `has_languages`, `languages`; the
constructors `explicit`, `not_explicit`, `cleaned`, `set_advisory`,
`clear_advisory`, `has_advisory`, `advisory` and the predicates `is_explicit`,
`is_not_explicit`, `is_cleaned`; and `set_version`, `clear_version`,
`has_version`, `version`.

The package consolidates `recording_genre`, `recording_language` and
`recording_advisory` and adds `version`. Every validation rule of the three
superseded packages is carried over: genre's duplicate-before-capacity
order, six-entry bound, `&Genre` proof on write and bare-`ID` removal;
language's count-before-duplicates order, ten-entry bound,
empty-means-instrumental and absence-is-not-instrumental; advisory's closed
three-variant enum and absence-is-not-`NotExplicit`. `version` follows the
string attributes of `release_metadata`: non-empty, byte-bounded (300),
stored exactly as given. Their one-field-per-attribute layout is replaced by
the shared record, their error codes are renumbered, and a final genre
removal no longer cascades a Cleared event. Deliberately not carried over,
so that no function derivable from the others is permanent surface on a
package that is never upgraded: `recording_language::set_instrumental` and
`is_instrumental`, and `recording_advisory::name`. This design and its
conventions are shared with `composition_metadata` and `release_metadata`.

## Dependency provenance

`Move.toml` pins `musicos` at `676dbd801583761b7e5ab53b4476e8606a12a8d7`,
`genre` at `268d4bc45eecdaf7b75dc443e4974b9469912513` and `language_code` at
`61542357f3d2ff989d120185046def7cf6c8bdcb`, all as exact Git revisions with
no local-path dependency. The generated Testnet and Mainnet lock graphs
resolve `bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` and `share` at
`6ac1dbf022e74957c5ec15ecf95890e28889cd62` through `musicos`, with no
duplicate package aliases.

The pinned core is the first with a single-parameter
`Recording<RecordingShare>`: the `CompositionShare` phantom was dropped from
the object, the cap and `RecordingPublishedEvent`, and the composition link is
the embedded `composition_id`. This package therefore takes one type
parameter everywhere and its events are phantom-typed by `RecordingShare`
alone; the superseded packages' second phantom dimension has no counterpart
and nothing here reads `composition_id`.

## Threat model and findings

The relevant threat is an unauthorized change to a recording's descriptive
metadata. Every write takes `&RecordingAdminCap<RecordingShare>` and reaches
the field only through `Recording::uid_mut`, including the silent
absent-clear paths. Authorization is type-only: `uid_mut` ignores the cap
value, so a distinct cap of the same share type is accepted (exercised in
`genre_tests`), while a cap of another share type cannot compile. Production
`recording::new` consumes the share's `TreasuryCap`, so one share type backs
at most one recording; the package inherits that uniqueness argument from
core and adds no cap-id comparison. The cap holder has permanent authority
over every dynamic field on the recording, this package's included; that is
core's documented extension surface, not something this package can or
claims to narrow.

Guard order, one rule for every function: validation that needs only the
argument runs before `uid_mut`; anything that reads stored state runs after
it. `set_version` validates emptiness (41) then the 300-byte bound (42);
`set_languages` validates the count (22) then duplicates (23); both before
authorization. `add_genre` authorizes, then rejects a duplicate (13) before
capacity (12, at 6); `remove_genre` authorizes, then reports a missing list
or member (14). Every `clear_*` authorizes before the existence check; an
authorized clear of nothing — record absent, or present for another
attribute — is a silent no-op. Every `set_*` likewise authorizes before
comparing with the stored value; setting the value already attached is a
silent no-op — no write, no event — and, since only an attached value can be
equalled, a no-op never creates the record.

Schema integrity: `ExtensionKey`, `RecordingMetadata` and the enum's
variants can be constructed only inside the module and the record's fields
are private, so no other extension can read, collide with or overwrite this
field, and no write to one attribute can reach another. Unrelated dynamic
fields on the same recording are untouched by the record's creation and
removal. The genre list admits only ids proven by a `&Genre` from the
shared, name-derived, frozen vocabulary; the language list admits only
`LanguageCode` values that `language_code::new` validated; the advisory is a
closed enum; the version is a `std::string::String`, valid UTF-8 by
construction, checked for emptiness and the byte bound. Absence is a distinct
state and is never read as a default value: `languages`, `advisory` and
`version` abort when nothing is attached, and `genres` returns an empty
vector for both an absent record and an empty list, which are the same
claim.

Bounds: six genres, ten languages, 300 version bytes, one enum. No path
allocates proportionally to caller input beyond those bounds. The record is
taken out with `df::remove` and destructured; no value is left orphaned
under a key.

No economic, custody, Vault, Action or Plugin surface exists. The package
moves no funds and holds no objects.

## Events

Nine events, phantom-typed by `RecordingShare`, emitted only after their
dynamic-field mutation succeeds. Payloads follow the pinned core's rule — a
field is carried only if an event-only indexer would otherwise need an
object lookup for it: `recording_id` on every event, plus the value now
attached on a set (the `vector<LanguageCode>`, the `Advisory` itself,
the version `String`) and the `genre_id` on genre add and remove. Dropped
from the superseded packages' payloads as derivable: the admin cap id
(derived address under `RecordingAdminCapKey`), the composition id
(`RecordingPublishedEvent`), prior values, counts and presence flags (the
indexer's own state after the previous event), the bounds (constants), the
genre name (`genre::GenreCreatedEvent`), the genre index and primary
transitions (append position and survivor order), and the cascaded Cleared
event after a last removal (one transition, one Removed event). Set events
fire only when the value changes — an equal set is a no-op and emits nothing;
clear events fire only on an actual removal; views and constructors are
silent. A `LanguageCode` serialises as its
two-byte code and the enum as its one-byte variant index (`Explicit = 0`,
`NotExplicit = 1`, `Cleaned = 2`), so the wire sizes are unchanged from the
superseded packages: genre Added/Removed 64, languages set `33 + 3n` (at most
63), advisory set 33, version set `32 + ULEB128(n) + n` (at most 334), every
Cleared 32.

## Evidence

With Sui `1.79.0`, strict Testnet and Mainnet builds
(`--lint --warnings-are-errors`) pass with zero warnings, and the suite
passes on each network:

```
Test result: OK. Total tests: 76; passed: 76; failed: 0
```

`sui move coverage summary` reports 100.00% for the production module.
Tests cover, per attribute: the published/shared-object lifecycle across
admin and stranger transactions; set, replace, silent equal set (no event,
record and value unchanged, never a record created, an equal instrumental
claim included), clear and absent clear; every abort in its documented order,
including validation of a replacement while a value is attached; the inclusive bounds (six
genres including a 64-byte-named entry, ten languages, 300 version bytes as
ASCII and as 150 two-byte characters, with 301 bytes and 151 two-byte
characters rejected); absence versus empty for languages and empty-list
semantics for genres; per-recording and per-share-type isolation of both
state and event streams; exact BCS payloads and sizes; and event-only replay
of the genre and language streams against the permissionless views. The
record-lifecycle tests prove it absent before any write, created by the
first write of any attribute (an instrumental claim included), kept while
any attribute is set, removed by the clear or removal that empties it,
recreated by a later write; that clearing one attribute preserves the
others; that clearing an unset attribute while others are set is silent;
and that an unrelated dynamic field survives. A package-level scenario sets
all four attributes on one published recording, clears or replaces each in
turn to show the attributes and event families are independent, and
withdraws the last of them to show the record leaves the shared object.

Validation is local; no Mainnet deployment, gas measurement or client
integration was performed.
