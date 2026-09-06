// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_credits::credits_tests;

use miso::recording::{Self, Recording, RecordingAdminCap};
use miso::test_helpers::{Self, RecordingShare, CompositionShare};
use miso_credit::credit;
use partyos::party::{Self, Party, PartyAdminCap};
use recording_credits::recording_credits as credits;
use recording_credits::recording_party_role as rpr;
use std::unit_test::{assert_eq, destroy};
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
    let rec_id = object::id(&rec);
    let (p, pc) = mk_party(b"Alice", ts.ctx());
    let pid = object::id(&p);

    credits::add_credit(
        &mut rec,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]),
    );

    let events = event::events_by_type<credits::CreditAddedEvent>();
    assert_eq!(events.length(), 1);
    let (recording_id, party_id, c) = credits::credit_added_event_fields(&events[0]);
    assert_eq!(recording_id, rec_id);
    assert_eq!(party_id, pid);
    assert_eq!(c, credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun remove_credit_emits_the_removed_credit() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let rec_id = object::id(&rec);
    let (p, pc) = mk_party(b"Alice", ts.ctx());
    let pid = object::id(&p);
    credits::add_credit(
        &mut rec,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]),
    );

    credits::remove_credit(&mut rec, &cap, pid);

    let events = event::events_by_type<credits::CreditRemovedEvent>();
    assert_eq!(events.length(), 1);
    let (recording_id, party_id, c) = credits::credit_removed_event_fields(&events[0]);
    assert_eq!(recording_id, rec_id);
    assert_eq!(party_id, pid);
    assert_eq!(c, credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));

    // The party held no primary/featured designation, so the cascade stays silent.
    assert_eq!(event::events_by_type<credits::PrimaryArtistRemovedEvent>().length(), 0);
    assert_eq!(event::events_by_type<credits::FeaturedArtistRemovedEvent>().length(), 0);

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun remove_credit_cascade_emits_artist_removals() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let rec_id = object::id(&rec);
    let (p1, p1c) = mk_party(b"Lead", ts.ctx());
    let (p2, p2c) = mk_party(b"Guest", ts.ctx());
    credits::add_credit(&mut rec, &cap, &p1,
        credit::new(b"Lead".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &p2,
        credit::new(b"Guest".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p1);
    credits::add_featured_artist(&mut rec, &cap, &p2);

    credits::remove_credit(&mut rec, &cap, object::id(&p1));
    credits::remove_credit(&mut rec, &cap, object::id(&p2));

    // Removing a credited primary/featured artist ends that designation too;
    // an indexer must hear about it without diffing object state.
    let primaries = event::events_by_type<credits::PrimaryArtistRemovedEvent>();
    assert_eq!(primaries.length(), 1);
    let (rid, pid) = credits::primary_artist_removed_event_fields(&primaries[0]);
    assert_eq!(rid, rec_id);
    assert_eq!(pid, object::id(&p1));

    let featured = event::events_by_type<credits::FeaturedArtistRemovedEvent>();
    assert_eq!(featured.length(), 1);
    let (rid, pid) = credits::featured_artist_removed_event_fields(&featured[0]);
    assert_eq!(rid, rec_id);
    assert_eq!(pid, object::id(&p2));

    destroy(rec); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test]
fun primary_artist_changes_emit_events() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rec, cap) = mk_recording(ts.ctx());
    let rec_id = object::id(&rec);
    let (p, pc) = mk_party(b"Alice", ts.ctx());
    let pid = object::id(&p);
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));

    credits::add_primary_artist(&mut rec, &cap, &p);

    let added = event::events_by_type<credits::PrimaryArtistAddedEvent>();
    assert_eq!(added.length(), 1);
    let (rid, pid_ev) = credits::primary_artist_added_event_fields(&added[0]);
    assert_eq!(rid, rec_id);
    assert_eq!(pid_ev, pid);

    credits::remove_primary_artist(&mut rec, &cap, pid);

    let removed = event::events_by_type<credits::PrimaryArtistRemovedEvent>();
    assert_eq!(removed.length(), 1);
    let (rid, pid_ev) = credits::primary_artist_removed_event_fields(&removed[0]);
    assert_eq!(rid, rec_id);
    assert_eq!(pid_ev, pid);

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

// === Additional coverage: validation, reference, and conflict-guard paths ===
// Single-transaction `test_scenario` style throughout — these are cap-gated
// mutations on one actor's own (unshared) recording, so a second sender or a
// shared-object round trip would prove nothing beyond what `mk_recording`
// already gives us. The published+shared, multi-sender shape lives in
// `recording_credits_e2e_tests.move`.

// NOTE on EMinRolesNotMet (20): `add_credit`'s own `roles().length() >=
// MIN_ROLES_PER_CREDIT` guard is unreachable from any test. `Credit<Role>`
// can only be constructed via `miso_credit::credit::new`, which already
// enforces `roles.length() >= MIN_ROLES` (its own `ENoRoles`, code 32) before
// a `Credit` value can exist at all — there is no way to hand `add_credit` a
// zero-role credit to trip its defensive duplicate of the same rule. Left
// as-is per the "do not contort the code" guidance; see the final report.

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
    let rec_id = object::id(&rec);
    let (p, pc) = mk_party(b"Alice", ts.ctx());
    let pid = object::id(&p);
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));

    credits::add_featured_artist(&mut rec, &cap, &p);

    let added = event::events_by_type<credits::FeaturedArtistAddedEvent>();
    assert_eq!(added.length(), 1);
    let (rid, pid_ev) = credits::featured_artist_added_event_fields(&added[0]);
    assert_eq!(rid, rec_id);
    assert_eq!(pid_ev, pid);

    credits::remove_featured_artist(&mut rec, &cap, pid);

    let removed = event::events_by_type<credits::FeaturedArtistRemovedEvent>();
    assert_eq!(removed.length(), 1);
    let (rid, pid_ev) = credits::featured_artist_removed_event_fields(&removed[0]);
    assert_eq!(rid, rec_id);
    assert_eq!(pid_ev, pid);

    destroy(rec); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}
