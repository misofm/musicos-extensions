# Security Audit — `release_kind`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pin: `miso` @ `7c13e40a…` (`Move.toml`); audited dependency source is the
on-disk `../../protocol` working tree. **Date:** 2026-08-23 · **Toolchain:**
sui 1.77.2-51d177ad7d65

Audit of `release_kind` (121 LOC, `sources/release_kind.move`), the extension
storing what a release calls itself ("Album", "EP", …) as a bounded free
string. Verdict: **safe to publish — no findings.**

## What it does

One dynamic field under `ExtensionKey()` (`release_kind.move:53`) holding a
`String` (non-empty, ≤ 32 bytes — `release_kind.move:77-79`). `set_kind`
upserts (`release_kind.move:76-89`), `unset_kind` removes idempotently
(`release_kind.move:93-100`); views are permissionless.

## Threat model

The threat is unauthorized set/clear on someone else's release (metadata
integrity). It fails on the authorization chain:

- Both mutators call `self.uid_mut(cap)` before any field access
  (`release_kind.move:82,95`). `miso::release::uid_mut`
  (`protocol/sources/release.move:337-340`) enforces `cap.release_id ==
  object::id(self)` via `authorize` (`release.move:303-305`) — ID-level
  binding.
- `unset_kind` cap-gates before the existence check — a wrong cap aborts even
  when nothing is attached (`release_kind.move:95-98`).
- Validation (non-empty, ≤ 32 bytes) runs before the gate but touches no
  state (`release_kind.move:77-79`).
- `ExtensionKey()` is module-local; value is a plain `String`; `df::add`
  aborts on re-add; replace path overwrites in place.
- DoS: 32-byte ceiling on a shared object; writer-paid. No loops.

## Findings

None.

## Edge cases verified

- Empty kind aborts `EEmptyKind` — "attached" always means an assertion;
  33-byte kind aborts `EKindTooLong`.
- `unset` on an unattached release is a silent no-op (test
  `unset_emits_only_when_something_was_removed`); `kind()` aborts `ENoKind`
  when unattached (`release_kind.move:110-113`).
- Case is stored exactly as given by design ("EP" ≠ "ep") — documented as a
  client-normalization concern (`release_kind.move:24-26`), not a protocol
  bug.
- Events carry the full kind string on set (`release_kind.move:88`).

## Verification

- **14/14 tests pass** (`sui move test`, sui 1.77.2), including e2e tests on
  shared published releases.
- Full source read; auth contract cross-checked against
  `miso::release::uid_mut`/`authorize`.
