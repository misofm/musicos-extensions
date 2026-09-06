# Security review — `recording_streaming_transcode`

Reviewed 2026-09-03. Verdict: no exploitable findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`22e247741581df95ec02f61b5e795dc44c31b9fb` and `ori` at
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
perform those checks before attaching the reference.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict lint and warnings-as-errors builds pass
for Testnet and Mainnet. All 7 tests pass in both environments, covering set,
replacement, idempotent unset, absent reads, wrapper construction and access,
full `u256` preservation, per-Recording isolation, exact event payloads,
permissionless reads, and the published shared-Recording lifecycle.
Production-module coverage is 100.00%.
