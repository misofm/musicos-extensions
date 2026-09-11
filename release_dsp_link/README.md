# Release DSP links

`release_dsp_link` stores raw native identifiers for eight DSPs on a
`musicos::release::Release`. Album links use `ReleaseLinkKey(platform)` and
track overrides use a `PerTrack<Option<DspLinkData>>` under
`TrackLinksKey(platform)`. Writes require the matching `ReleaseAdminCap`;
views are permissionless. `track_link` returns the raw override and does not
apply album fallback.

## Event field order

All events begin with these fields, in order:

```text
release_id: address
admin_cap_id: address
platform: u8
track_count: u64
field_existed_before: bool
field_exists_after: bool
```

Album set and clear events then append:

```text
previous_present: bool
previous_fields: vector<vector<u8>>
current_present: bool
current_fields: vector<vector<u8>>
```

`ReleaseDspLinkSetEvent` has `current_present = true` and
`field_exists_after = true`. `ReleaseDspLinkClearedEvent` has
`current_present = false`, empty `current_fields`, and
`field_exists_after = false`. `field_existed_before` distinguishes an insert
from a replacement.

Track set and single-slot clear events append, after the common fields:

```text
track_index: u64
recording_id: address
composition_id: address
previous_present: bool
previous_fields: vector<vector<u8>>
current_present: bool
current_fields: vector<vector<u8>>
album_present: bool
album_fields: vector<vector<u8>>
```

`ReleaseTrackDspLinkSetEvent` describes the override written to the slot.
`ReleaseTrackDspLinkClearedEvent` describes the previous override and the
empty slot afterward. A single-slot clear leaves the array in place, so its
field flags are `true -> true` and it emits even when the slot was already
empty. Clearing an absent array is silent, including for an out-of-range
index.

Bulk clear appends:

```text
removed_link_count: u64
removed_track_indices: vector<u64>
removed_recording_ids: vector<address>
removed_composition_ids: vector<address>
removed_link_fields: vector<vector<vector<u8>>>
album_present: bool
album_fields: vector<vector<u8>>
```

`removed_*` arrays are parallel and sorted by ascending track index. The
event has `field_existed_before = true` and `field_exists_after = false`, and
is emitted once for an existing array even when every slot is empty. An
absent array emits nothing; bulk clear never emits per-slot clear events.

## Raw identifier encoding

Each present link is encoded as exact UTF-8 byte vectors from its native
identifiers. Absent values are `present = false` with an empty fields vector.
The platform code is the event's `platform` field.

| Platform | Album fields | Track fields |
|---|---|---|
| 0 Spotify | `[id]` | `[id]` |
| 1 Apple Music | `[storefront, album_id]` | `[storefront, album_id, track_id]` when selected, otherwise the two album fields |
| 2 Amazon Music | `[album_id]` | `[album_id, track_id]` when selected, otherwise the album field |
| 3 Bandcamp | `[subdomain, slug]` | `[subdomain, slug]` |
| 4 Deezer | `[id]` | `[id]` |
| 5 SoundCloud | `[user, slug]` | `[user, slug]` |
| 6 Tidal | `[id]` | `[id]` |
| 7 YouTube Music | `[id]` | `[id]` |

Identifiers retain the constructor's existing 64-byte limits, or 128-byte
limits for Bandcamp and SoundCloud fields. The largest possible bulk-clear
event is 85,014 BCS bytes: 255 occupied Bandcamp/SoundCloud slots, 255
parallel track and address entries, and a two-field album snapshot. This is a
schema calculation, not a network throughput benchmark.

## Development

Run from this package directory:

```sh
sui move build -e testnet --lint --warnings-are-errors
sui move test -e testnet --lint --warnings-are-errors --coverage
sui move coverage summary -e testnet --summarize-functions
sui move build -e mainnet --lint --warnings-are-errors
sui move test -e mainnet --lint --warnings-are-errors --coverage
sui move coverage summary -e mainnet --summarize-functions
```
