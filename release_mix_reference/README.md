# `release_mix_reference`

Attaches one optional public mix-delivery descriptor reference to each immutable
track slot of a Miso `Release`. The references are stored outside the frozen
protocol core and remain aligned with the release tracklist by construction.

The outer reference must be a standalone, plaintext Walrus blob. Its contents
may describe separately encrypted mix assets, but the descriptor reference
itself cannot be a quilt patch or carry an Ori sealed DEK. Initial attachment
and replacement are deliberately separate operations so a caller cannot
silently overwrite a delivery pointer.

## What it stores

One dynamic field under `ExtensionKey()` contains a
`PerTrack<Option<WalrusData>>`. The `PerTrack` vector is created lazily on the
first attachment with exactly one empty slot per immutable release track. Slots
can be filled or explicitly replaced; this v1 package does not remove the
dynamic field or clear an individual slot.

## API

### Writes (cap-gated)

| Function | Description | Aborts |
|----------|-------------|--------|
| `attach_mix_reference` | Attaches a plaintext blob descriptor to an empty track slot. | Wrong release cap; out-of-range track; quilt patch; encrypted reference; occupied slot. |
| `replace_mix_reference` | Replaces a plaintext blob descriptor in an occupied track slot. | Wrong release cap; out-of-range track; quilt patch; encrypted reference; missing extension or empty slot. |

### Views

| Function | Returns |
|----------|---------|
| `has_mix_reference` | Whether the selected track slot contains a descriptor; `false` before the extension is created. |
| `mix_reference` | A borrowed `WalrusData` descriptor for the selected track. |

Both views abort when the track index is outside the release tracklist.
`mix_reference` also aborts when the extension or selected slot is absent.

## Events

| Event | When | Payload |
|-------|------|---------|
| `MixReferenceAttachedEvent` | A track slot is filled for the first time. | Release ID, track index, recording ID, and descriptor reference. |
| `MixReferenceReplacedEvent` | An occupied track slot is explicitly replaced. | Release ID, track index, recording ID, and replacement descriptor reference. |

## Errors

| Code | Constant | Condition |
|------|----------|-----------|
| `0` | `ori::walrus_data::ENotBlob` | The reference is a quilt patch rather than a standalone blob. |
| `1` | `ETrackIndexOutOfBounds` | The selected index is outside the release tracklist. |
| `2` | `EMixReferenceAlreadyAttached` | `attach_mix_reference` targets an occupied slot. |
| `3` | `EMixReferenceMissing` | The extension or selected slot required by an operation is absent. |
| `4` | `EEncryptedDescriptorReference` | The outer descriptor reference carries an Ori sealed DEK. |
| — | `miso::release::EUnauthorized` | The supplied `ReleaseAdminCap` belongs to another release. |

## Dependencies

- `miso` provides `Release`, `ReleaseAdminCap`, the immutable tracklist, and
  cap-gated UID access.
- `ori` provides the `WalrusData` external-storage reference type.
- `per_track` provides the release-aligned `PerTrack<Option<WalrusData>>`
  container.

All dependencies are pinned to exact 40-character commit SHAs in `Move.toml`.

## Integrator notes

Treat the referenced blob as a public descriptor, not as ciphertext or key
material. Resolve the descriptor contents to find the separately encrypted mix
assets. Indexers can use the event's release ID and track index as a change
signal, then re-read the dynamic field for current state; the recording ID is
included to make track identity explicit at emission time.

## Build and test

```sh
sui move build --force --lint --warnings-are-errors
sui move test --force --lint --warnings-are-errors --coverage
```
