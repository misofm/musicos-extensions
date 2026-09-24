// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The package-level property the per-attribute suites cannot show on their
/// own: the four attributes share one `RecordingMetadata` record under one
/// key, yet each is set and cleared independently. Setting, replacing or
/// clearing any one of them leaves the other three — and their event streams
/// — untouched, and the record exists exactly while at least one is set;
/// against the production shape of a published, shared `Recording` operated
/// on across transaction boundaries by the admin and read by a stranger.
#[test_only]
module recording_metadata::metadata_e2e_tests;

use genre::genre as g;
use genre::genre::{GenreRegistry, Genre};
use language_code::language_code;
use musicos::recording::{Self, Recording};
use recording_metadata::recording_metadata as rm;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;
const CREATOR: address = @0xC0;

public struct REC {}

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

#[test]
fun the_four_attributes_are_independent_fields_on_one_published_recording() {
    let mut ts = ts::begin(CREATOR);

    // === Tx 0 (CREATOR): stand up the genre vocabulary ===
    g::init_for_testing(ts.ctx());
    ts.next_tx(CREATOR);
    let hip_hop = create_genre(&ts, b"HIP_HOP");
    ts.next_tx(CREATOR);
    let ambient = create_genre(&ts, b"AMBIENT");

    // === Tx (ADMIN): create and publish the recording — this shares it ===
    ts.next_tx(ADMIN);
    let (rec, rec_cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec).to_address();
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    // === Tx (ADMIN): describe the take in full ===
    ts.next_tx(ADMIN);
    let genre_hip_hop = ts.take_immutable_by_id<Genre>(hip_hop);
    let genre_ambient = ts.take_immutable_by_id<Genre>(ambient);
    let mut rec = ts.take_shared<Recording<REC>>();
    assert!(!rm::has_metadata_for_testing(&rec));

    rm::add_genre(&mut rec, &rec_cap, &genre_hip_hop);
    assert!(rm::has_metadata_for_testing(&rec));
    rm::add_genre(&mut rec, &rec_cap, &genre_ambient);
    rm::set_languages(&mut rec, &rec_cap, vector[lang(b"en"), lang(b"fr")]);
    rm::set_advisory(&mut rec, &rec_cap, rm::explicit());
    rm::set_version(&mut rec, &rec_cap, b"Live".to_string());

    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<REC>>().length(), 2);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<REC>>().length(), 1);
    let (id, _) = rm::genre_added_event_fields(
        &event::events_by_type<rm::RecordingGenreAddedEvent<REC>>()[0],
    );
    assert_eq!(id, rec_id);
    let (id, _) = rm::languages_set_event_fields(
        &event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>()[0],
    );
    assert_eq!(id, rec_id);
    let (id, _) = rm::advisory_set_event_fields(
        &event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>()[0],
    );
    assert_eq!(id, rec_id);
    let (id, _) = rm::version_set_event_fields(
        &event::events_by_type<rm::RecordingVersionSetEvent<REC>>()[0],
    );
    assert_eq!(id, rec_id);

    ts::return_shared(rec);

    // === Tx (STRANGER): every attribute is readable without the cap ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert_eq!(rm::genres(&rec), vector[hip_hop, ambient]);
    assert_eq!(rm::languages(&rec).length(), 2);
    assert!(rm::advisory(&rec).is_explicit());
    assert_eq!(*rm::version(&rec), b"Live".to_string());
    ts::return_shared(rec);

    // === Tx (ADMIN): clear the languages — nothing else moves ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rm::clear_languages(&mut rec, &rec_cap);
    assert!(!rm::has_languages(&rec));
    assert!(rm::has_metadata_for_testing(&rec));
    assert_eq!(rm::genres(&rec), vector[hip_hop, ambient]);
    assert!(rm::advisory(&rec).is_explicit());
    assert_eq!(*rm::version(&rec), b"Live".to_string());
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingVersionClearedEvent<REC>>().length(), 0);
    ts::return_shared(rec);

    // === Tx (ADMIN): remove every genre one by one — the advisory and version
    // stay, and the language stays absent ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rm::remove_genre(&mut rec, &rec_cap, hip_hop);
    rm::remove_genre(&mut rec, &rec_cap, ambient);
    assert!(rm::genres(&rec).is_empty());
    assert!(rm::has_metadata_for_testing(&rec));
    assert!(!rm::has_languages(&rec));
    assert!(rm::advisory(&rec).is_explicit());
    assert_eq!(*rm::version(&rec), b"Live".to_string());
    assert_eq!(event::events_by_type<rm::RecordingGenreRemovedEvent<REC>>().length(), 2);
    assert_eq!(event::events_by_type<rm::RecordingGenresClearedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingVersionClearedEvent<REC>>().length(), 0);
    ts::return_shared(rec);

    // === Tx (ADMIN): re-rate as cleaned and rename the take; re-assert
    // instrumental ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rm::set_advisory(&mut rec, &rec_cap, rm::cleaned());
    rm::set_version(&mut rec, &rec_cap, b"Radio Edit".to_string());
    rm::set_languages(&mut rec, &rec_cap, vector[]);
    assert!(rm::genres(&rec).is_empty());
    assert_eq!(event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingGenreAddedEvent<REC>>().length(), 0);
    ts::return_shared(rec);

    // === Tx (STRANGER): the final state, attribute by attribute ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(rm::genres(&rec).is_empty());
    assert!(rm::has_languages(&rec));
    assert!(rm::languages(&rec).is_empty());
    assert!(rm::advisory(&rec).is_cleaned());
    assert_eq!(*rm::version(&rec), b"Radio Edit".to_string());
    ts::return_shared(rec);

    // === Tx (ADMIN): withdraw the rest one at a time — the record stays
    // until the last attribute goes ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rm::clear_advisory(&mut rec, &rec_cap);
    assert!(rm::has_metadata_for_testing(&rec));
    rm::clear_version(&mut rec, &rec_cap);
    assert!(rm::has_metadata_for_testing(&rec));
    rm::clear_languages(&mut rec, &rec_cap);
    assert!(!rm::has_metadata_for_testing(&rec));
    assert_eq!(event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingVersionClearedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>().length(), 1);
    ts::return_shared(rec);

    // === Tx (STRANGER): the record is gone from the shared object, not
    // merely emptied ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(!rm::has_metadata_for_testing(&rec));
    assert!(rm::genres(&rec).is_empty());
    assert!(!rm::has_languages(&rec));
    assert!(!rm::has_advisory(&rec));
    assert!(!rm::has_version(&rec));
    ts::return_shared(rec);

    ts::return_immutable(genre_hip_hop);
    ts::return_immutable(genre_ambient);
    destroy(rec_cap);
    ts.end();
}
