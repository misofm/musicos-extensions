// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_credits::credits_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers::{Self, RecordingShare, CompositionShare};
use credit::credit;
use partyos::party::{Self, Party, PartyAdminCap};
use recording_credits::recording_credits as credits;
use recording_credits::recording_party_role as rpr;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;
use sui::test_scenario;

const ARTIST: address = @0xA1;

fun mk_recording(
    ctx: &mut TxContext,
): (Recording<RecordingShare, CompositionShare>, RecordingAdminCap<RecordingShare>) {
    recording::new_for_testing(test_helpers::fake_id(ctx), ctx)
}

fun mk_party(name: vector<u8>, ctx: &mut TxContext): (Party, PartyAdminCap) {
    let clock = sui::clock::create_for_testing(ctx);
    let (party, cap) = party::new(party::new_individual_kind(), name.to_string(), &clock, ctx);
    clock.destroy_for_testing();
    (party, cap)
}

fun expected_credit_added(
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    role_kinds: vector<u8>,
    role_names: vector<vector<u8>>,
    role_instruments: vector<vector<u8>>,
    role_levels: vector<u8>,
    credit_index: u64,
    credit_count_before: u64,
    credit_count_after: u64,
    credits_initialized: bool,
): vector<u8> {
    let mut bytes = vector[];
    bytes.append(bcs::to_bytes(&recording_id));
    bytes.append(bcs::to_bytes(&composition_id));
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&party_id));
    bytes.append(bcs::to_bytes(&display_name));
    bytes.append(bcs::to_bytes(&role_kinds));
    bytes.append(bcs::to_bytes(&role_names));
    bytes.append(bcs::to_bytes(&role_instruments));
    bytes.append(bcs::to_bytes(&role_levels));
    bytes.append(bcs::to_bytes(&credit_index));
    bytes.append(bcs::to_bytes(&credit_count_before));
    bytes.append(bcs::to_bytes(&credit_count_after));
    bytes.append(bcs::to_bytes(&credits_initialized));
    bytes
}

fun expected_credit_removed(
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    role_kinds: vector<u8>,
    role_names: vector<vector<u8>>,
    role_instruments: vector<vector<u8>>,
    role_levels: vector<u8>,
    credit_index: u64,
    credit_count_before: u64,
    credit_count_after: u64,
    was_primary_artist: bool,
    was_featured_artist: bool,
): vector<u8> {
    let mut bytes = vector[];
    bytes.append(bcs::to_bytes(&recording_id));
    bytes.append(bcs::to_bytes(&composition_id));
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&party_id));
    bytes.append(bcs::to_bytes(&display_name));
    bytes.append(bcs::to_bytes(&role_kinds));
    bytes.append(bcs::to_bytes(&role_names));
    bytes.append(bcs::to_bytes(&role_instruments));
    bytes.append(bcs::to_bytes(&role_levels));
    bytes.append(bcs::to_bytes(&credit_index));
    bytes.append(bcs::to_bytes(&credit_count_before));
    bytes.append(bcs::to_bytes(&credit_count_after));
    bytes.append(bcs::to_bytes(&was_primary_artist));
    bytes.append(bcs::to_bytes(&was_featured_artist));
    bytes
}

fun expected_artist_added(
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    artist_index: u64,
    artist_count_before: u64,
    artist_count_after: u64,
    credit_count_after: u64,
): vector<u8> {
    let mut bytes = vector[];
    bytes.append(bcs::to_bytes(&recording_id));
    bytes.append(bcs::to_bytes(&composition_id));
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&party_id));
    bytes.append(bcs::to_bytes(&display_name));
    bytes.append(bcs::to_bytes(&artist_index));
    bytes.append(bcs::to_bytes(&artist_count_before));
    bytes.append(bcs::to_bytes(&artist_count_after));
    bytes.append(bcs::to_bytes(&credit_count_after));
    bytes
}

fun expected_artist_removed(
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    artist_index: u64,
    artist_count_before: u64,
    artist_count_after: u64,
    credit_count_after: u64,
    caused_by_credit_removal: bool,
): vector<u8> {
    let mut bytes = expected_artist_added(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        display_name,
        artist_index,
        artist_count_before,
        artist_count_after,
        credit_count_after,
    );
    bytes.append(bcs::to_bytes(&caused_by_credit_removal));
    bytes
}

#[test]
fun add_credit_attaches_and_reads_back() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    assert!(!credits::has_credits(&rec));

    let (p1, p1c) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(
        &mut rec,
        &cap,
        &p1,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]),
    );

    assert!(credits::has_credits(&rec));
    assert_eq!(credits::credits(&rec).length(), 1);

    let (p2, p2c) = mk_party(b"Bob", ts.ctx());
    credits::add_credit(
        &mut rec,
        &cap,
        &p2,
        credit::new(b"Bob".to_string(), vector[rpr::new_producer_role(option::none())]),
    );
    assert_eq!(credits::credits(&rec).length(), 2);

    destroy(rec); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test, expected_failure(abort_code = 40, location = recording_credits::recording_credits)] // EPartyAlreadyCredited
fun add_credit_rejects_duplicate_party() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(
        &mut rec,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]),
    );
    credits::add_credit(
        &mut rec,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_producer_role(option::none())]),
    );
    abort
}

#[test, expected_failure(abort_code = 30, location = recording_credits::recording_credits)] // EExceedsMaxRoles
fun add_credit_rejects_too_many_roles() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    let n = option::none();
    credits::add_credit(
        &mut rec,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[
            rpr::new_producer_role(n),
            rpr::new_vocalist_role(n),
            rpr::new_arranger_role(n),
            rpr::new_conductor_role(n),
            rpr::new_editor_role(n),
            rpr::new_mixing_engineer_role(n),
            rpr::new_mastering_engineer_role(n),
            rpr::new_recording_engineer_role(n),
            rpr::new_programmer_role(n),
            rpr::new_sound_designer_role(n),
            rpr::new_narrator_role(n), // 11 > MAX_ROLES_PER_CREDIT (10)
        ]),
    );
    abort
}

#[test]
fun primary_and_featured_round_trip() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p1, p1c) = mk_party(b"Lead", ts.ctx());
    let (p2, p2c) = mk_party(b"Guest", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p1,
        credit::new(b"Lead".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &p2,
        credit::new(b"Guest".to_string(), vector[rpr::new_vocalist_role(option::none())]));

    credits::add_primary_artist(&mut rec, &cap, &p1);
    credits::add_featured_artist(&mut rec, &cap, &p2);

    assert!(credits::is_primary_artist(&rec, object::id(&p1)));
    assert!(credits::is_featured_artist(&rec, object::id(&p2)));
    assert_eq!(credits::primary_artist_ids(&rec).length(), 1);
    assert_eq!(credits::featured_artist_ids(&rec).length(), 1);

    destroy(rec); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test, expected_failure(abort_code = 52, location = recording_credits::recording_credits)] // EPartyNotCredited
fun primary_artist_must_be_credited() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Ghost", ts.ctx());
    // attach a credits record (so the DF exists) via a different party
    let (other, _otherc) = mk_party(b"Real", ts.ctx());
    credits::add_credit(&mut rec, &cap, &other,
        credit::new(b"Real".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p); // not credited
    abort
}

#[test, expected_failure(abort_code = 41, location = recording_credits::recording_credits)] // EAlreadyPrimaryArtist
fun featured_rejects_existing_primary() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p);
    credits::add_featured_artist(&mut rec, &cap, &p); // already primary
    abort
}

#[test]
fun remove_credit_cascades_to_primary_and_featured() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    let pid = object::id(&p);
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p);
    assert!(credits::is_primary_artist(&rec, pid));

    credits::remove_credit(&mut rec, &cap, pid);
    assert!(!credits::is_primary_artist(&rec, pid));
    assert_eq!(credits::credits(&rec).length(), 0);

    destroy(rec); destroy(cap); destroy(p); destroy(_pc);
    ts.end();
}

#[test]
fun add_credit_emits_the_full_credit() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Alice Party", ts.ctx());
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let party_id = object::id(&p).to_address();

    credits::add_credit(
        &mut rec,
        &cap,
        &p,
        credit::new(b"Alice Display".to_string(), vector[
            rpr::new_producer_role(option::none()),
            rpr::new_custom_role(b"Producer".to_string(), option::some(rpr::new_primary_role_level())),
            rpr::new_instrumentalist_role(b"Piano".to_string(), option::some(rpr::new_lead_role_level())),
        ]),
    );

    let events = event::events_by_type<credits::CreditAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(events.length(), 1);
    assert_eq!(event::events_by_type<credits::CreditAddedEvent<RecordingShare, bool>>().length(), 0);
    assert_eq!(event::events_by_type<credits::CreditAddedEvent<bool, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::CreditAddedEvent<bool, bool>>().length(), 0);
    assert_eq!(event::events_by_type<credits::CreditAddedEvent<CompositionShare, RecordingShare>>().length(), 0);
    let payload = credits::credit_added_event_fields(&events[0]);
    let expected = expected_credit_added(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        b"Alice Display",
        vector[23, 31, 14],
        vector[b"Producer", b"Producer", b"Instrumentalist"],
        vector[b"", b"", b"Piano"],
        vector[0, 8, 7],
        0,
        0,
        1,
        true,
    );
    assert_eq!(payload, expected);

    // Views are silent and do not change the event count.
    assert!(credits::has_credits(&rec));
    assert_eq!(credits::credits(&rec).length(), 1);
    assert!(!credits::is_primary_artist(&rec, object::id(&p)));
    assert!(!credits::is_featured_artist(&rec, object::id(&p)));
    assert_eq!(event::events_by_type<credits::CreditAddedEvent<RecordingShare, CompositionShare>>().length(), 1);

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun remove_credit_emits_the_removed_credit() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Remover Party", ts.ctx());
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let party_id = object::id(&p).to_address();
    credits::add_credit(
        &mut rec,
        &cap,
        &p,
        credit::new(b"Remover Display".to_string(), vector[rpr::new_custom_role(
            b"Producer".to_string(), option::some(rpr::new_primary_role_level()),
        )]),
    );

    credits::remove_credit(&mut rec, &cap, object::id(&p));

    let events = event::events_by_type<credits::CreditRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(events.length(), 1);
    let payload = credits::credit_removed_event_fields(&events[0]);
    assert_eq!(payload, expected_credit_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        b"Remover Display",
        vector[31],
        vector[b"Producer"],
        vector[b""],
        vector[8],
        0,
        1,
        0,
        false,
        false,
    ));

    // The party held no primary/featured designation, so the cascade stays silent.
    assert_eq!(event::events_by_type<credits::PrimaryArtistRemovedEvent<RecordingShare, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::FeaturedArtistRemovedEvent<RecordingShare, CompositionShare>>().length(), 0);

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun remove_credit_cascade_emits_artist_removals() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p1, p1c) = mk_party(b"Lead Party", ts.ctx());
    let (p2, p2c) = mk_party(b"Guest Party", ts.ctx());
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let p1_id = object::id(&p1).to_address();
    let p2_id = object::id(&p2).to_address();
    credits::add_credit(&mut rec, &cap, &p1,
        credit::new(b"Lead Display".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &p2,
        credit::new(b"Guest Display".to_string(), vector[rpr::new_custom_role(
            b"Producer".to_string(), option::some(rpr::new_featured_role_level()),
        )]));
    credits::add_primary_artist(&mut rec, &cap, &p1);
    credits::add_featured_artist(&mut rec, &cap, &p2);

    credits::remove_credit(&mut rec, &cap, object::id(&p1));
    credits::remove_credit(&mut rec, &cap, object::id(&p2));

    // Removing a credited primary/featured artist ends that designation too;
    // an indexer must hear about it without diffing object state.
    let primaries = event::events_by_type<credits::PrimaryArtistRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(primaries.length(), 1);
    let payload = credits::primary_artist_removed_event_fields(&primaries[0]);
    assert_eq!(payload, expected_artist_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        p1_id,
        b"Lead Display",
        0,
        1,
        0,
        1,
        true,
    ));

    let featured = event::events_by_type<credits::FeaturedArtistRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(featured.length(), 1);
    let payload = credits::featured_artist_removed_event_fields(&featured[0]);
    assert_eq!(payload, expected_artist_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        p2_id,
        b"Guest Display",
        0,
        1,
        0,
        0,
        true,
    ));

    let removed = event::events_by_type<credits::CreditRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(removed.length(), 2);
    assert_eq!(credits::credit_removed_event_fields(&removed[0]), expected_credit_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        p1_id,
        b"Lead Display",
        vector[30],
        vector[b"Vocalist"],
        vector[b""],
        vector[0],
        0,
        2,
        1,
        true,
        false,
    ));
    assert_eq!(credits::credit_removed_event_fields(&removed[1]), expected_credit_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        p2_id,
        b"Guest Display",
        vector[31],
        vector[b"Producer"],
        vector[b""],
        vector[6],
        0,
        1,
        0,
        false,
        true,
    ));

    destroy(rec); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test]
fun primary_artist_changes_emit_events() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Primary Party", ts.ctx());
    let pid = object::id(&p);
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let party_id = pid.to_address();
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Primary Display".to_string(), vector[rpr::new_vocalist_role(option::none())]));

    credits::add_primary_artist(&mut rec, &cap, &p);

    let added = event::events_by_type<credits::PrimaryArtistAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(added.length(), 1);
    let payload = credits::primary_artist_added_event_fields(&added[0]);
    assert_eq!(payload, expected_artist_added(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        b"Primary Display",
        0,
        0,
        1,
        1,
    ));

    credits::remove_primary_artist(&mut rec, &cap, pid);

    let removed = event::events_by_type<credits::PrimaryArtistRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(removed.length(), 1);
    let payload = credits::primary_artist_removed_event_fields(&removed[0]);
    assert_eq!(payload, expected_artist_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        b"Primary Display",
        0,
        1,
        0,
        1,
        false,
    ));

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

// === Additional coverage: validation, reference, and conflict-guard paths ===
// Single-transaction `test_scenario` style throughout — these exercise local
// mutation and validation paths on an unshared recording. They do not claim a
// sender or cap-identity check: the pinned `uid_mut` is type-gated only. The
// published+shared, multi-sender shape lives in
// `recording_credits_e2e_tests.move`.

#[test, expected_failure(abort_code = 32, location = recording_credits::recording_credits)] // EMaxCreditsExceeded
fun add_credit_rejects_past_max_credits() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    150u64.do!(|_| {
        let (p, pc) = party::new(party::new_individual_kind(), b"P".to_string(), &clock, ts.ctx());
        credits::add_credit(&mut rec, &cap, &p,
            credit::new(b"P".to_string(), vector[rpr::new_vocalist_role(option::none())]));
        destroy(p); destroy(pc);
    });
    assert_eq!(credits::credits(&rec).length(), 150);

    // The 151st credit is the one that must abort.
    let (p, _pc) = party::new(party::new_individual_kind(), b"Overflow".to_string(), &clock, ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Overflow".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    abort
}

#[test, expected_failure(abort_code = 34, location = recording_credits::recording_credits)] // EMaxPrimaryArtistsExceeded
fun add_primary_artist_rejects_past_max_primary_artists() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    20u64.do!(|_| {
        let (p, pc) = party::new(party::new_individual_kind(), b"P".to_string(), &clock, ts.ctx());
        credits::add_credit(&mut rec, &cap, &p,
            credit::new(b"P".to_string(), vector[rpr::new_vocalist_role(option::none())]));
        credits::add_primary_artist(&mut rec, &cap, &p);
        destroy(p); destroy(pc);
    });
    assert_eq!(credits::primary_artist_ids(&rec).length(), 20);

    // The 21st credited party's primary designation is the one that must abort.
    let (p, _pc) = party::new(party::new_individual_kind(), b"Overflow".to_string(), &clock, ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Overflow".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p);
    abort
}

#[test, expected_failure(abort_code = 35, location = recording_credits::recording_credits)] // EMaxFeaturedArtistsExceeded
fun add_featured_artist_rejects_past_max_featured_artists() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    50u64.do!(|_| {
        let (p, pc) = party::new(party::new_individual_kind(), b"P".to_string(), &clock, ts.ctx());
        credits::add_credit(&mut rec, &cap, &p,
            credit::new(b"P".to_string(), vector[rpr::new_vocalist_role(option::none())]));
        credits::add_featured_artist(&mut rec, &cap, &p);
        destroy(p); destroy(pc);
    });
    assert_eq!(credits::featured_artist_ids(&rec).length(), 50);

    // The 51st credited party's featured designation is the one that must abort.
    let (p, _pc) = party::new(party::new_individual_kind(), b"Overflow".to_string(), &clock, ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Overflow".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_featured_artist(&mut rec, &cap, &p);
    abort
}

#[test, expected_failure(abort_code = 50, location = recording_credits::recording_credits)] // ENoCredits
fun add_primary_artist_rejects_when_no_credits_record() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Ghost", ts.ctx());
    credits::add_primary_artist(&mut rec, &cap, &p); // no add_credit ever called
    abort
}

#[test, expected_failure(abort_code = 50, location = recording_credits::recording_credits)] // ENoCredits
fun credits_view_aborts_when_no_credits_record() {
    let mut ts = test_scenario::begin(ARTIST);
    let (rec, _cap) = mk_recording(ts.ctx());
    let _ = credits::credits(&rec);
    abort
}

#[test]
fun is_primary_and_featured_artist_are_false_before_any_credit() {
    let mut ts = test_scenario::begin(ARTIST);
    let (rec, cap) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Ghost", ts.ctx());

    // `has_credits` short-circuits `is_primary_artist`/`is_featured_artist` to
    // `false` rather than aborting — absence must read as "not designated",
    // not as an error.
    assert!(!credits::has_credits(&rec));
    assert!(!credits::is_primary_artist(&rec, object::id(&p)));
    assert!(!credits::is_featured_artist(&rec, object::id(&p)));

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test, expected_failure(abort_code = 42, location = recording_credits::recording_credits)] // EAlreadyFeaturedArtist
fun add_primary_artist_rejects_existing_featured() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_featured_artist(&mut rec, &cap, &p);
    credits::add_primary_artist(&mut rec, &cap, &p); // already featured
    abort
}

#[test, expected_failure(abort_code = 41, location = recording_credits::recording_credits)] // EAlreadyPrimaryArtist
fun add_primary_artist_rejects_duplicate_designation() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p);
    credits::add_primary_artist(&mut rec, &cap, &p); // already primary
    abort
}

#[test, expected_failure(abort_code = 52, location = recording_credits::recording_credits)] // EPartyNotCredited
fun add_featured_artist_rejects_uncredited_party() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Ghost", ts.ctx());
    let (other, _oc) = mk_party(b"Real", ts.ctx());
    credits::add_credit(&mut rec, &cap, &other,
        credit::new(b"Real".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_featured_artist(&mut rec, &cap, &p); // not credited
    abort
}

#[test, expected_failure(abort_code = 42, location = recording_credits::recording_credits)] // EAlreadyFeaturedArtist
fun add_featured_artist_rejects_duplicate_designation() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_featured_artist(&mut rec, &cap, &p);
    credits::add_featured_artist(&mut rec, &cap, &p); // already featured
    abort
}

#[test, expected_failure(abort_code = 52, location = recording_credits::recording_credits)] // EPartyNotCredited
fun remove_primary_artist_rejects_when_not_primary() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::remove_primary_artist(&mut rec, &cap, object::id(&p)); // never was primary
    abort
}

#[test, expected_failure(abort_code = 52, location = recording_credits::recording_credits)] // EPartyNotCredited
fun remove_featured_artist_rejects_when_not_featured() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::remove_featured_artist(&mut rec, &cap, object::id(&p)); // never was featured
    abort
}

#[test, expected_failure(abort_code = 52, location = recording_credits::recording_credits)] // EPartyNotCredited
fun remove_credit_rejects_double_removal() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    let pid = object::id(&p);
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::remove_credit(&mut rec, &cap, pid);
    credits::remove_credit(&mut rec, &cap, pid); // operate-after-remove: already gone
    abort
}

/// Wrong-parent guarantee: credits live on the recording's own UID, not in
/// any shared/global table keyed by party ID, so a party credited on one
/// recording is invisible from another recording entirely.
#[test]
fun credits_are_scoped_to_their_own_recording() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec_a, cap_a) = mk_recording(ts.ctx());
    let (rec_b, cap_b) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(&mut rec_a, &cap_a, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_primary_artist(&mut rec_a, &cap_a, &p);

    assert!(credits::has_credits(&rec_a));
    assert!(credits::is_primary_artist(&rec_a, object::id(&p)));
    assert!(!credits::has_credits(&rec_b));
    assert!(!credits::is_primary_artist(&rec_b, object::id(&p)));

    destroy(rec_a); destroy(cap_a); destroy(rec_b); destroy(cap_b);
    destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun featured_artist_changes_emit_events() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Featured Party", ts.ctx());
    let pid = object::id(&p);
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let party_id = pid.to_address();
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Featured Display".to_string(), vector[rpr::new_vocalist_role(option::none())]));

    credits::add_featured_artist(&mut rec, &cap, &p);

    let added = event::events_by_type<credits::FeaturedArtistAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(added.length(), 1);
    let payload = credits::featured_artist_added_event_fields(&added[0]);
    assert_eq!(payload, expected_artist_added(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        b"Featured Display",
        0,
        0,
        1,
        1,
    ));

    credits::remove_featured_artist(&mut rec, &cap, pid);

    let removed = event::events_by_type<credits::FeaturedArtistRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(removed.length(), 1);
    let payload = credits::featured_artist_removed_event_fields(&removed[0]);
    assert_eq!(payload, expected_artist_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        b"Featured Display",
        0,
        1,
        0,
        1,
        false,
    ));

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun remove_and_readd_preserves_order_and_dynamic_field() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p1, p1c) = mk_party(b"One", ts.ctx());
    let (p2, p2c) = mk_party(b"Two", ts.ctx());
    let id1 = object::id(&p1);
    let id2 = object::id(&p2);
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let p1_address = id1.to_address();
    let p2_address = id2.to_address();
    credits::add_credit(&mut rec, &cap, &p1,
        credit::new(b"One".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::remove_credit(&mut rec, &cap, id1);
    assert!(credits::has_credits(&rec));
    assert_eq!(credits::credits(&rec).length(), 0);
    credits::add_credit(&mut rec, &cap, &p1,
        credit::new(b"OneAgain".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &p2,
        credit::new(b"Two".to_string(), vector[rpr::new_producer_role(option::none())]));
    assert_eq!(credits::credits(&rec).get_idx(&id1), 0);
    assert_eq!(credits::credits(&rec).get_idx(&id2), 1);

    let added = event::events_by_type<credits::CreditAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(added.length(), 3);
    assert_eq!(credits::credit_added_event_fields(&added[0]), expected_credit_added(
        recording_id,
        composition_id,
        admin_cap_id,
        p1_address,
        b"One",
        vector[30],
        vector[b"Vocalist"],
        vector[b""],
        vector[0],
        0,
        0,
        1,
        true,
    ));
    assert_eq!(credits::credit_added_event_fields(&added[1]), expected_credit_added(
        recording_id,
        composition_id,
        admin_cap_id,
        p1_address,
        b"OneAgain",
        vector[30],
        vector[b"Vocalist"],
        vector[b""],
        vector[0],
        0,
        0,
        1,
        false,
    ));
    assert_eq!(credits::credit_added_event_fields(&added[2]), expected_credit_added(
        recording_id,
        composition_id,
        admin_cap_id,
        p2_address,
        b"Two",
        vector[23],
        vector[b"Producer"],
        vector[b""],
        vector[0],
        1,
        1,
        2,
        false,
    ));

    let removed = event::events_by_type<credits::CreditRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(removed.length(), 1);
    assert_eq!(credits::credit_removed_event_fields(&removed[0]), expected_credit_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        p1_address,
        b"One",
        vector[30],
        vector[b"Vocalist"],
        vector[b""],
        vector[0],
        0,
        1,
        0,
        false,
        false,
    ));
    destroy(rec); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test]
fun same_share_other_cap_is_observationally_accepted() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec_a, cap_a) = mk_recording(ts.ctx());
    let (rec_b, cap_b) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Alice", ts.ctx());
    // `uid_mut` is type-only in the pinned musicos dependency; the cap value
    // is intentionally not an additional runtime authorization check.
    credits::add_credit(&mut rec_a, &cap_b, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    assert_eq!(credits::credits(&rec_a).length(), 1);
    destroy(rec_a); destroy(cap_a); destroy(rec_b); destroy(cap_b); destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun rich_event_bcs_sizes_match_declared_maxima() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Max", ts.ctx());
    let instrument = test_helpers::long_string(100);
    let max_credit = credit::new(test_helpers::long_string(200), vector[
        rpr::new_instrumentalist_role(instrument, option::none()),
        rpr::new_instrumentalist_role(test_helpers::long_string(100), option::some(rpr::new_additional_role_level())),
        rpr::new_instrumentalist_role(test_helpers::long_string(100), option::some(rpr::new_assistant_role_level())),
        rpr::new_instrumentalist_role(test_helpers::long_string(100), option::some(rpr::new_associate_role_level())),
        rpr::new_instrumentalist_role(test_helpers::long_string(100), option::some(rpr::new_backing_role_level())),
        rpr::new_instrumentalist_role(test_helpers::long_string(100), option::some(rpr::new_executive_role_level())),
        rpr::new_instrumentalist_role(test_helpers::long_string(100), option::some(rpr::new_featured_role_level())),
        rpr::new_instrumentalist_role(test_helpers::long_string(100), option::some(rpr::new_lead_role_level())),
        rpr::new_instrumentalist_role(test_helpers::long_string(100), option::some(rpr::new_primary_role_level())),
        rpr::new_instrumentalist_role(test_helpers::long_string(100), option::some(rpr::new_principal_role_level())),
    ]);
    let pid = object::id(&p);
    credits::add_credit(&mut rec, &cap, &p, max_credit);
    let added = event::events_by_type<credits::CreditAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(credits::credit_added_event_fields(&added[0]).length(), 1549);
    credits::add_primary_artist(&mut rec, &cap, &p);
    let primary_added = event::events_by_type<credits::PrimaryArtistAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(credits::primary_artist_added_event_fields(&primary_added[0]).length(), 362);
    credits::remove_primary_artist(&mut rec, &cap, pid);
    let primary_removed = event::events_by_type<credits::PrimaryArtistRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(credits::primary_artist_removed_event_fields(&primary_removed[0]).length(), 363);
    credits::add_featured_artist(&mut rec, &cap, &p);
    let featured_added = event::events_by_type<credits::FeaturedArtistAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(credits::featured_artist_added_event_fields(&featured_added[0]).length(), 362);
    credits::remove_featured_artist(&mut rec, &cap, pid);
    let featured_removed = event::events_by_type<credits::FeaturedArtistRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(credits::featured_artist_removed_event_fields(&featured_removed[0]).length(), 363);
    credits::remove_credit(&mut rec, &cap, pid);
    let removed = event::events_by_type<credits::CreditRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(credits::credit_removed_event_fields(&removed[0]).length(), 1550);
    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}
