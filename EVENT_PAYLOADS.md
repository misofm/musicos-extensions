# Event payload inventory — 2026-09-15

All 15 packages and all 41 event types were reviewed. Events preserve useful
business context: object/cap provenance, relationship IDs, ordering, counts,
compact role/language codes, state flags, and bounded media identities. Content
bodies and redundant display snapshots stay in storage and are fetched on demand.
No event type, operation signature, authorization check, storage limit, mutation,
or no-op rule is removed or changed. Recording credit and artist-designation
cascade events remain separate changes with separate emissions.

These are BCS **payload bytes**, excluding transaction/event-envelope overhead;
they are not measured gas savings or claims about network throughput. U(n) below
is the byte length of an unsigned LEB128 vector length. Addresses, IDs, and u256
are 32 bytes; u64 is 8; u32 is 4; u8/bool is 1; vectors add U(n). Phantom type
parameters add no payload bytes.

## Complete inventory

Sizes are source-derived maxima reachable through production operations unless
an explicit formula is given. Unchanged families are included deliberately.

| Package / event family | Before bytes | After bytes | Decision and retained context |
|---|---:|---:|---|
| composition_credits: Added / Removed (2) | 836 / 836 | 128 / 128 | Remove display name and custom labels; retain 5 ordered role tags, IDs, counts, index, field flags. |
| composition_lyrics: Set / Cleared (2) | 65,610 / 32,838 | 68 / 67 | Remove compressed bodies; retain two IDs, two-byte language key, prior presence on set. |
| recording_advisory: Set / Cleared (2) | 99 / 97 | unchanged | Compact rating codes and provenance. |
| recording_credits: CreditAdded / CreditRemoved (2) | 1,549 / 1,550 | 175 / 176 | Remove display/custom/instrument bytes; retain 10 ordered kinds and levels, IDs, index/counts, lifecycle/designation flags. |
| recording_credits: Primary/Featured Added / Removed (4) | 362 / 363 | 160 / 161 | Remove display name only; retain IDs, ordering/counts, cascade cause. |
| recording_engine_session: Set / Unset (2) | 178+2U(n)+65n / 136+2U(n)+65n | 178 / 136 | Unbounded stem arrays removed; retain old/current session blob IDs and stem counts. |
| recording_genre: Added / Removed (2) | 640 / 575 | 221 / 221 | Remove name and full lists; retain changed ID/index, counts, primary/lifecycle metadata. |
| recording_genre: Cleared (1) | 408 | 407 | Keep up to six removed relationship IDs; omit always-empty after list. |
| recording_language: Set / Cleared (2) | 185 / 136 | unchanged | Up to ten two-byte ISO codes are useful bounded classification context. |
| recording_master: MasterSet / MasterUnset (2) | 128 / 32 | unchanged | Audio contains bounded format (16 bytes), PCM parameters, digest32 and blob ID; no audio content. |
| recording_streaming_transcode: Set / Cleared (2) | 161 / 128 | unchanged | Fixed Quilt IDs and provenance. |
| release_cover_art: Album Set / Unset (2) | 374 / 310 | unchanged | Fixed blob IDs, encryption flags, key lengths, digest32; no image/key contents. |
| release_cover_art: Track Set / Unset (2) | 596 / 532 | unchanged | Same bounded context, plus track identity and album fallback. |
| release_credits: Added / Removed (2) | 325 / 325 | 123 / 123 | Remove display name; retain role kind, IDs, counts/index, field flags. |
| release_description: Set / Cleared (2) | 16,453 / 8,258 | 65 / 64 | Remove prose bodies; retain IDs and prior presence. Initial maximum set was 8,260. |
| release_dsp_link: Album Set / Cleared (2) | 599 / 339 | 77 / 77 | Remove native link text; retain platform, identity, count and presence/field flags. |
| release_dsp_link: Track Set / Cleared (2) | 933 / 673 | 150 / 150 | Remove link/album text; retain track index, recording/composition IDs, fallback presence. |
| release_dsp_link: TracksCleared (1) | 85,268 | 84 | Whole release/platform slice invalidation; count and album presence replace bulk slot snapshots. |
| release_genre: Added / Removed (2) | 608 / 543 | 189 / 189 | Same changed-relationship design as recording genre. |
| release_genre: Cleared (1) | 376 | 375 | Keep six removed IDs; omit always-empty after list. |
| release_kind: Set / Unset (2) | 149 / 117 | unchanged | One label capped at 32 bytes is useful bounded classification, including prior value. |

## Derivation and operational limits

- Lyrics: MAX_LYRICS_LENGTH=32,768. Old replacement:
  `64 + 3 + 1 + 2*(3+32768) = 65610`; old clear `64+3+3+32768=32838`.
  New set/clear are `64+3+1=68` and `64+3=67`.
- Description: MAX_DESCRIPTION_LENGTH=8,192. Old maximum replacement:
  `64+1+2*(2+8192)=16453`; new set is `64+1=65`.
- DSP: max native link is two 128-byte fields, each with a two-byte prefix:
  `1+2*(2+128)=261`. Album fixed context is 77; track is 150. A clear's
  absent current field vector was one byte. Whole-slice clear allowed 255 links:
  `84 + (2+8*255) + 2*(2+32*255) + (2+261*255) + 261 = 85268`.
  All new DSP payloads are fixed-size regardless of identifiers or occupied slots.
- Credits: generic credit display name limit is 200 bytes. Composition custom
  labels max 100 bytes × 5; recording role/instrument labels max 100 bytes × 10
  (a role uses either custom-name or instrument content, not both). Recording
  compact payload is `128+2*(1+10)+24+1=175` for add; removal adds one flag.
  Composition is `96+(1+5)+24+2=128`; release is `96+1+24+2=123`.
- Genres: MAX_GENRES=6, genre name limit 64. Add at capacity transition contains
  five before/six after IDs in the old schema; removal six/five. Clear retains
  one vector with at most six addresses (193 bytes). Empty after vector was 1 byte.
- Engine: each old stem contributes digest encoding33 plus blob ID32, with two
  outer prefixes. Stem count has no package limit. At 128 stems old set/unset
  were 8,502/8,460; now 178/136.
- Cover art hashes remain fixed 32 (or empty for plaintext/absent), and master
  Audio format is limited to 16 bytes with a fixed 32 PCM digest. These are
  references and technical metadata, not embedded media bodies.

Genre add/remove deliberately uses ID-only relationship notifications here: canonical
names resolve from frozen genre objects and are repeated across works. The party
genre extension may retain its small bounded canonical label as discovery context;
both designs satisfy the bounded-payload policy.

Consumers cannot reconstruct removed prose, lyrics, names, instruments, custom
role labels, links, or stem lists from the new events. Current values can be
read on demand while present. Genre relationships remain replayable from
changed IDs/indices and clear's removed IDs. DSP clear-all identifies the entire
slice, so clients invalidate it without needing a per-track removal manifest.

## Validation

Existing lifecycle, state, authorization, failure-precedence, no-op, shared-object,
phantom isolation, and cascade tests remain. BCS fixtures now assert the compact
field order. Description and credit maximum-input cases assert their new bounds;
lyrics assertions exercise tiny/empty and maximum bodies with fixed-size events;
engine tests assert the same set/unset size at 0, 1, 127, 128 stems. Genre replay tests
reconstruct lists using changed IDs/indices instead of copied before/after lists.

### Final validation on coordinated dependency pins

Sui 1.79.0: all 30 strict network builds, 30 strict covered test runs, and
30 function coverage summaries passed. 321 tests passed on each network
(642 test executions total). Both compile-fail cap-type checks also passed.

| Package | Tests per network | Coverage, both networks |
|---|---:|---:|
| composition_credits | 16 | 100.00% |
| composition_lyrics | 9 | 100.00% |
| recording_advisory | 12 | 100.00% |
| recording_credits | 44 | 100.00% |
| recording_engine_session | 25 | 100.00% |
| recording_genre | 25 | 100.00% |
| recording_language | 15 | 100.00% |
| recording_master | 10 | 100.00% |
| recording_streaming_transcode | 7 | 100.00% |
| release_cover_art | 20 | 97.14% |
| release_credits | 20 | 100.00% |
| release_description | 22 | 100.00% |
| release_dsp_link | 54 | 100.00% |
| release_genre | 23 | 100.00% |
| release_kind | 19 | 100.00% |

The retained cover-art `cover_snapshot` encrypted-key branches account for its
existing coverage gap; that implementation is unchanged. All changed production
modules have 100% coverage.
