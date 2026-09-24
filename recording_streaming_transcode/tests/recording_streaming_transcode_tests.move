// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Set/read/replace/clear mechanics against a bare `Recording`. Nothing here
/// crosses a transaction boundary, so `tx_context::dummy()` suffices; the
/// published, shared shape is covered in
/// `recording_streaming_transcode_e2e_tests`.
#[test_only]
module recording_streaming_transcode::recording_streaming_transcode_tests;

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

public struct REC {}
public struct OTHER_REC {}

const MAX_U256: u256 =
    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

/// Only a `Recording` is needed, so a bare id stands in for its composition.
fun new_rec<RecordingShare>(
    ctx: &mut TxContext,
): (Recording<RecordingShare>, RecordingAdminCap<RecordingShare>) {
    recording::new_for_testing<RecordingShare>(object::id_from_address(@0xC0FFEE), ctx)
}

fun new_transcode(quilt_id: u256): StreamingTranscode {
    transcode::new(data::new_quilt(quilt_id))
}

fun quilt_id(value: &StreamingTranscode): u256 {
    transcode::quilt(value).quilt_id()
}

/// Replays one set event into an event-only projection of the field.
fun project_set(
    projected_exists: &mut bool,
    projected_quilt_id: &mut u256,
    event: &RecordingStreamingTranscodeSetEvent<REC>,
) {
    let (_, event_quilt_id) = transcode::set_event_fields(event);
    *projected_exists = true;
    *projected_quilt_id = event_quilt_id;
}

fun project_cleared(projected_exists: &mut bool, projected_quilt_id: &mut u256) {
    assert!(*projected_exists);
    *projected_exists = false;
    *projected_quilt_id = 0;
}

fun assert_projection_matches_view(
    rec: &Recording<REC>,
    projected_exists: bool,
    projected_quilt_id: u256,
) {
    assert_eq!(transcode::has_streaming_transcode(rec), projected_exists);
    if (projected_exists) {
        assert_eq!(quilt_id(transcode::streaming_transcode(rec)), projected_quilt_id);
    };
}

/// Every write is replayed from its event alone and compared to the views,
/// so the event stream is sufficient to track the field.
/// The set event's fields, compared one at a time.
fun assert_set_event<RecordingShare>(
    e: &RecordingStreamingTranscodeSetEvent<RecordingShare>,
    recording_id: ID,
    quilt_id: u256,
) {
    let (event_recording_id, event_quilt_id) = transcode::set_event_fields(e);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(event_quilt_id, quilt_id);
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);
    let mut projected_exists = false;
    let mut projected_quilt_id = 0;

    assert!(!transcode::has_streaming_transcode(&rec));

    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(111));
    assert!(transcode::has_streaming_transcode(&rec));
    assert_eq!(quilt_id(transcode::streaming_transcode(&rec)), 111);
    let set_events = events_by_type<RecordingStreamingTranscodeSetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    assert_set_event(&set_events[0], rec_id, 111);
    project_set(&mut projected_exists, &mut projected_quilt_id, &set_events[0]);
    assert_projection_matches_view(&rec, projected_exists, projected_quilt_id);

    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(222));
    assert_eq!(quilt_id(transcode::streaming_transcode(&rec)), 222);
    let set_events = events_by_type<RecordingStreamingTranscodeSetEvent<REC>>();
    assert_eq!(set_events.length(), 2);
    assert_set_event(&set_events[1], rec_id, 222);
    project_set(&mut projected_exists, &mut projected_quilt_id, &set_events[1]);
    assert_projection_matches_view(&rec, projected_exists, projected_quilt_id);

    // Equal replacement neither writes nor emits.
    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(222));
    assert_eq!(events_by_type<RecordingStreamingTranscodeSetEvent<REC>>().length(), 2);
    assert_projection_matches_view(&rec, projected_exists, projected_quilt_id);

    transcode::clear_streaming_transcode(&mut rec, &cap);
    assert!(!transcode::has_streaming_transcode(&rec));
    let cleared = events_by_type<RecordingStreamingTranscodeClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(transcode::cleared_event_fields(&cleared[0]), rec_id);
    project_cleared(&mut projected_exists, &mut projected_quilt_id);
    assert_projection_matches_view(&rec, projected_exists, projected_quilt_id);

    // Clear is idempotent and silent when absent.
    transcode::clear_streaming_transcode(&mut rec, &cap);
    assert!(!transcode::has_streaming_transcode(&rec));
    assert_eq!(events_by_type<RecordingStreamingTranscodeClearedEvent<REC>>().length(), 1);
    assert_projection_matches_view(&rec, projected_exists, projected_quilt_id);

    // Re-set after removal is a fresh attachment, then clear it again.
    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(333));
    let set_events = events_by_type<RecordingStreamingTranscodeSetEvent<REC>>();
    assert_eq!(set_events.length(), 3);
    assert_set_event(&set_events[2], rec_id, 333);
    project_set(&mut projected_exists, &mut projected_quilt_id, &set_events[2]);
    assert_projection_matches_view(&rec, projected_exists, projected_quilt_id);
    transcode::clear_streaming_transcode(&mut rec, &cap);
    let cleared = events_by_type<RecordingStreamingTranscodeClearedEvent<REC>>();
    assert_eq!(cleared.length(), 2);
    project_cleared(&mut projected_exists, &mut projected_quilt_id);
    assert_projection_matches_view(&rec, projected_exists, projected_quilt_id);

    // Three 64-byte set events plus two 32-byte cleared events.
    set_events.do_ref!(|e| assert_eq!(to_bytes(e).length(), 64));
    cleared.do_ref!(|e| assert_eq!(to_bytes(e).length(), 32));

    destroy(rec);
    destroy(cap);
}

#[test]
fun complete_u256_quilt_id_domain_is_preserved() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);
    let values = vector[0u256, 9007199254740993, 9223372036854775809, MAX_U256];

    values.do!(|value| {
        transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(value));
        assert_eq!(quilt_id(transcode::streaming_transcode(&rec)), value);
    });

    let set_events = events_by_type<RecordingStreamingTranscodeSetEvent<REC>>();
    assert_eq!(set_events.length(), 4);
    values.length().do!(|i| {
        assert_set_event(&set_events[i], rec_id, values[i]);
        assert_eq!(to_bytes(&set_events[i]).length(), 64);
    });
    // The Quilt ID is the trailing 32 little-endian bytes.
    let max_bytes = to_bytes(&set_events[3]);
    32u64.do!(|i| assert_eq!(max_bytes[32 + i], 0xff));

    // A present field with Quilt ID zero is distinct from an absent field.
    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(0));
    assert!(transcode::has_streaming_transcode(&rec));
    assert_eq!(quilt_id(transcode::streaming_transcode(&rec)), 0);
    transcode::clear_streaming_transcode(&mut rec, &cap);
    assert!(!transcode::has_streaming_transcode(&rec));
    assert_eq!(events_by_type<RecordingStreamingTranscodeClearedEvent<REC>>().length(), 1);

    destroy(rec);
    destroy(cap);
}

#[test]
fun transcodes_are_isolated_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec<REC>(ctx);
    let (mut b, b_cap) = new_rec<OTHER_REC>(ctx);

    // Constructors and permissionless views are silent.
    let _ = new_transcode(1);
    assert_eq!(events_by_type<RecordingStreamingTranscodeSetEvent<REC>>().length(), 0);
    assert_eq!(events_by_type<RecordingStreamingTranscodeSetEvent<OTHER_REC>>().length(), 0);

    transcode::set_streaming_transcode(&mut a, &a_cap, new_transcode(9));
    transcode::set_streaming_transcode(&mut b, &b_cap, new_transcode(10));

    assert_eq!(quilt_id(transcode::streaming_transcode(&a)), 9);
    assert_eq!(quilt_id(transcode::streaming_transcode(&b)), 10);
    let a_events = events_by_type<RecordingStreamingTranscodeSetEvent<REC>>();
    let b_events = events_by_type<RecordingStreamingTranscodeSetEvent<OTHER_REC>>();
    assert_eq!(a_events.length(), 1);
    assert_eq!(b_events.length(), 1);
    assert_set_event(&a_events[0], object::id(&a), 9);
    assert_set_event(&b_events[0], object::id(&b), 10);

    transcode::clear_streaming_transcode(&mut a, &a_cap);
    assert!(!transcode::has_streaming_transcode(&a));
    assert!(transcode::has_streaming_transcode(&b));
    assert_eq!(events_by_type<RecordingStreamingTranscodeClearedEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingStreamingTranscodeClearedEvent<OTHER_REC>>().length(), 0);

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test]
fun set_event_carries_recording_and_quilt_id() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);

    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(7));

    let events = events_by_type<RecordingStreamingTranscodeSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    assert_set_event(&events[0], rec_id, 7);
    let bytes = to_bytes(&events[0]);
    assert_eq!(bytes.length(), 64);
    assert_eq!(bytes[32], 7);

    destroy(rec);
    destroy(cap);
}

#[test]
fun cleared_event_is_emitted_only_after_removal() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);

    transcode::clear_streaming_transcode(&mut rec, &cap);
    assert_eq!(events_by_type<RecordingStreamingTranscodeClearedEvent<REC>>().length(), 0);

    transcode::set_streaming_transcode(&mut rec, &cap, new_transcode(5));
    transcode::clear_streaming_transcode(&mut rec, &cap);

    let events = events_by_type<RecordingStreamingTranscodeClearedEvent<REC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(transcode::cleared_event_fields(&events[0]), rec_id);
    assert_eq!(to_bytes(&events[0]).length(), 32);

    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = transcode::ENoStreamingTranscode)]
fun streaming_transcode_aborts_when_absent() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec<REC>(ctx);
    let _ = transcode::streaming_transcode(&rec);
    destroy(rec);
    destroy(cap);
}
