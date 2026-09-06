// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A recording administrator's pointer to the Miso Engine session file for a
/// recording.
///
/// The domain-specific `EngineSession` wraps an unencrypted
/// `ori::data::WalrusBlob`. Ori models this as a standalone Walrus data
/// reference with explicit confidentiality metadata; encrypted blobs are
/// rejected when the wrapper is constructed.
///
/// This extension asserts only which session file the recording administrator
/// chose. It does not prove storage availability, file validity, or that the
/// session describes the attached recording. Publication tooling must perform
/// those checks before attachment.
module recording_engine_session::recording_engine_session;

use miso::recording::{Recording, RecordingAdminCap};
use ori::data::WalrusBlob;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// The supplied Miso Engine session file is encrypted.
#[error]
const EEncryptedEngineSession: vector<u8> =
    b"A Miso Engine session file must be unencrypted";

/// No Miso Engine session file is attached to this recording.
#[error]
const ENoEngineSession: vector<u8> =
    b"No Miso Engine session file is attached to this Recording";

// === Structs ===

/// Dynamic-field key — one Miso Engine session file per recording.
public struct ExtensionKey() has copy, drop, store;

/// An unencrypted Miso Engine session file stored as a standalone Walrus blob.
public struct EngineSession has copy, drop, store {
    data: WalrusBlob,
}

// === Events ===

/// Emitted when a Miso Engine session file is set or replaced.
public struct EngineSessionSetEvent has copy, drop {
    recording_id: ID,
    session: EngineSession,
}

/// Emitted when a Miso Engine session file is removed.
public struct EngineSessionUnsetEvent has copy, drop {
    recording_id: ID,
}

// === Public Functions ===

/// Creates an engine session reference from an unencrypted Walrus blob.
public fun new(data: WalrusBlob): EngineSession {
    assert!(!data.blob_confidentiality().is_encrypted(), EEncryptedEngineSession);
    EngineSession { data }
}

/// Returns the unencrypted Walrus blob containing the engine session file.
public fun data(self: &EngineSession): &WalrusBlob {
    &self.data
}

/// Sets or replaces the recording's Miso Engine session file.
public fun set_engine_session<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    session: EngineSession,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow_mut(uid, ExtensionKey()) = session;
    } else {
        df::add(uid, ExtensionKey(), session);
    };
    emit(EngineSessionSetEvent { recording_id, session });
}

/// Removes the recording's Miso Engine session file, if present. Idempotent.
public fun unset_engine_session<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: EngineSession = df::remove(uid, ExtensionKey());
        emit(EngineSessionUnsetEvent { recording_id });
    }
}

// === View Functions ===

/// Whether a Miso Engine session file is attached to the recording.
public fun has_engine_session<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's Miso Engine session file. Aborts when none is attached.
public fun engine_session<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &EngineSession {
    assert!(has_engine_session(self), ENoEngineSession);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields(e: &EngineSessionSetEvent): (ID, EngineSession) {
    (e.recording_id, e.session)
}

#[test_only]
public fun unset_event_recording_id(e: &EngineSessionUnsetEvent): ID {
    e.recording_id
}
