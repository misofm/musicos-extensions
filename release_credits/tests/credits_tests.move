// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_credits::credits_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use credit::credit;
use partyos::party::{Self, Party, PartyAdminCap};
use release_credits::release_credits as credits;
use release_credits::release_party_role as rpr;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const ARTIST: address = @0xA1;

fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    release::new_for_testing(b"Album".to_string(), vector[], ctx)
}

fun mk_party(name: vector<u8>, ctx: &mut TxContext): (Party, PartyAdminCap) {
    let clock = sui::clock::create_for_testing(ctx);
    let (party, cap) = party::new(party::new_individual_kind(), name.to_string(), &clock, ctx);
    clock.destroy_for_testing();
    (party, cap)
}

fun name_of_length(length: u64): std::string::String {
    let mut bytes = vector[];
    let mut i = 0;
    while (i < length) {
        bytes.push_back(88u8);
        i = i + 1;
    };
    bytes.to_string()
}

#[test]
fun add_credit_attaches_and_reads_back() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    assert!(!credits::has_credits(&rel));

    let (p1, p1c) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(
        &mut rel,
        &cap,
        &p1,
        credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]),
    );

    assert!(credits::has_credits(&rel));
    assert_eq!(credits::credits(&rel).length(), 1);

    let (p2, p2c) = mk_party(b"Bob", ts.ctx());
    credits::add_credit(
        &mut rel,
        &cap,
        &p2,
        credit::new(b"Bob".to_string(), vector[rpr::new_featured_role()]),
    );
    assert_eq!(credits::credits(&rel).length(), 2);

    destroy(rel); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test, expected_failure(abort_code = 40, location = release_credits::release_credits)] // EPartyAlreadyCredited
fun add_credit_rejects_duplicate_party() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(
        &mut rel,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]),
    );
    credits::add_credit(
        &mut rel,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_featured_role()]),
    );
    abort
}

#[test, expected_failure(abort_code = 53, location = release_credits::release_credits)] // EInvalidCreditRoleCount
fun add_credit_rejects_multiple_roles() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(
        &mut rel,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[
            rpr::new_primary_role(),
            rpr::new_featured_role(), // 2 != CREDIT_ROLE_COUNT (1)
        ]),
    );
    abort
}

#[test, expected_failure(abort_code = 32, location = release_credits::release_credits)] // EMaxCreditsExceeded (mirrors MAX_CREDITS = 50)
fun add_credit_rejects_the_fifty_first_credit() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());

    let mut i = 0u64;
    while (i < 50) {
        let (p, pc) = mk_party(b"Party", ts.ctx());
        credits::add_credit(
            &mut rel,
            &cap,
            &p,
            credit::new(b"Party".to_string(), vector[rpr::new_primary_role()]),
        );
        destroy(p);
        destroy(pc);
        i = i + 1;
    };
    assert_eq!(credits::credits(&rel).length(), 50);

    let (p51, _p51c) = mk_party(b"Party51", ts.ctx());
    credits::add_credit(
        &mut rel,
        &cap,
        &p51,
        credit::new(b"Party51".to_string(), vector[rpr::new_primary_role()]),
    );
    abort
}

#[test, expected_failure(abort_code = 32, location = release_credits::release_credits)]
fun add_credit_capacity_precedes_duplicate_party() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (first_party, _first_cap) = mk_party(b"First", ts.ctx());
    credits::add_credit(
        &mut rel,
        &cap,
        &first_party,
        credit::new(b"First".to_string(), vector[rpr::new_primary_role()]),
    );
    let mut i = 1u64;
    while (i < 50) {
        let (party, party_cap) = mk_party(b"Party", ts.ctx());
        credits::add_credit(
            &mut rel,
            &cap,
            &party,
            credit::new(b"Party".to_string(), vector[rpr::new_primary_role()]),
        );
        destroy(party);
        destroy(party_cap);
        i = i + 1;
    };
    // The duplicate is checked only after the capacity guard.
    credits::add_credit(
        &mut rel,
        &cap,
        &first_party,
        credit::new(b"Changed".to_string(), vector[rpr::new_featured_role()]),
    );
    abort
}

#[test, expected_failure(abort_code = 50, location = release_credits::release_credits)] // ENoCredits
fun credits_aborts_when_none_attached() {
    let mut ts = test_scenario::begin(ARTIST);
    let (rel, _cap) = mk_release(ts.ctx());
    let _ = credits::credits(&rel);
    abort
}

#[test, expected_failure(abort_code = 52, location = release_credits::release_credits)] // EPartyNotCredited
fun remove_credit_aborts_for_an_uncredited_party() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (p1, _p1c) = mk_party(b"Alice", ts.ctx());
    let (p2, _p2c) = mk_party(b"Bob", ts.ctx());
    credits::add_credit(
        &mut rel,
        &cap,
        &p1,
        credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]),
    );
    credits::remove_credit(&mut rel, &cap, object::id(&p2));
    abort
}

#[test, expected_failure(abort_code = 50, location = release_credits::release_credits)] // ENoCredits (via remove_credit's borrow_mut, distinct call site from credits()'s borrow)
fun remove_credit_aborts_when_no_credits_record_exists() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::remove_credit(&mut rel, &cap, object::id(&p));
    abort
}

#[test]
fun remove_credit_round_trip() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    let pid = object::id(&p);
    credits::add_credit(
        &mut rel,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]),
    );
    assert_eq!(credits::credits(&rel).length(), 1);

    credits::remove_credit(&mut rel, &cap, pid);
    assert_eq!(credits::credits(&rel).length(), 0);

    destroy(rel); destroy(cap); destroy(p); destroy(_pc);
    ts.end();
}

#[test]
fun add_credit_emits_the_full_record() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let rel_id = object::id(&rel);
    let (p1, p1c) = mk_party(b"Alice", ts.ctx());
    let (p2, p2c) = mk_party(b"Bob", ts.ctx());

    credits::add_credit(
        &mut rel,
        &cap,
        &p1,
        credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]),
    );
    credits::add_credit(
        &mut rel,
        &cap,
        &p2,
        credit::new(b"Bob".to_string(), vector[rpr::new_featured_role()]),
    );

    let events = event::events_by_type<credits::ReleaseCreditAddedEvent>();
    assert_eq!(events.length(), 2);

    let (release_id, cap_id, party_id, display_name, role_kind, count_before, count_after,
        credit_index, record_before, record_after) = credits::added_event_fields(&events[0]);
    assert_eq!(release_id, rel_id.to_address());
    assert_eq!(cap_id, object::id(&cap).to_address());
    assert_eq!(party_id, object::id(&p1).to_address());
    assert_eq!(display_name, b"Alice");
    assert_eq!(role_kind, 0);
    assert_eq!(count_before, 0);
    assert_eq!(count_after, 1);
    assert_eq!(credit_index, 0);
    assert!(!record_before);
    assert!(record_after);

    let (release_id, cap_id, party_id, display_name, role_kind, count_before, count_after,
        credit_index, record_before, record_after) = credits::added_event_fields(&events[1]);
    assert_eq!(release_id, rel_id.to_address());
    assert_eq!(cap_id, object::id(&cap).to_address());
    assert_eq!(party_id, object::id(&p2).to_address());
    assert_eq!(display_name, b"Bob");
    assert_eq!(role_kind, 1);
    assert_eq!(count_before, 1);
    assert_eq!(count_after, 2);
    assert_eq!(credit_index, 1);
    assert!(record_before);
    assert!(record_after);

    destroy(rel); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test]
fun remove_credit_emits_the_removed_record() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let rel_id = object::id(&rel);
    let (p, pc) = mk_party(b"Alice", ts.ctx());
    let pid = object::id(&p);

    credits::add_credit(
        &mut rel,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]),
    );
    credits::remove_credit(&mut rel, &cap, pid);

    let events = event::events_by_type<credits::ReleaseCreditRemovedEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(credits::removed_event_bcs(&events[0]).length(), 129);
    let (release_id, cap_id, party_id, display_name, role_kind, count_before, count_after,
        credit_index, record_before, record_after) = credits::removed_event_fields(&events[0]);
    assert_eq!(release_id, rel_id.to_address());
    assert_eq!(cap_id, object::id(&cap).to_address());
    assert_eq!(party_id, pid.to_address());
    assert_eq!(display_name, b"Alice");
    assert_eq!(role_kind, 0);
    assert_eq!(count_before, 1);
    assert_eq!(count_after, 0);
    assert_eq!(credit_index, 0);
    assert!(record_before);
    assert!(record_after);

    destroy(rel); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun role_names_are_stable_pascal_case_tokens() {
    assert_eq!(rpr::new_primary_role().name(), b"Primary".to_string());
    assert_eq!(rpr::new_featured_role().name(), b"Featured".to_string());
    assert_eq!(event::events_by_type<credits::ReleaseCreditAddedEvent>().length(), 0);
    assert_eq!(event::events_by_type<credits::ReleaseCreditRemovedEvent>().length(), 0);
}

#[test]
fun event_uses_credit_display_name_and_role_kind() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (party, party_cap) = mk_party(b"PartyObjectName", ts.ctx());
    credits::add_credit(
        &mut rel,
        &cap,
        &party,
        credit::new(b"BillingDisplayName".to_string(), vector[rpr::new_featured_role()]),
    );

    let events = event::events_by_type<credits::ReleaseCreditAddedEvent>();
    let (_, cap_id, party_id, display_name, role_kind, before, after, index, existed, exists) =
        credits::added_event_fields(&events[0]);
    assert_eq!(cap_id, object::id(&cap).to_address());
    assert_eq!(party_id, object::id(&party).to_address());
    assert_eq!(display_name, b"BillingDisplayName");
    assert_eq!(role_kind, 1);
    assert_eq!(before, 0);
    assert_eq!(after, 1);
    assert_eq!(index, 0);
    assert!(!existed);
    assert!(exists);

    destroy(rel); destroy(cap); destroy(party); destroy(party_cap);
    ts.end();
}

#[test]
fun remove_reports_stable_vecmap_index_and_readd_appends() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (p1, p1c) = mk_party(b"One", ts.ctx());
    let (p2, p2c) = mk_party(b"Two", ts.ctx());
    let (p3, p3c) = mk_party(b"Three", ts.ctx());
    credits::add_credit(&mut rel, &cap, &p1, credit::new(b"One".to_string(), vector[rpr::new_primary_role()]));
    credits::add_credit(&mut rel, &cap, &p2, credit::new(b"Two".to_string(), vector[rpr::new_featured_role()]));
    credits::add_credit(&mut rel, &cap, &p3, credit::new(b"Three".to_string(), vector[rpr::new_primary_role()]));
    credits::remove_credit(&mut rel, &cap, object::id(&p2));

    assert_eq!(credits::credits(&rel).length(), 2);
    assert_eq!(credits::credits(&rel).get_idx(&object::id(&p1)), 0);
    assert_eq!(credits::credits(&rel).get_idx(&object::id(&p3)), 1);
    let removed = event::events_by_type<credits::ReleaseCreditRemovedEvent>();
    let (_, _, removed_party, removed_name, removed_kind, before, after, index, _, _) =
        credits::removed_event_fields(&removed[0]);
    assert_eq!(removed_party, object::id(&p2).to_address());
    assert_eq!(removed_name, b"Two");
    assert_eq!(removed_kind, 1);
    assert_eq!(before, 3);
    assert_eq!(after, 2);
    assert_eq!(index, 1);

    credits::add_credit(
        &mut rel,
        &cap,
        &p2,
        credit::new(b"Two Readded".to_string(), vector[rpr::new_featured_role()]),
    );
    assert_eq!(credits::credits(&rel).get_idx(&object::id(&p2)), 2);
    let added = event::events_by_type<credits::ReleaseCreditAddedEvent>();
    let (_, _, _, name, kind, before, after, index, existed, exists) =
        credits::added_event_fields(&added[3]);
    assert_eq!(name, b"Two Readded");
    assert_eq!(kind, 1);
    assert_eq!(before, 2);
    assert_eq!(after, 3);
    assert_eq!(index, 2);
    assert!(existed);
    assert!(exists);

    destroy(rel); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    destroy(p3); destroy(p3c);
    ts.end();
}

#[test]
fun final_remove_retains_record_and_readd_reports_initialized() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (party, party_cap) = mk_party(b"Solo", ts.ctx());
    let party_id = object::id(&party);
    credits::add_credit(&mut rel, &cap, &party, credit::new(b"First".to_string(), vector[rpr::new_primary_role()]));
    credits::remove_credit(&mut rel, &cap, party_id);
    assert!(credits::has_credits(&rel));
    assert_eq!(credits::credits(&rel).length(), 0);
    let removed = event::events_by_type<credits::ReleaseCreditRemovedEvent>();
    let (_, _, _, _, _, before, after, index, existed, exists) = credits::removed_event_fields(&removed[0]);
    assert_eq!(before, 1);
    assert_eq!(after, 0);
    assert_eq!(index, 0);
    assert!(existed);
    assert!(exists);

    credits::add_credit(&mut rel, &cap, &party, credit::new(b"Second".to_string(), vector[rpr::new_featured_role()]));
    let added = event::events_by_type<credits::ReleaseCreditAddedEvent>();
    let (_, _, _, name, kind, before, after, index, existed, exists) = credits::added_event_fields(&added[1]);
    assert_eq!(name, b"Second");
    assert_eq!(kind, 1);
    assert_eq!(before, 0);
    assert_eq!(after, 1);
    assert_eq!(index, 0);
    assert!(existed);
    assert!(exists);

    destroy(rel); destroy(cap); destroy(party); destroy(party_cap);
    ts.end();
}

#[test]
fun event_bcs_length_matches_uleb_boundaries() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (p1, p1c) = mk_party(b"P1", ts.ctx());
    let (p2, p2c) = mk_party(b"P2", ts.ctx());
    let (p3, p3c) = mk_party(b"P3", ts.ctx());
    credits::add_credit(&mut rel, &cap, &p1, credit::new(name_of_length(1), vector[rpr::new_primary_role()]));
    credits::add_credit(&mut rel, &cap, &p2, credit::new(name_of_length(127), vector[rpr::new_primary_role()]));
    credits::add_credit(&mut rel, &cap, &p3, credit::new(name_of_length(128), vector[rpr::new_primary_role()]));
    let added = event::events_by_type<credits::ReleaseCreditAddedEvent>();
    assert_eq!(credits::added_event_bcs(&added[0]).length(), 125);
    assert_eq!(credits::added_event_bcs(&added[1]).length(), 251);
    assert_eq!(credits::added_event_bcs(&added[2]).length(), 253);

    destroy(rel); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    destroy(p3); destroy(p3c);
    ts.end();
}

#[test]
fun event_bcs_supports_maximum_credit_display_name() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (party, party_cap) = mk_party(b"Party", ts.ctx());
    credits::add_credit(&mut rel, &cap, &party, credit::new(name_of_length(200), vector[rpr::new_featured_role()]));
    let added = event::events_by_type<credits::ReleaseCreditAddedEvent>();
    assert_eq!(credits::added_event_bcs(&added[0]).length(), 325);
    let (_, _, _, display_name, role_kind, _, _, _, _, _) = credits::added_event_fields(&added[0]);
    assert_eq!(display_name.length(), 200);
    assert_eq!(role_kind, 1);
    destroy(rel); destroy(cap); destroy(party); destroy(party_cap);
    ts.end();
}

#[test]
fun views_are_silent_after_mutation() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut rel, cap) = mk_release(ts.ctx());
    let (party, party_cap) = mk_party(b"Viewer", ts.ctx());
    credits::add_credit(&mut rel, &cap, &party, credit::new(b"Viewer".to_string(), vector[rpr::new_primary_role()]));
    assert_eq!(event::events_by_type<credits::ReleaseCreditAddedEvent>().length(), 1);
    assert!(credits::has_credits(&rel));
    assert_eq!(credits::credits(&rel).length(), 1);
    assert_eq!(event::events_by_type<credits::ReleaseCreditAddedEvent>().length(), 1);
    assert_eq!(event::events_by_type<credits::ReleaseCreditRemovedEvent>().length(), 0);
    destroy(rel); destroy(cap); destroy(party); destroy(party_cap);
    ts.end();
}
