# `composition_metadata`

`composition_metadata` is the canonical, platform-neutral home for a
composition's basic descriptive metadata, attached to a
`musicos::composition::Composition<CompositionShare>` as one dynamic field.
Core stores what a composition *is* — identity, share type, royalty rate —
and carries no title; anything with more than one correct rendering
(translations, alternate titles, corrections) is presentation and lives here.

The package currently describes one attribute, the composition's preferred
**title**: a bounded, non-empty UTF-8 `String`, stored exactly as supplied —
whitespace, case and multi-byte UTF-8 are not normalized or hashed.

## Storage

One dynamic field on the composition's `UID`, under the module's one key,
holding one record whose fields are the attributes:

```text
ExtensionKey() -> CompositionMetadata { title: Option<String> }
```

The record is created by the first write and removed by the clear that
leaves every attribute unset, so "the field is absent" and "no metadata is
attached" are the same fact. With the title as the only attribute today, the
record is attached exactly when a title is. A future package generation adds
attributes as further fields of the record; each stays independently settable
and clearable. `CompositionMetadata` has only `store` and is taken out by
destructuring, never dropped. Nothing on-chain reads the value; it has no
economic or authorization meaning.

## API

- `set_title(&mut Composition<S>, &CompositionAdminCap<S>, String)` aborts
  `EEmptyTitle` (11) for an empty string, then `ETitleTooLong` (12) above 300
  bytes, both before the composition's cap-gated `uid_mut` is called. It
  creates the record on first use, replaces the title otherwise, and emits
  exactly one `CompositionTitleSetEvent<S>`. Setting the title already
  attached is a no-op: after the cap check nothing is written and nothing is
  emitted.
  Works in every lifecycle state: a title can be set before publication
  (earlier in the creating transaction) and corrected after it.
- `clear_title(&mut Composition<S>, &CompositionAdminCap<S>)` authorizes
  through `uid_mut` before checking existence. An attached title is removed
  with its record and emits one `CompositionTitleClearedEvent<S>`; an absent
  one is a silent, authorized no-op.
- `has_title(&Composition<S>): bool` is a permissionless presence view.
- `title(&Composition<S>): &String` is a permissionless value view and aborts
  `ENoTitle` (10) when absent — absence is a distinct state and never
  collapses into an empty string.

Guard order, shared with `recording_metadata` and `release_metadata`:
validation that needs only the argument runs before the cap is consulted;
anything that reads stored state runs after it. A write that would leave the
stored value unchanged — an equal set, or a clear of nothing — is a no-op
after the cap check: no write, no event. Error codes are numeric,
one decade per attribute (`x0` nothing attached, `x1` empty, `x2` bound
exceeded).

The pinned core binds a cap to a composition by share type (`S`); it does not
compare cap IDs at runtime. Production construction consumes the share
`TreasuryCap`, and the extension inherits that uniqueness and trust model
without adding capability custody or an authorization policy of its own.

## Events

Payloads follow musicos's slimmed event policy: a field is carried only if an
indexer reading events alone would otherwise need an object lookup for it.

- `CompositionTitleSetEvent<S> { composition_id: address, title: String }`
- `CompositionTitleClearedEvent<S> { composition_id: address }`

Dropped as derivable: the admin cap id (the derived address of
`composition_id` under `CompositionAdminCapKey`), the sender (the transaction
envelope), the share type (the event's type argument), and prior state (the
indexer's own previous projection; absent clears emit nothing, so a clear
always removes the currently projected value). The exact BCS sizes at the
bound are 334 bytes for a max-length set and 32 bytes for a clear.

## Usage

```move
use composition_metadata::composition_metadata;

// Name a composition (before or after publish) with its admin cap.
composition_metadata::set_title(&mut composition, &cap, b"So What".to_string());

// Anyone can read it.
if (composition_metadata::has_title(&composition)) {
    let title: &String = composition_metadata::title(&composition);
};

// Correct it, or take the name back.
composition_metadata::set_title(&mut composition, &cap, b"So What (Alternate Take)".to_string());
composition_metadata::clear_title(&mut composition, &cap);
```

## Verification

Run strict builds, tests, and coverage with Sui 1.79.0:

```sh
sui move build --build-env testnet --lint --warnings-are-errors
sui move test --build-env testnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env testnet
sui move build --build-env mainnet --lint --warnings-are-errors
sui move test --build-env mainnet --coverage --lint --warnings-are-errors
sui move coverage summary --build-env mainnet
python3 tests/check_cap_types.py
```

`musicos` is pinned to `676dbd801583761b7e5ab53b4476e8606a12a8d7`. The
title was removed from core at `8c3fd65f733d640c2b72c3a63b0a14f3953f396e`. This is an independent package
intended for fresh immutable publication under the repository's release
policy. No publication has been performed.
