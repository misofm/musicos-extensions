# Security review — `release_cover_art`

Reviewed 2026-09-11 for immutable publication and rich event payloads. Verdict:
no exploitable findings in the reviewed source.

## Dependency provenance

The Testnet manifest pins `cover_art` at
`603981fd563d10f3f89afe74851c1c4d3d50b0b4`, `musicos` at
`4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840`, and `per_track` at
`cba820dec3e058a1c543d5e8595ba8aed32e9dc6`. The checked-in Mainnet lock
graph pins those packages at `21fb2c04417fb0075d47f20c28149100e90af2cb`,
`b3d5d4005fe36044d90e318f864dbc8b01de41da`, and
`95b9830bda45fd82412c7653711ce9a2044a8be8`, respectively. Both graphs
resolve `bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` and `ori` at
`367ed5fe92a8b62da02c1116537cf08d111e0789`, with no duplicate aliases.

## Threat model and findings

All release-level and track-level writes require the matching
`ReleaseAdminCap`. `PerTrack` fixes override-array length to the immutable
tracklist and every indexed path checks bounds. Module-owned keying and private
stored fields protect the schema. Cover references inherit their validation
from the exact `cover_art` and `ori` dependencies. This is presentation data;
it neither moves revenue nor authorizes another operation.

## Evidence

With `/tmp/routed-stake-audit.zf2B9E/sui` (Sui 1.78.1-722ac4fcf484), isolated
Testnet and Mainnet copies pass strict lint/warnings-as-errors builds and tests:
19/19 on each network. Coverage runs on both copies report 97.02% for the
production module; all public mutation/view functions are 100% covered, while
the remaining uncovered lines are the encrypted sealed-DEK snapshot branches,
which cannot be constructed from this package without adding the already
transitive `ori` package to the manifest. The exercised tests cover the
published/shared Release flow, wrong-cap attempts, album and track lifecycle,
bounds, fallback, canonical absent/plaintext/animated snapshots, BCS field
decoding, and event cardinality.
