# Security review — `composition_title`

Reviewed 2026-09-24 for immutable publication. Verdict: no exploitable
findings in the reviewed source. This package is unpublished: there is no
`Published.toml`, no Mainnet or Testnet identity, and no deployment record.

## Reviewed surface

One module, `composition_title::composition_title`, with four public
functions: `set_title`, `clear_title`, and the permissionless views
`has_title` and `title`. The stored value is one `String` dynamic field under
the module-owned `ExtensionKey()`, added by the first write and removed by
clear, so "the field is absent" and "no title is attached" are the same fact.

## Dependency provenance

`Move.toml` pins `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c`, the current core, which stores no
title. Both network lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` and `share` at
`6ac1dbf022e74957c5ec15ecf95890e28889cd62` without duplicate aliases. There
is no local path dependency.

## Threat model and findings

Set and clear require the composition core's cap-gated `uid_mut`, including
the empty clear path. `set_title` validates emptiness (2), then the 300-byte
maximum (3), before cap authorization, so an invalid value reports its own
code whatever cap is supplied; `clear_title` authorizes before it checks
existence. The value is a bounded, non-empty UTF-8 `String` stored exactly as
supplied; the set event carries the same `String`. The value is descriptive
and has no economic or authorization meaning. No Vault, Action, or Plugin
code is present, and no payments, capability custody, or external calls occur
in the module.

Authorization is type-based: the pinned core matches the cap's
`CompositionShare` to the composition's and does not compare cap IDs at
runtime. Core production construction consumes the share `TreasuryCap`, so
one cap exists per share type; the extension inherits that uniqueness
assumption and adds no cap-ID comparison. The test helper can construct
states not available through production construction (two compositions of
one share type), which the e2e suite uses only to prove field isolation, never
as a wrong-cap case. A wrong-share-type cap is rejected at compile time, which
`tests/check_cap_types.py` demonstrates for both write entry points.

Schema integrity: `ExtensionKey` can be constructed only inside the module,
so no other extension can read, collide with or overwrite this field through
this API. The admin has permanent authority over the composition's dynamic
fields: the extension does not promise protection from the core's
administrative UID access, and the cap holder can mutate or delete this field,
forever.

Events carry only what an event-only indexer could not derive: the
composition id and, on set, the attached value. The admin cap id (derived
address under `CompositionAdminCapKey`), the sender (envelope), the share type
(type argument), and prior state (the indexer's previous projection) are
omitted. An equal set is a no-op — after the cap check it neither writes nor
emits — and absent clears and views emit nothing, so every event is a
transition. An indexer that joins the stream late must read the object once;
that is the accepted trade of the policy, not a defect.

## Evidence

With `sui 1.79.0`, strict Testnet and Mainnet lint, warnings-as-errors builds,
and tests pass: 24/24 on each network with zero warnings. The production
module reports 100.00% coverage across the pre-publish and post-publish
lifecycle under `sui::test_scenario` (published and shared, cap re-taken from
the sender's inventory, stranger reads across transactions), per-composition
and share-type isolation of state and event streams, an unrelated dynamic
field untouched throughout, validation (empty and 301 bytes on both add and
replace; exactly 300 bytes in ASCII and in three-byte UTF-8; 303 bytes of
three-byte UTF-8 rejected), verbatim storage, absence and clearing, silent
views, absent clears and equal sets, first-set-after-clear emitting again,
exact BCS event sizes (40 and 334 set, 32 clear), and UTF-8 preservation
through events. `python3 tests/check_cap_types.py` confirms that `set_title`
and `clear_title` each reject a cap with a different share type at compile
time (`EC04007`, invalid `cap` argument).

Validation is local; no Mainnet build against a published dependency graph,
live gas measurement, or deployment was performed.
