// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A composition's preferred title, written by whoever holds the composition's
/// admin cap, and believed.
///
/// Core stores what a composition *is* and carries no title: a title has more
/// than one correct rendering (translations, alternate titles, corrections),
/// which makes it presentation, and presentation lives in the mutable
/// extension layer. Nothing on-chain reads the value; it is stored exactly as
/// given under this module's key, settable before publication and correctable
/// after it. Reads are permissionless.
///
/// Guard order: argument-only validation (emptiness, the byte bound) runs
/// before the cap is consulted; anything that reads stored state runs after
/// `uid_mut`. A write that would leave the stored value unchanged — an equal
/// set, or a clear of nothing — is a no-op after the cap check: no write, no
/// event. Every emitted event is therefore a transition.
module composition_title::composition_title;

use musicos::composition::{Composition, CompositionAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No title is attached to this composition.
const ENoTitle: u64 = 1;
/// The title is empty. Naming nothing is done by not attaching.
const EEmptyTitle: u64 = 2;
/// The title exceeds `MAX_TITLE_LENGTH` bytes.
const ETitleTooLong: u64 = 3;

// === Constants ===

/// Maximum length of a title, in bytes — the bound core enforced while the
/// title was embedded. Bytes, not characters: a multi-byte title fits fewer.
const MAX_TITLE_LENGTH: u64 = 300;

// === Structs ===

/// Dynamic-field key — one `String` title per composition.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a title is added or replaced with a different value. Carries
/// the composition and the value now attached; the admin cap is derivable
/// from the composition id and prior state is the indexer's own projection.
public struct CompositionTitleSetEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    title: String,
}

/// Emitted when an attached title is removed. Absent clears emit nothing, so
/// a clear always removes the indexer's currently projected value.
public struct CompositionTitleClearedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
}

// === Public Functions ===

/// Sets (or replaces) the title, stored exactly as given. Aborts `EEmptyTitle`
/// for an empty string, then `ETitleTooLong` above `MAX_TITLE_LENGTH` bytes,
/// both before the cap is consulted. Setting the title already attached is a
/// no-op after the cap check. Works in any lifecycle state.
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
    if (df::exists(uid, ExtensionKey())) {
        let stored: &mut String = df::borrow_mut(uid, ExtensionKey());
        if (*stored == title) return;
        *stored = title;
    } else {
        df::add(uid, ExtensionKey(), title);
    };
    emit(CompositionTitleSetEvent<CompositionShare> { composition_id, title });
}

/// Removes the title, if any. Authorizes before it looks, so a clear of
/// nothing still requires the cap and is then silent.
public fun clear_title<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
) {
    let composition_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let _: String = df::remove(uid, ExtensionKey());
    emit(CompositionTitleClearedEvent<CompositionShare> { composition_id });
}

// === View Functions ===

/// Whether a title is attached to this composition.
public fun has_title<CompositionShare>(self: &Composition<CompositionShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The composition's title. Aborts `ENoTitle` if nothing is attached —
/// absence is a distinct state and never collapses into an empty string.
public fun title<CompositionShare>(self: &Composition<CompositionShare>): &String {
    assert!(has_title(self), ENoTitle);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

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
