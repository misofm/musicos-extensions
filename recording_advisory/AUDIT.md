# Security Audit — `recording_advisory`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pin: `miso` @ `7c13e40a…` (`Move.toml`); audited dependency source is the
on-disk `../../protocol` working tree. **Date:** 2026-08-23 · **Toolchain:**
sui 1.77.2-51d177ad7d65

Audit of `recording_advisory` (162 LOC,
`sources/recording_advisory.move`), the parental-advisory extension storing an
`ExplicitRating` per recording. Verdict: **safe to publish — no findings.**

## What it does

One dynamic field under `ExtensionKey()` (`recording_advisory.move:40`)
holding an `ExplicitRating` (`Explicit` / `NotExplicit` / `Cleaned`,
`recording_advisory.move:45-52`). `set_rating` upserts
(`recording_advisory.move:81-94`), `unset_rating` removes idempotently
(`recording_advisory.move:98-108`); views are permissionless.

## Threat model

The only threat worth modeling is an unauthorized party setting/clearing a
rating on someone else's recording (metadata integrity; storefronts act on
this). It fails on the authorization chain:

- Both mutators call `self.uid_mut(cap)` *before* any dynamic-field access
  (`recording_advisory.move:87,103`). `miso::recording::uid_mut`
  (`protocol/sources/recording.move:306-311`) demands a
  `&RecordingAdminCap<RecordingShare>` whose phantom matches the recording.
  Type-level binding is sound: one recording per share type (the treasury cap
  is consumed by `share::initialize` at creation) and one cap per recording
  (derived `claim`, `recording.move:217-219`). No cap, no write — in any
  lifecycle state.
- `ExtensionKey()` is module-local — no cross-package key confusion; the value
  is a closed enum, so nothing malformed can be stored.
- `unset_rating` is a genuine no-op (no event) when nothing is attached, and
  the cap gate fires before the existence check on every path — a wrong cap
  aborts even against an unattached recording
  (`recording_advisory.move:103-107`).
- No loops, no arithmetic, no caps or coins — no DoS or value surface.

## Findings

None.

## Edge cases verified

- Set → replace → unset lifecycle, including replace-over-existing
  (`*df::borrow_mut = rating` path, `recording_advisory.move:88-89`).
- `unset` on an unattached recording emits nothing (test
  `unset_emits_only_when_something_was_removed`).
- `rating()` aborts `ENoRating` when unattached rather than silently reading
  absence as `NotExplicit` (`recording_advisory.move:122-127`) — the
  three-state distinction (unrated / never-explicit / cleaned) is preserved.
- Events carry the rating on set and the recording id on unset
  (`recording_advisory.move:93,106`).

## Verification

- **10/10 tests pass** (`sui move test`, sui 1.77.2), including e2e tests on
  shared published recordings.
- Full source read; auth contract cross-checked against
  `miso::recording::uid_mut`.
