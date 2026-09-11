# release_kind

`release_kind` stores the free-form label a release uses for itself — for
example `Album`, `EP`, `Mixtape`, or `Split`. It is deliberately not a closed
vocabulary and is not derived from the track list. The value is stored as the
original `std::string::String`, including case, whitespace, NUL bytes, and
other valid UTF-8 bytes.

## Storage and API

One module-owned `ExtensionKey` dynamic field is attached to a `Release`.
`set_kind(release, cap, kind)` requires a matching `ReleaseAdminCap`, rejects an
empty string with `EEmptyKind` (2), and then rejects values longer than 32 bytes
with `EKindTooLong` (3). These validation checks happen before
`Release::uid_mut`, so an invalid value reports 2 or 3 even when the supplied
cap belongs to another release; a valid foreign cap aborts in musicos with
`EUnauthorized` (0). The bound is byte-based, not a character count.

`unset_kind(release, cap)` authorizes first and then removes the field when it
exists. An absent field is a successful silent no-op. Removing a field does not
change the `Release` object itself. `has_kind` is a permissionless presence
view, while `kind` is a permissionless value view that aborts with `ENoKind` (1)
when the field is absent.

Setting a value always writes the field and emits an event, including replacing
it with equal bytes. The event's `kind_changed` is `false` for equal bytes and
`true` otherwise. An unset event is emitted only for an attached field.

## Events and encoding

`KindSetEvent` and `KindUnsetEvent` are monomorphic and have the identical field
order and types:

1. `release_id: address`
2. `release_admin_cap_id: address`
3. `kind_record_existed_before: bool`
4. `previous_kind: vector<u8>`
5. `previous_kind_length: u64`
6. `kind: vector<u8>`
7. `kind_length: u64`
8. `kind_record_exists_after: bool`
9. `kind_changed: bool`

The vectors contain raw UTF-8 bytes. BCS uses its normal ULEB128 vector
lengths, little-endian `u64`s, and one byte for each bool. With previous byte
length `p` and new byte length `n`, either event is `85 + p + n` bytes for the
tested bounds. Therefore the largest set event is 149 bytes (`p = n = 32`),
and the largest unset event is 117 bytes (`p = 32`, `n = 0`). A first set has
an empty previous snapshot and `kind_record_existed_before = false`; a present
replacement reports the old bytes and `true`; an unset reports the old bytes,
an empty new snapshot, `kind_record_exists_after = false`, and
`kind_changed = true`.

## Dependencies and checks

- `musicos` provides `Release`, `ReleaseAdminCap`, and cap-gated `uid_mut`.

Run from `release_kind/`:

```sh
sui move build --build-env testnet --lint --warnings-are-errors
sui move test --build-env testnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env testnet
sui move build --build-env mainnet --lint --warnings-are-errors
sui move test --build-env mainnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env mainnet
```
