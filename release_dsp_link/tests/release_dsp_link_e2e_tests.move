// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenario for this package's full use case, run under
/// `sui::test_scenario`: real transaction boundaries and distinct senders,
/// against a `Release` that is genuinely PUBLISHED AND SHARED — the
/// production shape, since `miso::release::publish` calls
/// `transfer::share_object`. DSP-link writes (release-level and per-track)
/// and reads happen on the shared object via `take_shared` in later
/// transactions, exactly as a client PTB would compose them. Complements the
/// unit module's boundary/abort/math coverage.
#[test_only]
module release_dsp_link::release_dsp_link_e2e_tests;

use miso::release::{Self, Release};
use miso::test_helpers;
use miso::track;
use release_dsp_link::release_dsp_link as links;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

// ADMIN holds the release's admin cap and performs the cap-gated writes.
// STRANGER owns nothing and proves the views are genuinely permissionless.
const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

/// Publish → share → operate across transactions and senders: ADMIN sets a
/// release-level link and a per-track link on the freshly-shared release;
/// STRANGER (owning nothing) reads them back permissionlessly; ADMIN then
/// clears both and the event log across the whole flow is pinned exactly.
#[test]
fun published_shared_release_dsp_links_full_lifecycle() {
    let mut ts = test_scenario::begin(ADMIN);

    // --- Tx 1 (ADMIN): create a 2-track release and publish it — publish
    // shares the release, exactly as production does. ---
    let comp_id = test_helpers::fake_id(ts.ctx());
    let rec_0 = test_helpers::fake_id(ts.ctx());
    let rec_1 = test_helpers::fake_id(ts.ctx());
    let placeholder = test_helpers::fake_id(ts.ctx());
    let tracks = vector[
        track::new_for_testing(comp_id, rec_0, placeholder, 6000u16),
        track::new_for_testing(comp_id, rec_1, placeholder, 4000u16),
    ];
    let (rel, rel_cap) = release::new_for_testing(b"EP".to_string(), tracks, ts.ctx());
    let release_id = object::id(&rel);
    let clock = sui::clock::create_for_testing(ts.ctx());
    rel.publish(&rel_cap, &clock); // shares the release
    clock.destroy_for_testing();

    // --- Tx 2 (ADMIN): operate on the now-shared release via take_shared.
    // `sui::event::events_by_type` is scoped to the current test_scenario
    // transaction (each `next_tx` starts a fresh event log — see
    // `TransactionEffects.num_user_events`), so payload assertions happen
    // here, in the same transaction as the emitting call. ---
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    links::set_release_link(&mut rel, &rel_cap, links::new_spotify(b"albumid".to_string()));
    links::set_track_link(
        &mut rel,
        &rel_cap,
        0,
        links::new_apple_music_track(b"us".to_string(), b"1".to_string(), b"2".to_string()),
    );

    let set_events = event::events_by_type<links::ReleaseLinkSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (set_release_id, set_link) = links::release_link_set_event_fields(&set_events[0]);
    assert_eq!(set_release_id, release_id);
    assert_eq!(set_link, links::new_spotify(b"albumid".to_string()));

    let track_events = event::events_by_type<links::TrackLinkSetEvent>();
    assert_eq!(track_events.length(), 1);
    let (t0_release_id, t0_platform, t0_index, t0_link) =
        links::track_link_set_event_fields(&track_events[0]);
    assert_eq!(t0_release_id, release_id);
    assert_eq!(t0_platform, links::platform_apple_music());
    assert_eq!(t0_index, 0);
    assert_eq!(
        t0_link.destroy_some(),
        links::new_apple_music_track(b"us".to_string(), b"1".to_string(), b"2".to_string()),
    );

    test_scenario::return_shared(rel);

    // --- Tx 3 (STRANGER, owns nothing): permissionless reads against the
    // shared release. Track 1's Apple Music slot was never set, so it reads
    // none (the frontend falls back to the album-level link; the raw view
    // itself makes no such substitution). ---
    ts.next_tx(STRANGER);
    let rel = ts.take_shared<Release>();
    assert!(links::has_release_link(&rel, links::platform_spotify()));
    assert_eq!(
        links::release_link(&rel, links::platform_spotify()).destroy_some(),
        links::new_spotify(b"albumid".to_string()),
    );
    assert_eq!(
        links::track_link(&rel, links::platform_apple_music(), 0).destroy_some(),
        links::new_apple_music_track(b"us".to_string(), b"1".to_string(), b"2".to_string()),
    );
    assert!(links::track_link(&rel, links::platform_apple_music(), 1).is_none());
    test_scenario::return_shared(rel);

    // --- Tx 4 (ADMIN): clear both; the clear events are this transaction's
    // whole log (each `next_tx` starts a fresh one), so an unqualified
    // length check also proves nothing leaked across the boundary. ---
    ts.next_tx(ADMIN);
    let mut rel = ts.take_shared<Release>();
    links::clear_release_link(&mut rel, &rel_cap, links::platform_spotify());
    links::clear_track_link(&mut rel, &rel_cap, links::platform_apple_music(), 0);
    assert!(!links::has_release_link(&rel, links::platform_spotify()));
    assert!(links::track_link(&rel, links::platform_apple_music(), 0).is_none());

    let cleared_events = event::events_by_type<links::ReleaseLinkClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    let (cleared_release_id, cleared_platform) =
        links::release_link_cleared_event_fields(&cleared_events[0]);
    assert_eq!(cleared_release_id, release_id);
    assert_eq!(cleared_platform, links::platform_spotify());

    let track_events = event::events_by_type<links::TrackLinkSetEvent>();
    assert_eq!(track_events.length(), 1); // just this tx's clear, not tx 2's set
    let (t0_release_id, t0_platform, t0_index, t0_link) =
        links::track_link_set_event_fields(&track_events[0]);
    assert_eq!(t0_release_id, release_id);
    assert_eq!(t0_platform, links::platform_apple_music());
    assert_eq!(t0_index, 0);
    assert!(t0_link.is_none()); // the clear, written as a none slot

    test_scenario::return_shared(rel);
    destroy(rel_cap);
    ts.end();
}

/// Adversarial: a cap minted for a different release is rejected against a
/// live, published, shared release — the mismatch is on the cap's bound
/// release id (checked in `miso::release::authorize`), not on the sender, so
/// a stranger presenting a foreign-but-real cap aborts exactly like the
/// cap's rightful owner would.
#[test, expected_failure(abort_code = 0, location = miso::release)] // release::EUnauthorized
fun wrong_cap_rejected_against_shared_release() {
    let mut ts = test_scenario::begin(ADMIN);

    // Release A: published and shared.
    let comp_id = test_helpers::fake_id(ts.ctx());
    let rec_id = test_helpers::fake_id(ts.ctx());
    let placeholder = test_helpers::fake_id(ts.ctx());
    let tracks_a = vector[track::new_for_testing(comp_id, rec_id, placeholder, 10000u16)];
    let (rel_a, cap_a) = release::new_for_testing(b"A".to_string(), tracks_a, ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    rel_a.publish(&cap_a, &clock);
    clock.destroy_for_testing();
    destroy(cap_a);

    // Release B: never published — only its cap is needed, as a foreign key.
    let tracks_b = vector[track::new_for_testing(comp_id, rec_id, placeholder, 10000u16)];
    let (rel_b, cap_b) = release::new_for_testing(b"B".to_string(), tracks_b, ts.ctx());
    destroy(rel_b);

    // --- Tx 2 (STRANGER): attempts to write to A's shared release using B's
    // cap. ---
    ts.next_tx(STRANGER);
    let mut rel_a = ts.take_shared<Release>();
    links::set_release_link(&mut rel_a, &cap_b, links::new_spotify(b"x".to_string()));

    abort
}
