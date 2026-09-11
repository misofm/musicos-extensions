# Security review — `release_genre`

Reviewed 2026-09-11 for immutable publication. The event revision preserves
the stored key/value layout and production API while making every successful
mutation auditable as a bounded, replayable transition.

## Reviewed surface

The public API is four functions: `add_genre`, `remove_genre`,
`clear_genres`, and the permissionless `genres` view. The stored value remains
the package-owned `ExtensionKey` mapped to a bare, ordered `vector<ID>`; index
zero is primary and removing the final entry reclaims the dynamic field.

`add_genre` takes a real `&Genre`, captures its raw `Genre.name()` bytes in the
Added event, and appends only the object id. `remove_genre` retains its original
guard order: missing field or missing member aborts with 42 before cap
authorization; once a member field exists, `uid_mut` enforces the upstream
authorization check. `clear_genres` calls `uid_mut` first, so even an absent
field is authenticated before its silent no-op. The cap check is type-only in
the pinned `musicos` dependency; a runtime cap value or id is not an additional
authorization claim.

## Dependency provenance

`Move.toml` pins `genre` at
`cddf9491426723e2c468cebf40fb4231d9fb0d5a` and `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`. The checked-in `Move.lock`,
`Move.toml`, and `Published.toml` remain byte-identical to the baseline; build
resolution was restored after strict Mainnet verification.

## Events

The three monomorphic event declarations are `ReleaseGenreAddedEvent`,
`ReleaseGenreRemovedEvent`, and `ReleaseGenresClearedEvent`. Their fields are
the exact source declaration order documented in `README.md`: actual release,
cap, and genre addresses; Added's raw UTF-8 name; index; complete before and
after ordered address vectors; counts; field-existence and primary flags; and
primary ids/change flag. Cleared additionally carries `clear_cause` and
`trigger_genre_id`. Cause 0 is explicit clear with an `@0x0` trigger; cause 1
is the final-remove cascade with the removed id.

Every successful add emits exactly one Added event after the field write.
Every successful remove emits Removed before field deletion; a final remove
then emits Cleared with the canonical empty `[] -> []`, `true -> false`
snapshot. Explicit clear removes the field and emits one Cleared event; an
absent explicit clear emits none. Constructors, views, and failed guards are
silent. No owner, timestamp, or full `Genre` object is exposed.

For snapshot lengths `b`, `a`, and Added name length `n`, the exact BCS bounds
are:

* Added: `192 + n + 32*(b+a)`, maximum 608 (`n=64`, `b=5`, `a=6`);
* Removed: `191 + 32*(b+a)`, maximum 543;
* Cleared: `184 + 32*(b+a)`, maximum 376.

The final pair is 223-byte Removed plus 184-byte cascading Cleared. These are
serialized event bounds; vector/name lengths still contribute transaction gas.

## Evidence

With Sui 1.79.0, strict lint and warnings-as-errors Testnet and Mainnet builds
and tests pass 23/23. The Testnet and Mainnet production-module coverage
summaries are both 100.00%. Tests include full field-order BCS decoding with
empty-remainder assertions and event-only replay, exact 64-byte and six-item
bounds, final-removal pair sizes, two-release monomorphic streams, stable
ordering and primary promotion, clear/re-add lifecycle, absent and populated
wrong-cap guard precedence, duplicate-before-capacity behavior, published and
shared Release lifecycle, and no-op/event silence.
