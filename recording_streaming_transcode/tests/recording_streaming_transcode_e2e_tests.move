// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_streaming_transcode::recording_streaming_transcode_e2e_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers;
use ori::data;
use recording_streaming_transcode::recording_streaming_transcode as transcode;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self, Scenario};

public struct REC {}
public struct COMP {}

const ADMIN: address = @0xAD;
const READER: address = @0x51;

fun new_transcode(quilt_id: u256): transcode::StreamingTranscode {
    transcode::new(data::new_quilt(quilt_id))
}

fun quilt_id(value: &transcode::StreamingTranscode): u256 {
    transcode::quilt(value).quilt_id()
}

fun publish_and_share_recording(scenario: &mut Scenario): RecordingAdminCap<REC> {
    let (recording, cap) = recording::new_for_testing<REC, COMP>(
        test_helpers::fake_id(scenario.ctx()),
        scenario.ctx(),
    );
    let clock = sui::clock::create_for_testing(scenario.ctx());
    recording.publish(&cap, &clock);
    clock.destroy_for_testing();
    cap
}

#[test]
fun lifecycle_works_on_a_published_shared_recording() {
    let mut scenario = test_scenario::begin(ADMIN);
    let cap = publish_and_share_recording(&mut scenario);

    scenario.next_tx(ADMIN);
    let mut recording = scenario.take_shared<Recording<REC, COMP>>();
    let recording_id = object::id(&recording);
    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(111));
    assert_eq!(quilt_id(transcode::streaming_transcode(&recording)), 111);

    let set_events = event::events_by_type<transcode::StreamingTranscodeSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_recording_id, value) = transcode::set_event_fields(&set_events[0]);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(value, new_transcode(111));
    test_scenario::return_shared(recording);

    // Views are permissionless; only writes require the recording's cap.
    scenario.next_tx(READER);
    let recording = scenario.take_shared<Recording<REC, COMP>>();
    assert!(transcode::has_streaming_transcode(&recording));
    assert_eq!(quilt_id(transcode::streaming_transcode(&recording)), 111);
    test_scenario::return_shared(recording);

    scenario.next_tx(ADMIN);
    let mut recording = scenario.take_shared<Recording<REC, COMP>>();
    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(222));
    assert_eq!(quilt_id(transcode::streaming_transcode(&recording)), 222);
    transcode::unset_streaming_transcode(&mut recording, &cap);
    assert!(!transcode::has_streaming_transcode(&recording));

    let unset_events = event::events_by_type<transcode::StreamingTranscodeUnsetEvent>();
    assert_eq!(unset_events.length(), 1);
    assert_eq!(transcode::unset_event_recording_id(&unset_events[0]), recording_id);
    test_scenario::return_shared(recording);

    destroy(cap);
    scenario.end();
}
