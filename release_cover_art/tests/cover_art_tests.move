// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `release_cover_art`'s math/abort surface and event
/// payloads: index-bounds checks, unattached-record aborts, and the exact
/// event fields each write emits. Every test here operates as a single actor
/// on their own release — no cap crosses actors, so single-transaction
/// `tx_context::dummy()` (or a single-sender `test_scenario`, used where a
/// test wants Move's normal borrow-checked flow across several calls) adds
/// nothing over real transaction boundaries. Wrong-cap/wrong-actor aborts and
/// the published-and-shared production flow live in
/// `cover_art_e2e_tests.move`, run under distinct senders.
#[test_only]
module release_cover_art::cover_art_tests;

use cover_art::cover_art as cover;
use miso::release::{Release, ReleaseAdminCap};
use miso::test_helpers;
use miso::track;
use release_cover_art::release_cover_art;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const A: address = @0xA1;

// Mirrored from release_cover_art::release_cover_art (both private there).
const ENoCoverArt: u64 = 1;
const ETrackIndexOutOfBounds: u64 = 2;

// A 3-track release: flat tracklist indices 0, 1, 2. Composition/recording
// ids are synthetic (`fake_id`) — this package's logic never inspects them.
fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let rel_id = test_helpers::fake_id(ctx);
    let comp_id = test_helpers::fake_id(ctx);
    let r0 = test_helpers::fake_id(ctx);
    let r1 = test_helpers::fake_id(ctx);
    let r2 = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(comp_id, r0, rel_id, 4000u16),
        track::new_for_testing(comp_id, r1, rel_id, 3000u16),
        track::new_for_testing(comp_id, r2, rel_id, 3000u16),
    ];
    miso::release::new_for_testing(b"Album".to_string(), tracks, ctx)
}

#[test]
fun album_cover_set_read_unset() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());

    assert!(!release_cover_art::has_cover_art(&rel));
    release_cover_art::set_cover(&mut rel, &cap, cover::new_for_testing());
    assert!(release_cover_art::has_cover_art(&rel));
    assert!(release_cover_art::cover(&rel).is_some());

    release_cover_art::unset_cover(&mut rel, &cap);
    assert!(release_cover_art::cover(&rel).is_none());

    destroy(rel);
    destroy(cap);
    ts.end();
}

#[test]
fun track_cover_override_resolves_over_album() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx());

    release_cover_art::set_cover(&mut rel, &cap, cover::new_for_testing());

    // No override yet: every track resolves to the album cover.
    assert!(release_cover_art::track_cover(&rel, 0).is_some());
    assert!(release_cover_art::track_cover(&rel, 2).is_some());

    // Set an override on track 1.
    release_cover_art::set_track_cover(&mut rel, &cap, 1, cover::new_for_testing());
    assert!(release_cover_art::track_cover(&rel, 1).is_some());

    // Clear it; track 1 falls back to the album cover.
    release_cover_art::unset_track_cover(&mut rel, &cap, 1);
    assert!(release_cover_art::track_cover(&rel, 1).is_some());

    // With the album cover unset and no override, a track resolves to none.
    release_cover_art::unset_cover(&mut rel, &cap);
    assert!(release_cover_art::track_cover(&rel, 0).is_none());

    destroy(rel);
    destroy(cap);
    ts.end();
}

#[test, expected_failure(abort_code = ETrackIndexOutOfBounds, location = release_cover_art)]
fun set_track_cover_rejects_out_of_bounds_index() {
    let mut ts = test_scenario::begin(A);
    let (mut rel, cap) = mk_release(ts.ctx()); // 3 tracks → index 3 is invalid
    release_cover_art::set_track_cover(&mut rel, &cap, 3, cover::new_for_testing());
    abort
}

// `track_cover`'s own bounds check (the view path) is a separate line from
// `set_track_cover`'s — exercised here with nothing attached at all, so the
// bounds check must fire before the (absent) attachment would otherwise.
#[test, expected_failure(abort_code = ETrackIndexOutOfBounds, location = release_cover_art)]
fun track_cover_view_rejects_out_of_bounds_index() {
    let ctx = &mut tx_context::dummy();
    let (rel, _cap) = mk_release(ctx); // 3 tracks → index 3 is invalid

    let _ = release_cover_art::track_cover(&rel, 3);
    abort
}

// `unset_track_cover`'s bounds check sits behind its attachment check (cap
// gate first, then `ENoCoverArt`, then bounds) — attach a record first so
// this test actually reaches the bounds-check line rather than re-hitting
// the unattached abort.
#[test, expected_failure(abort_code = ETrackIndexOutOfBounds, location = release_cover_art)]
fun unset_track_cover_rejects_out_of_bounds_index_when_attached() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    release_cover_art::set_cover(&mut rel, &cap, cover::new_for_testing()); // attaches the record

    release_cover_art::unset_track_cover(&mut rel, &cap, 3);
    abort
}

// === Event assertions ===

#[test]
fun set_cover_emits_release_and_art() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel);

    release_cover_art::set_cover(&mut rel, &cap, cover::new_for_testing());

    let events = event::events_by_type<release_cover_art::CoverSetEvent>();
    assert_eq!(events.length(), 1);
    let (release_id, art) = release_cover_art::cover_set_event_fields(&events[0]);
    assert_eq!(release_id, rel_id);
    assert_eq!(art, cover::new_for_testing());

    destroy(rel);
    destroy(cap);
}

#[test]
fun unset_cover_emits_release_id() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel);

    release_cover_art::set_cover(&mut rel, &cap, cover::new_for_testing());
    release_cover_art::unset_cover(&mut rel, &cap);

    let events = event::events_by_type<release_cover_art::CoverUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(release_cover_art::cover_unset_event_release_id(&events[0]), rel_id);

    destroy(rel);
    destroy(cap);
}

#[test]
fun set_track_cover_emits_release_index_and_art() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel);

    // A per-track set lazily initializes the record (no album cover first).
    release_cover_art::set_track_cover(&mut rel, &cap, 1, cover::new_for_testing());

    let events = event::events_by_type<release_cover_art::TrackCoverSetEvent>();
    assert_eq!(events.length(), 1);
    let (release_id, track_index, art) = release_cover_art::track_cover_set_event_fields(&events[0]);
    assert_eq!(release_id, rel_id);
    assert_eq!(track_index, 1);
    assert_eq!(art, cover::new_for_testing());

    destroy(rel);
    destroy(cap);
}

#[test]
fun unset_track_cover_emits_release_and_index() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel);

    release_cover_art::set_track_cover(&mut rel, &cap, 1, cover::new_for_testing());
    release_cover_art::unset_track_cover(&mut rel, &cap, 1);

    let events = event::events_by_type<release_cover_art::TrackCoverUnsetEvent>();
    assert_eq!(events.length(), 1);
    let (release_id, track_index) = release_cover_art::track_cover_unset_event_fields(&events[0]);
    assert_eq!(release_id, rel_id);
    assert_eq!(track_index, 1);

    destroy(rel);
    destroy(cap);
}

// === Unattached aborts ===

#[test, expected_failure(abort_code = ENoCoverArt, location = release_cover_art)]
fun unset_cover_without_attachment_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    release_cover_art::unset_cover(&mut rel, &cap);
    abort
}

#[test, expected_failure(abort_code = ENoCoverArt, location = release_cover_art)]
fun unset_track_cover_without_attachment_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    release_cover_art::unset_track_cover(&mut rel, &cap, 0);
    abort
}

#[test, expected_failure(abort_code = ENoCoverArt, location = release_cover_art)]
fun cover_view_without_attachment_aborts() {
    let ctx = &mut tx_context::dummy();
    let (rel, _cap) = mk_release(ctx);

    let _ = release_cover_art::cover(&rel);
    abort
}

#[test, expected_failure(abort_code = ENoCoverArt, location = release_cover_art)]
fun track_cover_view_without_attachment_aborts() {
    let ctx = &mut tx_context::dummy();
    let (rel, _cap) = mk_release(ctx);

    let _ = release_cover_art::track_cover(&rel, 0);
    abort
}
