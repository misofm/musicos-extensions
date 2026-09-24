// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for the genre attribute's full use case, run under
/// `sui::test_scenario`: real transaction boundaries, distinct senders, and
/// the release genuinely published and shared before genre operations touch
/// it via `take_shared` in a later transaction — the production shape (core
/// releases are create-and-publish atomic, then shared for their whole life;
/// see `musicos::release`'s module doc).
///
/// Scope: canonical vocabulary creation (`genre::genre`, upstream context)
/// feeding a published, shared `Release`'s ordered genre list — appending in
/// the desired primary-first order, and clearing — plus the cap-gated
/// adversarial cases (wrong `ReleaseAdminCap` from a second release), with
/// their documented guard precedence.
#[test_only]
module release_metadata::genre_e2e_tests;

use genre::genre as g;
use genre::genre::Genre;
use musicos::release::Release;
use release_metadata::release_metadata as rm;
use release_metadata::test_utils::{publish_and_share_release, create_genre};
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self as ts};

// CREATOR creates canonical genres. LABEL creates and owns releases
// (the ReleaseAdminCap holder). STRANGER owns nothing relevant to either
// release and plays the wrong-cap adversary.
const CREATOR: address = @0xC0;
const LABEL: address = @0xAD;
const STRANGER: address = @0x51;

// === Full lifecycle against a published, shared release ===

#[test]
fun genre_lifecycle_on_published_shared_release() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    // --- Tx 1 (CREATOR): create the vocabulary entries ---
    scenario.next_tx(CREATOR);
    let hiphop_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(CREATOR);
    let electronic_id = create_genre(&scenario, b"ELECTRONIC");

    // --- Tx 2 (LABEL): create-and-publish the release (shares it) ---
    scenario.next_tx(LABEL);
    let (cap, release_id) = publish_and_share_release(&mut scenario);

    // --- Tx 3 (LABEL): operate on the now-shared release via take_shared ---
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    assert_eq!(object::id(&rel), release_id);
    assert!(rel.is_published_state());
    let hiphop = scenario.take_immutable_by_id<Genre>(hiphop_id);
    let electronic = scenario.take_immutable_by_id<Genre>(electronic_id);

    assert!(rm::genres(&rel).is_empty());
    // Add in the desired final order directly — electronic is meant to be
    // primary, so it is added first.
    rm::add_genre(&mut rel, &cap, &electronic);
    rm::add_genre(&mut rel, &cap, &hiphop);

    assert_eq!(rm::genres(&rel), vector[electronic_id, hiphop_id]);

    // Full event payloads, pinned against the real (post-publish) release id.
    let added_events = event::events_by_type<rm::ReleaseGenreAddedEvent>();
    assert_eq!(added_events.length(), 2);
    let (a0_release_id, a0_genre_id) = rm::genre_added_event_fields(&added_events[0]);
    assert_eq!(a0_release_id, release_id.to_address());
    assert_eq!(a0_genre_id, electronic_id.to_address());
    let (a1_release_id, a1_genre_id) = rm::genre_added_event_fields(&added_events[1]);
    assert_eq!(a1_release_id, release_id.to_address());
    assert_eq!(a1_genre_id, hiphop_id.to_address());

    ts::return_immutable(hiphop);
    ts::return_immutable(electronic);
    ts::return_shared(rel);

    // --- Tx 4 (STRANGER): reads are open to anyone, no cap required ---
    scenario.next_tx(STRANGER);
    let rel = scenario.take_shared<Release>();
    assert_eq!(rm::genres(&rel), vector[electronic_id, hiphop_id]);
    ts::return_shared(rel);

    // --- Tx 5 (LABEL): drops the secondary, then clears the rest ---
    scenario.next_tx(LABEL);
    let mut rel = scenario.take_shared<Release>();
    rm::remove_genre(&mut rel, &cap, hiphop_id);
    assert_eq!(rm::genres(&rel), vector[electronic_id]);
    let removed_events = event::events_by_type<rm::ReleaseGenreRemovedEvent>();
    assert_eq!(removed_events.length(), 1);
    let (removed_release_id, removed_genre_id) = rm::genre_removed_event_fields(&removed_events[0]);
    assert_eq!(removed_release_id, release_id.to_address());
    assert_eq!(removed_genre_id, hiphop_id.to_address());

    rm::clear_genres(&mut rel, &cap);
    assert!(rm::genres(&rel).is_empty());
    let cleared_events = event::events_by_type<rm::ReleaseGenresClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(rm::genres_cleared_event_fields(&cleared_events[0]), release_id.to_address());
    ts::return_shared(rel);

    // --- Tx 6 (STRANGER): the clear is visible too ---
    scenario.next_tx(STRANGER);
    let rel = scenario.take_shared<Release>();
    assert!(rm::genres(&rel).is_empty());
    ts::return_shared(rel);

    destroy(cap);
    scenario.end();
}

// === Adversarial: wrong ReleaseAdminCap from a second release ===

/// A stranger holding the *other* release's admin cap cannot touch this
/// release's genre list — `uid_mut`'s `authorize` check (core) rejects it
/// before this module ever runs its own logic.
#[test]
#[expected_failure(abort_code = 0, location = musicos::release)] // EUnauthorized
fun wrong_cap_from_other_release_aborts() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let hiphop_id = create_genre(&scenario, b"HIP_HOP");

    // --- Tx (LABEL): publish two distinct, shared releases ---
    scenario.next_tx(LABEL);
    let (_cap_a, release_id_a) = publish_and_share_release(&mut scenario);
    scenario.next_tx(LABEL);
    let (cap_b, _release_id_b) = publish_and_share_release(&mut scenario);

    // --- Tx (STRANGER): try to tag release A's genre using cap B ---
    scenario.next_tx(STRANGER);
    let mut rel_a = scenario.take_shared_by_id<Release>(release_id_a);
    let hiphop = scenario.take_immutable_by_id<Genre>(hiphop_id);
    rm::add_genre(&mut rel_a, &cap_b, &hiphop); // aborts: wrong cap

    // Unreachable, but the compiler requires all non-drop values consumed on
    // any path that returns normally; this path never does.
    abort
}

/// `remove_genre` authorizes before it reads any state, like every other
/// state-touching write here: with no genre list attached, a cap belonging
/// to another release is rejected by core rather than reported as a missing
/// genre by this module.
#[test]
#[expected_failure(abort_code = 0, location = musicos::release)]
fun wrong_cap_remove_absent_authenticates_first() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());
    scenario.next_tx(LABEL);
    let (_cap_a, release_id_a) = publish_and_share_release(&mut scenario);
    scenario.next_tx(LABEL);
    let (cap_b, _release_id_b) = publish_and_share_release(&mut scenario);
    scenario.next_tx(STRANGER);
    let mut rel_a = scenario.take_shared_by_id<Release>(release_id_a);
    rm::remove_genre(&mut rel_a, &cap_b, object::id_from_address(@0xF00D));
    abort
}

/// With a genre present, the same wrong-cap call is rejected identically:
/// the guard order does not depend on what is attached.
#[test]
#[expected_failure(abort_code = 0, location = musicos::release)]
fun wrong_cap_remove_present_reaches_authorization() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let genre_id = create_genre(&scenario, b"HIP_HOP");
    scenario.next_tx(LABEL);
    let (cap_a, release_id_a) = publish_and_share_release(&mut scenario);
    scenario.next_tx(LABEL);
    let (cap_b, _release_id_b) = publish_and_share_release(&mut scenario);
    scenario.next_tx(LABEL);
    let mut rel_a = scenario.take_shared_by_id<Release>(release_id_a);
    let genre = scenario.take_immutable_by_id<Genre>(genre_id);
    rm::add_genre(&mut rel_a, &cap_a, &genre);
    ts::return_immutable(genre);
    ts::return_shared(rel_a);
    scenario.next_tx(STRANGER);
    let mut rel_a = scenario.take_shared_by_id<Release>(release_id_a);
    rm::remove_genre(&mut rel_a, &cap_b, genre_id);
    abort
}

/// Clear authenticates first even when there is nothing to remove.
#[test]
#[expected_failure(abort_code = 0, location = musicos::release)]
fun wrong_cap_clear_absent_still_authenticates() {
    let mut scenario = ts::begin(CREATOR);
    g::init_for_testing(scenario.ctx());
    scenario.next_tx(LABEL);
    let (_cap_a, release_id_a) = publish_and_share_release(&mut scenario);
    scenario.next_tx(LABEL);
    let (cap_b, _release_id_b) = publish_and_share_release(&mut scenario);
    scenario.next_tx(STRANGER);
    let mut rel_a = scenario.take_shared_by_id<Release>(release_id_a);
    rm::clear_genres(&mut rel_a, &cap_b);
    abort
}
