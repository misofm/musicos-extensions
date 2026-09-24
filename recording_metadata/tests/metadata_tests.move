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
module recording_metadata::metadata_tests;

use genre::genre as g;
use genre::genre::{GenreRegistry, Genre};
use language_code::language_code;
use musicos::recording;
use recording_metadata::recording_metadata as rm;
use std::unit_test::{assert_eq, destroy};
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const CREATOR: address = @0xC0;

public struct REC {}
public struct UnrelatedKey() has copy, drop, store;

fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC>(object::id_from_address(@0xC0FFEE), ctx)
}

fun create_genre(scenario: &Scenario, name: vector<u8>): ID {
    let mut registry = scenario.take_shared<GenreRegistry>();
    let id = g::derive_address(&registry, name.to_string()).to_id();
    g::new(&mut registry, name.to_string());
    ts::return_shared(registry);
    id
}

fun lang(code: vector<u8>): language_code::LanguageCode {
    language_code::new(code.to_string())
}

/// Absent before any write; an authorized clear of nothing does not create
/// it; the first write of any attribute creates it; the clear that empties
/// it removes it; a later write recreates it.
#[test]
fun record_is_created_on_first_write_and_removed_on_last_clear() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    assert!(!rm::has_metadata_for_testing(&rec));
    rm::clear_genres(&mut rec, &cap);
    rm::clear_languages(&mut rec, &cap);
    rm::clear_advisory(&mut rec, &cap);
    rm::clear_version(&mut rec, &cap);
    assert!(!rm::has_metadata_for_testing(&rec));
    assert_eq!(event::num_events(), 0);

    rm::set_advisory(&mut rec, &cap, rm::explicit());
    assert!(rm::has_metadata_for_testing(&rec));
    rm::clear_advisory(&mut rec, &cap);
    assert!(!rm::has_metadata_for_testing(&rec));
    assert!(!rm::has_advisory(&rec));

    // Any attribute creates it — including an instrumental claim, which is
    // an attached empty list, not nothing.
    rm::set_languages(&mut rec, &cap, vector[]);
    assert!(rm::has_metadata_for_testing(&rec));
    assert!(rm::has_languages(&rec));
    rm::clear_languages(&mut rec, &cap);
    assert!(!rm::has_metadata_for_testing(&rec));

    rm::set_version(&mut rec, &cap, b"Live".to_string());
    assert!(rm::has_metadata_for_testing(&rec));
    assert_eq!(*rm::version(&rec), b"Live".to_string());

    destroy(rec);
    destroy(cap);
}

/// Clearing one attribute leaves every other exactly as it was and keeps the
/// record attached; only the clear that leaves nothing set removes it. The
/// genre list goes last here, so it is the removal of a genre — not a clear
/// — that finally takes the record away.
#[test]
fun clearing_one_attribute_preserves_the_others() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let jazz_id = create_genre(&scenario, b"JAZZ");
    scenario.next_tx(CREATOR);
    let jazz = scenario.take_immutable_by_id<Genre>(jazz_id);
    let (mut rec, cap) = new_rec(scenario.ctx());

    rm::add_genre(&mut rec, &cap, &jazz);
    rm::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    rm::set_advisory(&mut rec, &cap, rm::explicit());
    rm::set_version(&mut rec, &cap, b"Live".to_string());

    rm::clear_advisory(&mut rec, &cap);
    assert!(!rm::has_advisory(&rec));
    assert_eq!(rm::genres(&rec), vector[jazz_id]);
    assert_eq!(rm::languages(&rec).length(), 1);
    assert_eq!(*rm::version(&rec), b"Live".to_string());
    assert!(rm::has_metadata_for_testing(&rec));

    rm::clear_version(&mut rec, &cap);
    assert!(!rm::has_version(&rec));
    assert_eq!(rm::genres(&rec), vector[jazz_id]);
    assert_eq!(rm::languages(&rec).length(), 1);
    assert!(rm::has_metadata_for_testing(&rec));

    rm::clear_languages(&mut rec, &cap);
    assert!(!rm::has_languages(&rec));
    assert_eq!(rm::genres(&rec), vector[jazz_id]);
    assert!(rm::has_metadata_for_testing(&rec));

    rm::remove_genre(&mut rec, &cap, jazz_id);
    assert!(rm::genres(&rec).is_empty());
    assert!(!rm::has_metadata_for_testing(&rec));

    // One cleared event per attribute actually cleared, and one removal.
    assert_eq!(event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingVersionClearedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 0);

    ts::return_immutable(jazz);
    destroy(rec);
    destroy(cap);
    scenario.end();
}

/// Replacing one attribute is not a clear of any other: no cleared event
/// fires and nothing else moves.
#[test]
fun replacing_one_attribute_leaves_the_others_untouched() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    rm::set_version(&mut rec, &cap, b"Live".to_string());
    rm::set_advisory(&mut rec, &cap, rm::explicit());
    rm::set_advisory(&mut rec, &cap, rm::cleaned());
    rm::set_version(&mut rec, &cap, b"Radio Edit".to_string());

    assert!(rm::advisory(&rec).is_cleaned());
    assert_eq!(*rm::version(&rec), b"Radio Edit".to_string());
    assert!(!rm::has_languages(&rec));
    assert!(rm::genres(&rec).is_empty());
    assert_eq!(event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>().length(), 2);
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<REC>>().length(), 2);
    assert_eq!(event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingVersionClearedEvent<REC>>().length(), 0);

    destroy(rec);
    destroy(cap);
}

/// The record is one field under one key; other extensions' fields on the
/// same recording are untouched by its creation and removal.
#[test]
fun unrelated_dynamic_field_survives_record_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    df::add(rec.uid_mut(&cap), UnrelatedKey(), 77u64);
    rm::set_version(&mut rec, &cap, b"Live".to_string());
    rm::set_advisory(&mut rec, &cap, rm::explicit());
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    rm::clear_version(&mut rec, &cap);
    rm::clear_advisory(&mut rec, &cap);
    assert!(!rm::has_metadata_for_testing(&rec));
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    let marker: u64 = df::remove(rec.uid_mut(&cap), UnrelatedKey());
    assert_eq!(marker, 77);

    destroy(rec);
    destroy(cap);
}

/// Clearing an attribute that is not set while the record exists for
/// another one is a silent no-op: no event, nothing else moves, and the
/// record stays attached for the attribute that is set. Exercised for every
/// attribute, with each of the others holding the record up in turn.
#[test]
fun clearing_an_unset_attribute_while_others_are_set_is_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    // Only the version is set: clearing the other three touches nothing.
    rm::set_version(&mut rec, &cap, b"Live".to_string());
    let events_after_set = event::num_events();
    rm::clear_genres(&mut rec, &cap);
    rm::clear_languages(&mut rec, &cap);
    rm::clear_advisory(&mut rec, &cap);
    assert_eq!(event::num_events(), events_after_set);
    assert!(rm::has_metadata_for_testing(&rec));
    assert_eq!(*rm::version(&rec), b"Live".to_string());

    // Only the advisory is set: clearing the version touches nothing.
    rm::clear_version(&mut rec, &cap);
    assert!(!rm::has_metadata_for_testing(&rec));
    rm::set_advisory(&mut rec, &cap, rm::not_explicit());
    let events_after_set = event::num_events();
    rm::clear_version(&mut rec, &cap);
    rm::clear_languages(&mut rec, &cap);
    assert_eq!(event::num_events(), events_after_set);
    assert!(rm::has_metadata_for_testing(&rec));
    assert!(rm::advisory(&rec).is_not_explicit());

    // Advisory and languages both set: clearing the languages leaves the
    // advisory holding the record.
    rm::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    rm::clear_languages(&mut rec, &cap);
    assert!(rm::has_metadata_for_testing(&rec));
    assert!(!rm::has_languages(&rec));
    assert!(rm::advisory(&rec).is_not_explicit());
    rm::clear_advisory(&mut rec, &cap);
    assert!(!rm::has_metadata_for_testing(&rec));

    destroy(rec);
    destroy(cap);
}
