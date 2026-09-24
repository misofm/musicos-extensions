# release_description

`release_description` stores one bounded, non-empty UTF-8 `String` — the
paragraph a release says about itself — on a `musicos::release::Release`. The
prose is stored exactly as supplied: whitespace, case, line breaks, and
multi-byte UTF-8 are not normalized.

## Storage

One module-owned `ExtensionKey()` dynamic field on the release's `UID`, whose
value is the `String` itself. No wrapper struct, no other keys.

## API

All writes require the release's `ReleaseAdminCap` and go through the
cap-gated `release::uid_mut`; views are permissionless.

| Function | Description | Aborts |
|---|---|---|
| `set_description(release, cap, description: String)` | Sets or replaces the description, verbatim. Setting the value already stored neither writes nor emits. | `EEmptyDescription` (2), then `EDescriptionTooLong` (3) past 8192 bytes — both before cap authorization; then wrong cap (`release::EUnauthorized`, 0) |
| `clear_description(release, cap)` | Removes the description; an absent description is a silent no-op | wrong cap (0), even when nothing is attached |
| `has_description(release): bool` | Whether a description is attached | — |
| `description(release): &String` | The description | `ENoDescription` (1) when absent |

The 8192-byte bound is on bytes, not characters. Long-form writing belongs in
a Walrus blob referenced by an extension.

## Events

Both events are monomorphic and carry only what an event-only indexer would
otherwise have to look up.

| Event | Fields | BCS size |
|---|---|---|
| `ReleaseDescriptionSetEvent` | `release_id: ID`, `description: String` | 32 + ULEB128 length + description bytes; at most 8226 |
| `ReleaseDescriptionClearedEvent` | `release_id: ID` | 32 |

A set event is emitted only when the stored value actually changes; a cleared
event only when a description was actually removed. Views emit nothing.

## Errors

| Code | Constant | Location | Condition |
|---|---|---|---|
| 1 | `ENoDescription` | `release_description::release_description` | `description` with nothing attached |
| 2 | `EEmptyDescription` | `release_description::release_description` | `set_description` with an empty string |
| 3 | `EDescriptionTooLong` | `release_description::release_description` | `set_description` with more than 8192 bytes |
| 0 | `EUnauthorized` | `musicos::release` | any write with a cap for a different release |

## Dependencies

- [`musicos`](https://github.com/misofm/musicos) at
  `6dff4deca5ced186989c064e152c92a06384750c` — `Release`, `ReleaseAdminCap`,
  and cap-gated `uid_mut`.

## Publishing

`Published.toml` records the previously deployed generation. This generation
is published as a fresh immutable package identity and never upgraded in
place; clients migrate explicitly.

## Build and test

Run from this directory:

```sh
sui move build
sui move build --build-env mainnet
sui move test
sui move test --build-env mainnet
```
