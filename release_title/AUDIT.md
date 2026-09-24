# Security review — `release_title`

Reviewed 2026-09-24 ahead of first publication (unpublished; no
`Published.toml`). Verdict: no exploitable findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at `6dff4deca5ced186989c064e152c92a06384750c`.
Both the default and Mainnet lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` and `share` at
`6ac1dbf022e74957c5ec15ecf95890e28889cd62` without duplicate aliases.

## Threat model and findings

Set and clear require the release core's cap-gated `uid_mut`, including the
absent-clear path. Set validates emptiness (2) and the 300-byte bound (3)
before cap authorization (0), and neither writes nor emits when the stored
value is unchanged. A module-owned key stores one bounded, non-empty UTF-8
`String` exactly as provided. The monomorphic set event carries the release
id and the new title; the cleared event carries the release id. Views do not
emit. The value is descriptive and has no economic or authorization meaning.

## Evidence

With Sui 1.79.0, default and Mainnet builds and tests pass with no warnings:
20/20 on each environment. Tests cover the published/shared lifecycle with
distinct senders, wrong caps on set and on clear (absent and present),
validation-before-authorization precedence, absence, the exact 300-byte and
byte-versus-character bounds, verbatim storage, equal-set silence, silent
views, per-release isolation, and exact event field and BCS layouts including
the 334-byte maximum set event.
