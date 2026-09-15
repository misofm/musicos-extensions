# `recording_engine_session`

`recording_engine_session` attaches one Miso Engine Session V1 document and
its ordered stem references to a musicos `Recording`. Session and stems are
represented by bare Walrus blob IDs and are replaced atomically. Stems must
contain 32-byte digests in strict lexicographic order. There is no finite
stem-count cap.

## Events

Set carries recording/composition/admin-cap IDs, prior presence and change flags, previous/current session blob IDs, and previous/current stem counts (178 BCS bytes). Unset carries the three IDs plus removed session blob ID and stem count (136 bytes). Stem digest/blob arrays stay in storage and can be fetched with the session. Event size is independent of the number of stems. Equal replacement and absent unset remain silent.

See [the repository payload inventory](../EVENT_PAYLOADS.md) for byte bounds and retained context.

## Entry points

- `new_stem` creates a digest/blob-ID pair and rejects invalid digests.
- `new` creates a session from a blob ID and rejects unsorted stems.
- `set_engine_session` inserts or replaces the session through the recording's
  `RecordingAdminCap` type parameter.
- `unset_engine_session` removes the session if present; repeated absent
  calls do nothing.
- `has_engine_session`, `engine_session`, `blob_id`, `stems`, `stem_digest`, and
  `stem_blob_id` are permissionless views.

## Dependencies

- `musicos` supplies the generic `Recording` and `RecordingAdminCap`.
