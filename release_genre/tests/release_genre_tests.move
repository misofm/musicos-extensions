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
use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const CREATOR: address = @0xC0;

public struct UnrelatedKey() has copy, drop, store;

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
    rg::add_genre(&mut rel, &cap, &genre);
    rg::clear_genres(&mut rel, &cap);
    assert!(df::exists(rel.uid(), UnrelatedKey()));
    assert_eq!(*df::borrow(rel.uid(), UnrelatedKey()), 77u64);
    let marker: u64 = df::remove(rel.uid_mut(&cap), UnrelatedKey());
    assert_eq!(marker, 77);
    assert!(!df::exists(rel.uid(), UnrelatedKey()));
    assert_eq!(event::events_by_type<rg::ReleaseGenreAddedEvent>().length(), 1);
    assert_eq!(event::events_by_type<rg::ReleaseGenresClearedEvent>().length(), 1);
    ts::return_immutable(genre);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

fun ids_as_addresses(ids: &vector<ID>): vector<address> {
    let mut result = vector[];
    let mut i = 0;
    while (i < ids.length()) {
        result.push_back(ids[i].to_address());
        i = i + 1;
    };
    result
}

fun primary_id(ids: &vector<address>): address {
    if (ids.is_empty()) @0x0 else ids[0]
}

fun assert_replay_view(rel: &Release, exists: bool, state: &vector<address>) {
    let actual_ids = rg::genres(rel);
    let actual = ids_as_addresses(&actual_ids);
    assert_eq!(actual.length(), state.length());
    let mut i = 0;
    while (i < actual.length()) {
        assert_eq!(actual[i], state[i]);
        i = i + 1;
    };
    assert_eq!(exists, !state.is_empty());
}

fun project_added_event(
    event: &rg::ReleaseGenreAddedEvent,
    release_id: address,
    cap_id: address,
    expected_name: vector<u8>,
    expected_exists: &mut bool,
    expected_state: &mut vector<address>,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_address(), cap_id);
    let genre_id = bytes.peel_address();
    let genre_name = bytes.peel_vec_u8();
    let genre_index = bytes.peel_u64();
    let genres_before = bytes.peel_vec_address();
    let genres_after = bytes.peel_vec_address();
    let genre_count_before = bytes.peel_u64();
    let genre_count_after = bytes.peel_u64();
    let field_existed_before = bytes.peel_bool();
    let field_exists_after = bytes.peel_bool();
    let had_primary_before = bytes.peel_bool();
    let has_primary_after = bytes.peel_bool();
    let primary_genre_id_before = bytes.peel_address();
    let primary_genre_id_after = bytes.peel_address();
    let primary_changed = bytes.peel_bool();
    assert_eq!(genre_name, expected_name);
    assert_eq!(genres_before, *expected_state);
    assert_eq!(field_existed_before, *expected_exists);
    assert_eq!(genre_index, genres_before.length());
    assert_eq!(genre_count_before, genres_before.length());
    assert_eq!(genre_count_after, genres_after.length());
    assert_eq!(genres_after.length(), genres_before.length() + 1);
    assert_eq!(genres_after[genre_index], genre_id);
    assert!(field_exists_after);
    assert_eq!(had_primary_before, !genres_before.is_empty());
    assert!(has_primary_after);
    assert_eq!(primary_genre_id_before, primary_id(&genres_before));
    assert_eq!(primary_genre_id_after, primary_id(&genres_after));
    assert_eq!(primary_changed, primary_genre_id_before != primary_genre_id_after);
    assert!(bytes.into_remainder_bytes().is_empty());
    *expected_exists = true;
    *expected_state = genres_after;
}

fun project_removed_event(
    event: &rg::ReleaseGenreRemovedEvent,
    release_id: address,
    cap_id: address,
    expected_genre_id: address,
    expected_after: vector<address>,
    expected_exists: &mut bool,
    expected_state: &mut vector<address>,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_address(), cap_id);
    let genre_id = bytes.peel_address();
    let genre_index = bytes.peel_u64();
    let genres_before = bytes.peel_vec_address();
    let genres_after = bytes.peel_vec_address();
    let genre_count_before = bytes.peel_u64();
    let genre_count_after = bytes.peel_u64();
    let field_existed_before = bytes.peel_bool();
    let field_exists_after = bytes.peel_bool();
    let had_primary_before = bytes.peel_bool();
    let has_primary_after = bytes.peel_bool();
    let primary_genre_id_before = bytes.peel_address();
    let primary_genre_id_after = bytes.peel_address();
    let primary_changed = bytes.peel_bool();
    let (found, actual_index) = genres_before.index_of(&expected_genre_id);
    assert!(found);
    assert_eq!(genre_id, expected_genre_id);
    assert_eq!(genre_index, actual_index);
    assert_eq!(genres_before, *expected_state);
    assert_eq!(genres_after, expected_after);
    assert_eq!(genre_count_before, genres_before.length());
    assert_eq!(genre_count_after, genres_after.length());
    assert!(field_existed_before);
    assert!(field_exists_after);
    assert!(had_primary_before);
    assert_eq!(has_primary_after, !genres_after.is_empty());
    assert_eq!(primary_genre_id_before, primary_id(&genres_before));
    assert_eq!(primary_genre_id_after, primary_id(&genres_after));
    assert_eq!(primary_changed, primary_genre_id_before != primary_genre_id_after);
    assert!(bytes.into_remainder_bytes().is_empty());
    *expected_exists = !genres_after.is_empty();
    *expected_state = genres_after;
}

fun project_cleared_event(
    event: &rg::ReleaseGenresClearedEvent,
    release_id: address,
    cap_id: address,
    expected_cause: u8,
    expected_trigger: address,
    expected_exists: &mut bool,
    expected_state: &mut vector<address>,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_address(), cap_id);
    let clear_cause = bytes.peel_u8();
    let trigger_genre_id = bytes.peel_address();
    let genres_before = bytes.peel_vec_address();
    let genres_after = bytes.peel_vec_address();
    let genre_count_before = bytes.peel_u64();
    let genre_count_after = bytes.peel_u64();
    let field_existed_before = bytes.peel_bool();
    let field_exists_after = bytes.peel_bool();
    let had_primary_before = bytes.peel_bool();
    let has_primary_after = bytes.peel_bool();
    let primary_genre_id_before = bytes.peel_address();
    let primary_genre_id_after = bytes.peel_address();
    let primary_changed = bytes.peel_bool();
    assert_eq!(clear_cause, expected_cause);
    assert_eq!(trigger_genre_id, expected_trigger);
    assert_eq!(genres_before, *expected_state);
    assert!(genres_after.is_empty());
    assert_eq!(genre_count_before, genres_before.length());
    assert_eq!(genre_count_after, 0);
    // A final remove emits the companion clear only after the dynamic field
    // has already been deleted. Its before snapshot is nevertheless the
    // canonical empty field state (true -> false), whereas an explicit clear
    // carries the populated field state that existed at call time.
    if (expected_cause == 1) {
        assert!(field_existed_before);
        assert!(genres_before.is_empty());
    } else {
        assert_eq!(field_existed_before, *expected_exists);
    };
    assert!(!field_exists_after);
    assert_eq!(had_primary_before, !genres_before.is_empty());
    assert!(!has_primary_after);
    assert_eq!(primary_genre_id_before, primary_id(&genres_before));
    assert_eq!(primary_genre_id_after, @0x0);
    assert_eq!(primary_changed, !genres_before.is_empty());
    assert!(bytes.into_remainder_bytes().is_empty());
    *expected_exists = false;
    *expected_state = vector[];
}

// === Views before assignment ===

#[test]
fun views_before_assignment_are_empty() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let (rel, cap) = mk_release(scenario.ctx());

    assert!(rg::genres(&rel).is_empty());
    assert_eq!(event::events_by_type<rg::ReleaseGenreAddedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rg::ReleaseGenreRemovedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rg::ReleaseGenresClearedEvent>().length(), 0);

    destroy(rel);
    destroy(cap);
    scenario.end();
}

// Every event is independently consumable as a complete state transition:
// the decoder below does not consult the package view while projecting it.
// This also exercises the distinction between an empty retained field and a
// field that has been reclaimed after the final remove.
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
    let cap_id = object::id(&cap).to_address();
    let mut replay_exists = false;
    let mut replay_state = vector[];

    rg::add_genre(&mut rel, &cap, &a);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 1);
    project_added_event(
        &added[0], release_id, cap_id, b"HIP_HOP", &mut replay_exists, &mut replay_state,
    );
    assert_replay_view(&rel, replay_exists, &replay_state);

    rg::add_genre(&mut rel, &cap, &b);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 2);
    project_added_event(
        &added[1], release_id, cap_id, b"ELECTRONIC", &mut replay_exists, &mut replay_state,
    );
    assert_replay_view(&rel, replay_exists, &replay_state);

    rg::remove_genre(&mut rel, &cap, a_id);
    let removed = event::events_by_type<rg::ReleaseGenreRemovedEvent>();
    assert_eq!(removed.length(), 1);
    project_removed_event(
        &removed[0],
        release_id,
        cap_id,
        a_id.to_address(),
        vector[b_id.to_address()],
        &mut replay_exists,
        &mut replay_state,
    );
    assert_replay_view(&rel, replay_exists, &replay_state);
    assert_eq!(event::events_by_type<rg::ReleaseGenresClearedEvent>().length(), 0);

    rg::clear_genres(&mut rel, &cap);
    let cleared = event::events_by_type<rg::ReleaseGenresClearedEvent>();
    assert_eq!(cleared.length(), 1);
    project_cleared_event(
        &cleared[0],
        release_id,
        cap_id,
        0,
        @0x0,
        &mut replay_exists,
        &mut replay_state,
    );
    assert_replay_view(&rel, replay_exists, &replay_state);

    rg::add_genre(&mut rel, &cap, &c);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 3);
    project_added_event(
        &added[2], release_id, cap_id, b"AMBIENT", &mut replay_exists, &mut replay_state,
    );
    assert_replay_view(&rel, replay_exists, &replay_state);

    rg::remove_genre(&mut rel, &cap, c_id);
    let removed = event::events_by_type<rg::ReleaseGenreRemovedEvent>();
    assert_eq!(removed.length(), 2);
    project_removed_event(
        &removed[1],
        release_id,
        cap_id,
        c_id.to_address(),
        vector[],
        &mut replay_exists,
        &mut replay_state,
    );
    assert_replay_view(&rel, replay_exists, &replay_state);
    let cleared = event::events_by_type<rg::ReleaseGenresClearedEvent>();
    assert_eq!(cleared.length(), 2);
    project_cleared_event(
        &cleared[1],
        release_id,
        cap_id,
        1,
        c_id.to_address(),
        &mut replay_exists,
        &mut replay_state,
    );
    assert_replay_view(&rel, replay_exists, &replay_state);

    ts::return_immutable(a);
    ts::return_immutable(b);
    ts::return_immutable(c);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun max_event_payloads_and_final_pair_are_bounded() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    // The sixth name is exactly 64 bytes, the vocabulary's accepted maximum.
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
    let cap_id = object::id(&cap).to_address();
    let mut replay_exists = false;
    let mut replay_state = vector[];

    rg::add_genre(&mut rel, &cap, &genres[0]);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    project_added_event(
        &added[0], release_id, cap_id, b"HIP_HOP", &mut replay_exists, &mut replay_state,
    );
    rg::add_genre(&mut rel, &cap, &genres[1]);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    project_added_event(
        &added[1], release_id, cap_id, b"ELECTRONIC", &mut replay_exists, &mut replay_state,
    );
    rg::add_genre(&mut rel, &cap, &genres[2]);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    project_added_event(
        &added[2], release_id, cap_id, b"AMBIENT", &mut replay_exists, &mut replay_state,
    );
    rg::add_genre(&mut rel, &cap, &genres[3]);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    project_added_event(
        &added[3], release_id, cap_id, b"JAZZ", &mut replay_exists, &mut replay_state,
    );
    rg::add_genre(&mut rel, &cap, &genres[4]);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    project_added_event(
        &added[4], release_id, cap_id, b"ROCK", &mut replay_exists, &mut replay_state,
    );
    rg::add_genre(&mut rel, &cap, &genres[5]);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 6);
    project_added_event(
        &added[5],
        release_id,
        cap_id,
        b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        &mut replay_exists,
        &mut replay_state,
    );
    let (_, _, _, long_name, _, _, _, _, _, _, _, _, _, _, _, _) =
        rg::genre_added_event_fields(&added[5]);
    assert_eq!(long_name.length(), 64);
    // 192 + name bytes + 32 * (five previous + six current addresses).
    assert_eq!(bcs::to_bytes(&added[5]).length(), 608);
    assert_replay_view(&rel, replay_exists, &replay_state);

    // Removing from the six-item list exercises the maximum Removed payload
    // (191 + 32 * (six previous + five current addresses)). Re-append it so
    // the explicit clear below also reaches the maximum Cleared payload.
    rg::remove_genre(&mut rel, &cap, first_id);
    let after_remove = vector[
        object::id(&genres[1]).to_address(),
        object::id(&genres[2]).to_address(),
        object::id(&genres[3]).to_address(),
        object::id(&genres[4]).to_address(),
        object::id(&genres[5]).to_address(),
    ];
    let removed = event::events_by_type<rg::ReleaseGenreRemovedEvent>();
    assert_eq!(removed.length(), 1);
    project_removed_event(
        &removed[0], release_id, cap_id, first_id.to_address(), after_remove,
        &mut replay_exists, &mut replay_state,
    );
    assert_eq!(bcs::to_bytes(&removed[0]).length(), 543);
    rg::add_genre(&mut rel, &cap, &genres[0]);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 7);
    project_added_event(
        &added[6], release_id, cap_id, b"HIP_HOP", &mut replay_exists, &mut replay_state,
    );
    assert_replay_view(&rel, replay_exists, &replay_state);

    rg::clear_genres(&mut rel, &cap);
    let cleared = event::events_by_type<rg::ReleaseGenresClearedEvent>();
    assert_eq!(cleared.length(), 1);
    project_cleared_event(
        &cleared[0], release_id, cap_id, 0, @0x0, &mut replay_exists, &mut replay_state,
    );
    // 184 + 32 * (six previous + zero current addresses).
    assert_eq!(bcs::to_bytes(&cleared[0]).length(), 376);
    assert_replay_view(&rel, replay_exists, &replay_state);

    genres.destroy!(|genre| ts::return_immutable(genre));
    destroy(rel);
    destroy(cap);
    scenario.next_tx(CREATOR);
    let genre = scenario.take_immutable_by_id<Genre>(first_id);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel).to_address();
    let cap_id = object::id(&cap).to_address();
    let mut replay_exists = false;
    let mut replay_state = vector[];
    rg::add_genre(&mut rel, &cap, &genre);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 1);
    project_added_event(
        &added[0], release_id, cap_id, b"HIP_HOP", &mut replay_exists, &mut replay_state,
    );
    rg::remove_genre(&mut rel, &cap, first_id);
    let removed = event::events_by_type<rg::ReleaseGenreRemovedEvent>();
    assert_eq!(removed.length(), 1);
    project_removed_event(
        &removed[0], release_id, cap_id, first_id.to_address(), vector[],
        &mut replay_exists, &mut replay_state,
    );
    assert_eq!(bcs::to_bytes(&removed[0]).length(), 223);
    let cleared = event::events_by_type<rg::ReleaseGenresClearedEvent>();
    assert_eq!(cleared.length(), 1);
    project_cleared_event(
        &cleared[0], release_id, cap_id, 1, first_id.to_address(),
        &mut replay_exists, &mut replay_state,
    );
    assert_eq!(bcs::to_bytes(&cleared[0]).length(), 184);
    assert_replay_view(&rel, replay_exists, &replay_state);

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
    rg::add_genre(&mut rel_a, &cap_a, &a);
    rg::add_genre(&mut rel_b, &cap_b, &b);
    let added = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    assert_eq!(added.length(), 2);
    let (first_release, _, first_genre, _, _, _, _, _, _, _, _, _, _, _, _, _) =
        rg::genre_added_event_fields(&added[0]);
    let (second_release, _, second_genre, _, _, _, _, _, _, _, _, _, _, _, _, _) =
        rg::genre_added_event_fields(&added[1]);
    assert_eq!(first_release, rel_a_id);
    assert_eq!(first_genre, a_id.to_address());
    assert_eq!(second_release, rel_b_id);
    assert_eq!(second_genre, b_id.to_address());

    rg::clear_genres(&mut rel_a, &cap_a);
    rg::clear_genres(&mut rel_b, &cap_b);
    let cleared = event::events_by_type<rg::ReleaseGenresClearedEvent>();
    assert_eq!(cleared.length(), 2);
    let (first_clear_release, _, _, _, _, _, _, _, _, _, _, _, _, _, _) =
        rg::genres_cleared_event_fields(&cleared[0]);
    let (second_clear_release, _, _, _, _, _, _, _, _, _, _, _, _, _, _) =
        rg::genres_cleared_event_fields(&cleared[1]);
    assert_eq!(first_clear_release, rel_a_id);
    assert_eq!(second_clear_release, rel_b_id);
    assert!(rg::genres(&rel_a).is_empty());
    assert!(rg::genres(&rel_b).is_empty());

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

    rg::add_genre(&mut rel, &cap, &genre);
    assert!(rg::genres(&rel) == vector[genre_id]);

    let events = event::events_by_type<rg::ReleaseGenreAddedEvent>();
    assert_eq!(events.length(), 1);
    let (event_release_id, _, event_genre_id, _, _, _, _, _, _, _, _, _, _, _, _, _) =
        rg::genre_added_event_fields(&events[0]);
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

    let removed_events = event::events_by_type<rg::ReleaseGenreRemovedEvent>();
    assert_eq!(removed_events.length(), 1);
    let (event_release_id, _, event_genre_id, _, _, _, _, _, _, _, _, _, _, _, _) =
        rg::genre_removed_event_fields(&removed_events[0]);
    assert_eq!(event_release_id, release_id.to_address());
    assert_eq!(event_genre_id, a_id.to_address());

    assert_eq!(event::events_by_type<rg::ReleaseGenresClearedEvent>().length(), 0);

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

    assert_eq!(event::events_by_type<rg::ReleaseGenreRemovedEvent>().length(), 1);
    let cleared_events = event::events_by_type<rg::ReleaseGenresClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    let (cleared_release_id, _, _, _, _, _, _, _, _, _, _, _, _, _, _) =
        rg::genres_cleared_event_fields(&cleared_events[0]);
    assert_eq!(cleared_release_id, release_id.to_address());

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

    let cleared_events = event::events_by_type<rg::ReleaseGenresClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    let (cleared_release_id, _, _, _, _, _, _, _, _, _, _, _, _, _, _) =
        rg::genres_cleared_event_fields(&cleared_events[0]);
    assert_eq!(cleared_release_id, release_id.to_address());

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
    assert_eq!(event::events_by_type<rg::ReleaseGenreAddedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rg::ReleaseGenreRemovedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rg::ReleaseGenresClearedEvent>().length(), 0);

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
