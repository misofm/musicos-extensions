# `recording_master_reference`

`recording_master_reference` stores one `ori::data::WalrusBlob` reference on a
musicos `Recording`. The existing storage and APIs are unchanged: the
reference may be plaintext or encrypted, replacement swaps the whole value,
and clearing an absent value is silent.

## Mutation events

`set_master_reference` emits one
`RecordingMasterReferenceSetEvent<RecordingShare, CompositionShare>` after a
successful write. Its fields are declared in this exact order:

```text
recording_id: address
composition_id: address
had_master_reference: bool
previous_blob_id: u256
previous_is_encrypted: bool
previous_sealed_dek_length: u64
previous_sealed_dek_digest: vector<u8>
blob_id: u256
is_encrypted: bool
sealed_dek_length: u64
sealed_dek_digest: vector<u8>
```

An absent previous side uses `0`, `false`, `0`, and `[]`. Plaintext metadata
uses the same canonical values. Encrypted metadata contains the sealed-DEK
length and its BLAKE2b-256 digest; the sealed-DEK bytes are never emitted.
Equal replacements still emit one event.

`unset_master_reference` emits one
`RecordingMasterReferenceClearedEvent<RecordingShare, CompositionShare>` only
after removing a present value. Its fields are:

```text
recording_id: address
composition_id: address
removed_blob_id: u256
removed_is_encrypted: bool
removed_sealed_dek_length: u64
removed_sealed_dek_digest: vector<u8>
```

The actual recording and composition addresses are carried in both events.
There is no cap field in either event. The mutators retain their existing
cap-gated APIs and `uid_mut` behavior.

## BCS and hashing

With the fields above, the BCS size is `149 + 32 * encrypted_sides` for a Set
event: 149 bytes when both sides are plaintext, 181 bytes when one side is
encrypted, and 213 bytes when both sides are encrypted. A Cleared event is
`106 + 32 * encrypted` bytes: 106 bytes for a plaintext reference and 138
bytes for an encrypted reference. Each encrypted side adds the 32-byte
BLAKE2b-256 digest while retaining its one-byte vector length prefix.

Hashing occurs on-chain for every encrypted mutation, so gas grows with the
sealed-DEK input length. Only its length and digest are stored in the event;
the raw sealed-DEK bytes remain private to the input value.
