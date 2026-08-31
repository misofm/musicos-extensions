# `recording_engine_session`

Attaches one canonical, plaintext Walrus engine-session reference directly to a
Miso `Recording` through its `RecordingAdminCap`.

The session blob is the root of the delivery graph: it contains mixer metadata,
the encrypted stem blob IDs, and the Seal-wrapped session key. Stem ciphertext
remains off chain. A client can resolve the complete graph with deterministic
object and dynamic-field reads; no indexer-maintained pointer table is required.

Initial attachment and replacement are separate calls. The outer reference must
be a standalone, unencrypted Walrus blob. The audio named inside it may and, for
Record playback, should be encrypted independently.
