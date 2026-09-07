# Security review — `recording_engine_session`

Reviewed 2026-09-07 (stems generation). Verdict: no exploitable findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`22e247741581df95ec02f61b5e795dc44c31b9fb` and `ori` at
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
session per Recording, leaves unrelated dynamic fields untouched, and emits the
Recording ID plus the complete `EngineSession` value on every set or
replacement. An absent unset is an idempotent no-op and emits no misleading
event.

The extension records the Recording administrator's assertion. It cannot prove
that any blob is stored or retrievable, that the session blob is a valid Session
V1 document, that a stem blob decodes to the PCM its digest commits to, or that
the stem digests equal the document's declared sources. Publication tooling must
perform those checks before attaching the reference; the engine re-hashes
decoded PCM on load, so a mismatched stem fails to play rather than playing the
wrong audio.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict lint and warnings-as-errors builds pass
for Testnet and Mainnet. All 16 tests pass, covering set, replacement, idempotent
unset, absent reads, stem construction and access, digest-order storage, atomic
session-plus-stems replacement, encrypted session and stem rejection, short and
long digest rejection, unsorted and duplicate stem rejection including
late-byte ordering, full `u256` preservation, per-Recording isolation, exact
event payloads including stems, permissionless reads, and the published
shared-Recording lifecycle. Production-module coverage is 100.00%.
