# `composition_title`

`composition_title` stores a composition's preferred title, attached to a
`musicos::composition::Composition` as one dynamic field.
Core stores the composition identity and lifecycle state but carries no title.
Anything with more than one correct rendering
(translations, alternate titles, corrections) is presentation and lives in
the extension layer.

The title is a bounded, non-empty UTF-8 `String`, stored exactly as supplied —
whitespace, case and multi-byte UTF-8 are not normalized or hashed. Nothing
on-chain reads the value; it has no economic or authorization meaning.

## Storage

```text
ExtensionKey() -> String
```

One module-owned key, one value. Absence means nobody has named the
composition, which is why an empty string is rejected rather than stored:
there is no such thing as an empty title.

## API

- `set_title(&mut Composition, &CompositionAdminCap, String)` aborts
  `EEmptyTitle` (2) for an empty string, then `ETitleTooLong` (3) above 300
  bytes, both before the composition's cap-gated `uid_mut` is called. It
  adds or replaces the title and emits one `CompositionTitleSetEvent`.
  Setting the title already attached is a no-op: after the cap check nothing
  is written and nothing is emitted. Works in every lifecycle state — a title
  can be set before publication (earlier in the creating transaction) and
  corrected after it.
- `clear_title(&mut Composition, &CompositionAdminCap)` authorizes
  through `uid_mut` before checking existence. An attached title is removed
  and emits one `CompositionTitleClearedEvent`; an absent one is a silent,
  authorized no-op.
- `has_title(&Composition): bool` is a permissionless presence view.
- `title(&Composition): &String` is a permissionless value view and aborts
  `ENoTitle` (1) when absent — absence never collapses into an empty string.

The 300-byte bound is on bytes, not characters: a multi-byte title fits fewer
characters. Guard order: validation that needs only the argument runs before
the cap is consulted, so an invalid value reports its own code whatever cap
is supplied; anything that reads stored state runs after `uid_mut`.

The core checks that the admin cap contains this composition's object ID.
A cap for another composition aborts with `composition::EUnauthorized`.
The extension adds no authorization policy of its own.

## Events

A field is carried only if an indexer reading events alone would otherwise
need an object lookup for it.

- `CompositionTitleSetEvent { composition_id: ID, title: String }`
- `CompositionTitleClearedEvent { composition_id: ID }`

Dropped as derivable: the admin cap id (the derived address of
`composition_id` under `CompositionAdminCapKey`), the sender (the transaction
envelope), and prior state (the indexer's own previous projection; absent clears and equal sets emit nothing,
so every event is a transition). The exact BCS sizes at the bound are 334
bytes for a max-length set and 32 bytes for a clear.

## Usage

```move
use composition_title::composition_title;

// Name a composition (before or after publish) with its admin cap.
composition_title::set_title(&mut composition, &cap, b"So What".to_string());

// Anyone can read it.
if (composition_title::has_title(&composition)) {
    let title: &String = composition_title::title(&composition);
};

// Correct it, or take the name back.
composition_title::set_title(&mut composition, &cap, b"So What (Alternate Take)".to_string());
composition_title::clear_title(&mut composition, &cap);
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
```

`musicos` is pinned to `0b3eb07c9cb1af29c877b66cddfdcc9ef32fc721`. This is an
independent package intended for fresh immutable publication under the
repository's release policy. No publication has been performed.
