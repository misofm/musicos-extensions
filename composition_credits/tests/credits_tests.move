// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Add/remove mechanics, guard order, event payloads, and the production
/// published-and-shared shape for `composition_credits`. Every write that
/// would leave the record unchanged — re-crediting a party, removing an
/// uncredited one — aborts rather than silently passing, so the no-op rule is
/// covered by the abort tests.
#[test_only]
module composition_credits::credits_tests;

use composition_credits::composition_party_role as cpr;
use composition_credits::composition_credits as credits;
use credit::credit;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::test_helpers::{Self, CompositionShare};
use partyos::party::{Self, Party, PartyAdminCap};
use std::string::String;
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;
use sui::test_scenario;

const ARTIST: address = @0xA1;

public struct OtherCompositionShare has copy, drop, store {}

fun mk_composition(
    ctx: &mut TxContext,
): (Composition<CompositionShare>, CompositionAdminCap<CompositionShare>) {
    composition::new_for_testing(1500, ctx)
}

fun mk_other_composition(
    ctx: &mut TxContext,
): (Composition<OtherCompositionShare>, CompositionAdminCap<OtherCompositionShare>) {
    composition::new_for_testing<OtherCompositionShare>(1500, ctx)
}

fun mk_party(name: vector<u8>, ctx: &mut TxContext): (Party, PartyAdminCap) {
    party::new(party::new_individual_kind(), name.to_string(), ctx)
}

fun long_string(len: u64): String {
    let mut bytes = vector[];
    len.do!(|_| bytes.push_back(65));
    bytes.to_string()
}

#[test]
fun add_credit_attaches_and_reads_back() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut comp, cap) = mk_composition(ts.ctx());
    assert!(!credits::has_credits(&comp));

    let (p1, p1c) = mk_party(b"Alice", ts.ctx());
    let alice = credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]);
    credits::add_credit(&mut comp, &cap, &p1, alice);

    assert!(credits::has_credits(&comp));
    assert_eq!(credits::credits(&comp).length(), 1);
    assert_eq!(credits::credits(&comp)[&object::id(&p1)], alice);
    let added = events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    assert_eq!(added.length(), 1);
    let (_, first_party, first_roles) = credits::added_event_fields(&added[0]);
    assert_eq!(first_party, object::id(&p1).to_address());
    assert_eq!(first_roles, vector[cpr::new_composer_role()]);

    let (p2, p2c) = mk_party(b"Bob", ts.ctx());
    let bob = credit::new(b"Bob".to_string(), vector[cpr::new_lyricist_role()]);
    credits::add_credit(&mut comp, &cap, &p2, bob);
    assert_eq!(credits::credits(&comp).length(), 2);
    let added = events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    assert_eq!(added.length(), 2);
    let (_, second_party, second_roles) = credits::added_event_fields(&added[1]);
    assert_eq!(second_party, object::id(&p2).to_address());
    assert_eq!(second_roles, vector[cpr::new_lyricist_role()]);

    destroy(comp); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    ts.end();
}

#[test, expected_failure(abort_code = credits::EPartyAlreadyCredited)]
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

/// Re-adding the exact credit already stored is not a silent no-op: the
/// duplicate-party guard fires before any comparison of values.
#[test, expected_failure(abort_code = credits::EPartyAlreadyCredited)]
fun add_credit_rejects_identical_credit() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut comp, cap) = mk_composition(ts.ctx());
    let (p, _pc) = mk_party(b"Alice", ts.ctx());
    let alice = credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]);
    credits::add_credit(&mut comp, &cap, &p, alice);
    credits::add_credit(&mut comp, &cap, &p, alice);
    abort
}

#[test, expected_failure(abort_code = credits::EExceedsMaxRoles)]
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
    let (p1, p1c) = mk_party(b"Alice", ts.ctx());
    let (p2, p2c) = mk_party(b"Bob", ts.ctx());
    let (p3, p3c) = mk_party(b"Cara", ts.ctx());
    credits::add_credit(
        &mut comp,
        &cap,
        &p1,
        credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]),
    );
    credits::add_credit(
        &mut comp,
        &cap,
        &p2,
        credit::new(b"Bob".to_string(), vector[cpr::new_lyricist_role()]),
    );
    credits::add_credit(
        &mut comp,
        &cap,
        &p3,
        credit::new(b"Cara".to_string(), vector[cpr::new_songwriter_role()]),
    );
    assert_eq!(credits::credits(&comp).length(), 3);

    // Removing the middle entry shifts the survivors left in stored order;
    // the event names only the removed party, and an indexer replaying the
    // ordered add/remove stream reaches the same order.
    credits::remove_credit(&mut comp, &cap, object::id(&p2));
    assert_eq!(credits::credits(&comp).length(), 2);
    assert_eq!(credits::credits(&comp).get_idx(&object::id(&p1)), 0);
    assert_eq!(credits::credits(&comp).get_idx(&object::id(&p3)), 1);
    let removed = events_by_type<credits::CompositionCreditRemovedEvent<CompositionShare>>();
    assert_eq!(removed.length(), 1);
    let (_, event_party) = credits::removed_event_fields(&removed[0]);
    assert_eq!(event_party, object::id(&p2).to_address());

    credits::remove_credit(&mut comp, &cap, object::id(&p1));
    credits::remove_credit(&mut comp, &cap, object::id(&p3));
    assert_eq!(credits::credits(&comp).length(), 0);
    let removed = events_by_type<credits::CompositionCreditRemovedEvent<CompositionShare>>();
    assert_eq!(removed.length(), 3);
    let (_, event_party) = credits::removed_event_fields(&removed[1]);
    assert_eq!(event_party, object::id(&p1).to_address());
    let (_, event_party) = credits::removed_event_fields(&removed[2]);
    assert_eq!(event_party, object::id(&p3).to_address());

    // The retained empty record lets a party be re-added at index 0.
    assert!(credits::has_credits(&comp));
    let bob_again = credit::new(b"Bob Again".to_string(), vector[cpr::new_translator_role()]);
    credits::add_credit(&mut comp, &cap, &p2, bob_again);
    assert_eq!(credits::credits(&comp).length(), 1);
    assert_eq!(credits::credits(&comp).get_idx(&object::id(&p2)), 0);
    let added = events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    let (_, event_party, event_roles) = credits::added_event_fields(&added[3]);
    assert_eq!(event_party, object::id(&p2).to_address());
    assert_eq!(event_roles, vector[cpr::new_translator_role()]);

    // Views and test accessors are pure reads and do not add event records.
    assert!(credits::has_credits(&comp));
    assert_eq!(credits::credits(&comp).length(), 1);
    assert_eq!(events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>().length(), 4);
    assert_eq!(events_by_type<credits::CompositionCreditRemovedEvent<CompositionShare>>().length(), 3);

    destroy(comp); destroy(cap); destroy(p1); destroy(p1c); destroy(p2); destroy(p2c);
    destroy(p3); destroy(p3c);
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
    let roles = vector[
        cpr::new_adapter_role(),
        cpr::new_arranger_role(),
        cpr::new_composer_role(),
        cpr::new_lyricist_role(),
        cpr::new_translator_role(),
    ];
    let credit = credit::new(b"Alice".to_string(), roles);

    credits::add_credit(&mut comp, &cap, &p, credit);

    let events = events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    assert_eq!(events.length(), 1);
    let (event_composition_id, event_party_id, event_roles) = credits::added_event_fields(&events[0]);
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_party_id, party_id.to_address());
    assert_eq!(event_roles, roles);
    // Two addresses and five unit-variant roles (one byte each): the maximum.
    assert_eq!(to_bytes(&events[0]).length(), 32 + 32 + 1 + 5);

    // The phantom share type keeps independent composition event streams
    // separate even when their payload layouts are identical.
    let (mut other_comp, other_cap) = mk_other_composition(ctx);
    let (other_party, other_party_cap) = mk_party(b"Other", ctx);
    credits::add_credit(
        &mut other_comp,
        &other_cap,
        &other_party,
        credit::new(b"Other".to_string(), vector[cpr::new_lyricist_role()]),
    );
    assert_eq!(events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>().length(), 1);
    assert_eq!(events_by_type<credits::CompositionCreditAddedEvent<OtherCompositionShare>>().length(), 1);

    // A 200-byte display name stays in storage and leaves the size alone.
    let (max_party, max_party_cap) = mk_party(b"Max", ctx);
    credits::add_credit(&mut comp, &cap, &max_party, credit::new(long_string(200), roles));
    let max_events = events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    assert_eq!(to_bytes(&max_events[1]).length(), 70);
    assert_eq!(credits::credits(&comp)[&object::id(&max_party)].display_name().length(), 200);

    destroy(comp); destroy(cap); destroy(p); destroy(pc);
    destroy(other_comp); destroy(other_cap); destroy(other_party); destroy(other_party_cap);
    destroy(max_party); destroy(max_party_cap);
}

#[test]
fun remove_credit_emits_the_removed_party() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let (p, pc) = mk_party(b"Alice", ctx);
    let composition_id = object::id(&comp);
    let party_id = object::id(&p);
    let credit = credit::new(b"Alice".to_string(), vector[cpr::new_composer_role()]);
    credits::add_credit(&mut comp, &cap, &p, credit);

    credits::remove_credit(&mut comp, &cap, party_id);

    let events = events_by_type<credits::CompositionCreditRemovedEvent<CompositionShare>>();
    assert_eq!(events.length(), 1);
    let (event_composition_id, event_party_id) = credits::removed_event_fields(&events[0]);
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_party_id, party_id.to_address());
    assert_eq!(to_bytes(&events[0]).length(), 64);
    assert_eq!(events_by_type<credits::CompositionCreditRemovedEvent<OtherCompositionShare>>().length(), 0);

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
    comp.publish(&cap);

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

#[test, expected_failure(abort_code = credits::EMaxCreditsExceeded)]
/// `MAX_CREDITS` (50) is enforced exactly at the boundary: the 51st add
/// aborts `EMaxCreditsExceeded`.
fun add_credit_rejects_when_max_credits_reached() {
    let mut ts = test_scenario::begin(ARTIST);
    let (mut comp, cap) = mk_composition(ts.ctx());

    let (first_party, first_party_cap) = mk_party(b"P", ts.ctx());
    credits::add_credit(
        &mut comp,
        &cap,
        &first_party,
        credit::new(b"P".to_string(), vector[cpr::new_composer_role()]),
    );
    49u64.do!(|_| {
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

    // Capacity is checked before duplicate-party conflict, so this duplicate
    // at a full map must still abort with EMaxCreditsExceeded.
    credits::add_credit(
        &mut comp,
        &cap,
        &first_party,
        credit::new(b"P again".to_string(), vector[cpr::new_composer_role()]),
    );
    destroy(first_party_cap);
    abort
}

#[test, expected_failure(abort_code = credits::ENoCredits)]
fun credits_view_aborts_when_none_attached() {
    let ctx = &mut tx_context::dummy();
    let (comp, _cap) = mk_composition(ctx);
    credits::credits(&comp);
    abort
}

#[test, expected_failure(abort_code = credits::ENoCredits)]
fun remove_credit_aborts_when_none_attached() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = mk_composition(ctx);
    let fake_party_id = test_helpers::fake_id(ctx);
    credits::remove_credit(&mut comp, &cap, fake_party_id);
    abort
}

#[test, expected_failure(abort_code = credits::EPartyNotCredited)]
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
