# Security review — `composition_metadata`

Reviewed 2026-09-24 for immutable publication. Verdict: no exploitable
findings in the reviewed source. This package is unpublished: there is no
`Published.toml`, no Mainnet or Testnet identity, and no deployment record.

## Reviewed surface

One module, `composition_metadata::composition_metadata`, with four public
functions: `set_title`, `clear_title`, and the permissionless views
`has_title` and `title`. The stored value is one dynamic field under the
module-owned `ExtensionKey()`, holding a `CompositionMetadata { title:
Option<String> }` record with only the `store` ability. The record is created
by the first write and removed, by destructuring, by the clear that empties
it; with the title as its only attribute, the record is attached exactly when
a title is.

This design — one key, one record whose fields are the attributes — is shared
with `recording_metadata` and `release_metadata`, as are the guard order,
event shapes, error-code scheme and naming.

## Dependency provenance

`Move.toml` pins `musicos` at
`676dbd801583761b7e5ab53b4476e8606a12a8d7`. The composition title was removed
from core at `8c3fd65f733d640c2b72c3a63b0a14f3953f396e`, whose commit designates
this package as the title's new home. Both network lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` and `share` at
`6ac1dbf022e74957c5ec15ecf95890e28889cd62` without duplicate aliases. There
is no local path dependency.

## Threat model and findings

Set and clear require the composition core's cap-gated `uid_mut`, including
the empty clear path. `set_title` validates emptiness (11), then the 300-byte
maximum (12), before cap authorization, so an invalid value reports its own
code whatever cap is supplied; `clear_title` authorizes before it checks
existence. The value is a bounded, non-empty UTF-8 `String` stored exactly
as supplied; the set event carries the same `String`. The value is
descriptive and has no economic or authorization meaning. No Vault, Action,
or Plugin code is present, and no payments, capability custody, or external
calls occur in the module.

Authorization is type-based: the pinned core matches the cap's
`CompositionShare` to the composition's and does not compare cap IDs at
runtime. Core production construction consumes the share `TreasuryCap`, so
one cap exists per share type; the extension inherits that uniqueness
assumption and adds no cap-ID comparison. The test helper can construct
states not available through production construction (two compositions of
one share type), which the e2e suite uses only to prove field isolation, never
as a wrong-cap case. A wrong-share-type cap is rejected at compile time, which
`tests/check_cap_types.py` demonstrates for both write entry points.

Schema integrity: `ExtensionKey` and `CompositionMetadata` can be constructed
only inside the module, and the record's fields are private, so no other
extension can read, collide with or overwrite this field, and no path leaves
an empty record attached — every write sets an attribute before returning
and the clear takes the record out whole. The admin has permanent authority
over the composition's dynamic fields: the extension does not promise
protection from the core's administrative UID access, and the cap holder can
mutate or delete this field, forever.

Events follow the core's slimmed policy at the pinned revision. A field is
carried only if an event-only indexer would otherwise need a lookup for it:
the composition id and, on set, the attached value. The admin cap id (derived
address under `CompositionAdminCapKey`), the sender (envelope), the share type
(type argument), and prior state (the indexer's previous projection) are
omitted; absent clears and views emit nothing, so every clear event removes
the projected value. An equal set is a no-op — after the cap check it neither
writes nor emits — so every set event is a transition. Because the event no longer
snapshots the prior value, an indexer that joins the stream late must read the
object once; that is the accepted trade of the policy, not a defect.

## Evidence

With `sui 1.79.0`, strict Testnet and Mainnet lint, warnings-as-errors builds,
and tests pass: 27/27 on each network with zero warnings. The production
module reports 100.00% coverage across the pre-publish and post-publish
lifecycle under `sui::test_scenario` (published and shared, cap re-taken
from the sender's inventory, stranger reads across transactions), the
record's lifecycle (absent before any write, created by the first, removed
by the clear that empties it, recreated by a later write, an unrelated
dynamic field untouched throughout), share-type isolation of state and event
streams, validation (empty, 301 bytes, exactly 300 bytes in ASCII and in
three-byte UTF-8), verbatim storage, absence, clearing, silent views and
absent clears, silent equal sets (no event, record and value unchanged, and
never a record created), exact BCS event sizes (334 set, 32 clear), and an
event-only optional projector applied through initial, different and clear
transitions — with an equal set in between that leaves it untouched — and
compared with storage after each.
`python3 tests/check_cap_types.py` confirms that `set_title` and
`clear_title` each reject a cap with a different share type at compile time
(`EC04007`, invalid `cap` argument).

Validation is local; no Mainnet build against a published dependency graph,
live gas measurement, or deployment was performed.
