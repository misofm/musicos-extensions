// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_advisory` against the production shape: a
/// `Recording` is published and shared first, and the extension operates on
/// it later, across real transaction boundaries and distinct senders. Reads
/// are open to anyone; writes require the admin cap.
#[test_only]
module recording_advisory::recording_advisory_e2e_tests;

use musicos::recording::{Self, Recording};
use recording_advisory::recording_advisory::{
    Self as adv,
    RecordingAdvisorySetEvent,
    RecordingAdvisoryClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

public struct REC {}

/// Creates and publishes (shares) a recording as the current sender.
fun publish_recording(ts: &mut Scenario): (ID, recording::RecordingAdminCap<REC>) {
    let (rec, cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec);
    rec.publish(&cap);
    (rec_id, cap)
}

#[test]
fun admin_rates_a_published_shared_recording_and_a_stranger_reads_it() {
    let mut ts = ts::begin(ADMIN);

    // === Tx 1 (ADMIN): create and publish the recording — this shares it ===
    let (rec_id, rec_cap) = publish_recording(&mut ts);

    // === Tx 2 (ADMIN): take the shared recording, attach an advisory ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    assert!(!adv::has_advisory(&rec));

    adv::set_advisory(&mut rec, &rec_cap, adv::explicit());

    let events = events_by_type<RecordingAdvisorySetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (event_id, advisory) = adv::set_event_fields(&events[0]);
    assert_eq!(event_id, rec_id.to_address());
    assert!(advisory.is_explicit());
    assert_eq!(to_bytes(&events[0]).length(), 33);
    ts::return_shared(rec);

    // === Tx 3 (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(adv::has_advisory(&rec));
    assert!(adv::advisory(&rec).is_explicit());
    ts::return_shared(rec);

    // === Tx 4 (ADMIN): equal set is silent; replace; then clear ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    adv::set_advisory(&mut rec, &rec_cap, adv::explicit());
    assert_eq!(events_by_type<RecordingAdvisorySetEvent<REC>>().length(), 0);

    adv::set_advisory(&mut rec, &rec_cap, adv::cleaned());
    assert!(adv::advisory(&rec).is_cleaned());
    assert_eq!(events_by_type<RecordingAdvisorySetEvent<REC>>().length(), 1);

    adv::clear_advisory(&mut rec, &rec_cap);
    assert!(!adv::has_advisory(&rec));
    let cleared = events_by_type<RecordingAdvisoryClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(adv::cleared_event_fields(&cleared[0]), rec_id.to_address());
    assert_eq!(to_bytes(&cleared[0]).length(), 32);
    ts::return_shared(rec);

    // === Tx 5 (STRANGER): removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(!adv::has_advisory(&rec));
    ts::return_shared(rec);

    destroy(rec_cap);
    ts.end();
}

/// Reading after an explicit clear aborts exactly like a recording that was
/// never rated — absence is absence, regardless of history.
#[test, expected_failure(abort_code = adv::ENoAdvisory)]
fun reading_after_clear_aborts_for_any_reader() {
    let mut ts = ts::begin(ADMIN);
    let (_, rec_cap) = publish_recording(&mut ts);

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    adv::set_advisory(&mut rec, &rec_cap, adv::explicit());
    adv::clear_advisory(&mut rec, &rec_cap);
    ts::return_shared(rec);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    let _ = adv::advisory(&rec); // aborts: ENoAdvisory

    ts::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}
