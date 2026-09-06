// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// What a release calls itself — "Album", "EP", "Mixtape", "Split" — asserted by
/// whoever holds the release's admin cap, and believed.
///
/// Deliberately a free string rather than an enum. An enum would not decide the
/// classification (the admin still picks) but it would decide the *menu*, and
/// deciding which self-descriptions are legitimate is not the protocol's job.
/// Artists release beat tapes and splits and things nobody has named yet; a
/// closed set would make each of those a package swap, and in the meantime would
/// quietly push releases into whichever official-looking box fit worst.
///
/// Nothing here derives the value or checks it for plausibility. A four-track
/// release may call itself an Album and a twelve-track one an EP; both happen,
/// and the artist's intent is the fact worth recording. The only checks are
/// structural — non-empty and bounded — so the field stays storable.
///
/// This is the opposite call from `release_genre`, on purpose. Genre is a
/// curated vocabulary because discovery and reward-eligibility depend on releases
/// agreeing with each other about what a genre *is*. Nothing depends on two
/// releases agreeing about what an EP is.
///
/// The cost of that freedom lands on readers: "EP", "ep" and "Extended Play" are
/// three distinct values here. Clients that group or facet by kind should
/// normalise (case-fold at minimum) rather than expect canonical strings.
module release_kind::release_kind;

use miso::release::{Release, ReleaseAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No kind is attached to this release.
const ENoKind: u64 = 1;
/// The kind is empty. Asserting nothing should be done by not attaching.
const EEmptyKind: u64 = 2;
/// The kind exceeds `MAX_KIND_LENGTH` bytes.
const EKindTooLong: u64 = 3;

// === Constants ===

/// Maximum length of a kind, in bytes. Comfortably fits the long forms
/// ("Extended Play", "Album (Deluxe Edition)") while keeping the field bounded.
/// A kind is what the release *is*, not its title — anything longer is a title.
const MAX_KIND_LENGTH: u64 = 32;

// === Structs ===

/// Dynamic-field key — one kind per release.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a release's kind is set or replaced. How a release is presented
/// and grouped follows from this, so an indexer needs to hear it change.
public struct KindSetEvent has copy, drop {
    release_id: ID,
    kind: String,
}

/// Emitted when a release's kind is removed.
public struct KindUnsetEvent has copy, drop {
    release_id: ID,
}

// === Public Functions ===

/// Sets (or replaces) what the release calls itself.
///
/// The string is stored exactly as given, including case — it is the release's
/// own word for itself, and normalising it here would be the protocol having an
/// opinion after all.
public fun set_kind(self: &mut Release, cap: &ReleaseAdminCap, kind: String) {
    let bytes = kind.as_bytes();
    assert!(!bytes.is_empty(), EEmptyKind);
    assert!(bytes.length() <= MAX_KIND_LENGTH, EKindTooLong);

    let release_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow_mut(uid, ExtensionKey()) = kind;
    } else {
        df::add(uid, ExtensionKey(), kind);
    };
    emit(KindSetEvent { release_id, kind });
}

/// Removes the kind, if any. Idempotent. Leaves the release having said nothing
/// about what it is, which is a different state from calling itself anything.
public fun unset_kind(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: String = df::remove(uid, ExtensionKey());
        emit(KindUnsetEvent { release_id });
    }
}

// === View Functions ===

/// Whether a kind is attached to this release.
public fun has_kind(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// What the release calls itself. Aborts if nothing is attached.
public fun kind(self: &Release): String {
    assert!(has_kind(self), ENoKind);
    *df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields(e: &KindSetEvent): (ID, String) { (e.release_id, e.kind) }

#[test_only]
public fun unset_event_release_id(e: &KindUnsetEvent): ID { e.release_id }
