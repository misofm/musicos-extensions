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
/// A mismatched `RecordingShare` type cannot compile. A distinct
/// `RecordingAdminCap<RecordingShare>` value is accepted because
/// `recording::uid_mut` ignores the cap value; the foreign same-type-cap path
/// is exercised explicitly below.
#[test_only]
module recording_genre::recording_genre_tests;

use genre::genre as g;
use genre::genre::{GenreRegistry, Genre};
use musicos::recording;
use recording_genre::recording_genre as rg;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

public struct REC {}
public struct COMP {}
public struct OTHER_REC {}
public struct OTHER_COMP {}
public struct UnrelatedKey() has copy, drop, store;

public struct ReplayState has drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    genres: vector<address>,
    field_exists: bool,
    has_primary: bool,
    primary_genre_id: address,
}

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

fun addr(id: ID): address {
    id.to_address()
}

fun genre_addresses(recording: &recording::Recording<REC, COMP>): vector<address> {
    let ids = rg::genres(recording);
    let mut addresses = vector[];
    let mut index = 0;
    while (index < ids.length()) {
        addresses.push_back(ids[index].to_address());
        index = index + 1;
    };
    addresses
}

fun assert_added_payload(
    event: &rg::RecordingGenreAddedEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    genre_id: address,
    genre_name: vector<u8>,
    genre_index: u64,
    genres_before: vector<address>,
    genres_after: vector<address>,
    genre_count_before: u64,
    genre_count_after: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    had_primary_before: bool,
    has_primary_after: bool,
    primary_genre_id_before: address,
    primary_genre_id_after: address,
    primary_changed: bool,
) {
    let mut bytes = bcs::new(rg::added_event_bcs(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_address(), genre_id);
    assert_eq!(bytes.peel_vec_u8(), genre_name);
    assert_eq!(bytes.peel_u64(), genre_index);
    assert_eq!(bytes.peel_vec_address(), genres_before);
    assert_eq!(bytes.peel_vec_address(), genres_after);
    assert_eq!(bytes.peel_u64(), genre_count_before);
    assert_eq!(bytes.peel_u64(), genre_count_after);
    assert_eq!(bytes.peel_bool(), field_existed_before);
    assert_eq!(bytes.peel_bool(), field_exists_after);
    assert_eq!(bytes.peel_bool(), had_primary_before);
    assert_eq!(bytes.peel_bool(), has_primary_after);
    assert_eq!(bytes.peel_address(), primary_genre_id_before);
    assert_eq!(bytes.peel_address(), primary_genre_id_after);
    assert_eq!(bytes.peel_bool(), primary_changed);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_removed_payload(
    event: &rg::RecordingGenreRemovedEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    genre_id: address,
    genre_index: u64,
    genres_before: vector<address>,
    genres_after: vector<address>,
    genre_count_before: u64,
    genre_count_after: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    had_primary_before: bool,
    has_primary_after: bool,
    primary_genre_id_before: address,
    primary_genre_id_after: address,
    primary_changed: bool,
) {
    let mut bytes = bcs::new(rg::removed_event_bcs(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_address(), genre_id);
    assert_eq!(bytes.peel_u64(), genre_index);
    assert_eq!(bytes.peel_vec_address(), genres_before);
    assert_eq!(bytes.peel_vec_address(), genres_after);
    assert_eq!(bytes.peel_u64(), genre_count_before);
    assert_eq!(bytes.peel_u64(), genre_count_after);
    assert_eq!(bytes.peel_bool(), field_existed_before);
    assert_eq!(bytes.peel_bool(), field_exists_after);
    assert_eq!(bytes.peel_bool(), had_primary_before);
    assert_eq!(bytes.peel_bool(), has_primary_after);
    assert_eq!(bytes.peel_address(), primary_genre_id_before);
    assert_eq!(bytes.peel_address(), primary_genre_id_after);
    assert_eq!(bytes.peel_bool(), primary_changed);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_cleared_payload(
    event: &rg::RecordingGenresClearedEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    clear_cause: u8,
    trigger_genre_id: address,
    genres_before: vector<address>,
    genres_after: vector<address>,
    genre_count_before: u64,
    genre_count_after: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    had_primary_before: bool,
    has_primary_after: bool,
    primary_genre_id_before: address,
    primary_genre_id_after: address,
    primary_changed: bool,
) {
    let mut bytes = bcs::new(rg::cleared_event_bcs(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_u8(), clear_cause);
    assert_eq!(bytes.peel_address(), trigger_genre_id);
    assert_eq!(bytes.peel_vec_address(), genres_before);
    assert_eq!(bytes.peel_vec_address(), genres_after);
    assert_eq!(bytes.peel_u64(), genre_count_before);
    assert_eq!(bytes.peel_u64(), genre_count_after);
    assert_eq!(bytes.peel_bool(), field_existed_before);
    assert_eq!(bytes.peel_bool(), field_exists_after);
    assert_eq!(bytes.peel_bool(), had_primary_before);
    assert_eq!(bytes.peel_bool(), has_primary_after);
    assert_eq!(bytes.peel_address(), primary_genre_id_before);
    assert_eq!(bytes.peel_address(), primary_genre_id_after);
    assert_eq!(bytes.peel_bool(), primary_changed);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_projected(
    recording: &recording::Recording<REC, COMP>,
    projected: &ReplayState,
) {
    assert_eq!(genre_addresses(recording), projected.genres);
    assert_eq!(projected.has_primary, !projected.genres.is_empty());
    if (projected.has_primary) {
        assert_eq!(projected.primary_genre_id, projected.genres[0]);
    } else {
        assert_eq!(projected.primary_genre_id, @0x0);
    };
}

fun replay_added(
    projected: &mut ReplayState,
    event: &rg::RecordingGenreAddedEvent<REC, COMP>,
) {
    let mut bytes = bcs::new(rg::added_event_bcs(event));
    let recording_id = bytes.peel_address();
    let composition_id = bytes.peel_address();
    let admin_cap_id = bytes.peel_address();
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
    assert_eq!(recording_id, projected.recording_id);
    assert_eq!(composition_id, projected.composition_id);
    assert_eq!(admin_cap_id, projected.admin_cap_id);
    assert!(!genre_name.is_empty());
    assert_eq!(genres_before, projected.genres);
    assert_eq!(genre_count_before, genres_before.length());
    assert_eq!(genre_count_after, genres_after.length());
    assert_eq!(genre_index, genre_count_before);
    assert!(genre_index < genres_after.length());
    assert_eq!(genres_after[genre_index], genre_id);
    assert!(!genres_before.contains(&genre_id));
    assert_eq!(field_existed_before, projected.field_exists);
    assert!(field_exists_after);
    assert_eq!(had_primary_before, projected.has_primary);
    assert!(has_primary_after);
    assert_eq!(primary_genre_id_before, projected.primary_genre_id);
    assert_eq!(primary_genre_id_after, genres_after[0]);
    assert_eq!(primary_changed,
        had_primary_before != has_primary_after
            || primary_genre_id_before != primary_genre_id_after);
    assert!(bytes.into_remainder_bytes().is_empty());
    projected.genres = genres_after;
    projected.field_exists = field_exists_after;
    projected.has_primary = has_primary_after;
    projected.primary_genre_id = primary_genre_id_after;
}

fun replay_removed(
    projected: &mut ReplayState,
    event: &rg::RecordingGenreRemovedEvent<REC, COMP>,
) {
    let mut bytes = bcs::new(rg::removed_event_bcs(event));
    let recording_id = bytes.peel_address();
    let composition_id = bytes.peel_address();
    let admin_cap_id = bytes.peel_address();
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
    assert_eq!(recording_id, projected.recording_id);
    assert_eq!(composition_id, projected.composition_id);
    assert_eq!(admin_cap_id, projected.admin_cap_id);
    assert_eq!(genres_before, projected.genres);
    assert_eq!(genre_count_before, genres_before.length());
    assert_eq!(genre_count_after, genres_after.length());
    assert!(genre_index < genres_before.length());
    assert_eq!(genres_before[genre_index], genre_id);
    assert!(!genres_after.contains(&genre_id));
    assert_eq!(genres_after.length() + 1, genres_before.length());
    assert_eq!(field_existed_before, projected.field_exists);
    assert!(field_exists_after);
    assert_eq!(had_primary_before, projected.has_primary);
    assert_eq!(has_primary_after, !genres_after.is_empty());
    assert_eq!(primary_genre_id_before, projected.primary_genre_id);
    if (has_primary_after) {
        assert_eq!(primary_genre_id_after, genres_after[0]);
    } else {
        assert_eq!(primary_genre_id_after, @0x0);
    };
    assert_eq!(primary_changed,
        had_primary_before != has_primary_after
            || primary_genre_id_before != primary_genre_id_after);
    assert!(bytes.into_remainder_bytes().is_empty());
    projected.genres = genres_after;
    projected.field_exists = field_exists_after;
    projected.has_primary = has_primary_after;
    projected.primary_genre_id = primary_genre_id_after;
}

fun replay_cleared(
    projected: &mut ReplayState,
    event: &rg::RecordingGenresClearedEvent<REC, COMP>,
    expected_cause: u8,
    expected_trigger: address,
) {
    let mut bytes = bcs::new(rg::cleared_event_bcs(event));
    let recording_id = bytes.peel_address();
    let composition_id = bytes.peel_address();
    let admin_cap_id = bytes.peel_address();
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
    assert_eq!(recording_id, projected.recording_id);
    assert_eq!(composition_id, projected.composition_id);
    assert_eq!(admin_cap_id, projected.admin_cap_id);
    assert_eq!(clear_cause, expected_cause);
    assert_eq!(trigger_genre_id, expected_trigger);
    assert_eq!(genres_before, projected.genres);
    assert!(genres_after.is_empty());
    assert_eq!(genre_count_before, genres_before.length());
    assert_eq!(genre_count_after, 0);
    assert_eq!(field_existed_before, projected.field_exists);
    assert!(!field_exists_after);
    assert_eq!(had_primary_before, projected.has_primary);
    assert!(!has_primary_after);
    assert_eq!(primary_genre_id_before, projected.primary_genre_id);
    assert_eq!(primary_genre_id_after, @0x0);
    assert_eq!(primary_changed,
        had_primary_before != has_primary_after
            || primary_genre_id_before != primary_genre_id_after);
    if (clear_cause == 1) {
        assert!(genres_before.is_empty());
        assert_eq!(trigger_genre_id, expected_trigger);
    } else {
        assert_eq!(clear_cause, 0);
        assert_eq!(trigger_genre_id, @0x0);
    };
    assert!(bytes.into_remainder_bytes().is_empty());
    projected.genres = genres_after;
    projected.field_exists = field_exists_after;
    projected.has_primary = has_primary_after;
    projected.primary_genre_id = primary_genre_id_after;
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
fun rich_events_replay_order_primary_and_cascades() {
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
    let composition_id = @0xC0FFEE;
    let admin_cap_id = object::id(&cap).to_address();
    let mut projected = ReplayState {
        recording_id,
        composition_id,
        admin_cap_id,
        genres: vector[],
        field_exists: false,
        has_primary: false,
        primary_genre_id: @0x0,
    };

    rg::add_genre(&mut rec, &cap, &genre_a);
    let added = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>();
    assert_eq!(added.length(), 1);
    assert_added_payload(
        &added[0], recording_id, composition_id, admin_cap_id, addr(a), b"HIP_HOP", 0,
        vector[], vector[addr(a)], 0, 1, false, true, false, true, @0x0, addr(a), true,
    );
    assert_eq!(rg::added_event_bcs(&added[0]).length(), 263);
    replay_added(&mut projected, &added[0]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(a)]);

    rg::add_genre(&mut rec, &cap, &genre_b);
    let added = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>();
    assert_eq!(added.length(), 2);
    assert_added_payload(
        &added[1], recording_id, composition_id, admin_cap_id, addr(b), b"ELECTRONIC", 1,
        vector[addr(a)], vector[addr(a), addr(b)], 1, 2, true, true, true, true,
        addr(a), addr(a), false,
    );
    assert_eq!(rg::added_event_bcs(&added[1]).length(), 330);
    replay_added(&mut projected, &added[1]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(a), addr(b)]);

    rg::add_genre(&mut rec, &cap, &genre_c);
    let added = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>();
    assert_eq!(added.length(), 3);
    assert_added_payload(
        &added[2], recording_id, composition_id, admin_cap_id, addr(c), b"AMBIENT", 2,
        vector[addr(a), addr(b)], vector[addr(a), addr(b), addr(c)], 2, 3, true, true,
        true, true, addr(a), addr(a), false,
    );
    replay_added(&mut projected, &added[2]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(a), addr(b), addr(c)]);

    // Secondary removal preserves the primary and order of survivors.
    rg::remove_genre(&mut rec, &cap, b);
    let removed = event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>();
    assert_eq!(removed.length(), 1);
    assert_removed_payload(
        &removed[0], recording_id, composition_id, admin_cap_id, addr(b), 1,
        vector[addr(a), addr(b), addr(c)], vector[addr(a), addr(c)], 3, 2, true, true,
        true, true, addr(a), addr(a), false,
    );
    assert_eq!(rg::removed_event_bcs(&removed[0]).length(), 383);
    replay_removed(&mut projected, &removed[0]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(a), addr(c)]);

    // Primary removal promotes the next entry.
    rg::remove_genre(&mut rec, &cap, a);
    let removed = event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>();
    assert_eq!(removed.length(), 2);
    assert_removed_payload(
        &removed[1], recording_id, composition_id, admin_cap_id, addr(a), 0,
        vector[addr(a), addr(c)], vector[addr(c)], 2, 1, true, true, true, true,
        addr(a), addr(c), true,
    );
    replay_removed(&mut projected, &removed[1]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(c)]);

    // Last removal emits Removed before field deletion, then a cause-1 clear.
    rg::remove_genre(&mut rec, &cap, c);
    let removed = event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>();
    assert_eq!(removed.length(), 3);
    assert_removed_payload(
        &removed[2], recording_id, composition_id, admin_cap_id, addr(c), 0,
        vector[addr(c)], vector[], 1, 0, true, true, true, false, addr(c), @0x0, true,
    );
    assert_eq!(rg::removed_event_bcs(&removed[2]).length(), 255);
    replay_removed(&mut projected, &removed[2]);
    assert!(!projected.has_primary);
    assert!(projected.field_exists);
    let cleared = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 1);
    assert_cleared_payload(
        &cleared[0], recording_id, composition_id, admin_cap_id, 1, addr(c), vector[],
        vector[], 0, 0, true, false, false, false, @0x0, @0x0, false,
    );
    assert_eq!(rg::cleared_event_bcs(&cleared[0]).length(), 216);
    replay_cleared(&mut projected, &cleared[0], 1, addr(c));
    assert!(rg::genres(&rec).is_empty());
    assert_projected(&rec, &projected);
    assert!(projected.genres.is_empty());
    assert!(!projected.field_exists);

    // Absent clear is silent. Re-attachment starts a fresh ordered list.
    let added_before_absent_clear =
        event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>().length();
    let removed_before_absent_clear =
        event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>().length();
    let cleared_before_absent_clear =
        event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length();
    rg::clear_genres(&mut rec, &cap);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>().length(), added_before_absent_clear);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>().length(), removed_before_absent_clear);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length(), cleared_before_absent_clear);
    rg::add_genre(&mut rec, &cap, &genre_c);
    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::add_genre(&mut rec, &cap, &genre_b);
    let added = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>();
    assert_eq!(added.length(), 6);
    replay_added(&mut projected, &added[3]);
    replay_added(&mut projected, &added[4]);
    replay_added(&mut projected, &added[5]);
    assert_projected(&rec, &projected);
    assert_eq!(projected.genres, vector[addr(c), addr(a), addr(b)]);

    // Explicit clear carries the complete pre-clear list and cause 0.
    rg::clear_genres(&mut rec, &cap);
    let cleared = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 2);
    assert_cleared_payload(
        &cleared[1], recording_id, composition_id, admin_cap_id, 0, @0x0,
        vector[addr(c), addr(a), addr(b)], vector[], 3, 0, true, false, true, false,
        addr(c), @0x0, true,
    );
    assert_eq!(rg::cleared_event_bcs(&cleared[1]).length(), 312);
    replay_cleared(&mut projected, &cleared[1], 0, @0x0);
    assert!(rg::genres(&rec).is_empty());
    assert_projected(&rec, &projected);
    assert!(projected.genres.is_empty());

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
    let target_composition_id = @0xC0FFEE;
    let (foreign_recording, foreign_cap) =
        recording::new_for_testing<REC, COMP>(object::id_from_address(@0xF00D), scenario.ctx());
    let foreign_cap_id = object::id(&foreign_cap).to_address();
    destroy(foreign_recording);

    // The distinct same-type cap is accepted; every primitive identity in
    // the events must still identify the target recording and supplied cap.
    rg::add_genre(&mut recording, &foreign_cap, &genre_a);
    let added = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>();
    assert_eq!(added.length(), 1);
    assert_added_payload(
        &added[0], target_recording_id, target_composition_id, foreign_cap_id,
        addr(a), b"HIP_HOP", 0, vector[], vector[addr(a)], 0, 1,
        false, true, false, true, @0x0, addr(a), true,
    );

    // Last removal emits Removed with an empty-but-present intermediate
    // state, followed by the cause-1 deletion event.
    rg::remove_genre(&mut recording, &foreign_cap, a);
    let removed = event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>();
    assert_eq!(removed.length(), 1);
    assert_removed_payload(
        &removed[0], target_recording_id, target_composition_id, foreign_cap_id,
        addr(a), 0, vector[addr(a)], vector[], 1, 0, true, true,
        true, false, addr(a), @0x0, true,
    );
    let cleared = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 1);
    assert_cleared_payload(
        &cleared[0], target_recording_id, target_composition_id, foreign_cap_id,
        1, addr(a), vector[], vector[], 0, 0, true, false,
        false, false, @0x0, @0x0, false,
    );

    rg::add_genre(&mut recording, &foreign_cap, &genre_b);
    rg::clear_genres(&mut recording, &foreign_cap);
    let cleared = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 2);
    assert_cleared_payload(
        &cleared[1], target_recording_id, target_composition_id, foreign_cap_id,
        0, @0x0, vector[addr(b)], vector[], 1, 0, true, false,
        true, false, addr(b), @0x0, true,
    );

    // Authorized absent clear is silent for every family, including after
    // the cascading and explicit deletion paths above.
    let added_before = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>().length();
    let removed_before = event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>().length();
    let cleared_before = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length();
    rg::clear_genres(&mut recording, &foreign_cap);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>().length(), added_before);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>().length(), removed_before);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length(), cleared_before);

    ts::return_immutable(genre_a);
    ts::return_immutable(genre_b);
    destroy(recording);
    destroy(target_cap);
    destroy(foreign_cap);
    scenario.end();
}

#[test]
fun event_bounds_cover_64_byte_names_and_six_genres() {
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
    let admin_cap_id = object::id(&cap).to_address();

    rg::add_genre(&mut rec, &cap, &genre_a);
    rg::add_genre(&mut rec, &cap, &genre_b);
    rg::add_genre(&mut rec, &cap, &genre_c);
    rg::add_genre(&mut rec, &cap, &genre_d);
    rg::add_genre(&mut rec, &cap, &genre_e);
    rg::add_genre(&mut rec, &cap, &genre_long);
    assert_eq!(rg::genres(&rec).length(), 6);

    let added = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>();
    assert_eq!(added.length(), 6);
    assert_added_payload(
        &added[5], recording_id, @0xC0FFEE, admin_cap_id, addr(long),
        b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 5,
        vector[addr(a), addr(b), addr(c), addr(d), addr(e)],
        vector[addr(a), addr(b), addr(c), addr(d), addr(e), addr(long)],
        5, 6, true, true, true, true, addr(a), addr(a), false,
    );
    assert_eq!(rg::added_event_bcs(&added[5]).length(), 640);

    // Removing one entry from a six-item list exercises the maximum Removed
    // payload while preserving primary and survivor order.
    rg::remove_genre(&mut rec, &cap, e);
    let removed = event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>();
    assert_eq!(removed.length(), 1);
    assert_removed_payload(
        &removed[0], recording_id, @0xC0FFEE, admin_cap_id, addr(e), 4,
        vector[addr(a), addr(b), addr(c), addr(d), addr(e), addr(long)],
        vector[addr(a), addr(b), addr(c), addr(d), addr(long)], 6, 5,
        true, true, true, true, addr(a), addr(a), false,
    );
    assert_eq!(rg::removed_event_bcs(&removed[0]).length(), 575);

    // Re-adding restores six entries, then explicit clear exercises the
    // maximum Cleared snapshot.
    rg::add_genre(&mut rec, &cap, &genre_e);
    assert_eq!(rg::genres(&rec), vector[a, b, c, d, long, e]);
    rg::clear_genres(&mut rec, &cap);
    let cleared = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 1);
    assert_cleared_payload(
        &cleared[0], recording_id, @0xC0FFEE, admin_cap_id, 0, @0x0,
        vector[addr(a), addr(b), addr(c), addr(d), addr(long), addr(e)], vector[],
        6, 0, true, false, true, false, addr(a), @0x0, true,
    );
    assert_eq!(rg::cleared_event_bcs(&cleared[0]).length(), 408);
    assert!(rg::genres(&rec).is_empty());

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
    let rec_id = object::id(&rec);

    rg::add_genre(&mut rec, &cap, &genre1);
    assert!(!rg::genres(&rec).is_empty());
    assert_eq!(rg::genres(&rec), vector[g1]);

    let events = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>();
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

#[test, expected_failure(abort_code = rg::EDuplicateGenre)]
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
    let mut i = 0;
    while (i < 6) {
        rg::add_genre(&mut rec, &cap, &genres[i]);
        i = i + 1;
    };
    assert_eq!(rg::genres(&rec).length(), 6);
    // Duplicate validation precedes the capacity guard, so this is 40, not 41.
    rg::add_genre(&mut rec, &cap, &genres[0]);

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

    let removed_events = event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>();
    assert_eq!(removed_events.length(), 1);
    let (event_rec_id, event_genre_id) = rg::genre_removed_event_fields(&removed_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_genre_id, a);

    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length(), 0);

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

    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>().length(), 1);
    let cleared_events = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>();
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

    let cleared_events = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>();
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

    // Empty views and an authorized absent clear are silent for every event
    // family, not only the family named by the operation.
    let added_before = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>().length();
    let removed_before = event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>().length();
    let cleared_before = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length();
    assert!(rg::genres(&rec).is_empty());
    rg::clear_genres(&mut rec, &cap);

    assert!(rg::genres(&rec).is_empty());
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>().length(), added_before);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>().length(), removed_before);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length(), cleared_before);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length(), 0);

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

#[test]
fun phantom_event_types_have_positive_and_negative_queries() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let (mut rec_a, cap_a) = new_rec(scenario.ctx());
    let (mut rec_b, cap_b) = recording::new_for_testing<OTHER_REC, COMP>(
        object::id_from_address(@0xB0),
        scenario.ctx(),
    );
    let (mut rec_c, cap_c) = recording::new_for_testing<REC, OTHER_COMP>(
        object::id_from_address(@0xC0),
        scenario.ctx(),
    );

    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<OTHER_REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<REC, OTHER_COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<OTHER_REC, OTHER_COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<OTHER_REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, OTHER_COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<OTHER_REC, OTHER_COMP>>().length(), 0);

    rg::add_genre(&mut rec_a, &cap_a, &genre_a);
    // A real <REC, COMP> event must not appear in either alternate phantom
    // family before those recordings emit their own events.
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<OTHER_REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<REC, OTHER_COMP>>().length(), 0);
    rg::add_genre(&mut rec_b, &cap_b, &genre_a);
    rg::add_genre(&mut rec_c, &cap_c, &genre_a);
    assert_eq!(rg::genres(&rec_a), vector[a]);
    assert_eq!(rg::genres(&rec_b), vector[a]);
    assert_eq!(rg::genres(&rec_c), vector[a]);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<OTHER_REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<REC, OTHER_COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenreAddedEvent<OTHER_REC, OTHER_COMP>>().length(), 0);

    rg::remove_genre(&mut rec_a, &cap_a, a);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<OTHER_REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<REC, OTHER_COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<OTHER_REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, OTHER_COMP>>().length(), 0);
    rg::remove_genre(&mut rec_b, &cap_b, a);
    rg::remove_genre(&mut rec_c, &cap_c, a);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<OTHER_REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<REC, OTHER_COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenreRemovedEvent<OTHER_REC, OTHER_COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<OTHER_REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<REC, OTHER_COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rg::RecordingGenresClearedEvent<OTHER_REC, OTHER_COMP>>().length(), 0);
    assert!(rg::genres(&rec_a).is_empty());
    assert!(rg::genres(&rec_b).is_empty());
    assert!(rg::genres(&rec_c).is_empty());

    ts::return_immutable(genre_a);
    destroy(rec_a);
    destroy(cap_a);
    destroy(rec_b);
    destroy(cap_b);
    destroy(rec_c);
    destroy(cap_c);
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
    rg::add_genre(&mut rec, &cap, &genre_a);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    rg::remove_genre(&mut rec, &cap, a);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    rg::clear_genres(&mut rec, &cap);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    let _: u64 = df::remove(rec.uid_mut(&cap), UnrelatedKey());

    ts::return_immutable(genre_a);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

#[test]
fun existing_empty_field_records_primary_presence_transition() {
    let mut scenario = ts::begin(@0xC0);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xC0);
    let a = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(@0xC0);
    let genre_a = scenario.take_immutable_by_id<Genre>(a);
    let (mut rec, cap) = new_rec(scenario.ctx());
    let recording_id = object::id(&rec).to_address();
    let admin_cap_id = object::id(&cap).to_address();

    // The public key can be forged by a test to exercise the event's
    // presence-change branch; normal APIs reclaim the field before it can be
    // empty. An explicit clear of that empty field keeps primary_changed false.
    rg::add_empty_field_for_testing(&mut rec, &cap);
    rg::clear_genres(&mut rec, &cap);
    let cleared = event::events_by_type<rg::RecordingGenresClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 1);
    assert_cleared_payload(
        &cleared[0], recording_id, @0xC0FFEE, admin_cap_id, 0, @0x0,
        vector[], vector[], 0, 0, true, false, false, false, @0x0, @0x0, false,
    );

    rg::add_empty_field_for_testing(&mut rec, &cap);
    rg::add_genre(&mut rec, &cap, &genre_a);
    let events = event::events_by_type<rg::RecordingGenreAddedEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    assert_added_payload(
        &events[0], recording_id, @0xC0FFEE, admin_cap_id, addr(a), b"HIP_HOP", 0,
        vector[], vector[addr(a)], 0, 1, true, true, false, true, @0x0, addr(a), true,
    );
    assert_eq!(rg::genres(&rec), vector[a]);

    ts::return_immutable(genre_a);
    destroy(rec);
    destroy(cap);
    scenario.end();
}
