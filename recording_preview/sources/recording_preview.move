// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Recording audio preview: a short, public teaser clip for a recording,
/// stored as a dynamic field on the recording's UID, set/cleared via the
/// recording's cap-gated `uid_mut`.
///
/// V1 is deliberately minimal: the value is a bare `ori::data::WalrusBlob`
/// reference — no ingestion or attestation ties the preview to the
/// recording's master. What the blob contains (codec, duration, clip offset)
/// is client-side convention, not protocol state. An attested preview
/// standard can ship later as its own extension without touching this one.
module recording_preview::recording_preview;

use miso::recording::{Recording, RecordingAdminCap};
use ori::data::WalrusBlob;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No preview is attached to this recording.
const ENoPreview: u64 = 1;

// === Structs ===

/// Dynamic-field key — one preview per recording.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a preview is set or replaced. Carries the full Walrus
/// reference so an indexer can upsert its row without re-reading the object.
public struct PreviewSetEvent has copy, drop {
    recording_id: ID,
    preview: WalrusBlob,
}

/// Emitted when a preview is removed. The removed reference is recoverable
/// from the earlier `PreviewSetEvent`, so the recording ID suffices.
public struct PreviewUnsetEvent has copy, drop {
    recording_id: ID,
}

// === Public Functions ===

/// Sets (or replaces) the recording's preview. The reference must be a
/// standalone Walrus blob.
public fun set_preview<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    preview: WalrusBlob,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow_mut(uid, ExtensionKey()) = preview;
    } else {
        df::add(uid, ExtensionKey(), preview);
    };
    emit(PreviewSetEvent { recording_id, preview });
}

/// Removes the preview, if any.
public fun unset_preview<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: WalrusBlob = df::remove(uid, ExtensionKey());
        emit(PreviewUnsetEvent { recording_id });
    }
}

// === View Functions ===

/// Returns whether a preview is attached to this recording.
public fun has_preview<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// Borrows the preview's Walrus reference. Aborts if none is attached.
public fun preview<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &WalrusBlob {
    assert!(has_preview(self), ENoPreview);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields(e: &PreviewSetEvent): (ID, WalrusBlob) {
    (e.recording_id, e.preview)
}

#[test_only]
public fun unset_event_recording_id(e: &PreviewUnsetEvent): ID { e.recording_id }
