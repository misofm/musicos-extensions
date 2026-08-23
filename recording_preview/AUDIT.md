# Security Audit — `recording_preview`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pins: `miso` @ `7c13e40a…`, `ori` @ `8a4dbb5f…` (`Move.toml`); audited
dependency sources are the on-disk `../../protocol` tree and the pinned `ori`
checkout. **Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

Audit of `recording_preview` (103 LOC, `sources/recording_preview.move`), the
extension pointing a recording at a public teaser clip on Walrus. Verdict:
**safe to publish — no findings.**

## What it does

One dynamic field under `ExtensionKey()` (`recording_preview.move:28`) holding
a bare `WalrusData` blob reference. `set_preview` upserts, rejecting quilt
patches via `assert_is_blob` (`recording_preview.move:49-63`);
`unset_preview` removes idempotently (`recording_preview.move:66-76`); views
are permissionless.

## Threat model

The only threat is unauthorized set/clear of the preview on someone else's
recording (metadata integrity). It fails on the authorization chain:

- Both mutators call `self.uid_mut(cap)` before any field access
  (`recording_preview.move:56,71`). `miso::recording::uid_mut`
  (`protocol/sources/recording.move:306-311`) demands the
  `RecordingAdminCap<RecordingShare>` matching the recording's phantom —
  sound because one recording exists per share type (treasury cap consumed by
  `share::initialize` at creation) and one cap per recording (derived
  `claim`, `recording.move:217-219`).
- The value is a pure `WalrusData` reference with blob shape enforced
  (verified in the pinned `ori` source: `assert_is_blob` is a variant check);
  what the blob contains is client-side convention by design
  (`recording_preview.move:8-12`).
- `unset` cap-gates before the existence check — a wrong cap aborts even with
  nothing attached (`recording_preview.move:71-74`).
- No loops, arithmetic, caps, or coins.

## Findings

None.

## Edge cases verified

- Quilt patch rejected (`ENotBlob`); replace-over-existing overwrites in
  place.
- `unset` on a shared recording with no preview is a silent no-op (e2e test
  `unset_on_a_shared_recording_without_a_preview_is_silent`).
- `preview()` aborts `ENoPreview` when unattached; `has_preview` is the safe
  probe.
- `PreviewUnsetEvent` omits the removed reference deliberately — recoverable
  from the earlier `PreviewSetEvent` (`recording_preview.move:40-43`).

## Verification

- **9/9 tests pass** (`sui move test`, sui 1.77.2), including e2e tests on
  shared published recordings.
- Full source read; auth contract cross-checked against
  `miso::recording::uid_mut`.
