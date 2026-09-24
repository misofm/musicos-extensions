// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The title a release prefers to be known by, asserted by whoever holds the
/// release's admin cap, and believed.
///
/// Core `Release` carries no title: a title is presentation, not the
/// constitutive tracklist-and-splits state the release id commits to, so it
/// lives here as an extension. It is a free string with no vocabulary to
/// enforce and nothing to derive it from; the only checks are structural —
/// non-empty and bounded — so the field stays storable. It is mutable, since
/// a release may be retitled without changing what it is.
///
/// The value is stored verbatim. Attaching nothing and attaching a title are
/// distinct states, so an empty string is rejected rather than stored.
module release_title::release_title;

use musicos::release::{Release, ReleaseAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No title is attached to this release.
const ENoTitle: u64 = 1;
/// The title is empty. Asserting nothing is done by not attaching.
const EEmptyTitle: u64 = 2;
/// The title exceeds `MAX_TITLE_LENGTH` bytes.
const ETitleTooLong: u64 = 3;

// === Constants ===

/// Maximum length of a title, in bytes (not characters). Generous enough for
/// long-form and multi-byte titles while keeping the field bounded.
const MAX_TITLE_LENGTH: u64 = 300;

// === Structs ===

/// Dynamic-field key — one title (`String`) per release.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a release's title is set or replaced with a different value.
public struct ReleaseTitleSetEvent has copy, drop {
    release_id: address,
    title: String,
}

/// Emitted when an attached title is removed.
public struct ReleaseTitleClearedEvent has copy, drop {
    release_id: address,
}

// === Public Functions ===

/// Sets (or replaces) the release's title, stored exactly as given. Aborts
/// `EEmptyTitle` on an empty string and `ETitleTooLong` past
/// `MAX_TITLE_LENGTH` bytes, both before cap authorization. Setting the
/// value already stored neither writes nor emits.
public fun set_title(self: &mut Release, cap: &ReleaseAdminCap, title: String) {
    assert!(!title.is_empty(), EEmptyTitle);
    assert!(title.length() <= MAX_TITLE_LENGTH, ETitleTooLong);

    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let stored: &mut String = df::borrow_mut(uid, ExtensionKey());
        if (*stored == title) return;
        *stored = title;
    } else {
        df::add(uid, ExtensionKey(), title);
    };
    emit(ReleaseTitleSetEvent { release_id, title });
}

/// Removes the title, if any. Authorizes first; an absent title is a silent
/// no-op.
public fun clear_title(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: String = df::remove(uid, ExtensionKey());
        emit(ReleaseTitleClearedEvent { release_id });
    }
}

// === View Functions ===

/// Whether a title is attached to this release.
public fun has_title(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The release's title. Aborts `ENoTitle` if nothing is attached.
public fun title(self: &Release): &String {
    assert!(has_title(self), ENoTitle);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun title_set_event_fields(e: &ReleaseTitleSetEvent): (address, String) {
    (e.release_id, e.title)
}

#[test_only]
public fun title_cleared_event_fields(e: &ReleaseTitleClearedEvent): address {
    e.release_id
}
