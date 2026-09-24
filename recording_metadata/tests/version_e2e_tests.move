// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of the version attribute against the production shape:
/// a `Recording` is published and shared first, and the extension operates on
/// it later, across real transaction boundaries and distinct senders.
///
/// This package never touches the composition side of a recording, so a bare
/// id stands in for a real `Composition` — `recording::new_for_testing` only
/// needs a composition `ID`, not a live `Composition` object.
///
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type, not
/// by a runtime id check (`recording::uid_mut` takes the cap as `_`). What a
/// distinct sender can prove is that reads are open to anyone while writes
/// require holding the cap.
#[test_only]
module recording_metadata::version_e2e_tests;

use musicos::recording::{Self, Recording};
use recording_metadata::recording_metadata as rm;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

public struct REC {}

#[test]
fun admin_names_the_take_on_a_published_shared_recording_and_a_stranger_reads_it() {
    let mut ts = test_scenario::begin(ADMIN);

    // === Tx 1 (ADMIN): create and publish the recording — this shares it ===
    let (rec, rec_cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec).to_address();
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock); // shares the recording
    clock.destroy_for_testing();

    // === Tx 2 (ADMIN): take the shared recording, name the take ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    assert!(!rm::has_version(&rec));

    rm::set_version(&mut rec, &rec_cap, b"Live".to_string());

    let events = event::events_by_type<rm::RecordingVersionSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (event_id, version) = rm::version_set_event_fields(&events[0]);
    assert_eq!(event_id, rec_id);
    assert_eq!(version, b"Live".to_string());
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 37);

    test_scenario::return_shared(rec);

    // === Tx 3 (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(rm::has_version(&rec));
    assert_eq!(*rm::version(&rec), b"Live".to_string());
    test_scenario::return_shared(rec);

    // === Tx 4 (ADMIN): replaces the version, then removes it ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rm::set_version(&mut rec, &rec_cap, b"Radio Edit".to_string());
    assert_eq!(*rm::version(&rec), b"Radio Edit".to_string());

    // `test_scenario::next_tx` clears the event log, so only this
    // transaction's set event is visible here — not tx 2's.
    let replace_events = event::events_by_type<rm::RecordingVersionSetEvent<REC>>();
    assert_eq!(replace_events.length(), 1);
    let (_, version) = rm::version_set_event_fields(&replace_events[0]);
    assert_eq!(version, b"Radio Edit".to_string());

    rm::clear_version(&mut rec, &rec_cap);
    assert!(!rm::has_version(&rec));

    let cleared_events = event::events_by_type<rm::RecordingVersionClearedEvent<REC>>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rm::version_cleared_event_fields(&cleared_events[0]), rec_id);
    assert_eq!(sui::bcs::to_bytes(&cleared_events[0]).length(), 32);

    test_scenario::return_shared(rec);

    // === Tx 5 (STRANGER): confirms removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(!rm::has_version(&rec));
    test_scenario::return_shared(rec);

    destroy(rec_cap);
    ts.end();
}

/// Operate-after-remove: reading a version after it has been explicitly
/// removed aborts exactly like a recording that was never named — absence is
/// absence, regardless of history. Exercised across scenario boundaries and
/// a non-admin reader to match the production shape.
#[test, expected_failure(abort_code = rm::ENoVersion)]
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
    rm::set_version(&mut rec, &rec_cap, b"Live".to_string());
    rm::clear_version(&mut rec, &rec_cap);
    test_scenario::return_shared(rec);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    let _ = *rm::version(&rec); // aborts: ENoVersion

    test_scenario::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}

/// The validation aborts also apply against the production shape: an empty
/// version on a published, shared recording aborts the same as it does in the
/// bare-object unit tests.
#[test, expected_failure(abort_code = rm::EEmptyVersion)]
fun empty_version_aborts_against_a_shared_recording() {
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
    rm::set_version(&mut rec, &rec_cap, b"".to_string());

    test_scenario::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}
