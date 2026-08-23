# Security Audit — `release_description`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pin: `miso` @ `7c13e40a…` (`Move.toml`); audited dependency source is the
on-disk `../../protocol` working tree. **Date:** 2026-08-23 · **Toolchain:**
sui 1.77.2-51d177ad7d65

Audit of `release_description` (142 LOC,
`sources/release_description.move`), the extension storing a release's
free-text description (≤ 8 KB). Verdict: **safe to publish — no findings.**

## What it does

One dynamic field under `ExtensionKey()` (`release_description.move:71`)
holding a `String`. `set_description` validates (non-empty, ≤ 8192 bytes —
`release_description.move:95-97`) then upserts
(`release_description.move:94-107`); `clear_description` removes idempotently
(`release_description.move:111-120`); views are permissionless.

## Threat model

The threat is unauthorized set/clear of the description on someone else's
release (metadata integrity). It fails on the authorization chain:

- Both mutators call `self.uid_mut(cap)` before any field access
  (`release_description.move:100,115`). `miso::release::uid_mut`
  (`protocol/sources/release.move:337-340`) enforces `cap.release_id ==
  object::id(self)` via `authorize` (`release.move:303-305`) — ID-level
  binding; a cap for release A can never touch release B.
- `clear_description` cap-gates *before* the existence check, deliberately
  (`release_description.move:113-115` comment): a wrong cap aborts even when
  nothing is attached. This is the strictest gating discipline in the
  extension set.
- Validation runs before authorization but touches no state
  (`release_description.move:95-97`) — pure input checks.
- `ExtensionKey()` is module-local; the value is a plain `String`; `df::add`
  aborts on re-add, and the upsert uses `*df::borrow_mut = description` for
  the replace path.
- DoS: the 8 KB ceiling bounds storage on the shared object
  (`release_description.move:52`); writer-paid gas. Empty string is rejected
  so "attached" always means "someone wrote something"
  (`release_description.move:96`).

## Findings

None.

## Edge cases verified

- Empty description aborts `EEmptyDescription`; 8193-byte description aborts
  `EMaxDescriptionLengthExceeded`.
- Replace-over-existing overwrites in place; `clear` on an unattached release
  is a silent no-op; `description()` aborts `ENoDescription` when unattached —
  absence never collapses into an empty string
  (`release_description.move:131-134`).
- Multi-byte UTF-8 content: the bound is on bytes, and `String` guarantees
  valid UTF-8; a 4-byte-per-char string hits the byte ceiling first — no
  truncation is possible since the string is stored whole or the tx aborts.
- Events carry the full description on set
  (`release_description.move:106`).

## Verification

- **14/14 tests pass** (`sui move test`, sui 1.77.2), including the
  set/read/replace/clear lifecycle and e2e tests on shared published releases.
- Full source read; auth contract cross-checked against
  `miso::release::uid_mut`/`authorize`.
