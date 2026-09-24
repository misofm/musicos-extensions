# release_kind

`release_kind` stores the free-form label a release uses for itself — for
example `Album`, `EP`, `Mixtape`, or `Split` — on a `musicos::release::Release`.
It is deliberately not a closed vocabulary and is not derived from the track
list. The value is stored verbatim as a `std::string::String`, including case,
whitespace, NUL bytes, and other valid UTF-8 bytes.

## Storage

One module-owned `ExtensionKey()` dynamic field on the release's `UID`, whose
value is the `String` itself. No wrapper struct, no other keys.

## API

All writes require the release's `ReleaseAdminCap` and go through the
cap-gated `release::uid_mut`; views are permissionless.

| Function | Description | Aborts |
|---|---|---|
| `set_kind(release, cap, kind: String)` | Sets or replaces the kind, verbatim. Setting the value already stored neither writes nor emits. | `EEmptyKind` (2), then `EKindTooLong` (3) past 32 bytes — both before cap authorization; then wrong cap (`release::EUnauthorized`, 0) |
| `clear_kind(release, cap)` | Removes the kind; an absent kind is a silent no-op | wrong cap (0), even when nothing is attached |
| `has_kind(release): bool` | Whether a kind is attached | — |
| `kind(release): &String` | The kind | `ENoKind` (1) when absent |

The 32-byte bound is on bytes, not characters.

## Events

Both events are monomorphic and carry only what an event-only indexer would
otherwise have to look up.

| Event | Fields | BCS size |
|---|---|---|
| `ReleaseKindSetEvent` | `release_id: ID`, `kind: String` | 32 + ULEB128 length + kind bytes; at most 65 |
| `ReleaseKindClearedEvent` | `release_id: ID` | 32 |

A set event is emitted only when the stored value actually changes; a cleared
event only when a kind was actually removed. Views emit nothing.

## Errors

| Code | Constant | Location | Condition |
|---|---|---|---|
| 1 | `ENoKind` | `release_kind::release_kind` | `kind` with nothing attached |
| 2 | `EEmptyKind` | `release_kind::release_kind` | `set_kind` with an empty string |
| 3 | `EKindTooLong` | `release_kind::release_kind` | `set_kind` with more than 32 bytes |
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
