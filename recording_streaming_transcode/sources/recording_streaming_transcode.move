// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A recording administrator's pointer to the complete Walrus Quilt holding
/// the recording's streaming transcodes, stored as a dynamic field on the
/// recording's UID and written through its cap-gated `uid_mut`. Reads are
/// permissionless.
///
/// `StreamingTranscode` wraps an `ori::data::WalrusQuilt` — not a standalone
/// blob or a single Quilt patch. Clients combine its content-addressed Quilt
/// ID with the package's conventional item identifiers to locate the master
/// HLS playlist, rendition playlists, initialization maps, and media segments.
///
/// The extension asserts only which Quilt the administrator chose, not
/// storage availability, media conformance, or successful playback. Those
/// checks belong in the publication workflow before attachment.
module recording_streaming_transcode::recording_streaming_transcode;

use musicos::recording::{Recording, RecordingAdminCap};
use ori::data::WalrusQuilt;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No streaming transcode Quilt is attached to this recording.
const ENoStreamingTranscode: u64 = 1;

// === Structs ===

/// Dynamic-field key — one streaming transcode reference per recording.
public struct ExtensionKey() has copy, drop, store;

/// A complete streaming transcode package stored as a Walrus Quilt. The
/// wrapper gives streaming transcodes their own domain type while rendition
/// metadata stays canonical inside the content-addressed Quilt.
public struct StreamingTranscode has copy, drop, store {
    quilt: WalrusQuilt,
}

// === Events ===

/// Emitted when the transcode is set to a value it did not already hold.
public struct RecordingStreamingTranscodeSetEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    quilt_id: u256,
}

/// Emitted when an attached transcode is removed.
public struct RecordingStreamingTranscodeClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

// === Public Functions ===

/// Creates a streaming transcode reference from a complete Walrus Quilt.
public fun new(quilt: WalrusQuilt): StreamingTranscode {
    StreamingTranscode { quilt }
}

/// Sets (or replaces) the recording's transcode. Setting the value already
/// held neither writes nor emits.
public fun set_streaming_transcode<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    transcode: StreamingTranscode,
) {
    let recording_id = object::id(self).to_address();
    let quilt_id = transcode.quilt.quilt_id();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let current: &mut StreamingTranscode = df::borrow_mut(uid, ExtensionKey());
        if (*current == transcode) return;
        *current = transcode;
    } else {
        df::add(uid, ExtensionKey(), transcode);
    };
    emit(RecordingStreamingTranscodeSetEvent<RecordingShare> { recording_id, quilt_id });
}

/// Removes the recording's transcode, if any. Silent when nothing is attached.
public fun clear_streaming_transcode<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: StreamingTranscode = df::remove(uid, ExtensionKey());
        emit(RecordingStreamingTranscodeClearedEvent<RecordingShare> { recording_id });
    }
}

// === View Functions ===

/// Whether a streaming transcode reference is attached to the recording.
public fun has_streaming_transcode<RecordingShare>(self: &Recording<RecordingShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's transcode. Aborts `ENoStreamingTranscode` when none is attached.
public fun streaming_transcode<RecordingShare>(
    self: &Recording<RecordingShare>,
): &StreamingTranscode {
    assert!(has_streaming_transcode(self), ENoStreamingTranscode);
    df::borrow(self.uid(), ExtensionKey())
}

/// The complete Walrus Quilt containing the streaming package.
public fun quilt(self: &StreamingTranscode): &WalrusQuilt {
    &self.quilt
}

// === Test Functions ===

#[test_only]
public fun set_event_fields<RecordingShare>(
    e: &RecordingStreamingTranscodeSetEvent<RecordingShare>,
): (address, u256) {
    (e.recording_id, e.quilt_id)
}

#[test_only]
public fun cleared_event_fields<RecordingShare>(
    e: &RecordingStreamingTranscodeClearedEvent<RecordingShare>,
): address {
    e.recording_id
}
