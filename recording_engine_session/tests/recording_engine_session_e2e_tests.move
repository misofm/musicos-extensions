// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_engine_session` against the production
/// shape: a `Recording` is published and shared first, and the extension
/// operates on it later, across real transaction boundaries and distinct
/// senders. Reads are open to anyone; writes require the admin cap.
#[test_only]
module recording_engine_session::recording_engine_session_e2e_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_engine_session::recording_engine_session::{
    Self as session,
    EngineSession,
    RecordingEngineSessionSetEvent,
    RecordingEngineSessionClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;
use sui::test_scenario::{Self as ts, Scenario};

public struct REC {}

const ADMIN: address = @0xAD;
const READER: address = @0x51;

/// One session blob plus a single stem whose digest is all zeroes.
fun new_session(blob_id: u256): EngineSession {
    let digest = vector::tabulate!(32, |_| 0u8);
    session::new(blob_id, vector[session::new_stem(digest, blob_id + 1)])
}

fun blob_id(value: &EngineSession): u256 {
    session::blob_id(value)
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

#[test]
fun lifecycle_works_on_a_published_shared_recording() {
    let mut ts = ts::begin(ADMIN);
    let cap = publish_and_share_recording(&mut ts);

    // === Tx 2 (ADMIN): attach a session to the shared recording ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    let rec_id = object::id(&rec);
    session::set_engine_session(&mut rec, &cap, new_session(111));
    assert_eq!(blob_id(session::engine_session(&rec)), 111);
    assert_eq!(session::stem_blob_id(&session::stems(session::engine_session(&rec))[0]), 112);

    let set_events = events_by_type<RecordingEngineSessionSetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    let (event_rec_id, event_blob_id) = session::set_event_fields(&set_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_blob_id, 111);
    assert_eq!(to_bytes(&set_events[0]).length(), 64);
    ts::return_shared(rec);

    // === Tx 3 (READER): views are permissionless ===
    ts.next_tx(READER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(session::has_engine_session(&rec));
    assert_eq!(blob_id(session::engine_session(&rec)), 111);
    ts::return_shared(rec);

    // === Tx 4 (ADMIN): equal set is silent; replace; then clear ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    session::set_engine_session(&mut rec, &cap, new_session(111));
    assert_eq!(events_by_type<RecordingEngineSessionSetEvent<REC>>().length(), 0);

    session::set_engine_session(&mut rec, &cap, new_session(222));
    assert_eq!(blob_id(session::engine_session(&rec)), 222);
    assert_eq!(events_by_type<RecordingEngineSessionSetEvent<REC>>().length(), 1);

    session::clear_engine_session(&mut rec, &cap);
    assert!(!session::has_engine_session(&rec));
    let cleared = events_by_type<RecordingEngineSessionClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(session::cleared_event_fields(&cleared[0]), rec_id);
    assert_eq!(to_bytes(&cleared[0]).length(), 32);
    ts::return_shared(rec);

    // === Tx 5 (READER): removal is visible to any reader ===
    ts.next_tx(READER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(!session::has_engine_session(&rec));
    ts::return_shared(rec);

    destroy(cap);
    ts.end();
}
