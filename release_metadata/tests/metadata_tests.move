// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The record's lifecycle as a whole: one dynamic field under one key holds
/// every attribute, is absent before any write, is created by the first
/// write of any attribute, survives while any attribute is set, and is
/// removed by whichever clear or removal empties it. The per-attribute
/// suites prove each attribute's own rules; this module proves what they
/// share. Single-transaction `tx_context::dummy()` style, except where a
/// frozen `Genre` has to be reached through a scenario.
#[test_only]
module release_metadata::metadata_tests;

use genre::genre as g;
use genre::genre::Genre;
use release_metadata::release_metadata as rm;
use release_metadata::test_utils::{mk_release, create_genre};
use std::unit_test::{assert_eq, destroy};
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario::{Self as ts};

const CREATOR: address = @0xC0;

public struct UnrelatedKey() has copy, drop, store;

/// Absent before any write; an authorized clear of nothing does not create
/// it; the first write of any attribute creates it; the clear that empties
/// it removes it; a later write recreates it.
#[test]
fun record_is_created_on_first_write_and_removed_on_last_clear() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    assert!(!rm::has_metadata_for_testing(&rel));
    rm::clear_title(&mut rel, &cap);
    rm::clear_genres(&mut rel, &cap);
    rm::clear_kind(&mut rel, &cap);
    rm::clear_description(&mut rel, &cap);
    assert!(!rm::has_metadata_for_testing(&rel));
    assert_eq!(event::num_events(), 0);

    rm::set_kind(&mut rel, &cap, b"EP".to_string());
    assert!(rm::has_metadata_for_testing(&rel));
    rm::clear_kind(&mut rel, &cap);
    assert!(!rm::has_metadata_for_testing(&rel));
    assert!(!rm::has_kind(&rel));

    // Any attribute creates it, not only the first field.
    rm::set_description(&mut rel, &cap, b"Cut in a weekend.".to_string());
    assert!(rm::has_metadata_for_testing(&rel));
    rm::clear_description(&mut rel, &cap);
    assert!(!rm::has_metadata_for_testing(&rel));

    rm::set_title(&mut rel, &cap, b"Long Player".to_string());
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(*rm::title(&rel), b"Long Player".to_string());

    destroy(rel);
    destroy(cap);
}

/// Clearing one attribute leaves every other exactly as it was and keeps the
/// record attached; only the clear that leaves nothing set removes it. The
/// genre list is cleared last here, so it is the removal of a genre — not a
/// clear — that finally takes the record away.
#[test]
fun clearing_one_attribute_preserves_the_others() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let jazz_id = create_genre(&scenario, b"JAZZ");
    scenario.next_tx(CREATOR);
    let jazz = scenario.take_immutable_by_id<Genre>(jazz_id);
    let (mut rel, cap) = mk_release(scenario.ctx());

    rm::set_title(&mut rel, &cap, b"Long Player".to_string());
    rm::add_genre(&mut rel, &cap, &jazz);
    rm::set_kind(&mut rel, &cap, b"Album".to_string());
    rm::set_description(&mut rel, &cap, b"Two nights, one take each.".to_string());

    rm::clear_kind(&mut rel, &cap);
    assert!(!rm::has_kind(&rel));
    assert_eq!(*rm::title(&rel), b"Long Player".to_string());
    assert_eq!(rm::genres(&rel), vector[jazz_id]);
    assert_eq!(*rm::description(&rel), b"Two nights, one take each.".to_string());
    assert!(rm::has_metadata_for_testing(&rel));

    rm::clear_title(&mut rel, &cap);
    assert!(!rm::has_title(&rel));
    assert_eq!(rm::genres(&rel), vector[jazz_id]);
    assert_eq!(*rm::description(&rel), b"Two nights, one take each.".to_string());
    assert!(rm::has_metadata_for_testing(&rel));

    rm::clear_description(&mut rel, &cap);
    assert!(!rm::has_description(&rel));
    assert_eq!(rm::genres(&rel), vector[jazz_id]);
    assert!(rm::has_metadata_for_testing(&rel));

    rm::remove_genre(&mut rel, &cap, jazz_id);
    assert!(rm::genres(&rel).is_empty());
    assert!(!rm::has_metadata_for_testing(&rel));

    // One cleared event per attribute actually cleared, and one removal.
    assert_eq!(event::events_by_type<rm::ReleaseTitleClearedEvent>().length(), 1);
    assert_eq!(event::events_by_type<rm::ReleaseKindClearedEvent>().length(), 1);
    assert_eq!(event::events_by_type<rm::ReleaseDescriptionClearedEvent>().length(), 1);
    assert_eq!(event::events_by_type<rm::ReleaseGenreRemovedEvent>().length(), 1);
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 0);

    ts::return_immutable(jazz);
    destroy(rel);
    destroy(cap);
    scenario.end();
}

/// Replacing one attribute is not a clear of any other: no cleared event
/// fires and nothing else moves.
#[test]
fun replacing_one_attribute_leaves_the_others_untouched() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    rm::set_title(&mut rel, &cap, b"Long Player".to_string());
    rm::set_kind(&mut rel, &cap, b"Album".to_string());
    rm::set_kind(&mut rel, &cap, b"Extended Play".to_string());
    rm::set_title(&mut rel, &cap, b"Long Player (Remastered)".to_string());

    assert_eq!(*rm::title(&rel), b"Long Player (Remastered)".to_string());
    assert_eq!(*rm::kind(&rel), b"Extended Play".to_string());
    assert!(!rm::has_description(&rel));
    assert!(rm::genres(&rel).is_empty());
    assert_eq!(event::events_by_type<rm::ReleaseTitleSetEvent>().length(), 2);
    assert_eq!(event::events_by_type<rm::ReleaseKindSetEvent>().length(), 2);
    assert_eq!(event::events_by_type<rm::ReleaseTitleClearedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseKindClearedEvent>().length(), 0);

    destroy(rel);
    destroy(cap);
}

/// The record is one field under one key; other extensions' fields on the
/// same release are untouched by its creation and removal.
#[test]
fun unrelated_dynamic_field_survives_record_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    df::add(rel.uid_mut(&cap), UnrelatedKey(), 77u64);
    rm::set_title(&mut rel, &cap, b"Long Player".to_string());
    rm::set_description(&mut rel, &cap, b"Cut in a weekend.".to_string());
    assert_eq!(*df::borrow(rel.uid(), UnrelatedKey()), 77u64);
    rm::clear_title(&mut rel, &cap);
    rm::clear_description(&mut rel, &cap);
    assert!(!rm::has_metadata_for_testing(&rel));
    assert_eq!(*df::borrow(rel.uid(), UnrelatedKey()), 77u64);
    let marker: u64 = df::remove(rel.uid_mut(&cap), UnrelatedKey());
    assert_eq!(marker, 77);

    destroy(rel);
    destroy(cap);
}

/// Clearing an attribute that is not set while the record exists for
/// another one is a silent no-op: no event, nothing else moves, and the
/// record stays attached for the attribute that is set. Exercised for every
/// attribute, with each of the others holding the record up in turn.
#[test]
fun clearing_an_unset_attribute_while_others_are_set_is_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    // Only the kind is set: clearing the other three touches nothing.
    rm::set_kind(&mut rel, &cap, b"Album".to_string());
    let events_after_set = event::num_events();
    rm::clear_title(&mut rel, &cap);
    rm::clear_genres(&mut rel, &cap);
    rm::clear_description(&mut rel, &cap);
    assert_eq!(event::num_events(), events_after_set);
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(*rm::kind(&rel), b"Album".to_string());

    // Only the description is set: clearing the kind touches nothing.
    rm::clear_kind(&mut rel, &cap);
    assert!(!rm::has_metadata_for_testing(&rel));
    rm::set_description(&mut rel, &cap, b"Cut in a weekend.".to_string());
    let events_after_set = event::num_events();
    rm::clear_kind(&mut rel, &cap);
    rm::clear_title(&mut rel, &cap);
    assert_eq!(event::num_events(), events_after_set);
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(*rm::description(&rel), b"Cut in a weekend.".to_string());

    // Kind and description both set: clearing the description leaves the
    // kind holding the record.
    rm::set_kind(&mut rel, &cap, b"EP".to_string());
    rm::clear_description(&mut rel, &cap);
    assert!(rm::has_metadata_for_testing(&rel));
    assert!(!rm::has_description(&rel));
    assert_eq!(*rm::kind(&rel), b"EP".to_string());
    rm::clear_kind(&mut rel, &cap);
    assert!(!rm::has_metadata_for_testing(&rel));

    destroy(rel);
    destroy(cap);
}
