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

use musicos::recording::{Self, Recording, RecordingAdminCap};
use ori::data::{Self, WalrusQuilt};
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
public struct RecordingStreamingTranscodeSetEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    had_transcode: bool,
    previous_quilt_id: u256,
    quilt_id: u256,
}

/// Emitted when a streaming transcode Quilt is removed.
public struct RecordingStreamingTranscodeClearedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    quilt_id: u256,
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
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let quilt_id = quilt(&transcode).quilt_id();
    let uid = self.uid_mut(cap);
    let had_transcode = df::exists(uid, ExtensionKey());
    let mut previous_quilt_id = 0;
    if (had_transcode) {
        let previous: &StreamingTranscode = df::borrow(uid, ExtensionKey());
        previous_quilt_id = quilt(previous).quilt_id();
        *df::borrow_mut(uid, ExtensionKey()) = transcode;
    } else {
        df::add(uid, ExtensionKey(), transcode);
    };
    emit(RecordingStreamingTranscodeSetEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        admin_cap_id,
        had_transcode,
        previous_quilt_id,
        quilt_id,
    });
}

/// Removes the recording's streaming transcode reference, if present. Idempotent.
public fun unset_streaming_transcode<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let removed: StreamingTranscode = df::remove(uid, ExtensionKey());
        let quilt_id = quilt(&removed).quilt_id();
        emit(RecordingStreamingTranscodeClearedEvent<RecordingShare, CompositionShare> {
            recording_id,
            composition_id,
            admin_cap_id,
            quilt_id,
        });
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
public fun set_event_fields<RecordingShare, CompositionShare>(
    e: &RecordingStreamingTranscodeSetEvent<RecordingShare, CompositionShare>,
): (ID, StreamingTranscode) {
    (object::id_from_address(e.recording_id), new(data::new_quilt(e.quilt_id)))
}

#[test_only]
public fun set_event_payload<RecordingShare, CompositionShare>(
    e: &RecordingStreamingTranscodeSetEvent<RecordingShare, CompositionShare>,
): (address, address, address, bool, u256, u256) {
    (
        e.recording_id,
        e.composition_id,
        e.admin_cap_id,
        e.had_transcode,
        e.previous_quilt_id,
        e.quilt_id,
    )
}

#[test_only]
public fun clear_event_payload<RecordingShare, CompositionShare>(
    e: &RecordingStreamingTranscodeClearedEvent<RecordingShare, CompositionShare>,
): (address, address, address, u256) {
    (e.recording_id, e.composition_id, e.admin_cap_id, e.quilt_id)
}

#[test_only]
public fun unset_event_recording_id<RecordingShare, CompositionShare>(
    e: &RecordingStreamingTranscodeClearedEvent<RecordingShare, CompositionShare>,
): ID {
    object::id_from_address(e.recording_id)
}

#[test_only]
public fun set_event_bcs<RecordingShare, CompositionShare>(
    e: &RecordingStreamingTranscodeSetEvent<RecordingShare, CompositionShare>,
): vector<u8> {
    sui::bcs::to_bytes(e)
}

#[test_only]
public fun clear_event_bcs<RecordingShare, CompositionShare>(
    e: &RecordingStreamingTranscodeClearedEvent<RecordingShare, CompositionShare>,
): vector<u8> {
    sui::bcs::to_bytes(e)
}
