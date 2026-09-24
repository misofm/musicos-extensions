// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The version name of a recording — which take of the composition it is
/// ("Live", "Radio Edit", "Acoustic") — stored as a dynamic field on the
/// recording's UID and written through its cap-gated `uid_mut`.
///
/// A recording's display title is its composition's title plus this version
/// name; core `Recording` carries no title of its own. Absence means the
/// recording is the composition's plain rendition and displays under the
/// composition title alone.
///
/// The value is a non-empty UTF-8 `String` of at most `MAX_VERSION_LENGTH`
/// bytes, mutable through the recording's admin cap.
module recording_version::recording_version;

use musicos::recording::{Recording, RecordingAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No version name is attached to this recording.
const ENoVersion: u64 = 1;
/// The version name is empty.
const EEmptyVersion: u64 = 2;
/// The version name exceeds `MAX_VERSION_LENGTH` bytes.
const EVersionTooLong: u64 = 3;

// === Constants ===

/// Maximum version name length in bytes.
const MAX_VERSION_LENGTH: u64 = 300;

// === Structs ===

/// Dynamic-field key — one version name per recording.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when the version name is set to a value it did not already hold.
public struct RecordingVersionSetEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    version: String,
}

/// Emitted when an attached version name is removed.
public struct RecordingVersionClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

// === Public Functions ===

/// Sets (or replaces) the recording's version name. Aborts `EEmptyVersion`
/// on an empty string and `EVersionTooLong` past `MAX_VERSION_LENGTH` bytes.
/// Setting the value already held neither writes nor emits.
public fun set_version<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    version: String,
) {
    assert!(!version.is_empty(), EEmptyVersion);
    assert!(version.length() <= MAX_VERSION_LENGTH, EVersionTooLong);
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let current: &mut String = df::borrow_mut(uid, ExtensionKey());
        if (*current == version) return;
        *current = version;
    } else {
        df::add(uid, ExtensionKey(), version);
    };
    emit(RecordingVersionSetEvent<RecordingShare> { recording_id, version });
}

/// Removes the version name, if any. Silent when nothing is attached.
public fun clear_version<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: String = df::remove(uid, ExtensionKey());
        emit(RecordingVersionClearedEvent<RecordingShare> { recording_id });
    }
}

// === View Functions ===

/// Whether a version name is attached to this recording.
public fun has_version<RecordingShare>(self: &Recording<RecordingShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's version name. Aborts `ENoVersion` when none is attached.
public fun version<RecordingShare>(self: &Recording<RecordingShare>): &String {
    assert!(has_version(self), ENoVersion);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields<RecordingShare>(
    e: &RecordingVersionSetEvent<RecordingShare>,
): (address, String) {
    (e.recording_id, e.version)
}

#[test_only]
public fun cleared_event_fields<RecordingShare>(
    e: &RecordingVersionClearedEvent<RecordingShare>,
): address {
    e.recording_id
}
