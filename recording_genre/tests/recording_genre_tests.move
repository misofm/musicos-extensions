// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Attach/read/append/remove/clear mechanics and the validation aborts,
/// against a single bare `Recording`. A scenario (`sui::test_scenario`) is
/// used only because `genre::Genre` objects are frozen and must be taken back
/// via `take_immutable_by_id` — unlike `recording_advisory_tests`, plain
/// `tx_context::dummy()` is not enough here, since nothing here would work
/// without a shared `GenreRegistry` and frozen `Genre` objects to reference.
/// Nothing below crosses an ownership handoff between distinct senders; the
/// production shape — a published, shared `Recording` operated on across real
/// transaction boundaries — is covered separately in
/// `recording_genre_e2e_tests`.
///
/// A recording's `RecordingShare` type uniquely identifies it, so
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type and
/// `recording::uid_mut` performs no runtime check. A wrong-cap test is
/// therefore not expressible — the call would fail to compile, not abort.
#[test_only]
module recording_genre::recording_genre_tests;

use genre::genre as g;
use genre::genre::{GenreRegistry, Genre};
use miso::recording;
use recording_genre::recording_genre as rg;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

public struct REC {}
public struct COMP {}
public struct OTHER_REC {}

/// This package never touches the composition side of a recording — it only
/// needs a `Recording` to exist, so a bare id stands in for a real
/// `Composition` rather than constructing one.
fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(object::id_from_address(@0xC0FFEE), ctx)
}

/// Creates a genre in the permissionless registry and returns its derived id.
fun create_genre(scenario: &Scenario, name: vector<u8>): ID {
    let mut registry = scenario.take_shared<GenreRegistry>();
    let id = g::derive_address(&registry, name.to_string()).to_id();
    g::new(&mut registry, name.to_string());
    ts::return_shared(registry);
    id
}

#[test]
fun views_before_assignment_are_empty() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let (rec, cap) = new_rec(scenario.ctx());

    assert!(rg::genres(&rec).is_empty());

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
    let rec_id = object::id(&rec);

    rg::add_genre(&mut rec, &cap, &genre1);
    assert!(!rg::genres(&rec).is_empty());
    assert_eq!(rg::genres(&rec), vector[g1]);

    let events = event::events_by_type<rg::GenreAddedEvent>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, event_genre_id) = rg::genre_added_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_genre_id, g1);

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

    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::add_genre(&mut rec, &cap, &genre_b);
    rg::add_genre(&mut rec, &cap, &genre_c);
    assert_eq!(rg::genres(&rec), vector[a, b, c]);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    ts::return_immutable(genre_c);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rg::EDuplicateGenre)]
fun add_genre_duplicate_aborts() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(@0xC0);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rg::add_genre(&mut rec, &cap, &genre1);
    rg::add_genre(&mut rec, &cap, &genre1);

    ts::return_immutable(genre1);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rg::EMaxGenres)]
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

    let mut i = 0;
    while (i < 6) {
        rg::add_genre(&mut rec, &cap, &genres[i]);
        i = i + 1;
    };
    assert_eq!(rg::genres(&rec).length(), 6);
    // The 7th genre pushes past MAX_GENRES.
    rg::add_genre(&mut rec, &cap, &genres[6]);

    genres.destroy!(|genre| ts::return_immutable(genre));
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rg::EGenreNotPresent)]
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

    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::remove_genre(&mut rec, &cap, object::id(&genre_b)); // never added

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rg::EGenreNotPresent)]
fun remove_genre_not_present_aborts_when_nothing_attached() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rg::remove_genre(&mut rec, &cap, object::id(&genre_a)); // nothing attached

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
    let rec_id = object::id(&rec);

    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::add_genre(&mut rec, &cap, &genre_b);
    rg::add_genre(&mut rec, &cap, &genre_c);

    rg::remove_genre(&mut rec, &cap, a);
    assert_eq!(rg::genres(&rec), vector[b, c]);

    let removed_events = event::events_by_type<rg::GenreRemovedEvent>();
    assert_eq!(removed_events.length(), 1);
    let (event_rec_id, event_genre_id) = rg::genre_removed_event_fields(&removed_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_genre_id, a);

    assert_eq!(event::events_by_type<rg::GenresClearedEvent>().length(), 0);

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

    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::add_genre(&mut rec, &cap, &genre_b);
    rg::add_genre(&mut rec, &cap, &genre_c);

    rg::remove_genre(&mut rec, &cap, b);
    assert_eq!(rg::genres(&rec), vector[a, c]);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    ts::return_immutable(genre_c);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun removing_the_last_genre_drops_the_field() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let (mut rec, cap) = new_rec(scenario.ctx());
    let rec_id = object::id(&rec);

    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::remove_genre(&mut rec, &cap, a);

    assert!(rg::genres(&rec).is_empty());

    assert_eq!(event::events_by_type<rg::GenreRemovedEvent>().length(), 1);
    let cleared_events = event::events_by_type<rg::GenresClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rg::genres_cleared_event_recording_id(&cleared_events[0]), rec_id);

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

    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::remove_genre(&mut rec, &cap, a);
    assert!(rg::genres(&rec).is_empty());

    rg::add_genre(&mut rec, &cap, &genre_b);
    assert!(!rg::genres(&rec).is_empty());
    assert_eq!(rg::genres(&rec), vector[b]);

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
    let rec_id = object::id(&rec);

    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::add_genre(&mut rec, &cap, &genre_b);
    rg::add_genre(&mut rec, &cap, &genre_c);

    rg::clear_genres(&mut rec, &cap);
    assert!(rg::genres(&rec).is_empty());

    let cleared_events = event::events_by_type<rg::GenresClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rg::genres_cleared_event_recording_id(&cleared_events[0]), rec_id);

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

    rg::clear_genres(&mut rec, &cap);

    assert!(rg::genres(&rec).is_empty());
    assert_eq!(event::events_by_type<rg::GenresClearedEvent>().length(), 0);

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

    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::add_genre(&mut rec, &cap, &genre_b);
    rg::add_genre(&mut rec, &cap, &genre_c);
    assert_eq!(rg::genres(&rec), vector[a, b, c]);

    rg::clear_genres(&mut rec, &cap);
    rg::add_genre(&mut rec, &cap, &genre_c);
    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::add_genre(&mut rec, &cap, &genre_b);

    assert_eq!(rg::genres(&rec), vector[c, a, b]);

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
    let (rec_b, cap_b) = recording::new_for_testing<OTHER_REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        scenario.ctx(),
    );

    rg::add_genre(&mut rec_a, &cap_a, &genre_a);

    assert!(!rg::genres(&rec_a).is_empty());
    assert!(rg::genres(&rec_b).is_empty());

    ts::return_immutable(genre_a);
    destroy(rec_a);
    destroy(cap_a);
    destroy(rec_b);
    destroy(cap_b);
    scenario.end();
}
