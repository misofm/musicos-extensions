// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary, error-const, and event-payload coverage for the genre attribute.
/// Runs under `sui::test_scenario` throughout — the vocabulary lives in a
/// shared registry and mints frozen `Genre` objects, so scenario machinery is
/// needed to reach them — but a single CREATOR sender suffices, because every
/// operation is gated by a `ReleaseAdminCap` held locally (not by sender
/// identity), so there is nothing distinct senders would prove. The
/// cap-gating itself is exercised adversarially (wrong cap, wrong actor) in
/// `genre_e2e_tests`, alongside the full publish-and-share production
/// flow.
#[test_only]
module release_metadata::genre_tests;

use genre::genre as g;
use genre::genre::Genre;
use musicos::release::Release;
use release_metadata::release_metadata as rm;
use release_metadata::test_utils::{mk_release, create_genre};
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario::{Self as ts};

const CREATOR: address = @0xC0;

public struct UnrelatedKey() has copy, drop, store;

// === Event-only replay ===

// Every event is independently consumable: the projector below maintains an
// ordered list from the event stream alone, never consulting the package
// view, and is compared with `genres()` after each transition. Added always
// appends; Removed deletes by id, preserving order; Cleared empties.

fun assert_replay_view(rel: &Release, state: &vector<address>) {
    let actual = rm::genres(rel).map!(|id| id.to_address());
    assert_eq!(actual, *state);
}

fun project_added_event(
    e: &rm::ReleaseGenreAddedEvent,
    release_id: address,
    expected_genre_id: address,
    state: &mut vector<address>,
) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), release_id);
    let genre_id = bytes.peel_address();
    assert!(bytes.into_remainder_bytes().is_empty());
    assert_eq!(genre_id, expected_genre_id);
    assert!(!state.contains(&genre_id));
    state.push_back(genre_id);
}

fun project_removed_event(
    e: &rm::ReleaseGenreRemovedEvent,
    release_id: address,
    expected_genre_id: address,
    state: &mut vector<address>,
) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), release_id);
    let genre_id = bytes.peel_address();
    assert!(bytes.into_remainder_bytes().is_empty());
    assert_eq!(genre_id, expected_genre_id);
    let (found, idx) = state.index_of(&genre_id);
    assert!(found);
    state.remove(idx);
}

fun project_cleared_event(
    e: &rm::ReleaseGenresClearedEvent,
    release_id: address,
    state: &mut vector<address>,
) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), release_id);
    assert!(bytes.into_remainder_bytes().is_empty());
    *state = vector[];
}

// === Views before assignment ===

#[test]
fun views_before_assignment_are_empty() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let (rel, cap) = mk_release(scenario.ctx());

    assert!(rm::genres(&rel).is_empty());
    assert_eq!(event::events_by_type<rm::ReleaseGenreAddedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseGenreRemovedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 0);

    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun unrelated_dynamic_field_survives_genre_lifecycle() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let genre_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let genre = scenario.take_immutable_by_id<Genre>(genre_id);
    let (mut rel, cap) = mk_release(scenario.ctx());
    df::add(rel.uid_mut(&cap), UnrelatedKey(), 77u64);
    rm::add_genre(&mut rel, &cap, &genre);
    rm::clear_genres(&mut rel, &cap);
    assert!(df::exists(rel.uid(), UnrelatedKey()));
    assert_eq!(*df::borrow(rel.uid(), UnrelatedKey()), 77u64);
    let marker: u64 = df::remove(rel.uid_mut(&cap), UnrelatedKey());
    assert_eq!(marker, 77);
    assert!(!df::exists(rel.uid(), UnrelatedKey()));
    assert_eq!(event::events_by_type<rm::ReleaseGenreAddedEvent>().length(), 1);
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 1);
    ts::return_immutable(genre);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

// This also exercises the final remove: it is one Removed event, with no
// cascaded Cleared — the indexer's own list went empty, so it knows there is
// no genre left, and the metadata record is gone once nothing else is set.
#[test]
fun event_replay_tracks_order_and_field_lifecycle() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let a_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let b_id = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(CREATOR);
    let c_id = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(CREATOR);
    let a = scenario.take_immutable_by_id<Genre>(a_id);
    let b = scenario.take_immutable_by_id<Genre>(b_id);
    let c = scenario.take_immutable_by_id<Genre>(c_id);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel).to_address();
    let mut replay_state = vector[];

    rm::add_genre(&mut rel, &cap, &a);
    let added = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 1);
    project_added_event(&added[0], release_id, a_id.to_address(), &mut replay_state);
    assert_replay_view(&rel, &replay_state);

    rm::add_genre(&mut rel, &cap, &b);
    let added = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 2);
    project_added_event(&added[1], release_id, b_id.to_address(), &mut replay_state);
    assert_replay_view(&rel, &replay_state);

    rm::remove_genre(&mut rel, &cap, a_id);
    let removed = event::events_by_type<rm::ReleaseGenreRemovedEvent>();
    assert_eq!(removed.length(), 1);
    project_removed_event(&removed[0], release_id, a_id.to_address(), &mut replay_state);
    assert_eq!(replay_state, vector[b_id.to_address()]);
    assert_replay_view(&rel, &replay_state);
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 0);

    rm::clear_genres(&mut rel, &cap);
    let cleared = event::events_by_type<rm::ReleaseGenresClearedEvent>();
    assert_eq!(cleared.length(), 1);
    project_cleared_event(&cleared[0], release_id, &mut replay_state);
    assert_replay_view(&rel, &replay_state);

    rm::add_genre(&mut rel, &cap, &c);
    let added = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 3);
    project_added_event(&added[2], release_id, c_id.to_address(), &mut replay_state);
    assert_replay_view(&rel, &replay_state);

    // Final remove: one Removed event and nothing else.
    rm::remove_genre(&mut rel, &cap, c_id);
    let removed = event::events_by_type<rm::ReleaseGenreRemovedEvent>();
    assert_eq!(removed.length(), 2);
    project_removed_event(&removed[1], release_id, c_id.to_address(), &mut replay_state);
    assert!(replay_state.is_empty());
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 1);
    assert_replay_view(&rel, &replay_state);
    assert!(!rm::has_metadata_for_testing(&rel));

    ts::return_immutable(a);
    ts::return_immutable(b);
    ts::return_immutable(c);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

/// Every payload is fixed-size: Added and Removed are two addresses (64
/// bytes), Cleared is one (32). Exercised at the six-item capacity, on the
/// longest vocabulary name (64 bytes, which does not affect the event), and
/// on a final removal.
#[test]
fun event_payloads_are_fixed_size_at_capacity_and_on_final_removal() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    let names = vector[
        b"HIP_HOP",
        b"ELECTRONIC",
        b"AMBIENT",
        b"JAZZ",
        b"ROCK",
        b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    ];
    let mut ids = vector[];
    names.do!(|name| {
        scenario.next_tx(CREATOR);
        ids.push_back(create_genre(&scenario, name));
    });
    let first_id = ids[0];

    scenario.next_tx(CREATOR);
    let genres = ids.map!(|id| scenario.take_immutable_by_id<Genre>(id));
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel).to_address();
    let mut replay_state = vector[];

    genres.do_ref!(|genre| rm::add_genre(&mut rel, &cap, genre));
    let added = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 6);
    6u64.do!(|i| {
        project_added_event(&added[i], release_id, ids[i].to_address(), &mut replay_state);
        assert_eq!(bcs::to_bytes(&added[i]).length(), 64);
    });
    assert_eq!(genres[5].name().length(), 64);
    assert_replay_view(&rel, &replay_state);

    // Removing from the six-item list, then re-appending so the explicit
    // clear below drops a full list.
    rm::remove_genre(&mut rel, &cap, first_id);
    let removed = event::events_by_type<rm::ReleaseGenreRemovedEvent>();
    assert_eq!(removed.length(), 1);
    project_removed_event(&removed[0], release_id, first_id.to_address(), &mut replay_state);
    assert_eq!(bcs::to_bytes(&removed[0]).length(), 64);
    assert_replay_view(&rel, &replay_state);
    rm::add_genre(&mut rel, &cap, &genres[0]);
    let added = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 7);
    project_added_event(&added[6], release_id, first_id.to_address(), &mut replay_state);
    assert_replay_view(&rel, &replay_state);
    assert_eq!(rm::genres(&rel).length(), 6);

    rm::clear_genres(&mut rel, &cap);
    let cleared = event::events_by_type<rm::ReleaseGenresClearedEvent>();
    assert_eq!(cleared.length(), 1);
    project_cleared_event(&cleared[0], release_id, &mut replay_state);
    assert_eq!(bcs::to_bytes(&cleared[0]).length(), 32);
    assert_replay_view(&rel, &replay_state);

    genres.destroy!(|genre| ts::return_immutable(genre));
    destroy(rel);
    destroy(cap);

    // A final removal on a fresh release: one Removed event, no Cleared.
    scenario.next_tx(CREATOR);
    let genre = scenario.take_immutable_by_id<Genre>(first_id);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel).to_address();
    let mut replay_state = vector[];
    rm::add_genre(&mut rel, &cap, &genre);
    let added = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 1);
    project_added_event(&added[0], release_id, first_id.to_address(), &mut replay_state);
    rm::remove_genre(&mut rel, &cap, first_id);
    let removed = event::events_by_type<rm::ReleaseGenreRemovedEvent>();
    assert_eq!(removed.length(), 1);
    project_removed_event(&removed[0], release_id, first_id.to_address(), &mut replay_state);
    assert_eq!(bcs::to_bytes(&removed[0]).length(), 64);
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 0);
    assert_replay_view(&rel, &replay_state);

    ts::return_immutable(genre);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun two_releases_share_monomorphic_event_streams() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let a_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let b_id = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let a = scenario.take_immutable_by_id<Genre>(a_id);
    let b = scenario.take_immutable_by_id<Genre>(b_id);
    let (mut rel_a, cap_a) = mk_release(scenario.ctx());
    let (mut rel_b, cap_b) = mk_release(scenario.ctx());
    let rel_a_id = object::id(&rel_a).to_address();
    let rel_b_id = object::id(&rel_b).to_address();
    rm::add_genre(&mut rel_a, &cap_a, &a);
    rm::add_genre(&mut rel_b, &cap_b, &b);
    let added = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 2);
    let (first_release, first_genre) = rm::genre_added_event_fields(&added[0]);
    let (second_release, second_genre) = rm::genre_added_event_fields(&added[1]);
    assert_eq!(first_release, rel_a_id);
    assert_eq!(first_genre, a_id.to_address());
    assert_eq!(second_release, rel_b_id);
    assert_eq!(second_genre, b_id.to_address());

    rm::clear_genres(&mut rel_a, &cap_a);
    rm::clear_genres(&mut rel_b, &cap_b);
    let cleared = event::events_by_type<rm::ReleaseGenresClearedEvent>();
    assert_eq!(cleared.length(), 2);
    assert_eq!(rm::genres_cleared_event_fields(&cleared[0]), rel_a_id);
    assert_eq!(rm::genres_cleared_event_fields(&cleared[1]), rel_b_id);
    assert!(rm::genres(&rel_a).is_empty());
    assert!(rm::genres(&rel_b).is_empty());

    ts::return_immutable(a);
    ts::return_immutable(b);
    destroy(rel_a);
    destroy(cap_a);
    destroy(rel_b);
    destroy(cap_b);
    scenario.end();
}

// === add_genre ===

#[test]
fun first_add_genre_establishes_the_primary() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let genre_id = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre = scenario.take_immutable_by_id<Genre>(genre_id);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel);

    rm::add_genre(&mut rel, &cap, &genre);
    assert!(rm::genres(&rel) == vector[genre_id]);

    let events = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    assert_eq!(events.length(), 1);
    let (event_release_id, event_genre_id) = rm::genre_added_event_fields(&events[0]);
    assert_eq!(event_release_id, release_id.to_address());
    assert_eq!(event_genre_id, genre_id.to_address());

    ts::return_immutable(genre);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun appending_preserves_order() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let a_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let b_id = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(CREATOR);
    let c_id = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(CREATOR);
    let a = scenario.take_immutable_by_id<Genre>(a_id);
    let b = scenario.take_immutable_by_id<Genre>(b_id);
    let c = scenario.take_immutable_by_id<Genre>(c_id);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rm::add_genre(&mut rel, &cap, &a);
    rm::add_genre(&mut rel, &cap, &b);
    rm::add_genre(&mut rel, &cap, &c);

    assert_eq!(rm::genres(&rel), vector[a_id, b_id, c_id]);

    ts::return_immutable(a);
    ts::return_immutable(b);
    ts::return_immutable(c);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = rm::EDuplicateGenre)]
fun add_genre_duplicate_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let genre_id = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre = scenario.take_immutable_by_id<Genre>(genre_id);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rm::add_genre(&mut rel, &cap, &genre);
    rm::add_genre(&mut rel, &cap, &genre); // duplicate

    ts::return_immutable(genre);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = rm::EMaxGenres)]
fun add_genre_at_max_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    let names = vector[
        b"HIP_HOP", b"ELECTRONIC", b"AMBIENT", b"JAZZ", b"ROCK", b"POP", b"FOLK",
    ];
    let mut ids = vector[];
    names.do!(|name| {
        scenario.next_tx(CREATOR);
        ids.push_back(create_genre(&scenario, name));
    });

    scenario.next_tx(CREATOR);
    let genres = ids.map!(|id| scenario.take_immutable_by_id<Genre>(id));
    let (mut rel, cap) = mk_release(scenario.ctx());

    6u64.do!(|i| rm::add_genre(&mut rel, &cap, &genres[i]));
    assert_eq!(rm::genres(&rel).length(), 6);
    // The 7th genre pushes past MAX_GENRES.
    rm::add_genre(&mut rel, &cap, &genres[6]);

    genres.destroy!(|genre| ts::return_immutable(genre));
    destroy(rel);
    destroy(cap);
    scenario.end();
}

/// A duplicate at capacity reports the duplicate, not the capacity: the
/// membership check runs first.
#[test]
#[expected_failure(abort_code = rm::EDuplicateGenre)]
fun duplicate_is_reported_before_capacity() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    let names = vector[b"HIP_HOP", b"ELECTRONIC", b"AMBIENT", b"JAZZ", b"ROCK", b"POP"];
    let mut ids = vector[];
    names.do!(|name| {
        scenario.next_tx(CREATOR);
        ids.push_back(create_genre(&scenario, name));
    });

    scenario.next_tx(CREATOR);
    let genres = ids.map!(|id| scenario.take_immutable_by_id<Genre>(id));
    let (mut rel, cap) = mk_release(scenario.ctx());

    genres.do_ref!(|genre| rm::add_genre(&mut rel, &cap, genre));
    assert_eq!(rm::genres(&rel).length(), 6);
    rm::add_genre(&mut rel, &cap, &genres[0]);

    genres.destroy!(|genre| ts::return_immutable(genre));
    destroy(rel);
    destroy(cap);
    scenario.end();
}

// === remove_genre ===

#[test]
#[expected_failure(abort_code = rm::EGenreNotPresent)]
fun remove_genre_not_present_aborts_when_field_exists() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let a_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let b_id = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let a = scenario.take_immutable_by_id<Genre>(a_id);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rm::add_genre(&mut rel, &cap, &a);
    rm::remove_genre(&mut rel, &cap, b_id); // never assigned

    ts::return_immutable(a);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = rm::EGenreNotPresent)]
fun remove_genre_not_present_aborts_when_nothing_attached() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rm::remove_genre(&mut rel, &cap, object::id_from_address(@0xF00D));

    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun removing_the_primary_promotes_the_next() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let a_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let b_id = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(CREATOR);
    let c_id = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(CREATOR);
    let a = scenario.take_immutable_by_id<Genre>(a_id);
    let b = scenario.take_immutable_by_id<Genre>(b_id);
    let c = scenario.take_immutable_by_id<Genre>(c_id);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel);

    rm::add_genre(&mut rel, &cap, &a);
    rm::add_genre(&mut rel, &cap, &b);
    rm::add_genre(&mut rel, &cap, &c);

    rm::remove_genre(&mut rel, &cap, a_id);
    assert_eq!(rm::genres(&rel), vector[b_id, c_id]);

    let removed_events = event::events_by_type<rm::ReleaseGenreRemovedEvent>();
    assert_eq!(removed_events.length(), 1);
    let (event_release_id, event_genre_id) = rm::genre_removed_event_fields(&removed_events[0]);
    assert_eq!(event_release_id, release_id.to_address());
    assert_eq!(event_genre_id, a_id.to_address());

    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 0);

    ts::return_immutable(a);
    ts::return_immutable(b);
    ts::return_immutable(c);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun removing_a_non_primary_keeps_the_primary() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let a_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let b_id = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let a = scenario.take_immutable_by_id<Genre>(a_id);
    let b = scenario.take_immutable_by_id<Genre>(b_id);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rm::add_genre(&mut rel, &cap, &a);
    rm::add_genre(&mut rel, &cap, &b);

    rm::remove_genre(&mut rel, &cap, b_id);
    assert_eq!(rm::genres(&rel), vector[a_id]);

    ts::return_immutable(a);
    ts::return_immutable(b);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun removing_the_last_genre_drops_the_field() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let genre_id = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre = scenario.take_immutable_by_id<Genre>(genre_id);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel).to_address();

    rm::add_genre(&mut rel, &cap, &genre);
    assert!(rm::has_metadata_for_testing(&rel));
    rm::remove_genre(&mut rel, &cap, genre_id);

    // The list is empty, and with nothing else set the record itself is
    // gone — with the one Removed event, no cascaded Cleared.
    assert!(rm::genres(&rel).is_empty());
    assert!(!rm::has_metadata_for_testing(&rel));

    let removed_events = event::events_by_type<rm::ReleaseGenreRemovedEvent>();
    assert_eq!(removed_events.length(), 1);
    let (event_release_id, event_genre_id) = rm::genre_removed_event_fields(&removed_events[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_genre_id, genre_id.to_address());
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 0);

    ts::return_immutable(genre);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun add_genre_after_clearing_recreates_the_field() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let a_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let b_id = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let a = scenario.take_immutable_by_id<Genre>(a_id);
    let b = scenario.take_immutable_by_id<Genre>(b_id);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rm::add_genre(&mut rel, &cap, &a);
    rm::remove_genre(&mut rel, &cap, a_id);
    assert!(rm::genres(&rel).is_empty());

    rm::add_genre(&mut rel, &cap, &b);
    assert!(!rm::genres(&rel).is_empty());
    assert_eq!(rm::genres(&rel), vector[b_id]);

    ts::return_immutable(a);
    ts::return_immutable(b);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

// === clear_genres ===

#[test]
fun clear_genres_removes_the_whole_list() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let a_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let b_id = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(CREATOR);
    let c_id = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(CREATOR);
    let a = scenario.take_immutable_by_id<Genre>(a_id);
    let b = scenario.take_immutable_by_id<Genre>(b_id);
    let c = scenario.take_immutable_by_id<Genre>(c_id);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel);

    rm::add_genre(&mut rel, &cap, &a);
    rm::add_genre(&mut rel, &cap, &b);
    rm::add_genre(&mut rel, &cap, &c);

    rm::clear_genres(&mut rel, &cap);
    assert!(rm::genres(&rel).is_empty());

    let cleared_events = event::events_by_type<rm::ReleaseGenresClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rm::genres_cleared_event_fields(&cleared_events[0]), release_id.to_address());

    ts::return_immutable(a);
    ts::return_immutable(b);
    ts::return_immutable(c);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun clear_genres_when_absent_is_a_no_op() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rm::clear_genres(&mut rel, &cap);

    assert!(rm::genres(&rel).is_empty());
    assert_eq!(event::events_by_type<rm::ReleaseGenreAddedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseGenreRemovedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 0);

    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun reorder_via_clear_and_re_add() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let a_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let b_id = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(CREATOR);
    let c_id = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(CREATOR);
    let a = scenario.take_immutable_by_id<Genre>(a_id);
    let b = scenario.take_immutable_by_id<Genre>(b_id);
    let c = scenario.take_immutable_by_id<Genre>(c_id);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rm::add_genre(&mut rel, &cap, &a);
    rm::add_genre(&mut rel, &cap, &b);
    rm::add_genre(&mut rel, &cap, &c);
    assert_eq!(rm::genres(&rel), vector[a_id, b_id, c_id]);

    rm::clear_genres(&mut rel, &cap);
    rm::add_genre(&mut rel, &cap, &c);
    rm::add_genre(&mut rel, &cap, &a);
    rm::add_genre(&mut rel, &cap, &b);

    assert_eq!(rm::genres(&rel), vector[c_id, a_id, b_id]);

    ts::return_immutable(a);
    ts::return_immutable(b);
    ts::return_immutable(c);
    destroy(rel);
    destroy(cap);
    scenario.end();
}
