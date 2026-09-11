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
Recording, leaves unrelated dynamic fields untouched, and emits the Recording
ID plus complete `StreamingTranscode` value on every set or replacement. An
absent unset is an idempotent no-op and emits no misleading event.

The extension records the Recording administrator's assertion. It cannot prove
that the Quilt is stored or retrievable, that its patches satisfy the streaming
package contract, or that a client can decode them. Publication tooling must
perform those checks before attaching the reference. Both phantom parameters
are part of event type identity, so set and clear queries for independent
Recording/Composition pairs do not collide.

## Evidence

With the available Sui toolchain, strict lint and warnings-as-errors builds pass
for Testnet and Mainnet. All 7 tests pass in both environments, covering set,
replacement including equal assignment, idempotent unset, absent reads, wrapper
construction and access, zero/large/max `u256` preservation, per-Recording and
phantom isolation, exact event payloads and BCS replay, the six-event 900-byte
composition, permissionless reads, and the published shared-Recording
lifecycle. Production-module raw coverage is 100.00%.
