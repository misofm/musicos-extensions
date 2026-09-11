// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_engine_session::recording_engine_session_e2e_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers;
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

fun publish_and_share_recording(scenario: &mut Scenario): (RecordingAdminCap<REC>, ID) {
    let composition_id = test_helpers::fake_id(scenario.ctx());
    let (recording, cap) = recording::new_for_testing<REC, COMP>(
        composition_id,
        scenario.ctx(),
    );
    let clock = sui::clock::create_for_testing(scenario.ctx());
    recording.publish(&cap, &clock);
    clock.destroy_for_testing();
    (cap, composition_id)
}

#[test]
fun lifecycle_works_on_a_published_shared_recording() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (cap, composition_id) = publish_and_share_recording(&mut scenario);

    scenario.next_tx(ADMIN);
    let mut recording = scenario.take_shared<Recording<REC, COMP>>();
    let recording_id = object::id(&recording);
    session::set_engine_session(&mut recording, &cap, new_session(111));
    assert_eq!(blob_id(session::engine_session(&recording)), 111);
    assert_eq!(
        session::stem_data(&session::stems(session::engine_session(&recording))[0]).blob_id(),
        112,
    );

    let set_events = event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 1);
    let (event_recording_id, event_composition_id, event_admin_cap_id, had_previous,
        value_changed, previous_blob_id, previous_stem_count, event_blob_id, stem_count,
        stem_digests, stem_blob_ids) = session::set_event_fields(&set_events[0]);
    assert_eq!(event_recording_id, recording_id.to_address());
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_admin_cap_id, object::id(&cap).to_address());
    assert!(!had_previous);
    assert!(value_changed);
    assert_eq!(previous_blob_id, 0);
    assert_eq!(previous_stem_count, 0);
    assert_eq!(event_blob_id, 111);
    assert_eq!(stem_count, 1);
    assert_eq!(stem_digests.length(), 1);
    assert_eq!(stem_blob_ids, vector[112]);
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

    let unset_events = event::events_by_type<session::EngineSessionUnsetEvent<REC, COMP>>();
    assert_eq!(unset_events.length(), 1);
    let (event_recording_id, event_composition_id, event_admin_cap_id, removed_blob_id,
        removed_stem_count, removed_digests, removed_blob_ids) =
        session::unset_event_fields(&unset_events[0]);
    assert_eq!(event_recording_id, recording_id.to_address());
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_admin_cap_id, object::id(&cap).to_address());
    assert_eq!(removed_blob_id, 222);
    assert_eq!(removed_stem_count, 1);
    assert_eq!(removed_digests.length(), 1);
    assert_eq!(removed_blob_ids, vector[223]);
    test_scenario::return_shared(recording);

    destroy(cap);
    scenario.end();
}
