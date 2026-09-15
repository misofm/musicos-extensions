# Release DSP links

`release_dsp_link` stores raw native identifiers for eight DSPs on a
`musicos::release::Release`. Album links use `ReleaseLinkKey(platform)` and
track overrides use a `PerTrack<Option<DspLinkData>>` under
`TrackLinksKey(platform)`. Writes require the matching `ReleaseAdminCap`;
views are permissionless. `track_link` returns the raw override and does not
apply album fallback.

## Events

Every event retains release/admin-cap IDs, platform, total track count, and field lifecycle flags. Album set/clear also retain previous/current presence (77 BCS bytes). Single-track set/clear retain track index, recording/composition IDs, previous/current presence, and album presence (150 bytes). Bulk clear retains removed-link count and album presence (84 bytes); it invalidates the complete release/platform slice. Native link text and bulk per-track arrays stay out of events. The immutable release tracklist identifies track relationships; read the current link when displaying it. Equal replacements, empty clears, authorization, and mutations are unchanged.

See [the repository payload inventory](../EVENT_PAYLOADS.md) for byte bounds and retained context.

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
