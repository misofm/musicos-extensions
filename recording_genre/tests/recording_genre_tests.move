// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Add/read/remove/clear mechanics and the validation aborts against a bare
/// `Recording`. A scenario is used only because `genre::Genre` objects are
/// frozen and must be taken back via `take_immutable_by_id`; nothing here
/// changes hands between senders. The published, shared shape is covered in
/// `recording_genre_e2e_tests`.
///
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type —
/// one share type backs exactly one recording — so a wrong-cap call is a
/// compile error, not a runtime abort, and there is no such test here.
#[test_only]
module recording_genre::recording_genre_tests;

use genre::genre::{Self as g, GenreRegistry, Genre};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_genre::recording_genre::{
    Self as rg,
    RecordingGenreAddedEvent,
    RecordingGenreRemovedEvent,
    RecordingGenresClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::dynamic_field as df;
use sui::event::events_by_type;
use sui::test_scenario::{Self as ts, Scenario};

const CREATOR: address = @0xC0;

public struct REC {}
public struct OTHER_REC {}
public struct UnrelatedKey() has copy, drop, store;

/// Only a `Recording` is needed, so a bare id stands in for its composition.
fun new_rec<RecordingShare>(
    ctx: &mut TxContext,
): (Recording<RecordingShare>, RecordingAdminCap<RecordingShare>) {
    recording::new_for_testing<RecordingShare>(object::id_from_address(@0xC0FFEE), ctx)
}

/// Stands up the vocabulary and creates one frozen genre per name, each in
/// its own transaction, returning their derived ids.
fun create_genres(scenario: &mut Scenario, names: vector<vector<u8>>): vector<ID> {
    g::init_for_testing(scenario.ctx());
    names.map!(|name| {
        scenario.next_tx(CREATOR);
        let mut registry = scenario.take_shared<GenreRegistry>();
        let id = g::derive_address(&registry, name.to_string()).to_id();
        g::new(&mut registry, name.to_string());
        ts::return_shared(registry);
        id
    })
}

fun take_genres(scenario: &Scenario, ids: &vector<ID>): vector<Genre> {
    ids.map_ref!(|id| scenario.take_immutable_by_id<Genre>(*id))
}

fun return_genres(genres: vector<Genre>) {
    genres.destroy!(|genre| ts::return_immutable(genre));
}

fun assert_added(event: &RecordingGenreAddedEvent<REC>, rec: address, genre: ID) {
    let (event_rec, event_genre) = rg::added_event_fields(event);
    assert_eq!(event_rec, rec);
    assert_eq!(event_genre, genre.to_address());
    assert_eq!(to_bytes(event).length(), 64);
}

fun assert_removed(event: &RecordingGenreRemovedEvent<REC>, rec: address, genre: ID) {
    let (event_rec, event_genre) = rg::removed_event_fields(event);
    assert_eq!(event_rec, rec);
    assert_eq!(event_genre, genre.to_address());
    assert_eq!(to_bytes(event).length(), 64);
}

#[test]
fun views_before_assignment_are_empty() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec<REC>(ctx);
    assert!(rg::genres(&rec).is_empty());
    destroy(rec);
    destroy(cap);
}

#[test]
fun add_remove_clear_lifecycle_with_events() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"HIP_HOP", b"ELECTRONIC", b"AMBIENT"]);
    let (a, b, c) = (ids[0], ids[1], ids[2]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());
    let rec_id = object::id(&rec).to_address();

    // First add creates the field and establishes the primary.
    rg::add_genre(&mut rec, &cap, &genres[0]);
    assert_eq!(rg::genres(&rec), vector[a]);
    let added = events_by_type<RecordingGenreAddedEvent<REC>>();
    assert_eq!(added.length(), 1);
    assert_added(&added[0], rec_id, a);

    // Appends preserve order.
    rg::add_genre(&mut rec, &cap, &genres[1]);
    rg::add_genre(&mut rec, &cap, &genres[2]);
    assert_eq!(rg::genres(&rec), vector[a, b, c]);
    let added = events_by_type<RecordingGenreAddedEvent<REC>>();
    assert_eq!(added.length(), 3);
    assert_added(&added[1], rec_id, b);
    assert_added(&added[2], rec_id, c);

    // Secondary removal keeps the primary and survivor order.
    rg::remove_genre(&mut rec, &cap, b);
    assert_eq!(rg::genres(&rec), vector[a, c]);
    let removed = events_by_type<RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed.length(), 1);
    assert_removed(&removed[0], rec_id, b);

    // Primary removal promotes the next entry.
    rg::remove_genre(&mut rec, &cap, a);
    assert_eq!(rg::genres(&rec), vector[c]);
    let removed = events_by_type<RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed.length(), 2);
    assert_removed(&removed[1], rec_id, a);

    // Last removal drops the field and emits only the Removed event.
    rg::remove_genre(&mut rec, &cap, c);
    assert!(rg::genres(&rec).is_empty());
    let removed = events_by_type<RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed.length(), 3);
    assert_removed(&removed[2], rec_id, c);
    assert_eq!(events_by_type<RecordingGenresClearedEvent<REC>>().length(), 0);

    // Re-attachment starts a fresh ordered list; an explicit clear drops it.
    rg::add_genre(&mut rec, &cap, &genres[2]);
    rg::add_genre(&mut rec, &cap, &genres[0]);
    assert_eq!(rg::genres(&rec), vector[c, a]);
    rg::clear_genres(&mut rec, &cap);
    assert!(rg::genres(&rec).is_empty());
    let cleared = events_by_type<RecordingGenresClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(rg::cleared_event_fields(&cleared[0]), rec_id);
    assert_eq!(to_bytes(&cleared[0]).length(), 32);
    assert_eq!(events_by_type<RecordingGenreAddedEvent<REC>>().length(), 5);
    assert_eq!(events_by_type<RecordingGenreRemovedEvent<REC>>().length(), 3);

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

/// Exactly `MAX_GENRES` (6) entries are accepted, and removal from a full
/// list keeps primary and survivor order.
#[test]
fun exactly_max_genres_is_accepted() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"A", b"B", b"C", b"D", b"E", b"F"]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    genres.do_ref!(|genre| rg::add_genre(&mut rec, &cap, genre));
    assert_eq!(rg::genres(&rec), ids);
    assert_eq!(events_by_type<RecordingGenreAddedEvent<REC>>().length(), 6);

    rg::remove_genre(&mut rec, &cap, ids[4]);
    assert_eq!(rg::genres(&rec), vector[ids[0], ids[1], ids[2], ids[3], ids[5]]);

    // Back at capacity after re-adding the removed genre at the end.
    rg::add_genre(&mut rec, &cap, &genres[4]);
    assert_eq!(rg::genres(&rec), vector[ids[0], ids[1], ids[2], ids[3], ids[5], ids[4]]);

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun clear_when_absent_is_silent() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"HIP_HOP"]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    rg::clear_genres(&mut rec, &cap);
    assert!(rg::genres(&rec).is_empty());
    assert_eq!(events_by_type<RecordingGenresClearedEvent<REC>>().length(), 0);

    // Silent after the field was dropped by removal, and after a real clear.
    rg::add_genre(&mut rec, &cap, &genres[0]);
    rg::remove_genre(&mut rec, &cap, ids[0]);
    rg::clear_genres(&mut rec, &cap);
    assert_eq!(events_by_type<RecordingGenresClearedEvent<REC>>().length(), 0);

    rg::add_genre(&mut rec, &cap, &genres[0]);
    rg::clear_genres(&mut rec, &cap);
    rg::clear_genres(&mut rec, &cap);
    assert_eq!(events_by_type<RecordingGenresClearedEvent<REC>>().length(), 1);

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun reorder_via_clear_and_re_add() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"HIP_HOP", b"ELECTRONIC", b"AMBIENT"]);
    let (a, b, c) = (ids[0], ids[1], ids[2]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    genres.do_ref!(|genre| rg::add_genre(&mut rec, &cap, genre));
    assert_eq!(rg::genres(&rec), vector[a, b, c]);

    rg::clear_genres(&mut rec, &cap);
    rg::add_genre(&mut rec, &cap, &genres[2]);
    rg::add_genre(&mut rec, &cap, &genres[0]);
    rg::add_genre(&mut rec, &cap, &genres[1]);
    assert_eq!(rg::genres(&rec), vector[c, a, b]);

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun views_are_silent() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"HIP_HOP"]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    rg::add_genre(&mut rec, &cap, &genres[0]);
    let _ = rg::genres(&rec);
    let _ = rg::genres(&rec);
    assert_eq!(events_by_type<RecordingGenreAddedEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingGenreRemovedEvent<REC>>().length(), 0);
    assert_eq!(events_by_type<RecordingGenresClearedEvent<REC>>().length(), 0);

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

/// Genre lists live on their own recording's UID and in their own
/// share-typed event stream.
#[test]
fun genres_are_per_recording() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"HIP_HOP", b"ELECTRONIC"]);
    let (a, b) = (ids[0], ids[1]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec_a, cap_a) = new_rec<REC>(scenario.ctx());
    let (mut rec_b, cap_b) = new_rec<OTHER_REC>(scenario.ctx());

    rg::add_genre(&mut rec_a, &cap_a, &genres[0]);
    assert!(rg::genres(&rec_b).is_empty());
    assert_eq!(events_by_type<RecordingGenreAddedEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingGenreAddedEvent<OTHER_REC>>().length(), 0);

    rg::add_genre(&mut rec_b, &cap_b, &genres[1]);
    rg::add_genre(&mut rec_b, &cap_b, &genres[0]);
    assert_eq!(rg::genres(&rec_a), vector[a]);
    assert_eq!(rg::genres(&rec_b), vector[b, a]);
    assert_eq!(events_by_type<RecordingGenreAddedEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingGenreAddedEvent<OTHER_REC>>().length(), 2);

    rg::remove_genre(&mut rec_a, &cap_a, a);
    rg::clear_genres(&mut rec_b, &cap_b);
    assert_eq!(events_by_type<RecordingGenreRemovedEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingGenreRemovedEvent<OTHER_REC>>().length(), 0);
    assert_eq!(events_by_type<RecordingGenresClearedEvent<REC>>().length(), 0);
    assert_eq!(events_by_type<RecordingGenresClearedEvent<OTHER_REC>>().length(), 1);

    return_genres(genres);
    destroy(rec_a);
    destroy(cap_a);
    destroy(rec_b);
    destroy(cap_b);
    scenario.end();
}

#[test]
fun unrelated_dynamic_field_survives_genre_mutations() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"HIP_HOP"]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    df::add(rec.uid_mut(&cap), UnrelatedKey(), 77u64);
    rg::add_genre(&mut rec, &cap, &genres[0]);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    rg::remove_genre(&mut rec, &cap, ids[0]);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    rg::add_genre(&mut rec, &cap, &genres[0]);
    rg::clear_genres(&mut rec, &cap);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    let _: u64 = df::remove(rec.uid_mut(&cap), UnrelatedKey());

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rg::EDuplicateGenre)]
fun add_genre_duplicate_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"HIP_HOP"]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    rg::add_genre(&mut rec, &cap, &genres[0]);
    rg::add_genre(&mut rec, &cap, &genres[0]);

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rg::EMaxGenres)]
fun add_genre_at_capacity_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"A", b"B", b"C", b"D", b"E", b"F", b"G"]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    6u64.do!(|i| rg::add_genre(&mut rec, &cap, &genres[i]));
    assert_eq!(rg::genres(&rec).length(), 6);
    rg::add_genre(&mut rec, &cap, &genres[6]); // the 7th

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

/// The duplicate check precedes the capacity check: re-adding an existing
/// genre to a full list aborts with `EDuplicateGenre`, not `EMaxGenres`.
#[test, expected_failure(abort_code = rg::EDuplicateGenre)]
fun duplicate_at_capacity_keeps_duplicate_guard_first() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"A", b"B", b"C", b"D", b"E", b"F"]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    genres.do_ref!(|genre| rg::add_genre(&mut rec, &cap, genre));
    assert_eq!(rg::genres(&rec).length(), 6);
    rg::add_genre(&mut rec, &cap, &genres[0]);

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rg::EGenreNotPresent)]
fun remove_genre_not_present_aborts_when_field_exists() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"HIP_HOP", b"ELECTRONIC"]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    rg::add_genre(&mut rec, &cap, &genres[0]);
    rg::remove_genre(&mut rec, &cap, ids[1]); // never added

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rg::EGenreNotPresent)]
fun remove_genre_not_present_aborts_when_nothing_attached() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    rg::remove_genre(&mut rec, &cap, object::id_from_address(@0xBEEF));
    destroy(rec);
    destroy(cap);
}

/// Once the last genre is removed the field is gone, so removing it again
/// aborts the same way as on a recording that was never classified.
#[test, expected_failure(abort_code = rg::EGenreNotPresent)]
fun remove_genre_twice_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let ids = create_genres(&mut scenario, vector[b"HIP_HOP"]);

    scenario.next_tx(CREATOR);
    let genres = take_genres(&scenario, &ids);
    let (mut rec, cap) = new_rec<REC>(scenario.ctx());

    rg::add_genre(&mut rec, &cap, &genres[0]);
    rg::remove_genre(&mut rec, &cap, ids[0]);
    rg::remove_genre(&mut rec, &cap, ids[0]);

    return_genres(genres);
    destroy(rec);
    destroy(cap);
    scenario.end();
}
