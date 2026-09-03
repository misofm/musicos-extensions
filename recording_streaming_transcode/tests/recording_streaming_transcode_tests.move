// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_streaming_transcode::recording_streaming_transcode_tests;

use miso::recording;
use miso::test_helpers;
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

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);

    assert!(!transcode::has_streaming_transcode(&recording));

    transcode::set_streaming_transcode(&mut recording, &cap, data::new_quilt(111));
    assert!(transcode::has_streaming_transcode(&recording));
    assert_eq!(transcode::streaming_transcode(&recording).quilt_id(), 111);

    transcode::set_streaming_transcode(&mut recording, &cap, data::new_quilt(222));
    assert_eq!(transcode::streaming_transcode(&recording).quilt_id(), 222);

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

    transcode::set_streaming_transcode(&mut recording, &cap, data::new_quilt(MAX_U256));
    assert_eq!(transcode::streaming_transcode(&recording).quilt_id(), MAX_U256);

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

    transcode::set_streaming_transcode(&mut a, &a_cap, data::new_quilt(9));

    assert!(transcode::has_streaming_transcode(&a));
    assert!(!transcode::has_streaming_transcode(&b));

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test]
fun set_event_carries_recording_and_quilt() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording);

    transcode::set_streaming_transcode(&mut recording, &cap, data::new_quilt(7));

    let events = event::events_by_type<transcode::StreamingTranscodeSetEvent>();
    assert_eq!(events.length(), 1);
    let (event_recording_id, quilt) = transcode::set_event_fields(&events[0]);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(quilt, data::new_quilt(7));

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

    transcode::set_streaming_transcode(&mut recording, &cap, data::new_quilt(5));
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
