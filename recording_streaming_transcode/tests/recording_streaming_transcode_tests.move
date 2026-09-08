// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_streaming_transcode::recording_streaming_transcode_tests;

use musicos::recording;
use musicos::test_helpers;
use ori::data;
use recording_streaming_transcode::recording_streaming_transcode as transcode;
use std::unit_test::{assert_eq, destroy};
use sui::event;

public struct REC {}
public struct COMP {}
public struct OTHER_REC {}

const MAX_U256: u256 =
    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

fun new_recording(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(test_helpers::fake_id(ctx), ctx)
}

fun new_transcode(quilt_id: u256): transcode::StreamingTranscode {
    transcode::new(data::new_quilt(quilt_id))
}

fun quilt_id(value: &transcode::StreamingTranscode): u256 {
    transcode::quilt(value).quilt_id()
}

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);

    assert!(!transcode::has_streaming_transcode(&recording));

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(111));
    assert!(transcode::has_streaming_transcode(&recording));
    assert_eq!(quilt_id(transcode::streaming_transcode(&recording)), 111);

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(222));
    assert_eq!(quilt_id(transcode::streaming_transcode(&recording)), 222);

    transcode::unset_streaming_transcode(&mut recording, &cap);
    assert!(!transcode::has_streaming_transcode(&recording));

    // Unset is idempotent.
    transcode::unset_streaming_transcode(&mut recording, &cap);
    assert!(!transcode::has_streaming_transcode(&recording));

    destroy(recording);
    destroy(cap);
}

#[test]
fun complete_u256_quilt_id_domain_is_preserved() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(MAX_U256));
    assert_eq!(quilt_id(transcode::streaming_transcode(&recording)), MAX_U256);

    destroy(recording);
    destroy(cap);
}

#[test]
fun transcodes_are_isolated_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_recording(ctx);
    let (b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(
        test_helpers::fake_id(ctx),
        ctx,
    );

    transcode::set_streaming_transcode(&mut a, &a_cap, new_transcode(9));

    assert!(transcode::has_streaming_transcode(&a));
    assert!(!transcode::has_streaming_transcode(&b));

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test]
fun set_event_carries_recording_and_transcode() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording);

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(7));

    let events = event::events_by_type<transcode::StreamingTranscodeSetEvent>();
    assert_eq!(events.length(), 1);
    let (event_recording_id, value) = transcode::set_event_fields(&events[0]);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(value, new_transcode(7));
    assert_eq!(quilt_id(&value), 7);

    destroy(recording);
    destroy(cap);
}

#[test]
fun unset_event_is_emitted_only_after_removal() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording);

    transcode::unset_streaming_transcode(&mut recording, &cap);
    assert_eq!(
        event::events_by_type<transcode::StreamingTranscodeUnsetEvent>().length(),
        0,
    );

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(5));
    transcode::unset_streaming_transcode(&mut recording, &cap);

    let events = event::events_by_type<transcode::StreamingTranscodeUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(transcode::unset_event_recording_id(&events[0]), recording_id);

    destroy(recording);
    destroy(cap);
}

#[test, expected_failure(abort_code = transcode::ENoStreamingTranscode)]
fun streaming_transcode_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (recording, cap) = new_recording(ctx);
    let _ = transcode::streaming_transcode(&recording);
    destroy(recording);
    destroy(cap);
}
