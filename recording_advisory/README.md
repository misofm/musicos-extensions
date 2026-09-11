# `recording_advisory`

> Parental-advisory classification for `musicos::recording::Recording`.

The extension stores one `ExplicitRating` dynamic field on a recording through
the recording's cap-gated `uid_mut`. The three values are `Explicit`,
`NotExplicit`, and `Cleaned`; absence means that no advisory has been asserted.
The field remains independent of the recording's embedded lifecycle state and
can be changed through the typed `RecordingAdminCap`.

## Entry points

- `set_rating` adds, replaces, or equal-replaces the rating and emits exactly
  one `RecordingAdvisoryRatingSetEvent<RecordingShare, CompositionShare>` after
  the dynamic-field mutation.
- `unset_rating` removes an attached rating and emits one
  `RecordingAdvisoryRatingClearedEvent<RecordingShare, CompositionShare>`.
  Clearing an absent field is an idempotent silent no-op.
- `has_rating` and `rating` are permissionless views; `rating` aborts with
  `ENoRating` when no field is attached.

Set events contain recording, parent-composition, and supplied admin-cap
addresses; `had_rating`; the previous compact code; and the resulting compact
code. Clear events contain the same three addresses and the removed code.
Codes are `Explicit=0`, `NotExplicit=1`, and `Cleaned=2`; an absent prior value
is represented as `had_rating=false` and `previous_rating=0`. Event streams are
phantom-typed by both share dimensions, and payload sizes are 99 bytes for set
and 97 bytes for clear under BCS.

The cap address is event provenance. Authorization remains the recording core's
typed-cap `uid_mut` behavior; this extension adds no runtime cap-ID equality
check. Constructors, views, and rating predicates are silent.

## Build & test

```sh
sui move build
sui move test
```
