# `recording_preview`

> A public audio preview clip for a Miso recording — a single Walrus blob reference, stored off the frozen protocol core.

**Attaches to:** `Recording` (Miso core) as a dynamic field on its `&mut UID`, reached through the recording's cap-gated `uid_mut`.

A preview is a short teaser clip (e.g. 30 seconds of AAC) that anyone may stream without holding rights to the full master. V1 is deliberately minimal: the recording carries a bare `ori::data::WalrusBlob` reference under a single `ExtensionKey()` — no ingestion or attestation ties the preview to the recording's master, and the clip's codec, duration, and offset are client-side convention rather than protocol state. An attested preview standard can ship later as its own extension without touching this one.

All writes are gated by the `RecordingAdminCap`; views are permissionless. The reference is a standalone blob by type and may be encrypted or unencrypted.

## Entry points

- **`recording_preview::set_preview`** — cap-gated; sets or replaces the recording's preview blob reference.
- **`recording_preview::unset_preview`** — cap-gated; removes the preview if present (idempotent).

## Views

- **`recording_preview::has_preview`** — whether a preview is attached to the recording.
- **`recording_preview::preview`** — borrows the preview's `WalrusBlob`; aborts if none is attached.

## Dependencies

- **`miso`** — core protocol; provides `Recording` and its admin cap + `uid_mut`/`uid` accessors.
- **`ori`** — the `WalrusBlob` external-storage reference type and confidentiality metadata.

## Build & test

```sh
sui move build
sui move test
```
