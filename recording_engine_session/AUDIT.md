# Security review — `recording_engine_session`

Reviewed 2026-09-11 for rich primitive session mutation events. Verdict: no
exploitable findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840` and `ori` at
`367ed5fe92a8b62da02c1116537cf08d111e0789`. The Testnet and Mainnet lock
graphs resolve one copy of each dependency and pin every Git source to an exact
40-character commit.

## Threat model and findings

Only the matching `RecordingAdminCap` type can set, replace, or unset the
module-keyed engine session reference. The stored `EngineSession` wraps one
`ori::data::WalrusBlob` for the Session V1 document plus a vector of `Stem`
values, each pairing a 32-byte canonical PCM digest with its own unencrypted
`WalrusBlob`. Constructors reject encrypted blobs, digests that are not exactly
32 bytes, and stem vectors that are not in strictly increasing digest order
(which also rejects duplicates), so a stored value has one canonical form.
Session and stems are one value and replace atomically. The module stores one
session per Recording, leaves unrelated dynamic fields untouched, and emits
the recording, composition, and admin-cap addresses. A set event carries only
the previous session blob ID and stem count, while its current snapshot and
an unset event carry the complete ordered stem vectors; those current/removed
snapshots are unbounded and their payloads grow linearly with stem count. An
insertion uses zero values for those two previous fields and no previous stem
vectors. An absent unset is an idempotent no-op and emits no misleading event.

The extension records the Recording administrator's assertion. It cannot prove
that any blob is stored or retrievable, that the session blob is a valid Session
V1 document, that a stem blob decodes to the PCM its digest commits to, or that
the stem digests equal the document's declared sources. Publication tooling must
perform those checks before attaching the reference; the engine re-hashes
decoded PCM on load, so a mismatched stem fails to play rather than playing the
wrong audio.

## Evidence

With Sui `1.79.0`, strict warnings-as-errors builds and tests pass for Testnet
and Mainnet: 27/27 tests. Coverage includes complete primitive snapshots for
insert, equal replacement, session/stem digest/blob changes, latest-value
unset, zero and maximum `u256`, repeated stem blob IDs, independent phantom
event streams, type-only cap behavior, constructor/guard precedence, and the
0/1/127/128 stem BCS boundaries. Production-module coverage is 100.00%.
