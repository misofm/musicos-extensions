// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_streaming_transcode` against the
/// production shape: a `Recording` is published and shared first, and the
/// extension operates on it later, across real transaction boundaries and
/// distinct senders. Reads are open to anyone; writes require the admin cap.
#[test_only]
module recording_streaming_transcode::recording_streaming_transcode_e2e_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use ori::data;
use recording_streaming_transcode::recording_streaming_transcode::{
    Self as transcode,
    StreamingTranscode,
    RecordingStreamingTranscodeSetEvent,
    RecordingStreamingTranscodeClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;
use sui::test_scenario::{Self as ts, Scenario};

public struct REC {}

const ADMIN: address = @0xAD;
const READER: address = @0x51;

fun new_transcode(quilt_id: u256): StreamingTranscode {
    transcode::new(data::new_quilt(quilt_id))
}

fun quilt_id(value: &StreamingTranscode): u256 {
    transcode::quilt(value).quilt_id()
}

/// Creates and publishes (shares) a recording as the current sender.
fun publish_and_share_recording(ts: &mut Scenario): RecordingAdminCap<REC> {
    let (rec, cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    rec.publish(&cap);
    cap
}

/// The set event's fields, compared one at a time.
fun assert_set_event<RecordingShare>(
    e: &RecordingStreamingTranscodeSetEvent<RecordingShare>,
    recording_id: address,
    quilt_id: u256,
) {
    let (event_recording_id, event_quilt_id) = transcode::set_event_fields(e);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(event_quilt_id, quilt_id);
}

#[test]
fun lifecycle_works_on_a_published_shared_recording() {
    let mut ts = ts::begin(ADMIN);
    let cap = publish_and_share_recording(&mut ts);

    // === Tx 2 (ADMIN): attach a transcode to the shared recording ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    let rec_id = object::id(&rec).to_address();
    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(111));
    assert_eq!(quilt_id(transcode::streaming_transcode(&rec)), 111);

    let set_events = events_by_type<RecordingStreamingTranscodeSetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    assert_set_event(&set_events[0], rec_id, 111);
    assert_eq!(to_bytes(&set_events[0]).length(), 64);
    ts::return_shared(rec);

    // === Tx 3 (READER): views are permissionless ===
    ts.next_tx(READER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(transcode::has_streaming_transcode(&rec));
    assert_eq!(quilt_id(transcode::streaming_transcode(&rec)), 111);
    ts::return_shared(rec);

    // === Tx 4 (ADMIN): equal set is silent; replace; then clear ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(111));
    assert_eq!(events_by_type<RecordingStreamingTranscodeSetEvent<REC>>().length(), 0);

    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(222));
    assert_eq!(quilt_id(transcode::streaming_transcode(&rec)), 222);
    assert_eq!(events_by_type<RecordingStreamingTranscodeSetEvent<REC>>().length(), 1);

    transcode::clear_streaming_transcode(&mut rec, &cap);
    assert!(!transcode::has_streaming_transcode(&rec));
    let cleared = events_by_type<RecordingStreamingTranscodeClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(transcode::cleared_event_fields(&cleared[0]), rec_id);
    assert_eq!(to_bytes(&cleared[0]).length(), 32);
    ts::return_shared(rec);

    // === Tx 5 (READER): removal is visible to any reader ===
    ts.next_tx(READER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(!transcode::has_streaming_transcode(&rec));
    ts::return_shared(rec);

    destroy(cap);
    ts.end();
}
