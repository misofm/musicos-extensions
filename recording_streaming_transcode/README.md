# recording_streaming_transcode

This extension stores one administrator-selected `ori::data::WalrusQuilt`
reference per `musicos::Recording`. `StreamingTranscode` remains the stored
wrapper and all public constructors, views, writes, returns, and the missing
value error are unchanged. The package does not hash, inspect, or validate the
Quilt contents; it records the administrator's reference.

## API and lifecycle

`new(WalrusQuilt)` constructs the wrapper, and `quilt(&StreamingTranscode)`
returns its Quilt. `set_streaming_transcode(recording, cap, transcode)` uses the
recording's `uid_mut` constrained to the matching
`RecordingAdminCap<RecordingShare>` type, then either assigns the existing
dynamic field or adds it when absent. This is compile-time type authorization;
the extension performs no runtime authentication of the cap object's value or
ID. Replacing an equal Quilt ID still assigns and emits a set
event. `unset_streaming_transcode(recording, cap)` authorizes first, removes
the attached wrapper, and emits a clear event containing the removed Quilt ID;
an absent field is an authorized silent no-op. Removing the extension's field
leaves the embedded `Recording` fields, object identity, and published/shared
lifecycle unchanged.

`has_streaming_transcode` and `streaming_transcode` are permissionless views.
The latter aborts with `ENoStreamingTranscode` when no field is attached.

## Events and BCS layout

Both events are phantom-typed as
`<RecordingShare, CompositionShare>`:

`RecordingStreamingTranscodeSetEvent` fields, in order:

1. `recording_id: address`
2. `composition_id: address`
3. `admin_cap_id: address`
4. `had_transcode: bool`
5. `previous_quilt_id: u256`
6. `quilt_id: u256`

`RecordingStreamingTranscodeClearedEvent` fields, in order:

1. `recording_id: address`
2. `composition_id: address`
3. `admin_cap_id: address`
4. `quilt_id: u256`

The set event is 161 BCS bytes: three 32-byte addresses, one bool, and two
32-byte little-endian `u256`s. The clear event is 128 bytes: three addresses
and one `u256`. `had_transcode` disambiguates a legitimate previous Quilt ID
of zero from the absent state. The test suite peels every field and requires no
remainder, including the composed six-event payload total of 900 bytes.

## Dependencies and checks

- `musicos` supplies `Recording`, `RecordingAdminCap`, and the composition ID.
- `ori` supplies `WalrusQuilt` and its Quilt ID.

Run from `recording_streaming_transcode/`:

```sh
sui move build --build-env testnet --lint --warnings-are-errors
sui move test --build-env testnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env testnet
sui move build --build-env mainnet --lint --warnings-are-errors
sui move test --build-env mainnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env mainnet
```
