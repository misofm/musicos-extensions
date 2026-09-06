// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_credits::credits_tests;

use miso::release::{Self, Release, ReleaseAdminCap};
use miso_credit::credit;
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

    let events = event::events_by_type<credits::CreditAddedEvent>();
    assert_eq!(events.length(), 2);

    let (release_id, party_id, credit) = credits::added_event_fields(&events[0]);
    assert_eq!(release_id, rel_id);
    assert_eq!(party_id, object::id(&p1));
    assert_eq!(credit, credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]));

    let (release_id, party_id, credit) = credits::added_event_fields(&events[1]);
    assert_eq!(release_id, rel_id);
    assert_eq!(party_id, object::id(&p2));
    assert_eq!(credit, credit::new(b"Bob".to_string(), vector[rpr::new_featured_role()]));

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

    let events = event::events_by_type<credits::CreditRemovedEvent>();
    assert_eq!(events.length(), 1);
    let (release_id, party_id, credit) = credits::removed_event_fields(&events[0]);
    assert_eq!(release_id, rel_id);
    assert_eq!(party_id, pid);
    assert_eq!(credit, credit::new(b"Alice".to_string(), vector[rpr::new_primary_role()]));

    destroy(rel); destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test]
fun role_names_are_stable_pascal_case_tokens() {
    assert_eq!(rpr::new_primary_role().name(), b"Primary".to_string());
    assert_eq!(rpr::new_featured_role().name(), b"Featured".to_string());
}
