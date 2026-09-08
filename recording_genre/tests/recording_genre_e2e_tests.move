// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_genre` against the production shape: a
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
/// is deliberately no such test here, unlike the release side, where
/// `release::uid_mut` runtime-checks the cap and a wrong-cap abort is a real,
/// testable case.
#[test_only]
module recording_genre::recording_genre_e2e_tests;

use genre::genre as g;
use genre::genre::{GenreRegistry, Genre};
use miso::recording::{Self, Recording};
use recording_genre::recording_genre as rg;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;
const CREATOR: address = @0xC0;

public struct REC {}
public struct COMP {}

/// Creates a genre in the permissionless registry and returns its derived id.
fun create_genre(scenario: &Scenario, name: vector<u8>): ID {
    let mut registry = scenario.take_shared<GenreRegistry>();
    let id = g::derive_address(&registry, name.to_string()).to_id();
    g::new(&mut registry, name.to_string());
    ts::return_shared(registry);
    id
}

#[test]
fun admin_classifies_a_published_shared_recording_and_a_stranger_reads_it() {
    let mut ts = ts::begin(CREATOR);

    // === Tx 0 (CREATOR): stand up the genre vocabulary ===
    g::init_for_testing(ts.ctx());
    ts.next_tx(CREATOR);
    let a = create_genre(&ts, b"HIP_HOP");
    ts.next_tx(CREATOR);
    let b = create_genre(&ts, b"ELECTRONIC");

    // === Tx (ADMIN): create and publish the recording — this shares it ===
    ts.next_tx(ADMIN);
    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec);
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock); // shares the recording
    clock.destroy_for_testing();

    // === Tx (ADMIN): take the shared recording, classify it ===
    ts.next_tx(ADMIN);
    let genre_a = ts.take_immutable_by_id<Genre>(a);
    let genre_b = ts.take_immutable_by_id<Genre>(b);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(rg::genres(&rec).is_empty());

    // Add in the desired final order directly — b is meant to be primary, so
    // it is added first.
    rg::add_genre(&mut rec, &rec_cap, &genre_b);
    rg::add_genre(&mut rec, &rec_cap, &genre_a);

    assert_eq!(rg::genres(&rec), vector[b, a]);

    let added_events = event::events_by_type<rg::GenreAddedEvent>();
    assert_eq!(added_events.length(), 2);
    let (added_id_0, added_genre_0) = rg::genre_added_event_fields(&added_events[0]);
    assert_eq!(added_id_0, rec_id);
    assert_eq!(added_genre_0, b);
    let (added_id_1, added_genre_1) = rg::genre_added_event_fields(&added_events[1]);
    assert_eq!(added_id_1, rec_id);
    assert_eq!(added_genre_1, a);

    ts::return_shared(rec);

    // === Tx (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(!rg::genres(&rec).is_empty());
    assert_eq!(rg::genres(&rec), vector[b, a]);
    ts::return_shared(rec);

    // === Tx (ADMIN): clears the whole list in one call ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    rg::clear_genres(&mut rec, &rec_cap);
    assert!(rg::genres(&rec).is_empty());

    let cleared_events = event::events_by_type<rg::GenresClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rg::genres_cleared_event_recording_id(&cleared_events[0]), rec_id);

    ts::return_shared(rec);

    // === Tx (STRANGER): confirms removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(rg::genres(&rec).is_empty());
    ts::return_shared(rec);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    destroy(rec_cap);
    ts.end();
}

#[test, expected_failure(abort_code = rg::EDuplicateGenre)]
fun duplicate_genre_aborts_against_a_shared_recording() {
    let mut ts = ts::begin(CREATOR);
    g::init_for_testing(ts.ctx());
    ts.next_tx(CREATOR);
    let a = create_genre(&ts, b"HIP_HOP");

    ts.next_tx(ADMIN);
    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let genre_a = ts.take_immutable_by_id<Genre>(a);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();

    rg::add_genre(&mut rec, &rec_cap, &genre_a);
    rg::add_genre(&mut rec, &rec_cap, &genre_a); // duplicate

    ts::return_shared(rec);
    ts::return_immutable(genre_a);
    destroy(rec_cap);
    ts.end();
}

#[test, expected_failure(abort_code = rg::EGenreNotPresent)]
fun removing_an_absent_genre_aborts_for_the_admin_on_a_shared_recording() {
    let mut ts = ts::begin(CREATOR);
    g::init_for_testing(ts.ctx());
    ts.next_tx(CREATOR);
    let a = create_genre(&ts, b"HIP_HOP");

    ts.next_tx(ADMIN);
    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let genre_a = ts.take_immutable_by_id<Genre>(a);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();

    rg::remove_genre(&mut rec, &rec_cap, object::id(&genre_a)); // never added

    ts::return_shared(rec);
    ts::return_immutable(genre_a);
    destroy(rec_cap);
    ts.end();
}
