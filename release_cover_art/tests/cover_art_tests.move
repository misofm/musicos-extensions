// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `release_cover_art`'s abort surface, resolution rule,
/// no-op rule, and event payloads. Every test here operates as a single
/// actor on their own release in one transaction, so `tx_context::dummy()`
/// suffices. Wrong-cap aborts and the published-and-shared production flow
/// live in `cover_art_e2e_tests`, run under distinct senders.
#[test_only]
module release_cover_art::cover_art_tests;

use cover_art::cover_art as cover;
use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::track;
use release_cover_art::cover_art_fixtures as fixtures;
use release_cover_art::release_cover_art::{
    Self,
    ReleaseCoverArtSetEvent,
    ReleaseCoverArtClearedEvent,
    ReleaseTrackCoverArtSetEvent,
    ReleaseTrackCoverArtClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;

// A 3-track release: flat tracklist indices 0, 1, 2. Recording ids are
// synthetic — this package's logic never inspects them.
fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let rel_id = object::id_from_address(@0xB0B);
    let tracks = vector[
        track::new_for_testing(object::id_from_address(@0xA0), rel_id, 4000u16),
        track::new_for_testing(object::id_from_address(@0xA1), rel_id, 3000u16),
        track::new_for_testing(object::id_from_address(@0xA2), rel_id, 3000u16),
    ];
    release::new_for_testing(tracks, ctx)
}

/// Event fields, compared one at a time.
fun assert_set_event(
    e: &ReleaseCoverArtSetEvent,
    release_id: address,
    still_blob_id: u256,
    animated_blob_id: Option<u256>,
) {
    let (event_release_id, event_still, event_animated) = release_cover_art::set_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_still, still_blob_id);
    assert_eq!(event_animated, animated_blob_id);
}

fun assert_track_set_event(
    e: &ReleaseTrackCoverArtSetEvent,
    release_id: address,
    track_index: u64,
    still_blob_id: u256,
    animated_blob_id: Option<u256>,
) {
    let (event_release_id, event_index, event_still, event_animated) =
        release_cover_art::track_set_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_index, track_index);
    assert_eq!(event_still, still_blob_id);
    assert_eq!(event_animated, animated_blob_id);
}

fun assert_track_cleared_event(
    e: &ReleaseTrackCoverArtClearedEvent,
    release_id: address,
    track_index: u64,
) {
    let (event_release_id, event_index) = release_cover_art::track_cleared_event_fields(e);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_index, track_index);
}

#[test]
fun album_cover_set_read_clear() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    assert!(!release_cover_art::has_cover_art(&rel));
    release_cover_art::set_cover(&mut rel, &cap, cover::new_for_testing());
    assert!(release_cover_art::has_cover_art(&rel));
    assert!(release_cover_art::cover(&rel).is_some());

    release_cover_art::clear_cover(&mut rel, &cap);
    assert!(release_cover_art::has_cover_art(&rel));
    assert!(release_cover_art::cover(&rel).is_none());

    destroy(rel);
    destroy(cap);
}

#[test]
fun track_cover_override_resolves_over_album() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    let album = fixtures::plain(100);
    let override = fixtures::plain(200);
    let replacement = fixtures::plain(300);
    release_cover_art::set_cover(&mut rel, &cap, album);

    // No override yet: every track resolves to the album cover.
    assert_eq!(release_cover_art::track_cover(&rel, 0), option::some(album));
    assert_eq!(release_cover_art::track_cover(&rel, 2), option::some(album));

    // Set an override on track 1.
    release_cover_art::set_track_cover(&mut rel, &cap, 1, override);
    assert_eq!(release_cover_art::track_cover(&rel, 0), option::some(album));
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::some(override));
    assert_eq!(release_cover_art::track_cover(&rel, 2), option::some(album));

    // Replacing or clearing the album must preserve the independent override.
    release_cover_art::set_cover(&mut rel, &cap, replacement);
    assert_eq!(release_cover_art::track_cover(&rel, 0), option::some(replacement));
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::some(override));
    assert_eq!(release_cover_art::track_cover(&rel, 2), option::some(replacement));
    release_cover_art::clear_cover(&mut rel, &cap);
    assert_eq!(release_cover_art::track_cover(&rel, 0), option::none());
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::some(override));
    assert_eq!(release_cover_art::track_cover(&rel, 2), option::none());
    release_cover_art::set_cover(&mut rel, &cap, replacement);

    // Clear it; track 1 falls back to the album cover.
    release_cover_art::clear_track_cover(&mut rel, &cap, 1);
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::some(replacement));

    // With the album cover cleared and no override, a track resolves to none.
    release_cover_art::clear_cover(&mut rel, &cap);
    assert_eq!(release_cover_art::track_cover(&rel, 0), option::none());
    assert_eq!(release_cover_art::track_cover(&rel, 1), option::none());
    assert_eq!(release_cover_art::track_cover(&rel, 2), option::none());

    destroy(rel);
    destroy(cap);
}

// === Bounds ===

#[test, expected_failure(abort_code = release_cover_art::ETrackIndexOutOfBounds)]
fun set_track_cover_rejects_out_of_bounds_index() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx); // 3 tracks → index 3 is invalid
    release_cover_art::set_track_cover(&mut rel, &cap, 3, cover::new_for_testing());
    abort
}

// `track_cover`'s own bounds check (the view path) is a separate line from
// `set_track_cover`'s — exercised with nothing attached at all, so the bounds
// check must fire before the (absent) attachment would otherwise.
#[test, expected_failure(abort_code = release_cover_art::ETrackIndexOutOfBounds)]
fun track_cover_view_rejects_out_of_bounds_index() {
    let ctx = &mut tx_context::dummy();
    let (rel, _cap) = mk_release(ctx);
    let _ = release_cover_art::track_cover(&rel, 3);
    abort
}

// Argument validation precedes every stored-state check: an out-of-range
// clear aborts even though nothing is attached and an in-range clear would
// have been a silent no-op.
#[test, expected_failure(abort_code = release_cover_art::ETrackIndexOutOfBounds)]
fun clear_track_cover_rejects_out_of_bounds_index_when_unattached() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    release_cover_art::clear_track_cover(&mut rel, &cap, 3);
    abort
}

#[test, expected_failure(abort_code = release_cover_art::ETrackIndexOutOfBounds)]
fun clear_track_cover_rejects_out_of_bounds_index_when_attached() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    release_cover_art::set_cover(&mut rel, &cap, cover::new_for_testing());
    release_cover_art::clear_track_cover(&mut rel, &cap, 3);
    abort
}

// === Event payloads ===

#[test]
fun set_cover_emits_release_and_blob_ids() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel).to_address();

    release_cover_art::set_cover(&mut rel, &cap, fixtures::plain(100));

    let events = events_by_type<ReleaseCoverArtSetEvent>();
    assert_eq!(events.length(), 1);
    assert_set_event(&events[0], rel_id, 100, option::none());
    // Address, still blob ID, and an absent animated blob ID (one byte).
    assert_eq!(to_bytes(&events[0]).length(), 65);

    destroy(rel);
    destroy(cap);
}

#[test]
fun animated_cover_event_carries_both_blob_ids() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel).to_address();

    release_cover_art::set_cover(&mut rel, &cap, fixtures::animated(100, 101));

    let events = events_by_type<ReleaseCoverArtSetEvent>();
    assert_eq!(events.length(), 1);
    assert_set_event(&events[0], rel_id, 100, option::some(101));
    assert_eq!(to_bytes(&events[0]).length(), 97);
    assert!(release_cover_art::cover(&rel).is_some());

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_cover_emits_only_the_release() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel).to_address();

    release_cover_art::set_cover(&mut rel, &cap, cover::new_for_testing());
    release_cover_art::clear_cover(&mut rel, &cap);

    let events = events_by_type<ReleaseCoverArtClearedEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(release_cover_art::cleared_event_fields(&events[0]), rel_id);
    assert_eq!(to_bytes(&events[0]).length(), 32);

    destroy(rel);
    destroy(cap);
}

#[test]
fun set_track_cover_emits_release_index_and_blob_ids() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel).to_address();

    // A per-track set lazily initializes the record (no album cover first).
    release_cover_art::set_track_cover(&mut rel, &cap, 1, fixtures::animated(200, 201));
    assert!(release_cover_art::has_cover_art(&rel));
    assert!(release_cover_art::cover(&rel).is_none());

    let events = events_by_type<ReleaseTrackCoverArtSetEvent>();
    assert_eq!(events.length(), 1);
    assert_track_set_event(&events[0], rel_id, 1, 200, option::some(201));
    assert_eq!(to_bytes(&events[0]).length(), 105);

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_track_cover_emits_release_and_index() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let rel_id = object::id(&rel).to_address();

    release_cover_art::set_track_cover(&mut rel, &cap, 1, cover::new_for_testing());
    release_cover_art::clear_track_cover(&mut rel, &cap, 1);

    let events = events_by_type<ReleaseTrackCoverArtClearedEvent>();
    assert_eq!(events.length(), 1);
    assert_track_cleared_event(&events[0], rel_id, 1);
    assert_eq!(to_bytes(&events[0]).length(), 40);

    destroy(rel);
    destroy(cap);
}

// === No-op rule ===

#[test]
fun equal_sets_neither_write_nor_emit() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let art = fixtures::plain(100);

    release_cover_art::set_cover(&mut rel, &cap, art);
    release_cover_art::set_cover(&mut rel, &cap, art);
    assert_eq!(events_by_type<ReleaseCoverArtSetEvent>().length(), 1);

    release_cover_art::set_track_cover(&mut rel, &cap, 1, art);
    release_cover_art::set_track_cover(&mut rel, &cap, 1, art);
    assert_eq!(events_by_type<ReleaseTrackCoverArtSetEvent>().length(), 1);

    // Equality is over the whole value: the same still with an animation
    // added is a change.
    release_cover_art::set_cover(&mut rel, &cap, fixtures::animated(100, 101));
    assert_eq!(events_by_type<ReleaseCoverArtSetEvent>().length(), 2);

    destroy(rel);
    destroy(cap);
}

#[test]
fun clears_of_absent_values_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    // No record attached at all: nothing to remove, nothing attached either.
    release_cover_art::clear_cover(&mut rel, &cap);
    release_cover_art::clear_track_cover(&mut rel, &cap, 0);
    assert!(!release_cover_art::has_cover_art(&rel));
    assert_eq!(events_by_type<ReleaseCoverArtClearedEvent>().length(), 0);
    assert_eq!(events_by_type<ReleaseTrackCoverArtClearedEvent>().length(), 0);

    // Record attached, values absent.
    release_cover_art::set_cover(&mut rel, &cap, fixtures::plain(100));
    release_cover_art::clear_cover(&mut rel, &cap);
    release_cover_art::clear_cover(&mut rel, &cap);
    release_cover_art::clear_track_cover(&mut rel, &cap, 1);
    assert_eq!(events_by_type<ReleaseCoverArtClearedEvent>().length(), 1);
    assert_eq!(events_by_type<ReleaseTrackCoverArtClearedEvent>().length(), 0);

    release_cover_art::set_track_cover(&mut rel, &cap, 1, fixtures::plain(200));
    release_cover_art::clear_track_cover(&mut rel, &cap, 1);
    release_cover_art::clear_track_cover(&mut rel, &cap, 1);
    assert_eq!(events_by_type<ReleaseTrackCoverArtClearedEvent>().length(), 1);

    destroy(rel);
    destroy(cap);
}

// === Unattached aborts ===

#[test, expected_failure(abort_code = release_cover_art::ENoCoverArt)]
fun cover_view_without_attachment_aborts() {
    let ctx = &mut tx_context::dummy();
    let (rel, _cap) = mk_release(ctx);
    let _ = release_cover_art::cover(&rel);
    abort
}

#[test, expected_failure(abort_code = release_cover_art::ENoCoverArt)]
fun track_cover_view_without_attachment_aborts() {
    let ctx = &mut tx_context::dummy();
    let (rel, _cap) = mk_release(ctx);
    let _ = release_cover_art::track_cover(&rel, 0);
    abort
}
