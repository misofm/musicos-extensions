// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A recording administrator's pointer to the complete Walrus Quilt containing
/// the recording's streaming transcodes.
///
/// The domain-specific `StreamingTranscode` wraps an
/// `ori::data::WalrusQuilt`, not a standalone blob or a single Quilt patch.
/// Clients combine its content-addressed Quilt ID with the package's
/// conventional item identifiers to locate the master HLS playlist, rendition
/// playlists, initialization maps, and media segments.
///
/// This extension asserts only which Quilt the recording administrator chose.
/// It does not prove storage availability, media conformance, or successful
/// playback. Those checks belong in the publication workflow before attachment.
module recording_streaming_transcode::recording_streaming_transcode;

use musicos::recording::{Recording, RecordingAdminCap};
use ori::data::WalrusQuilt;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No streaming transcode Quilt is attached to this recording.
#[error]
const ENoStreamingTranscode: vector<u8> =
    b"No streaming transcode Quilt is attached to this Recording";

// === Structs ===

/// Dynamic-field key — one streaming transcode reference per recording.
public struct ExtensionKey() has copy, drop, store;

/// A complete streaming transcode package stored as a Walrus Quilt.
///
/// The wrapper gives streaming transcodes their own domain type while keeping
/// rendition metadata canonical inside the content-addressed Quilt.
public struct StreamingTranscode has copy, drop, store {
    quilt: WalrusQuilt,
}

// === Events ===

/// Emitted when a streaming transcode Quilt is set or replaced.
public struct StreamingTranscodeSetEvent has copy, drop {
    recording_id: ID,
    transcode: StreamingTranscode,
}

/// Emitted when a streaming transcode Quilt is removed.
public struct StreamingTranscodeUnsetEvent has copy, drop {
    recording_id: ID,
}

// === Public Functions ===

/// Creates a streaming transcode reference from a complete Walrus Quilt.
public fun new(quilt: WalrusQuilt): StreamingTranscode {
    StreamingTranscode { quilt }
}

/// Returns the complete Walrus Quilt containing the streaming package.
public fun quilt(self: &StreamingTranscode): &WalrusQuilt {
    &self.quilt
}

/// Sets or replaces the recording's streaming transcode reference.
public fun set_streaming_transcode<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    transcode: StreamingTranscode,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow_mut(uid, ExtensionKey()) = transcode;
    } else {
        df::add(uid, ExtensionKey(), transcode);
    };
    emit(StreamingTranscodeSetEvent { recording_id, transcode });
}

/// Removes the recording's streaming transcode reference, if present. Idempotent.
public fun unset_streaming_transcode<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: StreamingTranscode = df::remove(uid, ExtensionKey());
        emit(StreamingTranscodeUnsetEvent { recording_id });
    }
}

// === View Functions ===

/// Whether a streaming transcode reference is attached to the recording.
public fun has_streaming_transcode<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's streaming transcode reference. Aborts when none is attached.
public fun streaming_transcode<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &StreamingTranscode {
    assert!(has_streaming_transcode(self), ENoStreamingTranscode);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields(
    e: &StreamingTranscodeSetEvent,
): (ID, StreamingTranscode) {
    (e.recording_id, e.transcode)
}

#[test_only]
public fun unset_event_recording_id(e: &StreamingTranscodeUnsetEvent): ID {
    e.recording_id
}
