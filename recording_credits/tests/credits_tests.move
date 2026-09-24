// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Add/remove/designate mechanics, guard order, cascades, and event payloads
/// for `recording_credits` against an unshared recording. The published and
/// shared multi-sender shape lives in `recording_credits_e2e_tests`. Every
/// write that would leave the record unchanged — re-crediting a party,
/// re-designating an artist, removing an absent credit or designation —
/// aborts rather than silently passing, so the no-op rule is covered by the
/// abort tests. `uid_mut` is type-gated only: a same-share cap is accepted,
/// and there is no per-recording cap-identity claim.
#[test_only]
module recording_credits::credits_tests;

use credit::credit;
use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers::{Self, RecordingShare};
use partyos::party::{Self, Party, PartyAdminCap};
use recording_credits::recording_credits as credits;
use recording_credits::recording_party_role::{Self as rpr, RecordingPartyRole};
use std::string::String;
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;
use sui::test_scenario;

const ARTIST: address = @0xA1;

fun mk_recording(
    ctx: &mut TxContext,
): (Recording<RecordingShare>, RecordingAdminCap<RecordingShare>) {
    recording::new_for_testing(test_helpers::fake_id(ctx), ctx)
}

fun mk_party(name: vector<u8>, ctx: &mut TxContext): (Party, PartyAdminCap) {
    party::new(party::new_individual_kind(), name.to_string(), ctx)
}

fun long_string(len: u64): String {
    let mut bytes = vector[];
    len.do!(|_| bytes.push_back(65));
    bytes.to_string()
}

fun other_long_string(len: u64): String {
    let mut bytes = vector[];
    len.do!(|_| bytes.push_back(66));
    bytes.to_string()
}

/// Asserts one credit-added event's full payload against the credit added.
fun assert_added(
    e: &credits::RecordingCreditAddedEvent<RecordingShare>,
    recording_id: address,
    party_id: address,
    credit: &credit::Credit<RecordingPartyRole>,
) {
    let (event_object, event_party, event_roles) = credits::credit_added_event_fields(e);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, party_id);
    assert_eq!(event_roles, *credit.roles());
}

#[test]
fun add_credit_attaches_and_reads_back() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    assert!(!credits::has_credits(&rec));

    let (p1, p1c) = mk_party(b"Alice", ts.ctx());
    let alice = credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]);
    credits::add_credit(&mut rec, &cap, &p1, alice);

    assert!(credits::has_credits(&rec));
    assert_eq!(credits::credits(&rec).length(), 1);
    assert_eq!(credits::credits(&rec)[&object::id(&p1)], alice);

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

#[test, expected_failure(abort_code = credits::EPartyAlreadyCredited)]
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

/// Re-adding the exact credit already stored is not a silent no-op: the
/// duplicate-party guard fires before any comparison of values.
#[test, expected_failure(abort_code = credits::EPartyAlreadyCredited)]
fun add_credit_rejects_identical_credit() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    let alice = credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]);
    credits::add_credit(&mut rec, &cap, &p, alice);
    credits::add_credit(&mut rec, &cap, &p, alice);
    abort
}

#[test, expected_failure(abort_code = credits::EExceedsMaxRoles)]
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

#[test, expected_failure(abort_code = credits::EPartyNotCredited)]
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

#[test, expected_failure(abort_code = credits::EAlreadyPrimaryArtist)]
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
    assert_eq!(credits::primary_artist_ids(&rec).length(), 0);
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
    let party_id = object::id(&p).to_address();
    let credit = credit::new(b"Alice Display".to_string(), vector[
        rpr::new_producer_role(option::none()),
        rpr::new_producer_role(option::some(rpr::new_primary_role_level())),
        rpr::new_instrumentalist_role(b"Piano".to_string(), option::some(rpr::new_lead_role_level())),
    ]);

    credits::add_credit(&mut rec, &cap, &p, credit);

    // The phantom share type is the event filter; a different type sees nothing.
    let events = events_by_type<credits::RecordingCreditAddedEvent<RecordingShare>>();
    assert_eq!(events.length(), 1);
    assert_eq!(events_by_type<credits::RecordingCreditAddedEvent<bool>>().length(), 0);
    let (event_recording_id, event_party_id, event_roles) = credits::credit_added_event_fields(&events[0]);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(event_party_id, party_id);
    assert_eq!(event_roles, *credit.roles());
    // Two addresses and three roles: `Producer(None)` (1 + 1),
    // `Producer(Some(Primary))` (1 + 2), and `Instrumentalist("Piano",
    // Some(Lead))` (1 + 1 + 5 + 2); the display name stays in storage.
    assert_eq!(to_bytes(&events[0]).length(), 32 + 32 + 1 + 2 + 3 + 9);
    assert_eq!(credits::credits(&rec)[&object::id(&p)], credit);

    // Views are silent and do not change the event count.
    assert!(credits::has_credits(&rec));
    assert_eq!(credits::credits(&rec).length(), 1);
    assert!(!credits::is_primary_artist(&rec, object::id(&p)));
    assert!(!credits::is_featured_artist(&rec, object::id(&p)));
    assert_eq!(events_by_type<credits::RecordingCreditAddedEvent<RecordingShare>>().length(), 1);

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun remove_credit_emits_the_removed_party() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Remover Party", ts.ctx());
    let recording_id = object::id(&rec).to_address();
    let party_id = object::id(&p).to_address();
    credits::add_credit(
        &mut rec,
        &cap,
        &p,
        credit::new(b"Remover Display".to_string(), vector[rpr::new_producer_role(
            option::some(rpr::new_primary_role_level()),
        )]),
    );

    credits::remove_credit(&mut rec, &cap, object::id(&p));

    let events = events_by_type<credits::RecordingCreditRemovedEvent<RecordingShare>>();
    assert_eq!(events.length(), 1);
    let (event_object, event_party) = credits::credit_removed_event_fields(&events[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, party_id);
    assert_eq!(to_bytes(&events[0]).length(), 64);
    assert_eq!(events_by_type<credits::RecordingCreditRemovedEvent<bool>>().length(), 0);

    // The party held no designation, and the cascade is silent either way.
    assert_eq!(events_by_type<credits::RecordingPrimaryArtistRemovedEvent<RecordingShare>>().length(), 0);
    assert_eq!(events_by_type<credits::RecordingFeaturedArtistRemovedEvent<RecordingShare>>().length(), 0);

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

/// Removing a credited primary or featured artist ends that designation, but
/// the designation sets are subsets of the credits by invariant, so an
/// indexer infers the cascade from `RecordingCreditRemovedEvent` alone and
/// no artist-removed event is emitted.
#[test]
fun remove_credit_cascade_emits_no_artist_removal_events() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p1, p1c) = mk_party(b"Lead Party", ts.ctx());
    let (p2, p2c) = mk_party(b"Middle Party", ts.ctx());
    let (p3, p3c) = mk_party(b"Guest Party", ts.ctx());
    let recording_id = object::id(&rec).to_address();
    let p2_id = object::id(&p2).to_address();
    let p3_id = object::id(&p3).to_address();
    credits::add_credit(&mut rec, &cap, &p1,
        credit::new(b"Lead Display".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &p2,
        credit::new(b"Middle Display".to_string(), vector[rpr::new_producer_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &p3,
        credit::new(b"Guest Display".to_string(), vector[rpr::new_vocalist_role(
            option::some(rpr::new_featured_role_level()),
        )]));
    credits::add_primary_artist(&mut rec, &cap, &p1);
    credits::add_primary_artist(&mut rec, &cap, &p2);
    credits::add_featured_artist(&mut rec, &cap, &p3);

    credits::remove_credit(&mut rec, &cap, object::id(&p2));
    // Removing the middle credit shifts the surviving guest from index 2 to 1.
    assert_eq!(credits::credits(&rec).get_idx(&object::id(&p1)), 0);
    assert_eq!(credits::credits(&rec).get_idx(&object::id(&p3)), 1);
    credits::remove_credit(&mut rec, &cap, object::id(&p3));

    assert!(credits::is_primary_artist(&rec, object::id(&p1)));
    assert!(!credits::is_primary_artist(&rec, object::id(&p2)));
    assert!(!credits::is_featured_artist(&rec, object::id(&p3)));
    assert_eq!(credits::primary_artist_ids(&rec).length(), 1);
    assert_eq!(credits::featured_artist_ids(&rec).length(), 0);

    assert_eq!(events_by_type<credits::RecordingPrimaryArtistRemovedEvent<RecordingShare>>().length(), 0);
    assert_eq!(events_by_type<credits::RecordingFeaturedArtistRemovedEvent<RecordingShare>>().length(), 0);
    let removed = events_by_type<credits::RecordingCreditRemovedEvent<RecordingShare>>();
    assert_eq!(removed.length(), 2);
    let (event_object, event_party) = credits::credit_removed_event_fields(&removed[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, p2_id);
    let (event_object, event_party) = credits::credit_removed_event_fields(&removed[1]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, p3_id);

    destroy(rec); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c); destroy(p3); destroy(p3c);
    ts.end();
}

#[test]
fun primary_artist_changes_emit_events() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p1, p1c) = mk_party(b"Primary One Party", ts.ctx());
    let (p2, p2c) = mk_party(b"Primary Two Party", ts.ctx());
    let id1 = object::id(&p1);
    let id2 = object::id(&p2);
    let recording_id = object::id(&rec).to_address();
    credits::add_credit(&mut rec, &cap, &p1,
        credit::new(b"Primary One Display".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &p2,
        credit::new(b"Primary Two Display".to_string(), vector[rpr::new_producer_role(option::none())]));

    credits::add_primary_artist(&mut rec, &cap, &p1);
    credits::add_primary_artist(&mut rec, &cap, &p2);

    let added = events_by_type<credits::RecordingPrimaryArtistAddedEvent<RecordingShare>>();
    assert_eq!(added.length(), 2);
    let (event_object, event_party) = credits::primary_artist_added_event_fields(&added[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, id1.to_address());
    let (event_object, event_party) = credits::primary_artist_added_event_fields(&added[1]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, id2.to_address());
    assert_eq!(to_bytes(&added[0]).length(), 64);
    assert_eq!(events_by_type<credits::RecordingPrimaryArtistAddedEvent<bool>>().length(), 0);

    credits::remove_primary_artist(&mut rec, &cap, id2);

    let removed = events_by_type<credits::RecordingPrimaryArtistRemovedEvent<RecordingShare>>();
    assert_eq!(removed.length(), 1);
    let (event_object, event_party) = credits::primary_artist_removed_event_fields(&removed[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, id2.to_address());
    assert_eq!(to_bytes(&removed[0]).length(), 64);
    assert_eq!(events_by_type<credits::RecordingPrimaryArtistRemovedEvent<bool>>().length(), 0);
    assert!(credits::is_primary_artist(&rec, id1));
    assert!(!credits::is_primary_artist(&rec, id2));

    destroy(rec); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

// === Additional coverage: validation, reference, and conflict-guard paths ===

#[test, expected_failure(abort_code = credits::EMaxCreditsExceeded)]
fun add_credit_rejects_past_max_credits() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    150u64.do!(|_| {
        let (p, pc) = mk_party(b"P", ts.ctx());
        credits::add_credit(&mut rec, &cap, &p,
            credit::new(b"P".to_string(), vector[rpr::new_vocalist_role(option::none())]));
        destroy(p); destroy(pc);
    });
    assert_eq!(credits::credits(&rec).length(), 150);

    // The 151st credit is the one that must abort.
    let (p, _pc) = mk_party(b"Overflow", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Overflow".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    abort
}

#[test, expected_failure(abort_code = credits::EMaxPrimaryArtistsExceeded)]
fun add_primary_artist_rejects_past_max_primary_artists() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    20u64.do!(|_| {
        let (p, pc) = mk_party(b"P", ts.ctx());
        credits::add_credit(&mut rec, &cap, &p,
            credit::new(b"P".to_string(), vector[rpr::new_vocalist_role(option::none())]));
        credits::add_primary_artist(&mut rec, &cap, &p);
        destroy(p); destroy(pc);
    });
    assert_eq!(credits::primary_artist_ids(&rec).length(), 20);

    // The 21st credited party's primary designation is the one that must abort.
    let (p, _pc) = mk_party(b"Overflow", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Overflow".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p);
    abort
}

#[test, expected_failure(abort_code = credits::EMaxFeaturedArtistsExceeded)]
fun add_featured_artist_rejects_past_max_featured_artists() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    50u64.do!(|_| {
        let (p, pc) = mk_party(b"P", ts.ctx());
        credits::add_credit(&mut rec, &cap, &p,
            credit::new(b"P".to_string(), vector[rpr::new_vocalist_role(option::none())]));
        credits::add_featured_artist(&mut rec, &cap, &p);
        destroy(p); destroy(pc);
    });
    assert_eq!(credits::featured_artist_ids(&rec).length(), 50);

    // The 51st credited party's featured designation is the one that must abort.
    let (p, _pc) = mk_party(b"Overflow", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Overflow".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_featured_artist(&mut rec, &cap, &p);
    abort
}

#[test, expected_failure(abort_code = credits::ENoCredits)]
fun add_primary_artist_rejects_when_no_credits_record() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Ghost", ts.ctx());
    credits::add_primary_artist(&mut rec, &cap, &p); // no add_credit ever called
    abort
}

#[test, expected_failure(abort_code = credits::ENoCredits)]
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

#[test, expected_failure(abort_code = credits::EAlreadyFeaturedArtist)]
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

#[test, expected_failure(abort_code = credits::EAlreadyPrimaryArtist)]
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

#[test, expected_failure(abort_code = credits::EPartyNotCredited)]
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

#[test, expected_failure(abort_code = credits::EAlreadyFeaturedArtist)]
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

#[test, expected_failure(abort_code = credits::EPartyNotCredited)]
fun remove_primary_artist_rejects_when_not_primary() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::remove_primary_artist(&mut rec, &cap, object::id(&p)); // never was primary
    abort
}

#[test, expected_failure(abort_code = credits::EPartyNotCredited)]
fun remove_featured_artist_rejects_when_not_featured() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::remove_featured_artist(&mut rec, &cap, object::id(&p)); // never was featured
    abort
}

#[test, expected_failure(abort_code = credits::EPartyNotCredited)]
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
    let (p1, p1c) = mk_party(b"Featured One Party", ts.ctx());
    let (p2, p2c) = mk_party(b"Featured Two Party", ts.ctx());
    let id1 = object::id(&p1);
    let id2 = object::id(&p2);
    let recording_id = object::id(&rec).to_address();
    credits::add_credit(&mut rec, &cap, &p1,
        credit::new(b"Featured One Display".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &p2,
        credit::new(b"Featured Two Display".to_string(), vector[rpr::new_producer_role(option::none())]));

    credits::add_featured_artist(&mut rec, &cap, &p1);
    credits::add_featured_artist(&mut rec, &cap, &p2);

    let added = events_by_type<credits::RecordingFeaturedArtistAddedEvent<RecordingShare>>();
    assert_eq!(added.length(), 2);
    let (event_object, event_party) = credits::featured_artist_added_event_fields(&added[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, id1.to_address());
    let (event_object, event_party) = credits::featured_artist_added_event_fields(&added[1]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, id2.to_address());
    assert_eq!(to_bytes(&added[0]).length(), 64);
    assert_eq!(events_by_type<credits::RecordingFeaturedArtistAddedEvent<bool>>().length(), 0);

    credits::remove_featured_artist(&mut rec, &cap, id2);

    let removed = events_by_type<credits::RecordingFeaturedArtistRemovedEvent<RecordingShare>>();
    assert_eq!(removed.length(), 1);
    let (event_object, event_party) = credits::featured_artist_removed_event_fields(&removed[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, id2.to_address());
    assert_eq!(to_bytes(&removed[0]).length(), 64);
    assert_eq!(events_by_type<credits::RecordingFeaturedArtistRemovedEvent<bool>>().length(), 0);
    assert!(credits::is_featured_artist(&rec, id1));
    assert!(!credits::is_featured_artist(&rec, id2));

    destroy(rec); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test]
fun remove_and_readd_preserves_order_and_dynamic_field() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p1, p1c) = mk_party(b"One", ts.ctx());
    let (p2, p2c) = mk_party(b"Two", ts.ctx());
    let (p3, p3c) = mk_party(b"Three", ts.ctx());
    let (p4, p4c) = mk_party(b"Four", ts.ctx());
    let id1 = object::id(&p1);
    let id2 = object::id(&p2);
    let id3 = object::id(&p3);
    let id4 = object::id(&p4);
    let recording_id = object::id(&rec).to_address();
    let one = credit::new(b"One".to_string(), vector[rpr::new_vocalist_role(option::none())]);
    let one_again = credit::new(b"OneAgain".to_string(), vector[rpr::new_vocalist_role(option::none())]);
    let two = credit::new(b"Two".to_string(), vector[rpr::new_producer_role(option::none())]);
    let two_again = credit::new(b"TwoAgain".to_string(), vector[rpr::new_producer_role(option::none())]);
    let three = credit::new(b"Three".to_string(), vector[rpr::new_vocalist_role(option::none())]);
    let four = credit::new(b"Four".to_string(), vector[rpr::new_producer_role(option::none())]);

    // The first removal leaves the dynamic-field record allocated, so the
    // re-add lands in the retained empty record.
    credits::add_credit(&mut rec, &cap, &p1, one);
    credits::remove_credit(&mut rec, &cap, id1);
    assert!(credits::has_credits(&rec));
    assert_eq!(credits::credits(&rec).length(), 0);
    credits::add_credit(&mut rec, &cap, &p1, one_again);
    credits::add_credit(&mut rec, &cap, &p2, two);
    credits::add_credit(&mut rec, &cap, &p3, three);
    credits::add_credit(&mut rec, &cap, &p4, four);
    assert_eq!(credits::credits(&rec).get_idx(&id1), 0);
    assert_eq!(credits::credits(&rec).get_idx(&id2), 1);
    assert_eq!(credits::credits(&rec).get_idx(&id3), 2);
    assert_eq!(credits::credits(&rec).get_idx(&id4), 3);

    // Removing the middle entry shifts the survivors left; re-adding that
    // party appends it after the survivors rather than restoring index 1.
    credits::remove_credit(&mut rec, &cap, id2);
    assert_eq!(credits::credits(&rec).get_idx(&id1), 0);
    assert_eq!(credits::credits(&rec).get_idx(&id3), 1);
    assert_eq!(credits::credits(&rec).get_idx(&id4), 2);
    credits::add_credit(&mut rec, &cap, &p2, two_again);
    assert_eq!(credits::credits(&rec).get_idx(&id1), 0);
    assert_eq!(credits::credits(&rec).get_idx(&id3), 1);
    assert_eq!(credits::credits(&rec).get_idx(&id4), 2);
    assert_eq!(credits::credits(&rec).get_idx(&id2), 3);

    // The ordered add/remove stream is enough to replay that order; the
    // credits themselves are read from storage.
    assert_eq!(credits::credits(&rec)[&id1], one_again);
    assert_eq!(credits::credits(&rec)[&id2], two_again);
    assert_eq!(credits::credits(&rec)[&id3], three);
    assert_eq!(credits::credits(&rec)[&id4], four);
    let added = events_by_type<credits::RecordingCreditAddedEvent<RecordingShare>>();
    assert_eq!(added.length(), 6);
    assert_added(&added[0], recording_id, id1.to_address(), &one);
    assert_added(&added[1], recording_id, id1.to_address(), &one_again);
    assert_added(&added[2], recording_id, id2.to_address(), &two);
    assert_added(&added[3], recording_id, id3.to_address(), &three);
    assert_added(&added[4], recording_id, id4.to_address(), &four);
    assert_added(&added[5], recording_id, id2.to_address(), &two_again);

    let removed = events_by_type<credits::RecordingCreditRemovedEvent<RecordingShare>>();
    assert_eq!(removed.length(), 2);
    let (event_object, event_party) = credits::credit_removed_event_fields(&removed[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, id1.to_address());
    let (event_object, event_party) = credits::credit_removed_event_fields(&removed[1]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, id2.to_address());

    destroy(rec); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c); destroy(p3); destroy(p3c); destroy(p4); destroy(p4c);
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

/// The largest credit event: ten distinct instrumentalist roles, each with a
/// 100-byte instrument name and a level (1 + 1 + 100 + 2 bytes apiece), plus
/// two addresses and the vector length. The 200-byte display name stays in
/// storage. Designation events are two addresses regardless of the credit.
#[test]
fun event_bcs_sizes_match_declared_maxima() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let (p, pc) = mk_party(b"Max", ts.ctx());
    let max_credit = credit::new(long_string(200), vector[
        rpr::new_instrumentalist_role(long_string(100), option::some(rpr::new_additional_role_level())),
        rpr::new_instrumentalist_role(long_string(100), option::some(rpr::new_assistant_role_level())),
        rpr::new_instrumentalist_role(long_string(100), option::some(rpr::new_associate_role_level())),
        rpr::new_instrumentalist_role(long_string(100), option::some(rpr::new_backing_role_level())),
        rpr::new_instrumentalist_role(long_string(100), option::some(rpr::new_executive_role_level())),
        rpr::new_instrumentalist_role(long_string(100), option::some(rpr::new_featured_role_level())),
        rpr::new_instrumentalist_role(long_string(100), option::some(rpr::new_lead_role_level())),
        rpr::new_instrumentalist_role(long_string(100), option::some(rpr::new_primary_role_level())),
        rpr::new_instrumentalist_role(long_string(100), option::some(rpr::new_principal_role_level())),
        rpr::new_instrumentalist_role(other_long_string(100), option::some(rpr::new_principal_role_level())),
    ]);
    let pid = object::id(&p);
    credits::add_credit(&mut rec, &cap, &p, max_credit);
    let added = events_by_type<credits::RecordingCreditAddedEvent<RecordingShare>>();
    let (_, _, roles) = credits::credit_added_event_fields(&added[0]);
    assert_eq!(roles, *credits::credits(&rec)[&pid].roles());
    assert_eq!(to_bytes(&added[0]).length(), 32 + 32 + 1 + 10 * 104);
    credits::add_primary_artist(&mut rec, &cap, &p);
    let primary_added = events_by_type<credits::RecordingPrimaryArtistAddedEvent<RecordingShare>>();
    assert_eq!(to_bytes(&primary_added[0]).length(), 64);
    credits::remove_primary_artist(&mut rec, &cap, pid);
    let primary_removed = events_by_type<credits::RecordingPrimaryArtistRemovedEvent<RecordingShare>>();
    assert_eq!(to_bytes(&primary_removed[0]).length(), 64);
    credits::add_featured_artist(&mut rec, &cap, &p);
    let featured_added = events_by_type<credits::RecordingFeaturedArtistAddedEvent<RecordingShare>>();
    assert_eq!(to_bytes(&featured_added[0]).length(), 64);
    credits::remove_featured_artist(&mut rec, &cap, pid);
    let featured_removed = events_by_type<credits::RecordingFeaturedArtistRemovedEvent<RecordingShare>>();
    assert_eq!(to_bytes(&featured_removed[0]).length(), 64);
    credits::remove_credit(&mut rec, &cap, pid);
    let removed = events_by_type<credits::RecordingCreditRemovedEvent<RecordingShare>>();
    assert_eq!(to_bytes(&removed[0]).length(), 64);
    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}
