// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_credits::credits_tests;

use composition_credits::composition_party_role as cpr;
use composition_credits::composition_credits as credits;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::test_helpers::{Self, CompositionShare};
use credit::credit;
use partyos::party::{Self, Party, PartyAdminCap};
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;
use sui::test_scenario;

const ARTIST: address = @0xA1;

public struct OtherCompositionShare has copy, drop, store {}

fun mk_composition(
    ctx: &mut TxContext,
): (Composition<CompositionShare>, CompositionAdminCap<CompositionShare>) {
    composition::new_for_testing(b"Song".to_string(), 1500, ctx)
}

fun mk_other_composition(
    ctx: &mut TxContext,
): (Composition<OtherCompositionShare>, CompositionAdminCap<OtherCompositionShare>) {
    composition::new_for_testing<OtherCompositionShare>(b"Other Song".to_string(), 1500, ctx)
}

fun mk_party(name: vector<u8>, ctx: &mut TxContext): (Party, PartyAdminCap) {
    let clock = sui::clock::create_for_testing(ctx);
    let (party, cap) = party::new(party::new_individual_kind(), name.to_string(), &clock, ctx);
    clock.destroy_for_testing();
    (party, cap)
}

fun max_custom_name(suffix: u8): std::string::String {
    let mut bytes = *test_helpers::long_string(99).as_bytes();
    bytes.push_back(suffix);
    bytes.to_string()
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
    let added = event::events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    assert_eq!(added.length(), 1);
    let (_, _, first_party, first_name, first_kinds, first_custom_names, first_before, first_after,
        first_index, first_record_before, first_record_after) =
        credits::added_event_fields(&added[0]);
    assert_eq!(first_party, object::id(&p1).to_address());
    assert_eq!(first_name, b"Alice");
    assert_eq!(first_kinds, vector[2u8]);
    assert_eq!(first_custom_names, vector[b""]);
    assert_eq!(first_before, 0);
    assert_eq!(first_after, 1);
    assert_eq!(first_index, 0);
    assert!(!first_record_before);
    assert!(first_record_after);

    let (p2, p2c) = mk_party(b"Bob", ts.ctx());
    credits::add_credit(
        &mut comp,
        &cap,
        &p2,
        credit::new(
            b"Bob".to_string(),
            vector[cpr::new_custom_role(b"Composer".to_string())],
        ),
    );
    assert_eq!(credits::credits(&comp).length(), 2);
    let added = event::events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    assert_eq!(added.length(), 2);
    let (_, _, second_party, second_name, second_kinds, second_custom_names, second_before,
        second_after, second_index, second_record_before, second_record_after) =
        credits::added_event_fields(&added[1]);
    assert_eq!(second_party, object::id(&p2).to_address());
    assert_eq!(second_name, b"Bob");
    assert_eq!(second_kinds, vector[6u8]);
    assert_eq!(second_custom_names, vector[b"Composer"]);
    assert_eq!(second_before, 1);
    assert_eq!(second_after, 2);
    assert_eq!(second_index, 1);
    assert!(second_record_before);
    assert!(second_record_after);

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

    // Removing the middle entry reports its pre-removal insertion index.
    credits::remove_credit(&mut comp, &cap, object::id(&p2));
    assert_eq!(credits::credits(&comp).length(), 2);
    let removed = event::events_by_type<credits::CompositionCreditRemovedEvent<CompositionShare>>();
    assert_eq!(removed.length(), 1);
    let (_, _, event_party, event_name, event_kinds, event_custom_names, before, after, index,
        record_before, record_after) = credits::removed_event_fields(&removed[0]);
    assert_eq!(event_party, object::id(&p2).to_address());
    assert_eq!(event_name, b"Bob");
    assert_eq!(event_kinds, vector[3u8]);
    assert_eq!(event_custom_names, vector[b""]);
    assert_eq!(before, 3);
    assert_eq!(after, 2);
    assert_eq!(index, 1);
    assert!(record_before);
    assert!(record_after);

    // Removing the first entry leaves the former third entry at index zero.
    credits::remove_credit(&mut comp, &cap, object::id(&p1));
    credits::remove_credit(&mut comp, &cap, object::id(&p3));
    assert_eq!(credits::credits(&comp).length(), 0);
    let removed = event::events_by_type<credits::CompositionCreditRemovedEvent<CompositionShare>>();
    assert_eq!(removed.length(), 3);
    let (_, _, _, _, _, _, before, after, index, record_before, record_after) =
        credits::removed_event_fields(&removed[1]);
    assert_eq!(before, 2);
    assert_eq!(after, 1);
    assert_eq!(index, 0);
    assert!(record_before);
    assert!(record_after);
    let (_, _, event_party, event_name, event_kinds, _, before, after, index, record_before,
        record_after) = credits::removed_event_fields(&removed[2]);
    assert_eq!(event_party, object::id(&p3).to_address());
    assert_eq!(event_name, b"Cara");
    assert_eq!(event_kinds, vector[4u8]);
    assert_eq!(before, 1);
    assert_eq!(after, 0);
    assert_eq!(index, 0);
    assert!(record_before);
    assert!(record_after);

    // The retained empty record lets a party be re-added at insertion index 0.
    assert!(credits::has_credits(&comp));
    credits::add_credit(
        &mut comp,
        &cap,
        &p2,
        credit::new(b"Bob Again".to_string(), vector[cpr::new_translator_role()]),
    );
    assert_eq!(credits::credits(&comp).length(), 1);
    let added = event::events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    let (_, _, event_party, event_name, event_kinds, event_custom_names, before, after, index,
        record_before, record_after) = credits::added_event_fields(&added[3]);
    assert_eq!(event_party, object::id(&p2).to_address());
    assert_eq!(event_name, b"Bob Again");
    assert_eq!(event_kinds, vector[5u8]);
    assert_eq!(event_custom_names, vector[b""]);
    assert_eq!(before, 0);
    assert_eq!(after, 1);
    assert_eq!(index, 0);
    assert!(record_before);
    assert!(record_after);

    // Views and test accessors are pure reads and do not add event records.
    let added_before_views =
        event::events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>().length();
    let removed_before_views =
        event::events_by_type<credits::CompositionCreditRemovedEvent<CompositionShare>>().length();
    assert!(credits::has_credits(&comp));
    assert_eq!(credits::credits(&comp).length(), 1);
    assert_eq!(
        event::events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>().length(),
        added_before_views,
    );
    assert_eq!(
        event::events_by_type<credits::CompositionCreditRemovedEvent<CompositionShare>>().length(),
        removed_before_views,
    );

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
    let credit = credit::new(
        b"Alice".to_string(),
        vector[
            cpr::new_adapter_role(),
            cpr::new_arranger_role(),
            cpr::new_composer_role(),
            cpr::new_custom_role(b"Composer".to_string()),
            cpr::new_translator_role(),
        ],
    );

    credits::add_credit(&mut comp, &cap, &p, credit);

    let events = event::events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    assert_eq!(events.length(), 1);
    let (
        event_composition_id,
        event_cap_id,
        event_party_id,
        event_display_name,
        event_role_kinds,
        event_custom_names,
        event_count_before,
        event_count_after,
        event_index,
        event_record_before,
        event_record_after,
    ) =
        credits::added_event_fields(&events[0]);
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert_eq!(event_party_id, party_id.to_address());
    assert_eq!(event_display_name, b"Alice");
    assert_eq!(event_role_kinds, vector[0u8, 1u8, 2u8, 6u8, 5u8]);
    assert_eq!(event_custom_names, vector[b"", b"", b"", b"Composer", b""]);
    assert_eq!(event_count_before, 0);
    assert_eq!(event_count_after, 1);
    assert_eq!(event_index, 0);
    assert!(!event_record_before);
    assert!(event_record_after);

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
    assert_eq!(event::events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>().length(), 1);
    assert_eq!(event::events_by_type<credits::CompositionCreditAddedEvent<OtherCompositionShare>>().length(), 1);

    let (max_party, max_party_cap) = mk_party(b"Max", ctx);
    credits::add_credit(
        &mut comp,
        &cap,
        &max_party,
        credit::new(
            test_helpers::long_string(200),
            vector[
                cpr::new_custom_role(max_custom_name(65)),
                cpr::new_custom_role(max_custom_name(66)),
                cpr::new_custom_role(max_custom_name(67)),
                cpr::new_custom_role(max_custom_name(68)),
                cpr::new_custom_role(max_custom_name(69)),
            ],
        ),
    );
    let max_events = event::events_by_type<credits::CompositionCreditAddedEvent<CompositionShare>>();
    assert_eq!(bcs::to_bytes(&max_events[1]).length(), 836);

    destroy(comp); destroy(cap); destroy(p); destroy(pc);
    destroy(other_comp); destroy(other_cap); destroy(other_party); destroy(other_party_cap);
    destroy(max_party); destroy(max_party_cap);
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

    let events = event::events_by_type<credits::CompositionCreditRemovedEvent<CompositionShare>>();
    assert_eq!(events.length(), 1);
    let (
        event_composition_id,
        event_cap_id,
        event_party_id,
        event_display_name,
        event_role_kinds,
        event_custom_names,
        event_count_before,
        event_count_after,
        event_index,
        event_record_before,
        event_record_after,
    ) =
        credits::removed_event_fields(&events[0]);
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert_eq!(event_party_id, party_id.to_address());
    assert_eq!(event_display_name, b"Alice");
    assert_eq!(event_role_kinds, vector[2u8]);
    assert_eq!(event_custom_names, vector[b""]);
    assert_eq!(event_count_before, 1);
    assert_eq!(event_count_after, 0);
    assert_eq!(event_index, 0);
    assert!(event_record_before);
    assert!(event_record_after);

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
    // at a full map must still abort with EMaxCreditsExceeded (32).
    credits::add_credit(
        &mut comp,
        &cap,
        &first_party,
        credit::new(b"P again".to_string(), vector[cpr::new_composer_role()]),
    );
    destroy(first_party_cap);
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
