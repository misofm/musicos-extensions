# recording_master

Stores a self-attested `audio::audio::Audio` as a dynamic field on a MusicOS
Recording. `set_master(recording, cap, audio)` sets or replaces the entire value;
`unset_master(recording, cap)` removes it idempotently. Both require the matching
RecordingAdminCap. `has_master(recording)` and `master(recording): &Audio` are
permissionless views. Reading an absent master aborts with `ENoMaster`.

`MasterSetEvent` includes the recording ID and the complete `Audio` value,
including its WalrusBlob and confidentiality metadata. `MasterUnsetEvent` is emitted
only when a stored master is removed. Audio has `copy`, `drop`, and `store`: copying it duplicates metadata and a blob
reference, without duplicating the stored audio bytes.

The PCM digest uses unkeyed BLAKE3 with the default 32-byte output, as specified
by `Audio`. Metadata is caller-supplied and structurally validated by `audio::new`. This does
not verify the blob contents, PCM digest, or availability. Future Nautilus-attested
audio belongs in a separate package.

This replaces the `recording_master_reference` package and its blob-only API.
It uses a new module and dynamic-field key; existing fields do not migrate
automatically. Publish it as a fresh package identity. `Published.toml` retains
the predecessor's deployment history, not a deployment of this implementation.

`audio` is pinned to commit `54d54f6cecdbba39c880c64f2caf8b277d007679`
from `misofm/audio`, which includes the self-attested V1 API and its immutable
Testnet publication.

Run `sui move build --build-env testnet` and `sui move test --build-env testnet`
from this directory (Mainnet can also be selected with `--build-env mainnet`).
