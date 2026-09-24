// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// What a release calls itself — "Album", "EP", "Mixtape", "Split" — asserted
/// by whoever holds the release's admin cap, and believed.
///
/// Deliberately a free string rather than an enum: deciding which
/// self-descriptions are legitimate is not the protocol's job, and nothing
/// depends on two releases agreeing about what an EP is (unlike genre, which
/// is a curated vocabulary). Nothing here derives the value or checks it for
/// plausibility; the only checks are structural — non-empty and bounded.
///
/// The value is stored verbatim, so "EP", "ep" and "Extended Play" are three
/// distinct values. Clients that group by kind should normalise themselves.
module release_kind::release_kind;

use musicos::release::{Release, ReleaseAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No kind is attached to this release.
const ENoKind: u64 = 1;
/// The kind is empty. Asserting nothing is done by not attaching.
const EEmptyKind: u64 = 2;
/// The kind exceeds `MAX_KIND_LENGTH` bytes.
const EKindTooLong: u64 = 3;

// === Constants ===

/// Maximum length of a kind, in bytes. Fits the long forms ("Extended Play",
/// "Album (Deluxe Edition)"); anything longer is a title, not a kind.
const MAX_KIND_LENGTH: u64 = 32;

// === Structs ===

/// Dynamic-field key — one kind (`String`) per release.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a release's kind is set or replaced with a different value.
public struct ReleaseKindSetEvent has copy, drop {
    release_id: ID,
    kind: String,
}

/// Emitted when an attached kind is removed.
public struct ReleaseKindClearedEvent has copy, drop {
    release_id: ID,
}

// === Public Functions ===

/// Sets (or replaces) what the release calls itself, stored exactly as given.
/// Aborts `EEmptyKind` on an empty string and `EKindTooLong` past
/// `MAX_KIND_LENGTH` bytes, both before cap authorization. Setting the value
/// already stored neither writes nor emits.
public fun set_kind(self: &mut Release, cap: &ReleaseAdminCap, kind: String) {
    assert!(!kind.is_empty(), EEmptyKind);
    assert!(kind.length() <= MAX_KIND_LENGTH, EKindTooLong);

    let release_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let stored: &mut String = df::borrow_mut(uid, ExtensionKey());
        if (*stored == kind) return;
        *stored = kind;
    } else {
        df::add(uid, ExtensionKey(), kind);
    };
    emit(ReleaseKindSetEvent { release_id, kind });
}

/// Removes the kind, if any. Authorizes first; an absent kind is a silent
/// no-op.
public fun clear_kind(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: String = df::remove(uid, ExtensionKey());
        emit(ReleaseKindClearedEvent { release_id });
    }
}

// === View Functions ===

/// Whether a kind is attached to this release.
public fun has_kind(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// What the release calls itself. Aborts `ENoKind` if nothing is attached.
public fun kind(self: &Release): &String {
    assert!(has_kind(self), ENoKind);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun kind_set_event_fields(e: &ReleaseKindSetEvent): (ID, String) {
    (e.release_id, e.kind)
}

#[test_only]
public fun kind_cleared_event_fields(e: &ReleaseKindClearedEvent): ID {
    e.release_id
}
