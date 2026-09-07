// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_engine_session::recording_engine_session_e2e_tests;

use miso::recording::{Self, Recording, RecordingAdminCap};
use miso::test_helpers;
use ori::{confidentiality, data};
use recording_engine_session::recording_engine_session as session;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self, Scenario};

public struct REC {}
public struct COMP {}

const ADMIN: address = @0xAD;
const READER: address = @0x51;

fun plain_blob(blob_id: u256): data::WalrusBlob {
    data::new_blob(blob_id, confidentiality::new_unencrypted())
}

/// One session blob plus a single stem whose digest is all zeroes.
fun new_session(blob_id: u256): session::EngineSession {
    let mut digest = vector[];
    let mut i = 0u64;
    while (i < 32) {
        digest.push_back(0);
        i = i + 1;
    };
    session::new(
        plain_blob(blob_id),
        vector[session::new_stem(digest, plain_blob(blob_id + 1))],
    )
}

fun blob_id(value: &session::EngineSession): u256 {
    session::data(value).blob_id()
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
    session::set_engine_session(&mut recording, &cap, new_session(111));
    assert_eq!(blob_id(session::engine_session(&recording)), 111);
    assert_eq!(
        session::stem_data(&session::stems(session::engine_session(&recording))[0]).blob_id(),
        112,
    );

    let set_events = event::events_by_type<session::EngineSessionSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_recording_id, value) = session::set_event_fields(&set_events[0]);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(value, new_session(111));
    test_scenario::return_shared(recording);

    // Views are permissionless; only writes require the recording's cap.
    scenario.next_tx(READER);
    let recording = scenario.take_shared<Recording<REC, COMP>>();
    assert!(session::has_engine_session(&recording));
    assert_eq!(blob_id(session::engine_session(&recording)), 111);
    test_scenario::return_shared(recording);

    scenario.next_tx(ADMIN);
    let mut recording = scenario.take_shared<Recording<REC, COMP>>();
    session::set_engine_session(&mut recording, &cap, new_session(222));
    assert_eq!(blob_id(session::engine_session(&recording)), 222);
    session::unset_engine_session(&mut recording, &cap);
    assert!(!session::has_engine_session(&recording));

    let unset_events = event::events_by_type<session::EngineSessionUnsetEvent>();
    assert_eq!(unset_events.length(), 1);
    assert_eq!(session::unset_event_recording_id(&unset_events[0]), recording_id);
    test_scenario::return_shared(recording);

    destroy(cap);
    scenario.end();
}
