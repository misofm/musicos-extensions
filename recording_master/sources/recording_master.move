// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A recording's self-attested master: one `audio::audio::Audio` value stored
/// as a dynamic field on the recording's UID and written through its
/// cap-gated `uid_mut`. Reads are permissionless.
///
/// The metadata is structurally validated by `audio::new`, not externally
/// verified: the extension asserts which blob the recording administrator
/// chose and what they say is in it, not that the blob is stored, decodes, or
/// matches its PCM digest. Nautilus-attested audio belongs in a separate
/// package.
module recording_master::recording_master;

use audio::audio::Audio;
use musicos::recording::{Recording, RecordingAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No master is attached to this recording.
const ENoMaster: u64 = 1;

// === Structs ===

/// Dynamic-field key — one master per recording.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when the master is set to a value it did not already hold. The
/// `Audio` is bounded technical metadata plus a blob ID, so it is the value.
public struct RecordingMasterSetEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    master: Audio,
}

/// Emitted when an attached master is removed.
public struct RecordingMasterClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

// === Public Functions ===

/// Sets (or replaces) the master. Setting the value already held neither
/// writes nor emits.
public fun set_master<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    master: Audio,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let current: &mut Audio = df::borrow_mut(uid, ExtensionKey());
        if (*current == master) return;
        *current = master;
    } else {
        df::add(uid, ExtensionKey(), master);
    };
    emit(RecordingMasterSetEvent<RecordingShare> { recording_id, master });
}

/// Removes the master, if any. Silent when nothing is attached.
public fun clear_master<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: Audio = df::remove(uid, ExtensionKey());
        emit(RecordingMasterClearedEvent<RecordingShare> { recording_id });
    }
}

// === View Functions ===

/// Whether a master is attached to this recording.
public fun has_master<RecordingShare>(self: &Recording<RecordingShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's master. Aborts `ENoMaster` when none is attached.
public fun master<RecordingShare>(self: &Recording<RecordingShare>): &Audio {
    assert!(has_master(self), ENoMaster);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields<RecordingShare>(
    e: &RecordingMasterSetEvent<RecordingShare>,
): (address, Audio) {
    (e.recording_id, e.master)
}

#[test_only]
public fun cleared_event_fields<RecordingShare>(
    e: &RecordingMasterClearedEvent<RecordingShare>,
): address {
    e.recording_id
}
