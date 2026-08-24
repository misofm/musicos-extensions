# Security Audit — `recording_master_reference`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pins: `miso` @ `c23fe7f…` (bumped 2026-08-23 from `7c13e40a…`, carrying the `miso_share` treasury-cap hardening `d67ff8c`), `ori` @ `8a4dbb5f…` (`Move.toml`); audited
dependency sources are the on-disk `../../protocol` tree and the pinned `ori`
checkout. **Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

Audit of `recording_master_reference` (135 LOC,
`sources/recording_master_reference.move`), the holdover extension pointing a
recording at its master audio blob on Walrus. Verdict: **safe to publish — no
findings.**

## What it does

One dynamic field under `ExtensionKey()`
(`recording_master_reference.move:49`) holding a bare `WalrusData` blob
reference. `set_master_reference` upserts, rejecting quilt patches via
`assert_is_blob` (`recording_master_reference.move:77-91`);
`unset_master_reference` removes idempotently
(`recording_master_reference.move:98-108`); views are permissionless. The
module doc is explicit that this is a holdover until Nautilus-attested
ingestion lands (`recording_master_reference.move:20-29`).

## Threat model

This pointer decides *what audio clients play for the recording*, so
unauthorized replacement is the highest-impact metadata attack in the
extension set short of credits. It fails on the authorization chain:

- Both mutators call `self.uid_mut(cap)` before any field access
  (`recording_master_reference.move:84,103`).
  `miso::recording::uid_mut` (`protocol/sources/recording.move:306-311`)
  demands the `RecordingAdminCap<RecordingShare>` matching the recording's
  phantom — sound because one recording exists per share type (treasury cap
  consumed by `share::initialize`) and one cap per recording (derived
  `claim`, `recording.move:217-219`). No cap, no repointing of the master.
- The value is a pure `WalrusData` reference — it cannot *be* audio, only
  point at it; the extension asserts standalone-blob shape (verified in the
  pinned `ori` source: `assert_is_blob` is a variant check). Existence and
  content of the blob are client-side concerns by explicit design.
- Encrypted blobs are accepted deliberately
  (`recording_master_reference.move:75-76`) — the reference is identical
  either way; decryption is gated by the Seal policy package, not here.
- `unset` cap-gates before the existence check — a wrong cap aborts even with
  nothing attached (`recording_master_reference.move:103-106`).
- No loops, arithmetic, caps, or coins.

## Findings

None. Design note (not a vulnerability):

- **N1 (Informational): the master pointer is permanently admin-mutable.** A
  recording's admin can repoint or remove the master at any time, before or
  after publish (`uid_mut` works in any lifecycle state —
  `recording.move:300-311`). That is the protocol's documented extension
  trust model, and every change emits `MasterReferenceSet/UnsetEvent`
  carrying the new/old reference, so indexers and users can observe
  repointing. Until the attested-ingestion path lands, "the master" is only as
  stable as the cap holder.
  **Disposition (2026-08-24):** accepted-by-design — the protocol extension
  trust model leaves the pointer admin-mutable; every change emits an event.

## Edge cases verified

- Quilt patch rejected (`ENotBlob` via `assert_is_blob`,
  `recording_master_reference.move:82`).
- Replace-over-existing overwrites in place (`*df::borrow_mut = reference`).
- `unset` after `unset` is a silent no-op; `unset` on migration leaves no
  trace for the attested path (test
  `unset_leaves_no_trace_for_the_attested_path`).
- `master_reference()` aborts `ENoMasterReference` when unattached;
  `has_master_reference` is the safe probe.

## Verification

- **13/13 tests pass** (`sui move test`, sui 1.77.2), including e2e tests on
  shared published recordings.
- Full source read; `assert_is_blob` semantics verified in the pinned `ori`
  source; auth contract cross-checked against `miso::recording::uid_mut`.
