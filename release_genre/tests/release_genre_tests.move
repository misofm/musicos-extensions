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

// A 2-track release: flat tracklist indices 0, 1.
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

// === Album-level assignment ===

#[test]
fun views_before_assignment_are_empty() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let (rel, cap) = mk_release(scenario.ctx());

    // No genre assignment has been made yet: every view reports the empty
    // state, including the track view's early-return branch (it never
    // reaches the track-index bounds check when no assignment exists).
    assert!(!rg::has_genre(&rel));
    assert!(rg::primary_genre(&rel) == option::none());
    assert!(rg::secondary_genres(&rel).is_empty());
    assert!(rg::track_primary_genre(&rel, 0) == option::none());
    // Out-of-range index is fine too — the early return precedes the bounds
    // check when there is no assignment.
    assert!(rg::track_primary_genre(&rel, 99) == option::none());

    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun set_primary_genre_and_tracks_inherit() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let genre_id = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre = scenario.take_immutable_by_id<Genre>(genre_id);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel);

    assert!(!rg::has_genre(&rel));
    rg::set_primary_genre(&mut rel, &cap, &genre);
    assert!(rg::has_genre(&rel));
    assert!(rg::primary_genre(&rel) == option::some(genre_id));
    assert!(rg::secondary_genres(&rel).is_empty());
    // With no overrides, every track inherits the album primary.
    assert!(rg::track_primary_genre(&rel, 0) == option::some(genre_id));
    assert!(rg::track_primary_genre(&rel, 1) == option::some(genre_id));

    // `set_primary_genre` emits exactly one `PrimaryGenreSetEvent` with the
    // full payload pinned.
    let events = event::events_by_type<rg::PrimaryGenreSetEvent>();
    assert_eq!(events.length(), 1);
    let (event_release_id, event_genre_id) =
        rg::primary_genre_set_event_fields(&events[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_genre_id, genre_id);

    ts::return_immutable(genre);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun primary_can_be_replaced_immediately() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let g2 = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let genre2 = scenario.take_immutable_by_id<Genre>(g2);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    rg::set_primary_genre(&mut rel, &cap, &genre2);
    assert!(rg::primary_genre(&rel) == option::some(g2));

    ts::return_immutable(genre1);
    ts::return_immutable(genre2);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun add_and_remove_secondary_genres() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let g2 = create_genre(&scenario, b"ELECTRONIC");
    scenario.next_tx(CREATOR);
    let g3 = create_genre(&scenario, b"AMBIENT");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let genre2 = scenario.take_immutable_by_id<Genre>(g2);
    let genre3 = scenario.take_immutable_by_id<Genre>(g3);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel);

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    rg::add_secondary_genre(&mut rel, &cap, &genre2);
    rg::add_secondary_genre(&mut rel, &cap, &genre3);
    assert!(rg::secondary_genres(&rel) == vector[g2, g3]);

    // `add_secondary_genre` emits `SecondaryGenreAddedEvent` with the full
    // payload pinned (two calls above; check the second, for g3).
    let added_events = event::events_by_type<rg::SecondaryGenreAddedEvent>();
    assert_eq!(added_events.length(), 2);
    let (added_release_id, added_genre_id) =
        rg::secondary_genre_added_event_fields(&added_events[1]);
    assert_eq!(added_release_id, release_id);
    assert_eq!(added_genre_id, g3);

    rg::remove_secondary_genre(&mut rel, &cap, &genre2);
    assert!(rg::secondary_genres(&rel) == vector[g3]);

    // `remove_secondary_genre` emits `SecondaryGenreRemovedEvent` with the
    // full payload pinned.
    let removed_events = event::events_by_type<rg::SecondaryGenreRemovedEvent>();
    assert_eq!(removed_events.length(), 1);
    let (removed_release_id, removed_genre_id) =
        rg::secondary_genre_removed_event_fields(&removed_events[0]);
    assert_eq!(removed_release_id, release_id);
    assert_eq!(removed_genre_id, g2);

    ts::return_immutable(genre1);
    ts::return_immutable(genre2);
    ts::return_immutable(genre3);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 30, location = release_genre::release_genre)] // ENoPrimaryGenre
fun secondary_before_primary_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::add_secondary_genre(&mut rel, &cap, &genre1); // no primary yet

    ts::return_immutable(genre1);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 30, location = release_genre::release_genre)] // ENoPrimaryGenre
fun remove_secondary_before_primary_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::remove_secondary_genre(&mut rel, &cap, &genre1); // no primary yet

    ts::return_immutable(genre1);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 43, location = release_genre::release_genre)] // EGenreNotSecondary
fun remove_non_secondary_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let g2 = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let genre2 = scenario.take_immutable_by_id<Genre>(g2);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    rg::remove_secondary_genre(&mut rel, &cap, &genre2); // g2 was never added

    ts::return_immutable(genre1);
    ts::return_immutable(genre2);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 42, location = release_genre::release_genre)] // EMaxSecondaryGenres
fun max_secondary_genres_exceeded_aborts() {
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

    // genres[0] is the primary; genres[1..6] are exactly the max (5) secondaries.
    rg::set_primary_genre(&mut rel, &cap, &genres[0]);
    let mut i: u64 = 1;
    while (i <= 5u64) {
        rg::add_secondary_genre(&mut rel, &cap, &genres[i]);
        i = i + 1;
    };
    assert_eq!(rg::secondary_genres(&rel).length(), 5);
    // The 6th secondary (genres[6]) pushes past MAX_SECONDARY_GENRES.
    rg::add_secondary_genre(&mut rel, &cap, &genres[6]);

    genres.destroy!(|genre| ts::return_immutable(genre));
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 40, location = release_genre::release_genre)] // ESecondaryIsPrimary
fun secondary_equal_primary_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    rg::add_secondary_genre(&mut rel, &cap, &genre1); // same as primary

    ts::return_immutable(genre1);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = rg::EPrimaryIsSecondary)]
fun primary_equal_secondary_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let g2 = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let genre2 = scenario.take_immutable_by_id<Genre>(g2);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    rg::add_secondary_genre(&mut rel, &cap, &genre2);
    rg::set_primary_genre(&mut rel, &cap, &genre2);

    ts::return_immutable(genre1);
    ts::return_immutable(genre2);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
fun former_primary_becomes_secondary() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let g2 = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let genre2 = scenario.take_immutable_by_id<Genre>(g2);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    rg::set_primary_genre(&mut rel, &cap, &genre2);
    assert_eq!(rg::primary_genre(&rel), option::some(g2));
    assert!(rg::secondary_genres(&rel).is_empty());
    // The former primary is no longer the primary, so it can be a secondary.
    rg::add_secondary_genre(&mut rel, &cap, &genre1);
    assert_eq!(rg::secondary_genres(&rel), vector[g1]);

    ts::return_immutable(genre1);
    ts::return_immutable(genre2);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 41, location = release_genre::release_genre)] // EGenreAlreadySecondary
fun duplicate_secondary_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let g2 = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let genre2 = scenario.take_immutable_by_id<Genre>(g2);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    rg::add_secondary_genre(&mut rel, &cap, &genre2);
    rg::add_secondary_genre(&mut rel, &cap, &genre2); // duplicate

    ts::return_immutable(genre1);
    ts::return_immutable(genre2);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

// === Per-track overrides ===

#[test]
fun track_override_resolves_over_album() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let g2 = create_genre(&scenario, b"ELECTRONIC");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let genre2 = scenario.take_immutable_by_id<Genre>(g2);
    let (mut rel, cap) = mk_release(scenario.ctx());
    let release_id = object::id(&rel);

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    // Override track 1 to g2; track 0 still inherits the album primary g1.
    rg::set_track_primary_genre(&mut rel, &cap, 1, &genre2);
    assert!(rg::track_primary_genre(&rel, 0) == option::some(g1));
    assert!(rg::track_primary_genre(&rel, 1) == option::some(g2));

    // `set_track_primary_genre` emits `TrackPrimaryGenreSetEvent` with the
    // full payload pinned.
    let set_events = event::events_by_type<rg::TrackPrimaryGenreSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (set_release_id, set_track_index, set_genre_id) =
        rg::track_primary_genre_set_event_fields(&set_events[0]);
    assert_eq!(set_release_id, release_id);
    assert_eq!(set_track_index, 1);
    assert_eq!(set_genre_id, g2);

    // Clear the override; track 1 falls back to the album primary.
    rg::unset_track_primary_genre(&mut rel, &cap, 1);
    assert!(rg::track_primary_genre(&rel, 1) == option::some(g1));

    // `unset_track_primary_genre` emits `TrackPrimaryGenreUnsetEvent` with the
    // full payload pinned.
    let unset_events = event::events_by_type<rg::TrackPrimaryGenreUnsetEvent>();
    assert_eq!(unset_events.length(), 1);
    let (unset_release_id, unset_track_index) =
        rg::track_primary_genre_unset_event_fields(&unset_events[0]);
    assert_eq!(unset_release_id, release_id);
    assert_eq!(unset_track_index, 1);

    ts::return_immutable(genre1);
    ts::return_immutable(genre2);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 30, location = release_genre::release_genre)] // ENoPrimaryGenre
fun track_override_before_primary_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::set_track_primary_genre(&mut rel, &cap, 0, &genre1); // no album primary yet

    ts::return_immutable(genre1);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 50, location = release_genre::release_genre)] // ETrackIndexOutOfBounds
fun track_override_out_of_bounds_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    rg::set_track_primary_genre(&mut rel, &cap, 2, &genre1); // 2 tracks -> index 2 invalid

    ts::return_immutable(genre1);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 30, location = release_genre::release_genre)] // ENoPrimaryGenre
fun unset_track_override_before_primary_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::unset_track_primary_genre(&mut rel, &cap, 0); // no album primary yet

    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 50, location = release_genre::release_genre)] // ETrackIndexOutOfBounds
fun unset_track_override_out_of_bounds_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rg::set_primary_genre(&mut rel, &cap, &genre1);
    rg::unset_track_primary_genre(&mut rel, &cap, 2); // 2 tracks -> index 2 invalid

    ts::return_immutable(genre1);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 50, location = release_genre::release_genre)] // ETrackIndexOutOfBounds
fun track_primary_genre_view_out_of_bounds_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let g1 = create_genre(&scenario, b"HIP_HOP");

    scenario.next_tx(CREATOR);
    let genre1 = scenario.take_immutable_by_id<Genre>(g1);
    let (mut rel, cap) = mk_release(scenario.ctx());

    // Once an assignment exists, the view's own bounds check applies.
    rg::set_primary_genre(&mut rel, &cap, &genre1);
    let _ = rg::track_primary_genre(&rel, 2); // 2 tracks -> index 2 invalid

    ts::return_immutable(genre1);
    destroy(rel);
    destroy(cap);
    scenario.end();
}
