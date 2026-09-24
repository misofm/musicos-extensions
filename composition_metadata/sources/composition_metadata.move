// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A composition's basic descriptive metadata — for now, what it is called —
/// written by whoever holds the composition's admin cap, and believed.
///
/// Core stores what a composition *is*: its identity, its share type, and the
/// royalty rate it earns from recordings. It carries no title. A title has
/// more than one correct rendering — translations, alternate titles,
/// corrections — which makes it presentation, and presentation lives here, in
/// the mutable extension layer, never in the frozen core. The economics never
/// read a name, so nothing on-chain derives from the value stored by this
/// module: it is stored exactly as given and attributed to the cap holder.
///
/// **Storage.** One dynamic field on the composition's `UID`, under this
/// module's `ExtensionKey()`, holding one `CompositionMetadata` record whose
/// fields are the attributes. Every attribute is optional and independently
/// settable and clearable; the record is created by the first write and
/// removed by the clear that empties it, so "the field is absent" and "no
/// metadata is attached" are the same fact. Translations and alternate
/// titles are different attributes, not entries in this one; folding them
/// into it would turn a name into a schema.
///
/// The 300-byte ceiling is the bound core enforced while the title was
/// embedded, kept so nothing a client could already store becomes
/// unstorable. It is storage hygiene, not an editorial opinion: this package
/// publishes immutable, so a ceiling that turns out too low can never be
/// raised, while one too high costs only the writer who fills it.
///
/// Attaching nothing and attaching a title are distinct states: absence means
/// nobody has named the composition, which is why an empty string is rejected
/// rather than stored. There is no such thing as an empty title. Writes
/// require the composition's matching admin cap in every lifecycle state —
/// a title is settable before publication and correctable after it; reads
/// are permissionless.
///
/// **Guard order.** Validation that needs only the argument (emptiness, the
/// byte bound) runs before the cap is consulted, so an invalid value reports
/// its own code whatever cap is supplied. Anything that reads stored state
/// runs after `uid_mut`, so a clear authorizes before it looks.
///
/// **No-ops.** A write that would leave the stored value unchanged is a
/// no-op: it performs no write and emits no event. A set of the value already
/// attached returns after the cap check without touching the record; a clear
/// of nothing returns after the cap check without emitting. Only an attached
/// value can be equalled, so a set never creates the record as a no-op.
module composition_metadata::composition_metadata;

use musicos::composition::{Composition, CompositionAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

// One decade per attribute, in field order. Within a decade: `0` nothing
// attached, `1` empty input, `2` bound exceeded.

// Title (10–19)
/// No title is attached to this composition.
const ENoTitle: u64 = 10;
/// The title is empty. Naming nothing is done by not attaching.
const EEmptyTitle: u64 = 11;
/// The title exceeds `MAX_TITLE_LENGTH` bytes.
const ETitleTooLong: u64 = 12;

// === Constants ===

/// Maximum length of a title, in bytes — the bound core enforced before the
/// title moved here. The bound is on bytes, not characters: a multi-byte
/// title fits fewer characters, and a client that wants to show a character
/// count must derive it itself.
const MAX_TITLE_LENGTH: u64 = 300;

// === Structs ===

/// Dynamic-field key — one metadata record per composition.
public struct ExtensionKey() has copy, drop, store;

/// The record stored under `ExtensionKey()`. Present only while at least one
/// attribute is set; a clear that leaves every attribute `None` removes the
/// field. `store` only: it is taken out by destructuring, never dropped.
public struct CompositionMetadata has store {
    /// The composition's preferred title, stored exactly as given.
    title: Option<String>,
}

// === Events ===

/// Emitted when a composition's title is added or replaced with a different
/// value; an equal set is a no-op and emits nothing, so every event is a
/// transition. The payload is what an event-only indexer could not
/// get without a lookup: the composition and the value now attached. Prior
/// state is the indexer's own previous projection; the admin cap is the
/// derived address of `composition_id` under `CompositionAdminCapKey`; the
/// sender is the transaction envelope; the share type is the type argument.
public struct CompositionTitleSetEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    title: String,
}

/// Emitted when an attached title is removed. Clearing an absent title is an
/// authorized, silent no-op and therefore emits nothing, so a clear always
/// removes the indexer's currently projected value.
public struct CompositionTitleClearedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
}

// === Public Functions ===

/// Sets (or replaces) the composition's title.
///
/// Stored exactly as given — whitespace and case included. Aborts
/// `EEmptyTitle` for an empty string, then `ETitleTooLong` above
/// `MAX_TITLE_LENGTH` bytes, both before the cap is consulted. Creates the
/// metadata record on first use. Setting the title already attached is a
/// no-op after the cap check: nothing is written and nothing is emitted.
/// Works in any lifecycle state.
public fun set_title<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    title: String,
) {
    let bytes = title.as_bytes();
    assert!(!bytes.is_empty(), EEmptyTitle);
    assert!(bytes.length() <= MAX_TITLE_LENGTH, ETitleTooLong);

    let composition_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey()) && metadata(uid).title.contains(&title)) return;
    metadata_mut(uid).title = option::some(title);
    emit(CompositionTitleSetEvent<CompositionShare> { composition_id, title });
}

/// Removes the title, if any. Idempotent. Cap-gates before the existence
/// check, so a wrong cap aborts even when there is nothing to remove. Leaves
/// the composition unnamed, which is where every composition starts, and
/// removes the metadata record when nothing else is set.
public fun clear_title<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
) {
    let composition_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    // The title is the record's only attribute, so an attached record always
    // has it set and clearing it empties the record: take the record out
    // whole, keeping "field absent" and "no metadata" the same fact.
    let CompositionMetadata { title: _ } = df::remove(uid, ExtensionKey());
    emit(CompositionTitleClearedEvent<CompositionShare> { composition_id });
}

// === View Functions ===

/// Whether a title is attached to this composition. The title is the
/// record's only attribute, so the record is attached exactly when it is.
public fun has_title<CompositionShare>(self: &Composition<CompositionShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The composition's title. Aborts `ENoTitle` if nothing is attached —
/// absence is a distinct state and must not collapse into an empty string.
public fun title<CompositionShare>(self: &Composition<CompositionShare>): &String {
    assert!(has_title(self), ENoTitle);
    metadata(self.uid()).title.borrow()
}

// === Test Functions ===

/// Whether the metadata record itself is attached — lets tests prove the
/// field lifecycle (absent before any write, created by the first, removed
/// by the clear that empties it) without a production predicate for it.
#[test_only]
public fun has_metadata_for_testing<CompositionShare>(
    self: &Composition<CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

#[test_only]
public fun set_event_fields<CompositionShare>(
    e: &CompositionTitleSetEvent<CompositionShare>,
): (address, String) {
    (e.composition_id, e.title)
}

#[test_only]
public fun cleared_event_fields<CompositionShare>(
    e: &CompositionTitleClearedEvent<CompositionShare>,
): address {
    e.composition_id
}

// === Private Functions ===

/// The attached record. Callers check existence first.
fun metadata(uid: &UID): &CompositionMetadata {
    df::borrow(uid, ExtensionKey())
}

/// The attached record, creating an empty one if none is attached. Every
/// write goes through here, so the record exists exactly from the first
/// write on; the caller sets the attribute before the write returns, so no
/// empty record is ever left attached.
fun metadata_mut(uid: &mut UID): &mut CompositionMetadata {
    if (!df::exists(uid, ExtensionKey())) {
        df::add(uid, ExtensionKey(), CompositionMetadata { title: option::none() });
    };
    df::borrow_mut(uid, ExtensionKey())
}
