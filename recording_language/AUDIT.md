# Security Audit — `recording_language`

**Revision:** working tree @ 2026-08-23 (the `misonetwork` workspace is not a
git repository — `git rev-parse` fails; no commit hash exists). Dependency
pins: `miso` @ `7c13e40a…`, `language_code` @ `c5973df8…` (`Move.toml`);
audited dependency source is the on-disk `../../protocol` working tree.
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

Audit of `recording_language` (163 LOC,
`sources/recording_language.move`), the extension storing the sung/spoken
ISO 639-1 languages of a recording. Verdict: **safe to publish — no
findings.**

## What it does

One dynamic field under `ExtensionKey()` (`recording_language.move:52`)
holding a `vector<LanguageCode>` (≤ 10 entries, no duplicates; empty vector ==
assertion of "instrumental"). `set_languages` upserts after validation
(`recording_language.move:74-88`), `set_instrumental` delegates with an empty
vector (`recording_language.move:91-96`), `unset_languages` removes
idempotently (`recording_language.move:100-110`); views are permissionless.

## Threat model

The only threat is unauthorized set/clear on someone else's recording
(metadata integrity). It fails on the authorization chain:

- Both mutators call `self.uid_mut(cap)` before touching the field
  (`recording_language.move:81,105`). `miso::recording::uid_mut`
  (`protocol/sources/recording.move:306-311`) demands the
  `RecordingAdminCap<RecordingShare>` matching the recording's phantom — sound
  because one recording exists per share type (treasury cap consumed at
  creation) and one cap per recording (derived `claim`,
  `recording.move:217-219`).
- Validation order in `set_languages` is input-validation *first*
  (`validate`, `recording_language.move:79`), then the cap gate, then the
  write — no state touched pre-authorization, and an over-limit or duplicate
  input aborts before gas is spent on the field.
- `validate` (`recording_language.move:146-153`) bounds the vector at 10 and
  rejects duplicates via a `VecSet`; each `LanguageCode` is a valid ISO 639-1
  code by construction in the pinned `language_code` package (trusted
  dependency — a value type with its own constructor validation).
- `unset_languages` cap-gates before the existence check — a wrong cap aborts
  even when nothing is attached (`recording_language.move:105-108`).
- No loops over unbounded data (≤ 10 entries), no arithmetic, no coins.

## Findings

None.

## Edge cases verified

- Empty vector is *stored* (instrumental assertion), not rejected —
  `is_instrumental` is `true` only when attached-and-empty, `false` when
  unattached (`recording_language.move:133-140`); the two states never
  collapse.
- Duplicate languages and the 11th language abort
  (`EDuplicateLanguage`/`ETooManyLanguages`).
- The set event re-borrows the stored value
  (`recording_language.move:87`), so the event always matches post-write
  state.
- `unset` on an unattached recording is a silent no-op (test
  `unset_emits_only_when_something_was_removed`); `languages()` aborts
  `ENoLanguages` rather than returning an empty vector for "unattached".

## Verification

- **15/15 tests pass** (`sui move test`, sui 1.77.2), including e2e tests on
  shared published recordings.
- Full source read; auth contract cross-checked against
  `miso::recording::uid_mut`.
