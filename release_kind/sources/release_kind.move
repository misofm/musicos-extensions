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

use musicos::release::{Release, ReleaseAdminCap};
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
/// and grouped follows from this, so an indexer needs to hear every assignment.
public struct ReleaseKindSetEvent has copy, drop {
    release_id: address,
    release_admin_cap_id: address,
    kind_record_existed_before: bool,
    previous_kind: vector<u8>,
    previous_kind_length: u64,
    kind: vector<u8>,
    kind_length: u64,
    kind_record_exists_after: bool,
    kind_changed: bool,
}

/// Emitted when a release's kind is removed.
public struct ReleaseKindUnsetEvent has copy, drop {
    release_id: address,
    release_admin_cap_id: address,
    kind_record_existed_before: bool,
    previous_kind: vector<u8>,
    previous_kind_length: u64,
    kind: vector<u8>,
    kind_length: u64,
    kind_record_exists_after: bool,
    kind_changed: bool,
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

    let release_id = object::id(self).to_address();
    let release_admin_cap_id = object::id(cap).to_address();
    let kind_bytes = *bytes;
    let kind_length = kind_bytes.length();
    let uid = self.uid_mut(cap);
    let kind_record_existed_before = df::exists(uid, ExtensionKey());
    let mut previous_kind = vector[];
    let mut previous_kind_length = 0;
    if (kind_record_existed_before) {
        let previous: &String = df::borrow(uid, ExtensionKey());
        previous_kind = *previous.as_bytes();
        previous_kind_length = previous_kind.length();
        *df::borrow_mut(uid, ExtensionKey()) = kind;
    } else {
        df::add(uid, ExtensionKey(), kind);
    };
    let kind_record_exists_after = df::exists(uid, ExtensionKey());
    let kind_changed = previous_kind != kind_bytes;
    emit(ReleaseKindSetEvent {
        release_id,
        release_admin_cap_id,
        kind_record_existed_before,
        previous_kind,
        previous_kind_length,
        kind: kind_bytes,
        kind_length,
        kind_record_exists_after,
        kind_changed,
    });
}

/// Removes the kind, if any. Idempotent. Leaves the release having said nothing
/// about what it is, which is a different state from calling itself anything.
public fun unset_kind(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self).to_address();
    let release_admin_cap_id = object::id(cap).to_address();
    let uid = self.uid_mut(cap);
    let kind_record_existed_before = df::exists(uid, ExtensionKey());
    if (kind_record_existed_before) {
        let previous: &String = df::borrow(uid, ExtensionKey());
        let previous_kind = *previous.as_bytes();
        let previous_kind_length = previous_kind.length();
        let _: String = df::remove(uid, ExtensionKey());
        let kind_record_exists_after = df::exists(uid, ExtensionKey());
        emit(ReleaseKindUnsetEvent {
            release_id,
            release_admin_cap_id,
            kind_record_existed_before,
            previous_kind,
            previous_kind_length,
            kind: vector[],
            kind_length: 0,
            kind_record_exists_after,
            kind_changed: true,
        });
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
public fun release_kind_set_event_fields(e: &ReleaseKindSetEvent): (ID, String) {
    (object::id_from_address(e.release_id), std::string::utf8(e.kind))
}

#[test_only]
public fun release_kind_set_event_payload(e: &ReleaseKindSetEvent):
    (address, address, bool, vector<u8>, u64, vector<u8>, u64, bool, bool) {
    (
        e.release_id,
        e.release_admin_cap_id,
        e.kind_record_existed_before,
        e.previous_kind,
        e.previous_kind_length,
        e.kind,
        e.kind_length,
        e.kind_record_exists_after,
        e.kind_changed,
    )
}

#[test_only]
public fun release_kind_unset_event_payload(e: &ReleaseKindUnsetEvent):
    (address, address, bool, vector<u8>, u64, vector<u8>, u64, bool, bool) {
    (
        e.release_id,
        e.release_admin_cap_id,
        e.kind_record_existed_before,
        e.previous_kind,
        e.previous_kind_length,
        e.kind,
        e.kind_length,
        e.kind_record_exists_after,
        e.kind_changed,
    )
}

#[test_only]
public fun release_kind_unset_event_release_id(e: &ReleaseKindUnsetEvent): ID {
    object::id_from_address(e.release_id)
}

#[test_only]
public fun release_kind_set_event_bcs(e: &ReleaseKindSetEvent): vector<u8> { sui::bcs::to_bytes(e) }

#[test_only]
public fun release_kind_unset_event_bcs(e: &ReleaseKindUnsetEvent): vector<u8> { sui::bcs::to_bytes(e) }
