# `recording_engine_session`

`recording_engine_session` attaches one Miso Engine Session V1 document and
its ordered stem references to a musicos `Recording`. The dynamic-field value
and all existing constructors, views, and cap-gated mutation APIs are
unchanged: session and stems are replaced atomically, stems must contain
32-byte digests in strict lexicographic order, and encrypted blobs are
rejected. There is no finite stem-count cap.

## Mutation events

`set_engine_session` emits one
`EngineSessionSetEvent<RecordingShare, CompositionShare>` after the dynamic
field write. Its fields are declared in this exact order:

```text
recording_id: address
composition_id: address
admin_cap_id: address
had_previous: bool
value_changed: bool
previous_session_blob_id: u256
previous_stem_count: u64
session_blob_id: u256
stem_count: u64
stem_digests: vector<vector<u8>>
stem_blob_ids: vector<u256>
```

An insertion uses two zero scalar sentinels (`previous_session_blob_id` and
`previous_stem_count`) for the absent previous value; it has no previous stem
vectors, and sets `had_previous = false`, `value_changed = true`. A replacement
snapshots only the prior session blob ID and stem count, then compares the full
session (session blob, ordered digests, and aligned stem blob IDs); an exactly
equal replacement has `value_changed = false`. The current digest and blob-ID
vectors preserve stored order and remain positionally aligned.

`unset_engine_session` emits one
`EngineSessionUnsetEvent<RecordingShare, CompositionShare>` only when a value
was present, after removal. Its fields are declared in this exact order:

```text
recording_id: address
composition_id: address
admin_cap_id: address
removed_session_blob_id: u256
removed_stem_count: u64
removed_stem_digests: vector<vector<u8>>
removed_stem_blob_ids: vector<u256>
```

An absent unset is silent. Both events carry the actual recording,
composition, and admin-cap IDs; `uid_mut` remains type-only and does not
authenticate a cap value.

Current and removed stem snapshots are unbounded in count, so their event
payloads grow linearly with the number of stems. The previous set snapshot is
only the two scalar fields described above.

For `n` stems, BCS sizes are:

- Set: `178 + 2 * ULEB128(n) + 65n` bytes — 180 at `n = 0`, 245 at `n = 1`,
  8435 at `n = 127`, and 8502 at `n = 128`.
- Unset: `136 + 2 * ULEB128(n) + 65n` bytes — 138 at `n = 0`, 203 at `n = 1`,
  8393 at `n = 127`, and 8460 at `n = 128`.

## Entry points

- `new_stem` creates a digest/blob pair and rejects invalid or encrypted data.
- `new` creates a session and rejects encrypted sessions or unsorted stems.
- `set_engine_session` inserts or replaces the session through the recording's
  `RecordingAdminCap` type parameter.
- `unset_engine_session` removes the session if present; repeated absent
  calls do nothing.
- `has_engine_session`, `engine_session`, `data`, `stems`, `stem_digest`, and
  `stem_data` are permissionless views.

## Dependencies

- `musicos` supplies the generic `Recording` and `RecordingAdminCap`.
- `ori` supplies `WalrusBlob` and confidentiality metadata.
