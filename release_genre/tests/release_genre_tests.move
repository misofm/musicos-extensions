// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary, error-const, and event-payload coverage for `release_genre`.
/// Runs under `sui::test_scenario` throughout — a single CREATOR sender
/// suffices here because every operation is gated by a `ReleaseAdminCap` held
/// locally (not by sender identity), so there is nothing distinct senders
/// would prove; the cap-gating itself is exercised adversarially (wrong cap,
/// wrong actor) in `release_genre_e2e_tests`, alongside the full
/// publish-and-share production flow.
#[test_only]
module release_genre::release_genre_tests;

use genre::genre as g;
use genre::genre::{GenreRegistry, Genre};
use release_genre::release_genre as rg;
use miso::release::{Self, Release, ReleaseAdminCap};
use miso::test_helpers;
use miso::track;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const CREATOR: address = @0xC0;

// === Helpers ===

/// Creates a genre in the permissionless registry and returns its derived id.
fun create_genre(scenario: &Scenario, name: vector<u8>): ID {
    let mut registry = scenario.take_shared<GenreRegistry>();
    let id = g::derive_address(&registry, name.to_string()).to_id();
    g::new(&mut registry, name.to_string());
    ts::return_shared(registry);
    id
}

// A 2-track release: flat tracklist indices 0, 1. This package no longer
// reads the tracklist, but the release constructor still needs tracks.
fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let comp_id = test_helpers::fake_id(ctx);
    let rel_id = test_helpers::fake_id(ctx);
    let r0 = test_helpers::fake_id(ctx);
    let r1 = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(comp_id, r0, rel_id, 5000u16),
        track::new_for_testing(comp_id, r1, rel_id, 5000u16),
    ];
    release::new_for_testing(b"Album".to_string(), tracks, ctx)
}

// === Views before assignment ===

#[test]
fun views_before_assignment_are_empty() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let (rel, cap) = mk_release(scenario.ctx());

    assert!(rg::genres(&rel).is_empty());

    destroy(rel);
    destroy(cap);
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

    rg::add_genre(&mut rel, &cap, &genre);
    assert!(rg::genres(&rel) == vector[genre_id]);

    let events = event::events_by_type<rg::GenreAddedEvent>();
    assert_eq!(events.length(), 1);
    let (event_release_id, event_genre_id) = rg::genre_added_event_fields(&events[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_genre_id, genre_id);

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

    rg::add_genre(&mut rel, &cap, &a);
    rg::add_genre(&mut rel, &cap, &b);
    rg::add_genre(&mut rel, &cap, &c);

    assert_eq!(rg::genres(&rel), vector[a_id, b_id, c_id]);

    ts::return_immutable(a);
    ts::return_immutable(b);
    ts::return_immutable(c);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 40, location = release_genre::release_genre)] // EDuplicateGenre
fun add_genre_duplicate_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let genre_id = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre = scenario.take_immutable_by_id<Genre>(genre_id);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::add_genre(&mut rel, &cap, &genre);
    rg::add_genre(&mut rel, &cap, &genre); // duplicate

    ts::return_immutable(genre);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 41, location = release_genre::release_genre)] // EMaxGenres
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

    let mut i = 0;
    while (i < 6) {
        rg::add_genre(&mut rel, &cap, &genres[i]);
        i = i + 1;
    };
    assert_eq!(rg::genres(&rel).length(), 6);
    // The 7th genre pushes past MAX_GENRES.
    rg::add_genre(&mut rel, &cap, &genres[6]);

    genres.destroy!(|genre| ts::return_immutable(genre));
    destroy(rel);
    destroy(cap);
    scenario.end();
}

// === remove_genre ===

#[test]
#[expected_failure(abort_code = 42, location = release_genre::release_genre)] // EGenreNotPresent
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

    rg::add_genre(&mut rel, &cap, &a);
    rg::remove_genre(&mut rel, &cap, b_id); // never assigned

    ts::return_immutable(a);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 42, location = release_genre::release_genre)] // EGenreNotPresent
fun remove_genre_not_present_aborts_when_nothing_attached() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::remove_genre(&mut rel, &cap, object::id_from_address(@0xF00D));

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

    rg::add_genre(&mut rel, &cap, &a);
    rg::add_genre(&mut rel, &cap, &b);
    rg::add_genre(&mut rel, &cap, &c);

    rg::remove_genre(&mut rel, &cap, a_id);
    assert_eq!(rg::genres(&rel), vector[b_id, c_id]);

    let removed_events = event::events_by_type<rg::GenreRemovedEvent>();
    assert_eq!(removed_events.length(), 1);
    let (event_release_id, event_genre_id) = rg::genre_removed_event_fields(&removed_events[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_genre_id, a_id);

    assert_eq!(event::events_by_type<rg::GenresClearedEvent>().length(), 0);

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

    rg::add_genre(&mut rel, &cap, &a);
    rg::add_genre(&mut rel, &cap, &b);

    rg::remove_genre(&mut rel, &cap, b_id);
    assert_eq!(rg::genres(&rel), vector[a_id]);

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
    let release_id = object::id(&rel);

    rg::add_genre(&mut rel, &cap, &genre);
    rg::remove_genre(&mut rel, &cap, genre_id);

    assert!(rg::genres(&rel).is_empty());

    assert_eq!(event::events_by_type<rg::GenreRemovedEvent>().length(), 1);
    let cleared_events = event::events_by_type<rg::GenresClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rg::genres_cleared_event_release_id(&cleared_events[0]), release_id);

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

    rg::add_genre(&mut rel, &cap, &a);
    rg::remove_genre(&mut rel, &cap, a_id);
    assert!(rg::genres(&rel).is_empty());

    rg::add_genre(&mut rel, &cap, &b);
    assert!(!rg::genres(&rel).is_empty());
    assert_eq!(rg::genres(&rel), vector[b_id]);

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

    rg::add_genre(&mut rel, &cap, &a);
    rg::add_genre(&mut rel, &cap, &b);
    rg::add_genre(&mut rel, &cap, &c);

    rg::clear_genres(&mut rel, &cap);
    assert!(rg::genres(&rel).is_empty());

    let cleared_events = event::events_by_type<rg::GenresClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rg::genres_cleared_event_release_id(&cleared_events[0]), release_id);

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

    rg::clear_genres(&mut rel, &cap);

    assert!(rg::genres(&rel).is_empty());
    assert_eq!(event::events_by_type<rg::GenresClearedEvent>().length(), 0);

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

    rg::add_genre(&mut rel, &cap, &a);
    rg::add_genre(&mut rel, &cap, &b);
    rg::add_genre(&mut rel, &cap, &c);
    assert_eq!(rg::genres(&rel), vector[a_id, b_id, c_id]);

    rg::clear_genres(&mut rel, &cap);
    rg::add_genre(&mut rel, &cap, &c);
    rg::add_genre(&mut rel, &cap, &a);
    rg::add_genre(&mut rel, &cap, &b);

    assert_eq!(rg::genres(&rel), vector[c_id, a_id, b_id]);

    ts::return_immutable(a);
    ts::return_immutable(b);
    ts::return_immutable(c);
    destroy(rel);
    destroy(cap);
    scenario.end();
}
