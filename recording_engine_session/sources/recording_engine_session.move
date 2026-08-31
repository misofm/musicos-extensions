// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The canonical, publicly readable engine-session pointer for a Recording.
///
/// The referenced standalone Walrus blob is plaintext metadata. It describes
/// the mix and names separately encrypted stem blobs; access to their shared
/// AES key is enforced independently by the Miso Record Seal policy. Keeping
/// only this root pointer on chain makes the complete delivery graph directly
/// discoverable from the Recording without duplicating every stem reference in
/// dynamic fields or requiring an indexer.
module recording_engine_session::recording_engine_session;

use miso::recording::{Recording, RecordingAdminCap};
use ori::walrus_data::WalrusData;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

const EEngineSessionAlreadyAttached: u64 = 1;
const EEngineSessionMissing: u64 = 2;
const EEncryptedEngineSession: u64 = 3;

// === Structs ===

/// Dynamic-field key — one canonical engine session per Recording.
public struct ExtensionKey() has copy, drop, store;

/// The Recording-admin-authored root of the public delivery graph.
public struct EngineSession has copy, drop, store {
    reference: WalrusData,
}

// === Events ===

/// Emitted when a Recording receives its first engine session.
public struct EngineSessionAttachedEvent has copy, drop {
    recording_id: ID,
    reference: WalrusData,
}

/// Emitted when the Recording admin explicitly changes the canonical session.
public struct EngineSessionReplacedEvent has copy, drop {
    recording_id: ID,
    reference: WalrusData,
}

/// Emitted when the canonical session is removed.
public struct EngineSessionUnsetEvent has copy, drop {
    recording_id: ID,
}

// === Public Functions ===

/// Attaches the first canonical engine session.
///
/// This never upserts: an occupied Recording requires the explicit replacement
/// function so tooling cannot silently change purchaser-visible audio.
public fun attach_engine_session<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    reference: WalrusData,
) {
    assert_public_session(&reference);
    assert!(!has_engine_session(self), EEngineSessionAlreadyAttached);

    let recording_id = object::id(self);
    df::add(
        self.uid_mut(cap),
        ExtensionKey(),
        EngineSession { reference },
    );
    emit(EngineSessionAttachedEvent { recording_id, reference });
}

/// Explicitly replaces an existing canonical engine session.
public fun replace_engine_session<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    reference: WalrusData,
) {
    assert_public_session(&reference);
    assert!(has_engine_session(self), EEngineSessionMissing);

    let recording_id = object::id(self);
    *df::borrow_mut<ExtensionKey, EngineSession>(
        self.uid_mut(cap),
        ExtensionKey(),
    ) = EngineSession { reference };
    emit(EngineSessionReplacedEvent { recording_id, reference });
}

/// Removes the canonical engine session, if one is attached.
public fun unset_engine_session<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    if (!has_engine_session(self)) return;
    let recording_id = object::id(self);
    let _: EngineSession = df::remove(self.uid_mut(cap), ExtensionKey());
    emit(EngineSessionUnsetEvent { recording_id });
}

// === View Functions ===

/// Whether the Recording has a canonical engine session.
public fun has_engine_session<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The Recording's canonical engine session. Aborts when none is attached.
public fun engine_session<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &EngineSession {
    assert!(has_engine_session(self), EEngineSessionMissing);
    df::borrow(self.uid(), ExtensionKey())
}

/// The public standalone Walrus session reference.
public fun reference(self: &EngineSession): &WalrusData {
    &self.reference
}

fun assert_public_session(reference: &WalrusData) {
    reference.assert_is_blob();
    assert!(!reference.is_encrypted(), EEncryptedEngineSession);
}

// === Test Functions ===

#[test_only]
public fun attached_event_fields(
    event: &EngineSessionAttachedEvent,
): (ID, WalrusData) {
    (event.recording_id, event.reference)
}

#[test_only]
public fun replaced_event_fields(
    event: &EngineSessionReplacedEvent,
): (ID, WalrusData) {
    (event.recording_id, event.reference)
}

#[test_only]
public fun unset_event_recording_id(event: &EngineSessionUnsetEvent): ID {
    event.recording_id
}
