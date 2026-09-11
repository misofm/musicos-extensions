# `release_description`

`release_description` stores one bounded, non-empty UTF-8 `String` on a
`musicos::release::Release` through a private dynamic-field key. The prose is
stored exactly as supplied: whitespace, case, line breaks, and multi-byte UTF-8
bytes are not normalized or hashed.

## API

- `set_description(&mut Release, &ReleaseAdminCap, String)` validates empty
  input first and the 8192-byte maximum second, then uses the release's
  cap-gated `uid_mut`. It adds or replaces the field, including equal
  replacement, and emits exactly one `ReleaseDescriptionSetEvent` after the
  dynamic-field mutation.
- `clear_description(&mut Release, &ReleaseAdminCap)` authorizes through
  `uid_mut` before checking field existence. An attached value is removed and
  emits one `ReleaseDescriptionClearedEvent`; an absent value is a silent,
  authorized no-op.
- `has_description` is a permissionless presence view. `description` is a
  permissionless value view and aborts with `ENoDescription` when absent.

The set event fields, in order, are `release_id`,
`release_admin_cap_id`, `description_existed_before`, `description_before`,
and `description_after`. The clear event fields are `release_id`,
`release_admin_cap_id`, and `description_before`. IDs are event provenance;
the extension adds no cap-ID equality check beyond the core release's existing
`uid_mut` authorization. Their exact maximum BCS sizes are 8260 bytes for an
initial max-length set, 16453 bytes for a max-length replacement, and 8258
bytes for a max-length clear.

## Verification

Run strict builds, tests, and coverage with Sui 1.79.0:

```sh
sui move build --build-env testnet --lint --warnings-are-errors
sui move test --build-env testnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env testnet
sui move build --build-env mainnet --lint --warnings-are-errors
sui move test --build-env mainnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env mainnet
```
