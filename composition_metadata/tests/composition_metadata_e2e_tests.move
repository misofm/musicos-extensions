// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenarios for this package's full use case, run under
/// `sui::test_scenario`: real transaction boundaries, distinct senders, the
/// admin cap held as an owned object and re-taken from the sender's inventory,
/// and the composition genuinely published and shared — the production shape,
/// where `uid_mut` is the cap-gated surface that stays open after publish
/// while the composition's embedded fields are frozen.
///
/// A composition is `key`-only with no `drop`, so an `Initialized` one cannot
/// outlive its creating transaction: "before publish" means earlier in the
/// same transaction, which is what the first flow exercises.
#[test_only]
module composition_metadata::composition_metadata_e2e_tests;

use composition_metadata::composition_metadata as cm;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::test_helpers::CompositionShare;
use std::unit_test::assert_eq;
use sui::event;
use sui::test_scenario::{Self, Scenario};

const WRITER: address = @0xA0;
const STRANGER: address = @0x51;

/// Publishes and shares a composition in the current transaction, sending
/// its admin cap to the sender. Returns the composition's id so a later
/// transaction can find the shared object. The cap is transferred rather
/// than held so that later transactions take it from the sender's inventory,
/// as a wallet would.
fun publish_composition(scenario: &mut Scenario, sender: address): ID {
    let ctx = scenario.ctx();
    let (comp, cap) = composition::new_for_testing<CompositionShare>(1500, ctx);
    let comp_id = object::id(&comp);
    let clock = sui::clock::create_for_testing(ctx);
    comp.publish(&cap, &clock);
    clock.destroy_for_testing();
    transfer::public_transfer(cap, sender);
    comp_id
}

/// The title is settable before publication: WRITER names the composition
/// while it is still `Initialized`, in the same transaction that creates,
/// publishes and shares it. The title survives publication unchanged, a
/// stranger reads it, and WRITER corrects it later against the shared
/// object.
#[test]
fun title_set_before_publish_survives_publication() {
    let mut ts = test_scenario::begin(WRITER);

    // --- Tx 1 (WRITER): create, name, publish and share ---
    let ctx = ts.ctx();
    let (mut comp, cap) = composition::new_for_testing<CompositionShare>(1500, ctx);
    let comp_id = object::id(&comp);
    assert!(comp.is_initialized_state());
    cm::set_title(&mut comp, &cap, b"So What".to_string());
    assert_eq!(*cm::title(&comp), b"So What".to_string());
    let clock = sui::clock::create_for_testing(ctx);
    comp.publish(&cap, &clock);
    clock.destroy_for_testing();
    transfer::public_transfer(cap, WRITER);

    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 1);
    let (event_id, title) = cm::set_event_fields(&sets[0]);
    assert_eq!(event_id, comp_id.to_address());
    assert_eq!(title, b"So What".to_string());

    // --- Tx 2 (STRANGER): the title is on the published, shared object ---
    ts.next_tx(STRANGER);
    let comp = ts.take_shared<Composition<CompositionShare>>();
    assert!(comp.is_published_state());
    assert_eq!(*cm::title(&comp), b"So What".to_string());
    test_scenario::return_shared(comp);

    // --- Tx 3 (WRITER): a correction after publish, cap taken from the
    // sender's inventory ---
    ts.next_tx(WRITER);
    let mut comp = ts.take_shared<Composition<CompositionShare>>();
    let cap = ts.take_from_sender<CompositionAdminCap<CompositionShare>>();
    cm::set_title(&mut comp, &cap, b"So What (Alternate Take)".to_string());
    ts.return_to_sender(cap);
    test_scenario::return_shared(comp);

    // --- Tx 4 (STRANGER): sees the correction ---
    ts.next_tx(STRANGER);
    let comp = ts.take_shared<Composition<CompositionShare>>();
    assert_eq!(*cm::title(&comp), b"So What (Alternate Take)".to_string());
    test_scenario::return_shared(comp);

    ts.end();
}

/// The production shape end to end: WRITER publishes and shares an unnamed
/// composition; a stranger reads that absence a transaction later. WRITER
/// then names, renames and clears — each time reaching the shared object via
/// `take_shared` in its own later transaction, with the cap taken from the
/// sender's inventory — and a stranger observes every state change.
#[test]
fun title_lifecycle_on_a_published_and_shared_composition() {
    let mut ts = test_scenario::begin(WRITER);

    // --- Tx 1 (WRITER): publish and share, unnamed ---
    let comp_id = publish_composition(&mut ts, WRITER);

    // --- Tx 2 (STRANGER): the extension surface is readable by anyone, and
    // starts empty ---
    ts.next_tx(STRANGER);
    let comp = ts.take_shared<Composition<CompositionShare>>();
    assert!(!cm::has_title(&comp));
    test_scenario::return_shared(comp);

    // --- Tx 3 (WRITER): names it ---
    ts.next_tx(WRITER);
    let mut comp = ts.take_shared<Composition<CompositionShare>>();
    let cap = ts.take_from_sender<CompositionAdminCap<CompositionShare>>();
    cm::set_title(&mut comp, &cap, b"Freddie Freeloader".to_string());
    assert!(cm::has_title(&comp));
    ts.return_to_sender(cap);
    test_scenario::return_shared(comp);

    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 1);
    let (event_id, title) = cm::set_event_fields(&sets[0]);
    assert_eq!(event_id, comp_id.to_address());
    assert_eq!(title, b"Freddie Freeloader".to_string());

    // --- Tx 4 (STRANGER): reads back the same title a transaction later ---
    ts.next_tx(STRANGER);
    let comp = ts.take_shared<Composition<CompositionShare>>();
    assert_eq!(*cm::title(&comp), b"Freddie Freeloader".to_string());
    test_scenario::return_shared(comp);

    // --- Tx 5 (WRITER): renames, then clears — both against the shared
    // object, both in one later transaction ---
    ts.next_tx(WRITER);
    let mut comp = ts.take_shared<Composition<CompositionShare>>();
    let cap = ts.take_from_sender<CompositionAdminCap<CompositionShare>>();
    cm::set_title(&mut comp, &cap, b"Freddie the Freeloader".to_string());
    cm::clear_title(&mut comp, &cap);
    assert!(!cm::has_title(&comp));
    ts.return_to_sender(cap);
    test_scenario::return_shared(comp);

    let sets = event::events_by_type<cm::CompositionTitleSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 1);
    let (event_id, title) = cm::set_event_fields(&sets[0]);
    assert_eq!(event_id, comp_id.to_address());
    assert_eq!(title, b"Freddie the Freeloader".to_string());

    let clears = event::events_by_type<cm::CompositionTitleClearedEvent<CompositionShare>>();
    assert_eq!(clears.length(), 1);
    assert_eq!(cm::cleared_event_fields(&clears[0]), comp_id.to_address());

    // --- Tx 6 (STRANGER): the clear is visible too, and the record itself
    // is gone from the shared object, not merely emptied ---
    ts.next_tx(STRANGER);
    let comp = ts.take_shared<Composition<CompositionShare>>();
    assert!(!cm::has_title(&comp));
    assert!(!cm::has_metadata_for_testing(&comp));
    test_scenario::return_shared(comp);

    ts.end();
}

/// Two published, shared compositions with the same share type are written by
/// their own caps and keep independent titles. The core binds a cap to a
/// composition by share type, not by id — see `tests/check_cap_types.py`
/// for the compile-time rejection of a cap with another share type — so the
/// runtime guarantee exercised here is isolation of the two dynamic fields,
/// with each id-disambiguated shared object touched only by its own admin.
#[test]
fun two_shared_compositions_keep_independent_titles() {
    let mut ts = test_scenario::begin(WRITER);
    let first_id = publish_composition(&mut ts, WRITER);

    ts.next_tx(STRANGER);
    let second_id = publish_composition(&mut ts, STRANGER);

    ts.next_tx(WRITER);
    let mut first = test_scenario::take_shared_by_id<Composition<CompositionShare>>(&ts, first_id);
    let cap = ts.take_from_sender<CompositionAdminCap<CompositionShare>>();
    cm::set_title(&mut first, &cap, b"Writer's Song".to_string());
    ts.return_to_sender(cap);
    test_scenario::return_shared(first);

    ts.next_tx(STRANGER);
    let mut second =
        test_scenario::take_shared_by_id<Composition<CompositionShare>>(&ts, second_id);
    let cap = ts.take_from_sender<CompositionAdminCap<CompositionShare>>();
    assert!(!cm::has_title(&second));
    cm::set_title(&mut second, &cap, b"Stranger's Song".to_string());
    ts.return_to_sender(cap);
    test_scenario::return_shared(second);

    ts.next_tx(STRANGER);
    let first = test_scenario::take_shared_by_id<Composition<CompositionShare>>(&ts, first_id);
    let second = test_scenario::take_shared_by_id<Composition<CompositionShare>>(&ts, second_id);
    assert_eq!(*cm::title(&first), b"Writer's Song".to_string());
    assert_eq!(*cm::title(&second), b"Stranger's Song".to_string());
    test_scenario::return_shared(first);
    test_scenario::return_shared(second);

    ts.end();
}
