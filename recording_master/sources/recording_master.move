// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A recording's self-attested master audio, stored as a single `Audio` value.
/// Writes require its matching admin cap; reads are permissionless.
/// Metadata is structurally validated by `audio::new`, not externally verified.
/// Nautilus-attested audio belongs in a separate future package.
module recording_master::recording_master;

use audio::audio::Audio;
use musicos::recording::{Recording, RecordingAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;

/// No master is attached to this recording.
const ENoMaster: u64 = 1;

/// Dynamic-field key — one master per recording.
public struct ExtensionKey() has copy, drop, store;

/// Emitted when a master is set or replaced, carrying the recording's authentic
/// share-type identity and the complete audio value.
public struct MasterSetEvent<phantom RecordingShare, phantom CompositionShare> has copy, drop {
    recording_id: ID,
    master: Audio,
}

/// Emitted when an existing master is removed, carrying the recording's
/// authentic share-type identity.
public struct MasterUnsetEvent<phantom RecordingShare, phantom CompositionShare> has copy, drop {
    recording_id: ID,
}

/// Sets or replaces the entire master, including all audio metadata and its blob ID.
public fun set_master<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    master: Audio,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    let mut value_changed = true;
    if (df::exists(uid, ExtensionKey())) {
        let previous: &Audio = df::borrow(uid, ExtensionKey());
        value_changed = *previous != master;
        *df::borrow_mut(uid, ExtensionKey()) = master;
    } else {
        df::add(uid, ExtensionKey(), master);
    };
    if (value_changed) {
        emit(MasterSetEvent<RecordingShare, CompositionShare> { recording_id, master });
    };
}

/// Removes the master, if any. Idempotent; emits only when a value was removed.
public fun unset_master<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: Audio = df::remove(uid, ExtensionKey());
        emit(MasterUnsetEvent<RecordingShare, CompositionShare> { recording_id });
    }
}

/// Whether a master is attached to this recording.
public fun has_master<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's master audio. Aborts if none is attached.
public fun master<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &Audio {
    assert!(has_master(self), ENoMaster);
    df::borrow(self.uid(), ExtensionKey())
}

#[test_only]
public fun set_event_fields<RecordingShare, CompositionShare>(
    e: &MasterSetEvent<RecordingShare, CompositionShare>,
): (ID, Audio) {
    (e.recording_id, e.master)
}

#[test_only]
public fun unset_event_recording_id<RecordingShare, CompositionShare>(
    e: &MasterUnsetEvent<RecordingShare, CompositionShare>,
): ID {
    e.recording_id
}
