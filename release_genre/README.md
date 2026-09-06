# `release_genre`

> Pure genre metadata for a Miso `Release`.

The package attaches one primary genre, up to five secondary genres, and
optional per-track primary overrides to a release through its cap-gated
`&mut UID`. It does not implement reward eligibility, timing restrictions, or
other economic policy.

The primary genre can be replaced at any time by the release administrator.
Primary and secondary genres remain disjoint, and every track override is
validated against the release's tracklist.

## Public API

- `set_primary_genre`
- `add_secondary_genre`
- `remove_secondary_genre`
- `set_track_primary_genre`
- `unset_track_primary_genre`
- `has_genre`
- `primary_genre`
- `secondary_genres`
- `track_primary_genre`

## Publishing

This data layout is intentionally distinct from the historical version 1
package. It is published as a fresh immutable package identity and is never
upgraded from that deployment. Clients migrate explicitly by selecting the new
package and its dynamic-field key type.

## Build and test

```sh
sui move build
sui move test
```
