// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_credits::credits_tests;

use composition_credits::composition_party_role as cpr;
use composition_credits::composition_credits as credits;
use miso::composition::{Self, Composition, CompositionAdminCap};
use miso::test_helpers::{Self, CompositionShare};
use miso_credit::credit;
use partyos::party::{Self, Party, PartyAdminCap};
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const ARTIST: address = @0xA1;

fun mk_composition(
    ctx: &mut TxContext,
): (Composition<CompositionShare>, CompositionAdminCap<CompositionShare>) {
    composition::new_for_testing(b"Song".to_string(), 1500, ctx)
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
    let (mut comp, cap) = mk_composition(ts.ctx());
    assert!(!credits::has_credits(&comp));

    let (p1, p1c) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(
        &mut comp,
        &cap,
        &p1,
        credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]),
    );

    assert!(credits::has_credits(&comp));
    assert_eq!(credits::credits(&comp).length(), 1);

    let (p2, p2c) = mk_party(b"Bob", ts.ctx());
    credits::add_credit(
        &mut comp,
        &cap,
        &p2,
        credit::new(b"Bob".to_string(), vector[cpr::new_lyricist_role()]),
    );
    assert_eq!(credits::credits(&comp).length(), 2);

    destroy(comp); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test, expected_failure(abort_code = 40, location = composition_credits::composition_credits)] // EPartyAlreadyCredited
fun add_credit_rejects_duplicate_party() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut comp, cap) = mk_composition(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(
        &mut comp,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]),
    );
    credits::add_credit(
        &mut comp,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[cpr::new_lyricist_role()]),
    );
    abort
}

#[test, expected_failure(abort_code = 30, location = composition_credits::composition_credits)] // EExceedsMaxRoles
fun add_credit_rejects_too_many_roles() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut comp, cap) = mk_composition(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(
        &mut comp,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[
            cpr::new_adapter_role(),
            cpr::new_arranger_role(),
            cpr::new_composer_role(),
            cpr::new_lyricist_role(),
            cpr::new_songwriter_role(),
            cpr::new_translator_role(), // 6 > MAX_ROLES_PER_CREDIT (5)
        ]),
    );
    abort
}

#[test]
fun remove_credit_round_trip() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut comp, cap) = mk_composition(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    let pid = object::id(&p);
    credits::add_credit(
        &mut comp,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]),
    );
    assert_eq!(credits::credits(&comp).length(), 1);

    credits::remove_credit(&mut comp, &cap, pid);
    assert_eq!(credits::credits(&comp).length(), 0);

    destroy(comp); destroy(cap); destroy(p); destroy(_pc);
    ts.end();
}

// The remaining single-transaction `tx_context::dummy()` tests below check
// event-payload correctness and abort conditions — cap-gated, single-actor
// checks with no shared object and no distinct-sender mechanics to model
// (that production shape is already covered by
// `add_credit_against_published_and_shared_composition` above); scenario
// mechanics would add nothing here.

#[test]
fun add_credit_emits_full_record() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let (p, pc) = mk_party(b"Alice", ctx);
    let composition_id = object::id(&comp);
    let party_id = object::id(&p);
    let credit = credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]);

    credits::add_credit(&mut comp, &cap, &p, credit);

    let events = event::events_by_type<credits::CreditAddedEvent>();
    assert_eq!(events.length(), 1);
    let (event_composition_id, event_party_id, event_credit) =
        credits::added_event_fields(&events[0]);
    assert_eq!(event_composition_id, composition_id);
    assert_eq!(event_party_id, party_id);
    assert_eq!(event_credit, credit);

    destroy(comp); destroy(cap); destroy(p); destroy(pc);
}

#[test]
fun remove_credit_emits_full_record() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let (p, pc) = mk_party(b"Alice", ctx);
    let composition_id = object::id(&comp);
    let party_id = object::id(&p);
    let credit = credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]);
    credits::add_credit(&mut comp, &cap, &p, credit);

    credits::remove_credit(&mut comp, &cap, party_id);

    let events = event::events_by_type<credits::CreditRemovedEvent>();
    assert_eq!(events.length(), 1);
    let (event_composition_id, event_party_id, event_credit) =
        credits::removed_event_fields(&events[0]);
    assert_eq!(event_composition_id, composition_id);
    assert_eq!(event_party_id, party_id);
    assert_eq!(event_credit, credit);

    destroy(comp); destroy(cap); destroy(p); destroy(pc);
}

#[test]
/// Production shape: the composition is created and published — hence
/// shared — in one atomic step (`composition::publish`; core enforces this
/// per its module doc), and the extension operates on it in a later
/// transaction via `take_shared`, not the locally-held fixture the other
/// tests here use.
fun add_credit_against_published_and_shared_composition() {
    let mut ts = test_scenario::begin(ARTIST);
    let (comp, cap) = mk_composition(ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    comp.publish(&cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ARTIST);
    let mut comp = ts.take_shared<Composition<CompositionShare>>();
    let (p, pc) = mk_party(b"Alice", ts.ctx());
    credits::add_credit(
        &mut comp,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]),
    );
    assert_eq!(credits::credits(&comp).length(), 1);

    test_scenario::return_shared(comp);
    destroy(cap); destroy(p); destroy(pc);
    ts.end();
}

#[test, expected_failure(abort_code = 32, location = composition_credits::composition_credits)] // EMaxCreditsExceeded
/// `MAX_CREDITS` (50) is enforced exactly at the boundary: the 51st add
/// aborts `EMaxCreditsExceeded`.
fun add_credit_rejects_when_max_credits_reached() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut comp, cap) = mk_composition(ts.ctx());

    50u64.do!(|_| {
        let (p, pc) = mk_party(b"P", ts.ctx());
        credits::add_credit(
            &mut comp,
            &cap,
            &p,
            credit::new(b"P".to_string(), vector[cpr::new_composer_role()]),
        );
        destroy(p);
        destroy(pc);
    });
    assert_eq!(credits::credits(&comp).length(), 50);

    let (p, pc) = mk_party(b"Overflow", ts.ctx());
    credits::add_credit(
        &mut comp,
        &cap,
        &p,
        credit::new(b"Overflow".to_string(), vector[cpr::new_composer_role()]),
    );
    destroy(pc);
    abort
}

#[test, expected_failure(abort_code = 50, location = composition_credits::composition_credits)] // ENoCredits
fun credits_view_aborts_when_none_attached() {
    let ctx = &mut tx_context::dummy();
    let (comp, _cap) = mk_composition(ctx);
    credits::credits(&comp);
    abort
}

#[test, expected_failure(abort_code = 50, location = composition_credits::composition_credits)] // ENoCredits
fun remove_credit_aborts_when_none_attached() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let fake_party_id = test_helpers::fake_id(ctx);
    credits::remove_credit(&mut comp, &cap, fake_party_id);
    abort
}

#[test, expected_failure(abort_code = 52, location = composition_credits::composition_credits)] // EPartyNotCredited
fun remove_credit_rejects_uncredited_party() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let (p, _pc) = mk_party(b"Alice", ctx);
    credits::add_credit(
        &mut comp,
        &cap,
        &p,
        credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]),
    );

    let fake_party_id = test_helpers::fake_id(ctx);
    credits::remove_credit(&mut comp, &cap, fake_party_id);
    abort
}
