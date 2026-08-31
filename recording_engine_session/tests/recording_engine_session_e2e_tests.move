// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_engine_session::recording_engine_session_e2e_tests;

use miso::recording::{Self, Recording, RecordingAdminCap};
use miso::test_helpers;
use ori::walrus_data;
use recording_engine_session::recording_engine_session as session;
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::test_scenario as ts;

public struct REC {}
public struct COMP {}

const ADMIN: address = @0xAD;
const READER: address = @0x51;

fun publish(ts: &mut ts::Scenario): RecordingAdminCap<REC> {
    let (recording, cap) = recording::new_for_testing<REC, COMP>(
        test_helpers::fake_id(ts.ctx()),
        ts.ctx(),
    );
    let clock = clock::create_for_testing(ts.ctx());
    recording.publish(&cap, &clock);
    clock.destroy_for_testing();
    cap
}

#[test]
fun published_recording_session_is_publicly_discoverable_and_admin_mutable() {
    let mut scenario = ts::begin(ADMIN);
    let cap = publish(&mut scenario);

    scenario.next_tx(ADMIN);
    let mut recording = scenario.take_shared<Recording<REC, COMP>>();
    session::attach_engine_session(&mut recording, &cap, walrus_data::new_blob(11));
    ts::return_shared(recording);

    scenario.next_tx(READER);
    let recording = scenario.take_shared<Recording<REC, COMP>>();
    assert_eq!(session::engine_session(&recording).reference().blob_id(), 11);
    ts::return_shared(recording);

    scenario.next_tx(ADMIN);
    let mut recording = scenario.take_shared<Recording<REC, COMP>>();
    session::replace_engine_session(&mut recording, &cap, walrus_data::new_blob(22));
    assert_eq!(session::engine_session(&recording).reference().blob_id(), 22);
    ts::return_shared(recording);

    destroy(cap);
    scenario.end();
}
