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
the event, never the raw sealed-DEK bytes. It contains no funds or custody
logic.

## Evidence

With Sui `1.79.0`, strict Testnet and Mainnet warnings-as-errors builds and
tests pass 12/12 tests covering plaintext/encrypted transition replay,
replacement/clear, shared-object flow, phantom isolation, exact BCS fields,
and event silence. Production coverage is 100.00%.
