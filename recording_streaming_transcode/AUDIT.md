# Security review — `recording_streaming_transcode`

Reviewed 2026-09-11. Verdict: no exploitable findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840` and `ori` at
`367ed5fe92a8b62da02c1116537cf08d111e0789`. The Testnet and Mainnet lock
graphs resolve one copy of each dependency and pin every Git source to an exact
40-character commit.

## Threat model and findings

Only the matching `RecordingAdminCap` type can set, replace, or unset the
module-keyed streaming transcode reference. The stored `StreamingTranscode`
wraps exactly one `ori::data::WalrusQuilt`; standalone blobs and individual
Quilt patches cannot reach the API. The module stores one reference per
Recording, leaves unrelated dynamic fields untouched, and emits primitive
Recording/composition/cap addresses, presence, and previous/current Quilt IDs
on each value-changing set or replacement. An equal replacement writes silently.
An absent unset is an idempotent no-op and emits
no misleading event.

The extension records the Recording administrator's assertion. Its set event
contains the primitive payload `(recording_id, composition_id, admin_cap_id,
had_transcode, previous_quilt_id, quilt_id)`: three addresses, presence, and
the previous/current `u256` Quilt IDs. It cannot prove that the Quilt is stored
or retrievable, that its patches satisfy the streaming package contract, or
that a client can decode them. Publication tooling must perform those checks
before attaching the reference. Both phantom parameters are part of event type
identity, so set and clear queries for independent Recording/Composition pairs
do not collide.

## Evidence

With the available Sui toolchain, strict lint and warnings-as-errors builds pass
for Testnet and Mainnet. All 7 tests pass in both environments, covering set,
replacement including equal assignment, idempotent unset, absent reads, wrapper
construction and access, zero/large/max `u256` preservation, per-Recording and
phantom isolation, exact event payloads and BCS replay, the three-set/two-clear
739-byte composition, permissionless reads, and the published shared-Recording
lifecycle. Production-module raw coverage is 100.00%.

## 2026-09-24 — regeneration against musicos `6dff4de`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c`, where `Recording` takes a single
`RecordingShare` parameter and `publish` no longer takes a Clock. `ori` stays
at `367ed5fe92a8b62da02c1116537cf08d111e0789`; both lock graphs now resolve
`musicos` at `6dff4de` and `share` at `6ac1dbf`. Verdict: no exploitable
findings.

Changes in this generation:

- `ENoStreamingTranscode` is the numeric constant 1 (previously an
  `#[error]` byte string).
- `unset_streaming_transcode` → `clear_streaming_transcode`; every signature
  drops the `CompositionShare` parameter.
- `RecordingStreamingTranscode{Set,Cleared}Event` are now
  `<phantom RecordingShare>` only and slimmed to the recording address plus,
  on set, the Quilt ID (64 and 32 BCS bytes, down from 161 and 128). Dropped:
  composition id (joinable via `RecordingPublishedEvent`), admin cap address,
  `had_transcode`, `previous_quilt_id`, and the removed Quilt ID on clear.
- An equal set now neither writes nor emits; previously it rewrote the field
  silently. Absent clears remain silent.
- Guard order is cap check then stored-state comparison; the function takes
  no validatable argument.

Storage key, value type, the Quilt-only wrapper, and authorization are
unchanged.

Evidence: with Sui `1.79.0`, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean and all 7 tests pass on each network
(count unchanged); the production module reports 100.00% coverage, and the
lifecycle test replays every event into an event-only projection that matches
the views at each step.
