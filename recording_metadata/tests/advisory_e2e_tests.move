// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of the advisory attribute against the production shape:
/// a `Recording` is published and shared first, and the extension operates on
/// it later, across real transaction boundaries and distinct senders.
///
/// This package never touches the composition side of a recording, so a bare
/// id stands in for a real `Composition` — `recording::new_for_testing` only
/// needs a composition `ID`, not a live `Composition` object.
///
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type, not
/// by a runtime id check (`recording::uid_mut` takes the cap as `_`). One
/// share currency is minted per recording in production, so a "wrong cap,
/// same type" scenario would be a compile error, not a runtime abort — there
/// is deliberately no such test here. What a distinct sender can prove is
/// that reads are open to anyone while writes require holding the cap.
#[test_only]
module recording_metadata::advisory_e2e_tests;

use musicos::recording::{Self, Recording};
use recording_metadata::recording_metadata as rm;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

public struct REC {}

#[test]
fun admin_rates_a_published_shared_recording_and_a_stranger_reads_it() {
    let mut ts = test_scenario::begin(ADMIN);

    // === Tx 1 (ADMIN): create and publish the recording — this shares it ===
    let (rec, rec_cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec);
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock); // shares the recording
    clock.destroy_for_testing();

    // === Tx 2 (ADMIN): take the shared recording, attach an advisory ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    assert!(!rm::has_advisory(&rec));

    rm::set_advisory(&mut rec, &rec_cap, rm::explicit());

    let events = event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (event_id, advisory) = rm::advisory_set_event_fields(&events[0]);
    assert_eq!(event_id, rec_id.to_address());
    assert!(advisory.is_explicit());

    test_scenario::return_shared(rec);

    // === Tx 3 (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(rm::has_advisory(&rec));
    assert!(rm::advisory(&rec).is_explicit());
    test_scenario::return_shared(rec);

    // === Tx 4 (ADMIN): replaces the advisory, then removes it ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rm::set_advisory(&mut rec, &rec_cap, rm::cleaned());
    assert!(rm::advisory(&rec).is_cleaned());

    rm::clear_advisory(&mut rec, &rec_cap);
    assert!(!rm::has_advisory(&rec));

    let clear_events = event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>();
    assert_eq!(clear_events.length(), 1);
    assert_eq!(rm::advisory_cleared_event_fields(&clear_events[0]), rec_id.to_address());

    test_scenario::return_shared(rec);

    // === Tx 5 (STRANGER): confirms removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(!rm::has_advisory(&rec));
    test_scenario::return_shared(rec);

    destroy(rec_cap);
    ts.end();
}

/// Operate-after-remove: reading an advisory after it has been explicitly
/// removed aborts exactly like a recording that was never rated — absence is
/// absence, regardless of history. Exercised across scenario boundaries and
/// a non-admin reader to match the production shape.
#[test, expected_failure(abort_code = rm::ENoAdvisory)]
fun reading_after_clear_aborts_for_any_reader() {
    let mut ts = test_scenario::begin(ADMIN);

    let (rec, rec_cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rm::set_advisory(&mut rec, &rec_cap, rm::explicit());
    rm::clear_advisory(&mut rec, &rec_cap);
    test_scenario::return_shared(rec);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    let _ = rm::advisory(&rec); // aborts: ENoAdvisory

    test_scenario::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}
