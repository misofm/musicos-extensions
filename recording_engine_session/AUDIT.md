> Historical audit below predates the 2026-09-15 payload revision. Current event contracts and size bounds are documented in [EVENT_PAYLOADS.md](../EVENT_PAYLOADS.md). Storage, authority, and mutation behavior remain unchanged.

# Security review — `recording_engine_session`

Reviewed 2026-09-15 for rich primitive session mutation events and bare blob-ID
references. Verdict: no exploitable findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`e56c4cbc0d9673f6422e365364b128d0813341ac`. The Testnet and Mainnet lock
graphs pin the Git source to an exact 40-character commit.

## Threat model and findings

Only the matching `RecordingAdminCap` type can set, replace, or unset the
module-keyed engine session reference. The stored `EngineSession` carries one
bare blob ID for the Session V1 document plus a vector of `Stem` values, each
pairing a 32-byte canonical PCM digest with its own blob ID. Constructors reject
digests that are not exactly 32 bytes and stem vectors that are not in strictly
increasing digest order (which also rejects duplicates), so a stored value has
one canonical form.
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
and Mainnet: 25/25 tests. Coverage includes complete primitive snapshots for
insert, equal replacement, session/stem digest/blob changes, latest-value
unset, zero and maximum `u256`, repeated stem blob IDs, independent phantom
event streams, type-only cap behavior, constructor validation precedence, and the
0/1/127/128 stem BCS boundaries. Constructor validation precedence is covered;
production-module coverage is 100.00%.

## 2026-09-24 — regeneration against musicos `6dff4de`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c`, where `Recording` takes a single
`RecordingShare` parameter and `publish` no longer takes a Clock. Both lock
graphs now resolve `musicos` at `6dff4de` and `share` at `6ac1dbf`. Verdict:
no exploitable findings.

Changes in this generation:

- Errors are numeric `u64` constants: `ENoEngineSession` = 1,
  `EInvalidStemDigest` = 2, `EUnsortedStems` = 3 (previously `#[error]`
  byte strings).
- `unset_engine_session` → `clear_engine_session`; every signature drops the
  `CompositionShare` parameter.
- Events renamed `EngineSession{Set,Unset}Event<RecordingShare,
  CompositionShare>` → `RecordingEngineSession{Set,Cleared}Event<RecordingShare>`
  and slimmed to the recording address plus, on set, the session blob ID
  (64 and 32 BCS bytes, down from 178 and 136). Dropped: composition id
  (joinable via `RecordingPublishedEvent`), admin cap address, the
  `had_previous`/`value_changed` flags, the previous session blob ID, and
  the previous/current/removed stem counts. The stem list stays excluded as
  unbounded content; a set event whose blob ID is unchanged signals a stem
  change and the indexer re-reads the recording.
- An equal set now neither writes nor emits; previously it rewrote the field
  silently. Absent clears remain silent.
- Guard order: constructor argument validation (`new_stem`, `new`) → cap
  check → stored-state comparison.

Storage key, value type, constructor validation, canonical stem ordering, and
authorization are unchanged.

Evidence: with Sui `1.79.0`, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean and all 25 tests pass on each network
(count unchanged); the production module reports 100.00% coverage, including
the 0/1/127/128-stem size invariance and both no-op paths.

Event `recording_id` fields are typed `ID` rather than `address`, and emit
sites pass the object id directly; BCS layout and sizes are unchanged.
