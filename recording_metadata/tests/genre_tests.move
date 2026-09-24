// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Attach/read/append/remove/clear mechanics of the genre attribute and its
/// validation aborts, against a single bare `Recording`. A scenario
/// (`sui::test_scenario`) is used only because `genre::Genre` objects are
/// frozen and must be taken back via `take_immutable_by_id` — unlike
/// `advisory_tests`, plain `tx_context::dummy()` is not enough here, since
/// nothing here would work without a shared `GenreRegistry` and frozen
/// `Genre` objects to reference. Nothing below crosses an ownership handoff
/// between distinct senders; the production shape — a published, shared
/// `Recording` operated on across real transaction boundaries — is covered
/// separately in `genre_e2e_tests`.
///
/// A mismatched `RecordingShare` type cannot compile. A distinct
/// `RecordingAdminCap<RecordingShare>` value is accepted because
/// `recording::uid_mut` ignores the cap value; the foreign same-type-cap path
/// is exercised explicitly below.
#[test_only]
module recording_metadata::genre_tests;

use genre::genre as g;
use genre::genre::{GenreRegistry, Genre};
use musicos::recording;
use recording_metadata::recording_metadata as rm;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

public struct REC {}
public struct OTHER_REC {}
public struct UnrelatedKey() has copy, drop, store;

/// An event-only indexer's view of one recording's genre list.
public struct ReplayState has drop {
    recording_id: address,
    genres: vector<address>,
    field_exists: bool,
}

/// This package never touches the composition side of a recording — it only
/// needs a `Recording` to exist, so a bare id stands in for a real
/// `Composition` rather than constructing one.
fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC>(object::id_from_address(@0xC0FFEE), ctx)
}

/// Creates a genre in the permissionless registry and returns its derived id.
fun create_genre(scenario: &Scenario, name: vector<u8>): ID {
    let mut registry = scenario.take_shared<GenreRegistry>();
    let id = g::derive_address(&registry, name.to_string()).to_id();
    g::new(&mut registry, name.to_string());
    ts::return_shared(registry);
    id
}

fun addr(id: ID): address {
    id.to_address()
}

fun genre_addresses(recording: &recording::Recording<REC>): vector<address> {
    let mut addresses = vector[];
    rm::genres(recording).do_ref!(|id| addresses.push_back(id.to_address()));
    addresses
}

fun assert_added_payload(
    event: &rm::RecordingGenreAddedEvent<REC>,
    recording_id: address,
    genre_id: address,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), genre_id);
    assert!(bytes.into_remainder_bytes().is_empty());
    assert_eq!(bcs::to_bytes(event).length(), 64);
}

fun assert_removed_payload(
    event: &rm::RecordingGenreRemovedEvent<REC>,
    recording_id: address,
    genre_id: address,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), genre_id);
    assert!(bytes.into_remainder_bytes().is_empty());
    assert_eq!(bcs::to_bytes(event).length(), 64);
}

fun assert_cleared_payload(
    event: &rm::RecordingGenresClearedEvent<REC>,
    recording_id: address,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert!(bytes.into_remainder_bytes().is_empty());
    assert_eq!(bcs::to_bytes(event).length(), 32);
}

/// The event-only projection must agree with the permissionless view. With
/// no other attribute set anywhere in this module, the record is attached
/// exactly when the genre list is non-empty, and that must hold on both
/// sides.
fun assert_projected(recording: &recording::Recording<REC>, projected: &ReplayState) {
    assert_eq!(genre_addresses(recording), projected.genres);
    assert_eq!(rm::has_metadata_for_testing(recording), projected.field_exists);
    assert_eq!(projected.field_exists, !projected.genres.is_empty());
}

/// An add lands at the end: the indexer derives the index and whether the
/// genre became primary from its own list.
fun replay_added(projected: &mut ReplayState, event: &rm::RecordingGenreAddedEvent<REC>) {
    let (recording_id, genre_id) = rm::genre_added_event_fields(event);
    assert_eq!(recording_id, projected.recording_id);
    assert!(!projected.genres.contains(&genre_id));
    assert!(projected.genres.length() < 6);
    projected.genres.push_back(genre_id);
    projected.field_exists = true;
}

/// A removal drops one entry and keeps survivor order; emptying the list
/// means the field is gone.
fun replay_removed(projected: &mut ReplayState, event: &rm::RecordingGenreRemovedEvent<REC>) {
    let (recording_id, genre_id) = rm::genre_removed_event_fields(event);
    assert_eq!(recording_id, projected.recording_id);
    let (found, index) = projected.genres.index_of(&genre_id);
    assert!(found);
    projected.genres.remove(index);
    projected.field_exists = !projected.genres.is_empty();
}

fun replay_cleared(projected: &mut ReplayState, event: &rm::RecordingGenresClearedEvent<REC>) {
    assert_eq!(rm::genres_cleared_event_fields(event), projected.recording_id);
    assert!(projected.field_exists);
    projected.genres = vector[];
    projected.field_exists = false;
}

#[test]
fun views_before_assignment_are_empty() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let (rec, cap) = new_rec(scenario.ctx());

    assert!(rm::genres(&rec).is_empty());
    assert!(!rm::has_metadata_for_testing(&rec));

    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun events_replay_order_primary_and_last_removal() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(@0xC0);
    let c = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let genre_c = scenario.take_immutable_by_id<Genre>(c);
    let (mut rec, cap) = new_rec(scenario.ctx());
    let recording_id = object::id(&rec).to_address();
    let mut projected = ReplayState { recording_id, genres: vector[], field_exists: false };

    rm::add_genre(&mut rec, &cap, &genre_a);
    let added = event::events_by_type<rm::RecordingGenreAddedEvent<REC>>();
    assert_eq!(added.length(), 1);
    assert_added_payload(&added[0], recording_id, addr(a));
    replay_added(&mut projected, &added[0]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(a)]);

    rm::add_genre(&mut rec, &cap, &genre_b);
    rm::add_genre(&mut rec, &cap, &genre_c);
    let added = event::events_by_type<rm::RecordingGenreAddedEvent<REC>>();
    assert_eq!(added.length(), 3);
    assert_added_payload(&added[1], recording_id, addr(b));
    assert_added_payload(&added[2], recording_id, addr(c));
    replay_added(&mut projected, &added[1]);
    replay_added(&mut projected, &added[2]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(a), addr(b), addr(c)]);

    // Secondary removal preserves the primary and order of survivors.
    rm::remove_genre(&mut rec, &cap, b);
    let removed = event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed.length(), 1);
    assert_removed_payload(&removed[0], recording_id, addr(b));
    replay_removed(&mut projected, &removed[0]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(a), addr(c)]);

    // Primary removal promotes the next entry.
    rm::remove_genre(&mut rec, &cap, a);
    let removed = event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed.length(), 2);
    assert_removed_payload(&removed[1], recording_id, addr(a));
    replay_removed(&mut projected, &removed[1]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(c)]);

    // Last removal drops the field. It is one state transition and one event:
    // the indexer's own list went empty, so it knows the field is gone.
    rm::remove_genre(&mut rec, &cap, c);
    let removed = event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed.length(), 3);
    assert_removed_payload(&removed[2], recording_id, addr(c));
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 0);
    replay_removed(&mut projected, &removed[2]);
    assert_projected(&rec, &projected);
    assert!(projected.genres.is_empty());
    assert!(!projected.field_exists);

    // Absent clear is silent. Re-attachment starts a fresh ordered list.
    rm::clear_genres(&mut rec, &cap);
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 0);
    rm::add_genre(&mut rec, &cap, &genre_c);
    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::add_genre(&mut rec, &cap, &genre_b);
    let added = event::events_by_type<rm::RecordingGenreAddedEvent<REC>>();
    assert_eq!(added.length(), 6);
    replay_added(&mut projected, &added[3]);
    replay_added(&mut projected, &added[4]);
    replay_added(&mut projected, &added[5]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(c), addr(a), addr(b)]);

    // Explicit clear of an attached list emits once.
    rm::clear_genres(&mut rec, &cap);
    let cleared = event::events_by_type<rm::RecordingGenresClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_cleared_payload(&cleared[0], recording_id);
    replay_cleared(&mut projected, &cleared[0]);
    assert_projected(&rec, &projected);
    assert!(rm::genres(&rec).is_empty());

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    ts::return_immutable(genre_c);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun same_type_foreign_cap_drives_all_event_families() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let (mut recording, target_cap) = new_rec(scenario.ctx());
    let target_recording_id = object::id(&recording).to_address();
    let (foreign_recording, foreign_cap) =
        recording::new_for_testing<REC>(object::id_from_address(@0xF00D), scenario.ctx());
    destroy(foreign_recording);

    // The distinct same-type cap is accepted; every event must still identify
    // the target recording, never the cap's own.
    rm::add_genre(&mut recording, &foreign_cap, &genre_a);
    let added = event::events_by_type<rm::RecordingGenreAddedEvent<REC>>();
    assert_eq!(added.length(), 1);
    assert_added_payload(&added[0], target_recording_id, addr(a));

    rm::remove_genre(&mut recording, &foreign_cap, a);
    let removed = event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed.length(), 1);
    assert_removed_payload(&removed[0], target_recording_id, addr(a));
    assert!(!rm::has_metadata_for_testing(&recording));

    rm::add_genre(&mut recording, &foreign_cap, &genre_b);
    rm::clear_genres(&mut recording, &foreign_cap);
    let cleared = event::events_by_type<rm::RecordingGenresClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_cleared_payload(&cleared[0], target_recording_id);

    // Authorized absent clear is silent for every family.
    rm::clear_genres(&mut recording, &foreign_cap);
    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<REC>>().length(), 2);
    assert_eq!(event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 1);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    destroy(recording);
    destroy(target_cap);
    destroy(foreign_cap);
    scenario.end();
}

/// The bound is inclusive and the payloads are fixed-size: a six-item list
/// including the vocabulary's longest permitted name (64 bytes) round-trips,
/// and no event grows with the list or the name.
#[test]
fun six_genres_and_fixed_event_sizes() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"GENRE_A");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"GENRE_B");
    scenario.next_tx(@0xC0);
    let c = create_genre(&scenario, b"GENRE_C");
    scenario.next_tx(@0xC0);
    let d = create_genre(&scenario, b"GENRE_D");
    scenario.next_tx(@0xC0);
    let e = create_genre(&scenario, b"GENRE_E");
    scenario.next_tx(@0xC0);
    let long = create_genre(
        &scenario,
        b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    );

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let genre_c = scenario.take_immutable_by_id<Genre>(c);
    let genre_d = scenario.take_immutable_by_id<Genre>(d);
    let genre_e = scenario.take_immutable_by_id<Genre>(e);
    let genre_long = scenario.take_immutable_by_id<Genre>(long);
    let (mut rec, cap) = new_rec(scenario.ctx());
    let recording_id = object::id(&rec).to_address();

    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::add_genre(&mut rec, &cap, &genre_b);
    rm::add_genre(&mut rec, &cap, &genre_c);
    rm::add_genre(&mut rec, &cap, &genre_d);
    rm::add_genre(&mut rec, &cap, &genre_e);
    rm::add_genre(&mut rec, &cap, &genre_long);
    assert_eq!(rm::genres(&rec), vector[a, b, c, d, e, long]);

    let added = event::events_by_type<rm::RecordingGenreAddedEvent<REC>>();
    assert_eq!(added.length(), 6);
    assert_added_payload(&added[5], recording_id, addr(long));

    // Removing one entry from a six-item list preserves primary and survivor
    // order.
    rm::remove_genre(&mut rec, &cap, e);
    let removed = event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed.length(), 1);
    assert_removed_payload(&removed[0], recording_id, addr(e));
    assert_eq!(rm::genres(&rec), vector[a, b, c, d, long]);

    // Re-adding restores six entries, then an explicit clear drops them all.
    rm::add_genre(&mut rec, &cap, &genre_e);
    assert_eq!(rm::genres(&rec), vector[a, b, c, d, long, e]);
    rm::clear_genres(&mut rec, &cap);
    let cleared = event::events_by_type<rm::RecordingGenresClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_cleared_payload(&cleared[0], recording_id);
    assert!(rm::genres(&rec).is_empty());

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    ts::return_immutable(genre_c);
    ts::return_immutable(genre_d);
    ts::return_immutable(genre_e);
    ts::return_immutable(genre_long);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun first_add_genre_establishes_the_primary() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(@0xC0);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rec, cap) = new_rec(scenario.ctx());
    let rec_id = object::id(&rec).to_address();

    rm::add_genre(&mut rec, &cap, &genre1);
    assert!(!rm::genres(&rec).is_empty());
    assert_eq!(rm::genres(&rec), vector[g1]);
    assert_eq!(rm::genres(&rec)[0], g1);

    let events = event::events_by_type<rm::RecordingGenreAddedEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, event_genre_id) = rm::genre_added_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_genre_id, addr(g1));

    ts::return_immutable(genre1);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun appending_preserves_order() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(@0xC0);
    let c = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let genre_c = scenario.take_immutable_by_id<Genre>(c);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::add_genre(&mut rec, &cap, &genre_b);
    rm::add_genre(&mut rec, &cap, &genre_c);
    assert_eq!(rm::genres(&rec), vector[a, b, c]);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    ts::return_immutable(genre_c);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rm::EDuplicateGenre)]
fun add_genre_duplicate_aborts() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(@0xC0);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rm::add_genre(&mut rec, &cap, &genre1);
    rm::add_genre(&mut rec, &cap, &genre1);

    ts::return_immutable(genre1);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rm::EMaxGenres)]
fun add_genre_at_capacity_aborts() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    let names = vector[
        b"HIP_HOP", b"ELECTRONIC", b"AMBIENT", b"JAZZ", b"ROCK", b"POP", b"FOLK",
    ];
    let mut ids = vector[];
    names.do!(|name| {
        scenario.next_tx(@0xC0);
        ids.push_back(create_genre(&scenario, name));
    });

    scenario.next_tx(@0xC0);
    let genres = ids.map!(|id| scenario.take_immutable_by_id<Genre>(id));
    let (mut rec, cap) = new_rec(scenario.ctx());

    6u64.do!(|i| rm::add_genre(&mut rec, &cap, &genres[i]));
    assert_eq!(rm::genres(&rec).length(), 6);
    // The 7th genre pushes past MAX_GENRES.
    rm::add_genre(&mut rec, &cap, &genres[6]);

    genres.destroy!(|genre| ts::return_immutable(genre));
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rm::EDuplicateGenre)]
fun duplicate_at_capacity_keeps_duplicate_guard_first() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    let names = vector[
        b"GENRE_A", b"GENRE_B", b"GENRE_C", b"GENRE_D", b"GENRE_E", b"GENRE_F",
    ];
    let mut ids = vector[];
    names.do!(|name| {
        scenario.next_tx(@0xC0);
        ids.push_back(create_genre(&scenario, name));
    });

    scenario.next_tx(@0xC0);
    let genres = ids.map!(|id| scenario.take_immutable_by_id<Genre>(id));
    let (mut rec, cap) = new_rec(scenario.ctx());
    6u64.do!(|i| rm::add_genre(&mut rec, &cap, &genres[i]));
    assert_eq!(rm::genres(&rec).length(), 6);
    // Duplicate validation precedes the capacity guard, so this is 40, not 41.
    rm::add_genre(&mut rec, &cap, &genres[0]);

    genres.destroy!(|genre| ts::return_immutable(genre));
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rm::EGenreNotPresent)]
fun remove_genre_not_present_aborts_when_field_exists() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::remove_genre(&mut rec, &cap, object::id(&genre_b)); // never added

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rm::EGenreNotPresent)]
fun remove_genre_not_present_aborts_when_nothing_attached() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rm::remove_genre(&mut rec, &cap, object::id(&genre_a)); // nothing attached

    ts::return_immutable(genre_a);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun removing_the_primary_promotes_the_next() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(@0xC0);
    let c = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let genre_c = scenario.take_immutable_by_id<Genre>(c);
    let (mut rec, cap) = new_rec(scenario.ctx());
    let rec_id = object::id(&rec).to_address();

    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::add_genre(&mut rec, &cap, &genre_b);
    rm::add_genre(&mut rec, &cap, &genre_c);

    rm::remove_genre(&mut rec, &cap, a);
    assert_eq!(rm::genres(&rec), vector[b, c]);
    assert_eq!(rm::genres(&rec)[0], b);

    let removed_events = event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed_events.length(), 1);
    let (event_rec_id, event_genre_id) = rm::genre_removed_event_fields(&removed_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_genre_id, addr(a));

    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 0);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    ts::return_immutable(genre_c);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun removing_a_non_primary_keeps_the_primary() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(@0xC0);
    let c = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let genre_c = scenario.take_immutable_by_id<Genre>(c);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::add_genre(&mut rec, &cap, &genre_b);
    rm::add_genre(&mut rec, &cap, &genre_c);

    rm::remove_genre(&mut rec, &cap, b);
    assert_eq!(rm::genres(&rec), vector[a, c]);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    ts::return_immutable(genre_c);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

/// Non-empty by construction: the last removal drops the field itself, not
/// just its contents, and does so with the one Removed event.
#[test]
fun removing_the_last_genre_drops_the_field() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let (mut rec, cap) = new_rec(scenario.ctx());
    let rec_id = object::id(&rec).to_address();

    rm::add_genre(&mut rec, &cap, &genre_a);
    assert!(rm::has_metadata_for_testing(&rec));
    rm::remove_genre(&mut rec, &cap, a);

    assert!(rm::genres(&rec).is_empty());
    assert!(!rm::has_metadata_for_testing(&rec));

    let removed_events = event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>();
    assert_eq!(removed_events.length(), 1);
    let (event_rec_id, event_genre_id) = rm::genre_removed_event_fields(&removed_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_genre_id, addr(a));
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 0);

    ts::return_immutable(genre_a);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

/// After the field is dropped by removing the last genre, adding again
/// recreates it from scratch.
#[test]
fun add_genre_after_clearing_recreates_the_field() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::remove_genre(&mut rec, &cap, a);
    assert!(rm::genres(&rec).is_empty());

    rm::add_genre(&mut rec, &cap, &genre_b);
    assert!(rm::has_metadata_for_testing(&rec));
    assert_eq!(rm::genres(&rec), vector[b]);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

// === clear_genres ===

#[test]
fun clear_genres_removes_the_whole_list() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(@0xC0);
    let c = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let genre_c = scenario.take_immutable_by_id<Genre>(c);
    let (mut rec, cap) = new_rec(scenario.ctx());
    let rec_id = object::id(&rec).to_address();

    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::add_genre(&mut rec, &cap, &genre_b);
    rm::add_genre(&mut rec, &cap, &genre_c);

    rm::clear_genres(&mut rec, &cap);
    assert!(rm::genres(&rec).is_empty());
    assert!(!rm::has_metadata_for_testing(&rec));

    let cleared_events = event::events_by_type<rm::RecordingGenresClearedEvent<REC>>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rm::genres_cleared_event_fields(&cleared_events[0]), rec_id);
    // A whole-list clear is one event, not one Removed per entry.
    assert_eq!(event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>().length(), 0);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    ts::return_immutable(genre_c);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun clear_genres_when_absent_is_a_no_op() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let (mut rec, cap) = new_rec(scenario.ctx());

    // Empty views and an authorized absent clear are silent for every event
    // family, not only the family named by the operation.
    assert!(rm::genres(&rec).is_empty());
    rm::clear_genres(&mut rec, &cap);

    assert!(rm::genres(&rec).is_empty());
    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 0);

    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun reorder_via_clear_and_re_add() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let b = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(@0xC0);
    let c = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let genre_b = scenario.take_immutable_by_id<Genre>(b);
    let genre_c = scenario.take_immutable_by_id<Genre>(c);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::add_genre(&mut rec, &cap, &genre_b);
    rm::add_genre(&mut rec, &cap, &genre_c);
    assert_eq!(rm::genres(&rec), vector[a, b, c]);

    rm::clear_genres(&mut rec, &cap);
    rm::add_genre(&mut rec, &cap, &genre_c);
    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::add_genre(&mut rec, &cap, &genre_b);
    assert_eq!(rm::genres(&rec), vector[c, a, b]);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    ts::return_immutable(genre_c);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

/// Genres live on their own recording's UID; one recording's genres are not
/// visible from another.
#[test]
fun genres_are_per_recording() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let (mut rec_a, cap_a) = new_rec(scenario.ctx());
    let (rec_b, cap_b) = recording::new_for_testing<OTHER_REC>(
        object::id_from_address(@0xC0FFEE),
        scenario.ctx(),
    );

    rm::add_genre(&mut rec_a, &cap_a, &genre_a);

    assert!(!rm::genres(&rec_a).is_empty());
    assert!(rm::genres(&rec_b).is_empty());

    ts::return_immutable(genre_a);
    destroy(rec_a);
    destroy(cap_a);
    destroy(rec_b);
    destroy(cap_b);
    scenario.end();
}

#[test]
fun phantom_event_types_have_positive_and_negative_queries() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let (mut rec_a, cap_a) = new_rec(scenario.ctx());
    let (mut rec_b, cap_b) = recording::new_for_testing<OTHER_REC>(
        object::id_from_address(@0xB0),
        scenario.ctx(),
    );

    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<OTHER_REC>>().length(), 0);

    rm::add_genre(&mut rec_a, &cap_a, &genre_a);
    // A real <REC> event must not appear in the other phantom family before
    // that recording emits its own events.
    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<OTHER_REC>>().length(), 0);
    rm::add_genre(&mut rec_b, &cap_b, &genre_a);
    assert_eq!(rm::genres(&rec_a), vector[a]);
    assert_eq!(rm::genres(&rec_b), vector[a]);
    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<OTHER_REC>>().length(), 1);

    rm::remove_genre(&mut rec_a, &cap_a, a);
    assert_eq!(event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingGenreRemovedEvent<OTHER_REC>>().length(), 0);
    rm::clear_genres(&mut rec_b, &cap_b);
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<OTHER_REC>>().length(), 1);
    assert!(rm::genres(&rec_a).is_empty());
    assert!(rm::genres(&rec_b).is_empty());

    ts::return_immutable(genre_a);
    destroy(rec_a);
    destroy(cap_a);
    destroy(rec_b);
    destroy(cap_b);
    scenario.end();
}

#[test]
fun unrelated_dynamic_field_survives_genre_mutations() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let (mut rec, cap) = new_rec(scenario.ctx());

    df::add(rec.uid_mut(&cap), UnrelatedKey(), 77u64);
    rm::add_genre(&mut rec, &cap, &genre_a);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    rm::remove_genre(&mut rec, &cap, a);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    rm::add_genre(&mut rec, &cap, &genre_a);
    rm::clear_genres(&mut rec, &cap);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    let _: u64 = df::remove(rec.uid_mut(&cap), UnrelatedKey());

    ts::return_immutable(genre_a);
    destroy(rec);
    destroy(cap);
    scenario.end();
}
