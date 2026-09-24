// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for the package as a whole: one published, shared
/// release acquiring its complete basic profile — title, genres, kind,
/// description — across transaction boundaries and senders, and the
/// independence of the four attributes from each other. All four live in one
/// `ReleaseMetadata` record under one key, but each is set and cleared on
/// its own: writing or clearing one never disturbs another, and the record
/// exists exactly while at least one is set. This module proves that on the
/// production shape, while each attribute's own e2e module proves its
/// lifecycle and cap gate in isolation.
#[test_only]
module release_metadata::metadata_e2e_tests;

use genre::genre as g;
use genre::genre::Genre;
use musicos::release::{Release, ReleaseAdminCap};
use release_metadata::release_metadata as rm;
use release_metadata::test_utils::{publish_and_share_release, create_genre};
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const CREATOR: address = @0xC0;
const LABEL: address = @0xAD;
const STRANGER: address = @0x51;

// === Helpers ===

/// CREATOR seeds the vocabulary and LABEL publishes and shares a release.
/// Returns the cap, the release id, and the two genre ids (primary first).
fun setup(scenario: &mut Scenario): (ReleaseAdminCap, ID, ID, ID) {
    g::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let jazz_id = create_genre(scenario, b"JAZZ");
    scenario.next_tx(CREATOR);
    let funk_id = create_genre(scenario, b"FUNK");
    scenario.next_tx(LABEL);
    let (cap, release_id) = publish_and_share_release(scenario);
    (cap, release_id, jazz_id, funk_id)
}

/// LABEL fills in the whole profile in one transaction against the shared
/// release.
fun set_full_profile(scenario: &mut Scenario, cap: &ReleaseAdminCap, jazz_id: ID, funk_id: ID) {
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    let jazz = scenario.take_immutable_by_id<Genre>(jazz_id);
    let funk = scenario.take_immutable_by_id<Genre>(funk_id);
    rm::set_title(&mut rel, cap, b"Live at the Village".to_string());
    rm::add_genre(&mut rel, cap, &jazz);
    rm::add_genre(&mut rel, cap, &funk);
    rm::set_kind(&mut rel, cap, b"Album".to_string());
    rm::set_description(&mut rel, cap, b"Two nights, one take each.".to_string());
    ts::return_immutable(jazz);
    ts::return_immutable(funk);
    ts::return_shared(rel);
}

fun assert_no_profile(rel: &Release) {
    assert!(!rm::has_title(rel));
    assert!(rm::genres(rel).is_empty());
    assert!(!rm::has_kind(rel));
    assert!(!rm::has_description(rel));
}

fun assert_no_cleared_events() {
    assert_eq!(event::events_by_type<rm::ReleaseTitleClearedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseKindClearedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseDescriptionClearedEvent>().length(), 0);
}

// === Tests ===

/// A label publishes a release, then fills in its profile across two
/// transactions; a stranger reads the growing profile between writes, and
/// every event names the release and carries its value.
#[test]
fun full_profile_on_a_published_shared_release() {
    let mut scenario = ts::begin(CREATOR);
    let (cap, release_id, jazz_id, funk_id) = setup(&mut scenario);

    // --- (STRANGER): a published release starts with no profile at all;
    // core embeds no title, and nothing is attached yet ---
    scenario.next_tx(STRANGER);
    let rel = scenario.take_shared<Release>();
    assert!(rel.is_published_state());
    assert_no_profile(&rel);
    assert!(!rm::has_metadata_for_testing(&rel));
    ts::return_shared(rel);

    // --- (LABEL): title and kind, in one PTB ---
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    rm::set_title(&mut rel, &cap, b"Live at the Village".to_string());
    rm::set_kind(&mut rel, &cap, b"Album".to_string());
    ts::return_shared(rel);

    let title_sets = event::events_by_type<rm::ReleaseTitleSetEvent>();
    let kind_sets = event::events_by_type<rm::ReleaseKindSetEvent>();
    assert_eq!(title_sets.length(), 1);
    assert_eq!(kind_sets.length(), 1);
    let (title_release, title) = rm::title_set_event_fields(&title_sets[0]);
    let (kind_release, kind) = rm::kind_set_event_fields(&kind_sets[0]);
    assert_eq!(title_release, release_id.to_address());
    assert_eq!(kind_release, release_id.to_address());
    assert_eq!(title, b"Live at the Village".to_string());
    assert_eq!(kind, b"Album".to_string());

    // --- (STRANGER): partial profile is readable; the rest still absent ---
    scenario.next_tx(STRANGER);
    let rel = scenario.take_shared<Release>();
    assert_eq!(*rm::title(&rel), b"Live at the Village".to_string());
    assert_eq!(*rm::kind(&rel), b"Album".to_string());
    assert!(rm::genres(&rel).is_empty());
    assert!(!rm::has_description(&rel));
    ts::return_shared(rel);

    // --- (LABEL): genres (primary first) and description ---
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    let jazz = scenario.take_immutable_by_id<Genre>(jazz_id);
    let funk = scenario.take_immutable_by_id<Genre>(funk_id);
    rm::add_genre(&mut rel, &cap, &jazz);
    rm::add_genre(&mut rel, &cap, &funk);
    rm::set_description(&mut rel, &cap, b"Two nights, one take each.".to_string());
    ts::return_immutable(jazz);
    ts::return_immutable(funk);
    ts::return_shared(rel);

    let genre_adds = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    let description_sets = event::events_by_type<rm::ReleaseDescriptionSetEvent>();
    assert_eq!(genre_adds.length(), 2);
    assert_eq!(description_sets.length(), 1);
    let (genre_release_0, genre_0) = rm::genre_added_event_fields(&genre_adds[0]);
    let (genre_release_1, genre_1) = rm::genre_added_event_fields(&genre_adds[1]);
    let (description_release, description) = rm::description_set_event_fields(&description_sets[0]);
    assert_eq!(genre_release_0, release_id.to_address());
    assert_eq!(genre_release_1, release_id.to_address());
    assert_eq!(description_release, release_id.to_address());
    assert_eq!(genre_0, jazz_id.to_address());
    assert_eq!(genre_1, funk_id.to_address());
    assert_eq!(description, b"Two nights, one take each.".to_string());

    // --- (STRANGER): the complete profile ---
    scenario.next_tx(STRANGER);
    let rel = scenario.take_shared<Release>();
    assert_eq!(*rm::title(&rel), b"Live at the Village".to_string());
    assert_eq!(rm::genres(&rel), vector[jazz_id, funk_id]);
    assert_eq!(*rm::kind(&rel), b"Album".to_string());
    assert_eq!(*rm::description(&rel), b"Two nights, one take each.".to_string());
    ts::return_shared(rel);

    destroy(cap);
    scenario.end();
}

/// The attributes share one record but are cleared independently: clearing
/// or rewriting one leaves the others exactly as they were, emits a cleared
/// event for that attribute alone, and keeps the record attached until the
/// last one goes.
#[test]
fun attributes_are_cleared_independently() {
    let mut scenario = ts::begin(CREATOR);
    let (cap, _release_id, jazz_id, funk_id) = setup(&mut scenario);
    set_full_profile(&mut scenario, &cap, jazz_id, funk_id);

    // --- (LABEL): clear the kind; everything else survives ---
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    rm::clear_kind(&mut rel, &cap);
    assert!(!rm::has_kind(&rel));
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(*rm::title(&rel), b"Live at the Village".to_string());
    assert_eq!(rm::genres(&rel), vector[jazz_id, funk_id]);
    assert_eq!(*rm::description(&rel), b"Two nights, one take each.".to_string());
    ts::return_shared(rel);
    assert_eq!(event::events_by_type<rm::ReleaseKindClearedEvent>().length(), 1);
    assert_eq!(event::events_by_type<rm::ReleaseTitleClearedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseDescriptionClearedEvent>().length(), 0);

    // --- (LABEL): clear the genres; title and description survive ---
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    rm::clear_genres(&mut rel, &cap);
    assert!(rm::genres(&rel).is_empty());
    assert_eq!(*rm::title(&rel), b"Live at the Village".to_string());
    assert_eq!(*rm::description(&rel), b"Two nights, one take each.".to_string());
    ts::return_shared(rel);
    assert_eq!(event::events_by_type<rm::ReleaseGenresClearedEvent>().length(), 1);
    assert_eq!(event::events_by_type<rm::ReleaseTitleClearedEvent>().length(), 0);
    assert_eq!(event::events_by_type<rm::ReleaseDescriptionClearedEvent>().length(), 0);

    // --- (LABEL): rename; the description survives, nothing is cleared ---
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    rm::set_title(&mut rel, &cap, b"Live at the Village (Complete)".to_string());
    assert_eq!(*rm::description(&rel), b"Two nights, one take each.".to_string());
    ts::return_shared(rel);
    assert_eq!(event::events_by_type<rm::ReleaseTitleSetEvent>().length(), 1);
    assert_no_cleared_events();

    // --- (STRANGER): the end state, one attribute at a time ---
    scenario.next_tx(STRANGER);
    let rel = scenario.take_shared<Release>();
    assert_eq!(*rm::title(&rel), b"Live at the Village (Complete)".to_string());
    assert!(rm::genres(&rel).is_empty());
    assert!(!rm::has_kind(&rel));
    assert_eq!(*rm::description(&rel), b"Two nights, one take each.".to_string());
    ts::return_shared(rel);

    // --- (LABEL): clear the rest; the release is back to no profile ---
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    rm::clear_title(&mut rel, &cap);
    assert!(rm::has_metadata_for_testing(&rel));
    rm::clear_description(&mut rel, &cap);
    assert_no_profile(&rel);
    assert!(!rm::has_metadata_for_testing(&rel));
    ts::return_shared(rel);
    assert_eq!(event::events_by_type<rm::ReleaseTitleClearedEvent>().length(), 1);
    assert_eq!(event::events_by_type<rm::ReleaseDescriptionClearedEvent>().length(), 1);

    // --- (STRANGER): the record is gone from the shared object, not merely
    // emptied ---
    scenario.next_tx(STRANGER);
    let rel = scenario.take_shared<Release>();
    assert_no_profile(&rel);
    assert!(!rm::has_metadata_for_testing(&rel));
    ts::return_shared(rel);

    destroy(cap);
    scenario.end();
}
