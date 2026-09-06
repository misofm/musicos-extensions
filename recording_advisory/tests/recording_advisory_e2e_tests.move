// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_advisory` against the production shape: a
/// `Recording` is published and shared first, and the extension operates on
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
/// is deliberately no such test here. See the ADMIN-only-write assertions
/// below instead: the module has no notion of a non-admin actor at the type
/// level, so what a distinct sender can prove is that reads are open to
/// anyone while writes require holding the cap.
#[test_only]
module recording_advisory::recording_advisory_e2e_tests;

use miso::recording::{Self, Recording};
use recording_advisory::recording_advisory as adv;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

public struct REC {}
public struct COMP {}

#[test]
fun admin_rates_a_published_shared_recording_and_a_stranger_reads_it() {
    let mut ts = test_scenario::begin(ADMIN);

    // === Tx 1 (ADMIN): create and publish the recording — this shares it ===
    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec);
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock); // shares the recording
    clock.destroy_for_testing();

    // === Tx 2 (ADMIN): take the shared recording, attach a rating ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(!adv::has_rating(&rec));

    adv::set_rating(&mut rec, &rec_cap, adv::explicit());

    let events = event::events_by_type<adv::AdvisoryRatingSetEvent>();
    assert_eq!(events.length(), 1);
    let (event_id, event_rating) = adv::set_event_fields(&events[0]);
    assert_eq!(event_id, rec_id);
    assert!(event_rating.is_explicit());

    test_scenario::return_shared(rec);

    // === Tx 3 (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(adv::has_rating(&rec));
    assert!(adv::rating(&rec).is_explicit());
    test_scenario::return_shared(rec);

    // === Tx 4 (ADMIN): replaces the rating, then removes it ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    adv::set_rating(&mut rec, &rec_cap, adv::cleaned());
    assert!(adv::rating(&rec).is_cleaned());

    adv::unset_rating(&mut rec, &rec_cap);
    assert!(!adv::has_rating(&rec));

    let unset_events = event::events_by_type<adv::AdvisoryRatingUnsetEvent>();
    assert_eq!(unset_events.length(), 1);
    assert_eq!(adv::unset_event_recording_id(&unset_events[0]), rec_id);

    test_scenario::return_shared(rec);

    // === Tx 5 (STRANGER): confirms removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(!adv::has_rating(&rec));
    test_scenario::return_shared(rec);

    destroy(rec_cap);
    ts.end();
}

/// Operate-after-remove: reading a rating after it has been explicitly
/// removed aborts exactly like a recording that was never rated — absence is
/// absence, regardless of history. Exercised across scenario boundaries and
/// a non-admin reader to match the production shape.
#[test, expected_failure(abort_code = adv::ENoRating)]
fun reading_after_remove_aborts_for_any_reader() {
    let mut ts = test_scenario::begin(ADMIN);

    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    adv::set_rating(&mut rec, &rec_cap, adv::explicit());
    adv::unset_rating(&mut rec, &rec_cap);
    test_scenario::return_shared(rec);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    let _ = adv::rating(&rec); // aborts: ENoRating

    test_scenario::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}
