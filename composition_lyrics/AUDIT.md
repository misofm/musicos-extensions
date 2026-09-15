# Implementation review — composition_lyrics

Reviewed locally on 2026-09-15. This is an implementation review and test record,
not an independent security audit or a publication record.

## Scope and trust model

- `musicos` is pinned to `e56c4cbc0d9673f6422e365364b128d0813341ac`.
- `language_code` is pinned to `61542357f3d2ff989d120185046def7cf6c8bdcb`.
- Set and clear require `CompositionAdminCap<CompositionShare>` and call the
  pinned core's `uid_mut`. Authorization is type-based, including absent clears.
  Core production construction consumes the share TreasuryCap. The extension
  inherits that uniqueness assumption and adds no cap-ID comparison. The test
  helper can construct states not available through production construction.
- The admin has permanent authority over the composition's dynamic fields.
  This module's key cannot be constructed outside its defining module, but
  the extension does not promise protection from the core's administrative UID
  access. Cap addresses in events provide provenance, not another authority check.
- Each `ExtensionKey(LanguageCode)` names one independent byte vector. Replacing
  or clearing it leaves other language entries untouched.
- The 32 KiB limit bounds stored bytes per entry. It does not bound decompressed
  size, verify a frame, or validate lyrics. Empty/malformed payload acceptance
  is intentional. Client decoding must enforce output and memory limits.
- Events contain exact compressed snapshots and explicit prior presence. Equal
  replacements emit; absent clears and views do not emit. Snapshot events add
  storage in transaction history. No payments, blob renewals, capability custody,
  external dictionary, or network calls occur in the module.

## Validation

Using `sui 1.78.1-722ac4fcf484` and the generated Testnet lock graph:

- `sui move build --warnings-are-errors --lint`: passed.
- `sui move test --coverage --warnings-are-errors --lint`: 9/9 passed.
- `sui move coverage summary`: 100.00% module coverage.
- `python3 tests/check_cap_types.py`: set and clear each reject a cap with a
  different share type at compile time (`EC04007`, invalid `cap` argument).

Tests exercise published/shared compositions across senders and transactions,
independent languages, share-type isolation, exact opaque byte preservation,
event payloads for add/different/equal replacement, clear/re-add, empty versus
absent entries, missing reads, and 32,768/32,769-byte boundaries. Full-size
replacement events are exercised as well as full-size storage.

Validation is local; no Mainnet build, live gas measurement, browser decoder
integration, or deployment was performed. No blocking issue was identified in
this module within the inherited core trust model above.
