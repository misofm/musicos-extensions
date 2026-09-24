// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of the genre attribute against the production shape: a
/// `Recording` is published and shared first, and the extension operates on
/// it later, across real transaction boundaries and distinct senders.
///
/// This package never touches the composition side of a recording, so a bare
/// id stands in for a real `Composition` — `recording::new_for_testing` only
/// needs a composition `ID`, not a live `Composition` object.
///
/// `RecordingAdminCap<RecordingShare>` is matched by type, not by a runtime id
/// check (`recording::uid_mut` ignores the cap value). A mismatched share type
/// cannot compile; a same-type cap value is not runtime-authenticated. There is
/// deliberately no wrong-cap test here, unlike the release side, where
/// `release::uid_mut` runtime-checks the cap and a wrong-cap abort is a real,
/// testable case.
#[test_only]
module recording_metadata::genre_e2e_tests;

use genre::genre as g;
use genre::genre::{GenreRegistry, Genre};
use musicos::recording::{Self, Recording};
use recording_metadata::recording_metadata as rm;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;
const CREATOR: address = @0xC0;

public struct REC {}

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
    let (rec, rec_cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec).to_address();
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock); // shares the recording
    clock.destroy_for_testing();

    // === Tx (ADMIN): take the shared recording, classify it ===
    ts.next_tx(ADMIN);
    let genre_a = ts.take_immutable_by_id<Genre>(a);
    let genre_b = ts.take_immutable_by_id<Genre>(b);
    let mut rec = ts.take_shared<Recording<REC>>();
    assert!(rm::genres(&rec).is_empty());

    // Add in the desired final order directly — b is meant to be primary, so
    // it is added first.
    rm::add_genre(&mut rec, &rec_cap, &genre_b);
    rm::add_genre(&mut rec, &rec_cap, &genre_a);

    assert_eq!(rm::genres(&rec), vector[b, a]);

    let added_events = event::events_by_type<rm::RecordingGenreAddedEvent<REC>>();
    assert_eq!(added_events.length(), 2);
    let (added_id_0, added_genre_0) = rm::genre_added_event_fields(&added_events[0]);
    assert_eq!(added_id_0, rec_id);
    assert_eq!(added_genre_0, b.to_address());
    let (added_id_1, added_genre_1) = rm::genre_added_event_fields(&added_events[1]);
    assert_eq!(added_id_1, rec_id);
    assert_eq!(added_genre_1, a.to_address());

    ts::return_shared(rec);

    // === Tx (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(!rm::genres(&rec).is_empty());
    assert_eq!(rm::genres(&rec), vector[b, a]);
    ts::return_shared(rec);

    // === Tx (ADMIN): clears the whole list in one call ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rm::clear_genres(&mut rec, &rec_cap);
    assert!(rm::genres(&rec).is_empty());

    let cleared_events = event::events_by_type<rm::RecordingGenresClearedEvent<REC>>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rm::genres_cleared_event_fields(&cleared_events[0]), rec_id);

    ts::return_shared(rec);

    // === Tx (STRANGER): confirms removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(rm::genres(&rec).is_empty());
    ts::return_shared(rec);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    destroy(rec_cap);
    ts.end();
}

#[test, expected_failure(abort_code = rm::EDuplicateGenre)]
fun duplicate_genre_aborts_against_a_shared_recording() {
    let mut ts = ts::begin(CREATOR);
    g::init_for_testing(ts.ctx());
    ts.next_tx(CREATOR);
    let a = create_genre(&ts, b"HIP_HOP");

    ts.next_tx(ADMIN);
    let (rec, rec_cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let genre_a = ts.take_immutable_by_id<Genre>(a);
    let mut rec = ts.take_shared<Recording<REC>>();

    rm::add_genre(&mut rec, &rec_cap, &genre_a);
    rm::add_genre(&mut rec, &rec_cap, &genre_a); // duplicate

    ts::return_shared(rec);
    ts::return_immutable(genre_a);
    destroy(rec_cap);
    ts.end();
}

#[test, expected_failure(abort_code = rm::EGenreNotPresent)]
fun removing_an_absent_genre_aborts_for_the_admin_on_a_shared_recording() {
    let mut ts = ts::begin(CREATOR);
    g::init_for_testing(ts.ctx());
    ts.next_tx(CREATOR);
    let a = create_genre(&ts, b"HIP_HOP");

    ts.next_tx(ADMIN);
    let (rec, rec_cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let genre_a = ts.take_immutable_by_id<Genre>(a);
    let mut rec = ts.take_shared<Recording<REC>>();

    rm::remove_genre(&mut rec, &rec_cap, object::id(&genre_a)); // never added

    ts::return_shared(rec);
    ts::return_immutable(genre_a);
    destroy(rec_cap);
    ts.end();
}
