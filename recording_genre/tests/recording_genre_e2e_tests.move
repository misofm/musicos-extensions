// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_genre` against the production shape: a
/// `Recording` is published and shared first, and the extension operates on
/// it later, across real transaction boundaries and distinct senders. Reads
/// are open to anyone; writes require the admin cap.
#[test_only]
module recording_genre::recording_genre_e2e_tests;

use genre::genre::{Self as g, GenreRegistry, Genre};
use musicos::recording::{Self, Recording};
use recording_genre::recording_genre::{
    Self as rg,
    RecordingGenreAddedEvent,
    RecordingGenreRemovedEvent,
    RecordingGenresClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;
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
    let (rec_id, rec_cap) = publish_recording(&mut ts);

    // === Tx (ADMIN): take the shared recording, classify it ===
    ts.next_tx(ADMIN);
    let genre_a = ts.take_immutable_by_id<Genre>(a);
    let genre_b = ts.take_immutable_by_id<Genre>(b);
    let mut rec = ts.take_shared<Recording<REC>>();
    assert!(rg::genres(&rec).is_empty());

    // Added in the desired final order — b is meant to be primary.
    rg::add_genre(&mut rec, &rec_cap, &genre_b);
    rg::add_genre(&mut rec, &rec_cap, &genre_a);
    assert_eq!(rg::genres(&rec), vector[b, a]);

    let added = events_by_type<RecordingGenreAddedEvent<REC>>();
    assert_eq!(added.length(), 2);
    let (added_rec_0, added_genre_0) = rg::added_event_fields(&added[0]);
    assert_eq!(added_rec_0, rec_id);
    assert_eq!(added_genre_0, b);
    let (added_rec_1, added_genre_1) = rg::added_event_fields(&added[1]);
    assert_eq!(added_rec_1, rec_id);
    assert_eq!(added_genre_1, a);
    assert_eq!(to_bytes(&added[1]).length(), 64);
    ts::return_shared(rec);

    // === Tx (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert_eq!(rg::genres(&rec), vector[b, a]);
    ts::return_shared(rec);

    // === Tx (ADMIN): remove the primary, then clear the rest ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rg::remove_genre(&mut rec, &rec_cap, b);
    assert_eq!(rg::genres(&rec), vector[a]);
    let removed = events_by_type<RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed.length(), 1);
    let (removed_rec, removed_genre) = rg::removed_event_fields(&removed[0]);
    assert_eq!(removed_rec, rec_id);
    assert_eq!(removed_genre, b);
    assert_eq!(to_bytes(&removed[0]).length(), 64);

    rg::clear_genres(&mut rec, &rec_cap);
    assert!(rg::genres(&rec).is_empty());
    let cleared = events_by_type<RecordingGenresClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(rg::cleared_event_fields(&cleared[0]), rec_id);
    assert_eq!(to_bytes(&cleared[0]).length(), 32);
    ts::return_shared(rec);

    // === Tx (STRANGER): removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
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
    let (_, rec_cap) = publish_recording(&mut ts);

    ts.next_tx(ADMIN);
    let genre_a = ts.take_immutable_by_id<Genre>(a);
    let mut rec = ts.take_shared<Recording<REC>>();
    rg::add_genre(&mut rec, &rec_cap, &genre_a);
    rg::add_genre(&mut rec, &rec_cap, &genre_a); // duplicate

    ts::return_shared(rec);
    ts::return_immutable(genre_a);
    destroy(rec_cap);
    ts.end();
}

#[test, expected_failure(abort_code = rg::EGenreNotPresent)]
fun removing_an_absent_genre_aborts_against_a_shared_recording() {
    let mut ts = ts::begin(CREATOR);
    g::init_for_testing(ts.ctx());
    ts.next_tx(CREATOR);
    let a = create_genre(&ts, b"HIP_HOP");

    ts.next_tx(ADMIN);
    let (_, rec_cap) = publish_recording(&mut ts);

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rg::remove_genre(&mut rec, &rec_cap, a); // never added

    ts::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}
