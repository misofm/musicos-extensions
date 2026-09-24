# Historical security review — `recording_master_reference`

> Superseded on 2026-09-14 by `recording_master`. The new package stores
> `audio::audio::Audio` with a bare `u256` Walrus blob ID and emits the complete
> audio value. The report below describes the previous blob-only package and is
> not an audit of the replacement. Publication records are retained as provenance.

# Security review — `recording_master_reference`

Reviewed 2026-09-11 for primitive master-reference transition events. Verdict:
no exploitable findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840` and `ori` at
`367ed5fe92a8b62da02c1116537cf08d111e0789`. Both lock graphs resolve `bps` at
`4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

Writes require the existing `RecordingAdminCap` API and its type-only
`uid_mut` behavior; the event carries no cap field. The extension accepts
`WalrusBlob` references, including encrypted blobs; incompatible quilt and
quilt-patch types cannot reach its API. It attests only to the Recording
administrator's chosen pointer; it cannot prove off-chain blob availability,
authenticity, decoding, or key delivery. Encrypted mutations hash the sealed
DEK on-chain, so gas grows with input length; only its length and digest enter
the event, never the raw sealed-DEK bytes. The existing WalrusBlob view still
exposes those bytes, so event omission is not a privacy boundary. It contains
no funds or custody logic.

## Evidence

With Sui `1.79.0`, strict Testnet and Mainnet warnings-as-errors builds and
tests pass 14/14 tests covering plaintext/encrypted transition replay,
replacement/clear, shared-object flow, phantom isolation, exact BCS fields,
minimum/large sealed-DEK boundaries, and event silence. Production coverage is
100.00%.

## 2026-09-24 — regeneration against musicos `6dff4de`

Re-reviewed for republication against `musicos` at
`6dff4deca5ced186989c064e152c92a06384750c`, where `Recording` takes a single
`RecordingShare` parameter and `publish` no longer takes a Clock. `audio`
stays at `f8dec25997691a9604f568fda6c4515c98299e70`; both lock graphs now
resolve `musicos` at `6dff4de` and `share` at `6ac1dbf`. Verdict: no
exploitable findings.

Changes in this generation:

- `unset_master` → `clear_master`; every signature drops the
  `CompositionShare` parameter.
- Events renamed `Master{Set,Unset}Event<RecordingShare, CompositionShare>`
  → `RecordingMaster{Set,Cleared}Event<RecordingShare>`; `recording_id` is
  now an `address` (was `ID`, same 32 bytes). The set event still carries the
  complete `Audio` — bounded technical metadata plus a blob ID — so payloads
  are unchanged at 112 + format length (128 maximum) and 32.
- An equal set now neither writes nor emits; previously it rewrote the field
  silently. Absent clears remain silent.
- Guard order is cap check then stored-state comparison; beyond what
  `audio::new` already enforces, the function takes no validatable argument.

Storage key, value type, authorization, and the self-attested (unverified)
trust model are unchanged.

Evidence: with Sui `1.79.0`, strict Testnet and Mainnet lint and
warnings-as-errors builds pass clean and all 12 tests pass on each network
(previously 11); the production module reports 100.00% coverage, including
the 128-byte format ceiling and both no-op paths.
