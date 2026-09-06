// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Release cover art: an album-level cover plus optional per-track cover
/// overrides. Stored as a dynamic field on the release's UID, set/cleared via
/// the release's cap-gated `uid_mut`.
///
/// Cover art is presentation, not objective recording data, so it lives on the
/// release (the consumer object) rather than the recording. A track's effective
/// cover resolves as: its per-track override if set, else the album cover. The
/// overrides are a `PerTrack<Option<CoverArt>>` — one slot per track, aligned to
/// the release's tracklist by construction (sized from `tracks().length()`).
module release_cover_art::release_cover_art;

use cover_art::cover_art::CoverArt;
use miso::release::{Release, ReleaseAdminCap};
use per_track::per_track::{Self, PerTrack};
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No cover art record is attached to this release.
const ENoCoverArt: u64 = 1;
/// Track index is out of bounds for this release's track count.
const ETrackIndexOutOfBounds: u64 = 2;

// === Structs ===

/// Dynamic-field key — one cover art record per release.
public struct ExtensionKey() has copy, drop, store;

/// The release's cover art: an album-level cover and per-track overrides. A
/// track with no override inherits the album cover.
public struct ReleaseCoverArt has store {
    cover: Option<CoverArt>,
    track_covers: PerTrack<Option<CoverArt>>,
}

// === Events ===

/// Emitted when the album-level cover is set or replaced.
public struct CoverSetEvent has copy, drop {
    release_id: ID,
    /// The full cover art record that was written.
    art: CoverArt,
}

/// Emitted when the album-level cover is removed. Per-track overrides are
/// unaffected.
public struct CoverUnsetEvent has copy, drop {
    release_id: ID,
}

/// Emitted when a track's cover override is set or replaced.
public struct TrackCoverSetEvent has copy, drop {
    release_id: ID,
    track_index: u64,
    /// The full cover art record that was written.
    art: CoverArt,
}

/// Emitted when a track's cover override is removed — the track falls back to
/// the album cover.
public struct TrackCoverUnsetEvent has copy, drop {
    release_id: ID,
    track_index: u64,
}

// === Public Functions ===

/// Sets (or replaces) the album-level cover.
public fun set_cover(self: &mut Release, cap: &ReleaseAdminCap, art: CoverArt) {
    let release_id = object::id(self);
    borrow_mut_or_init(self, cap).cover.swap_or_fill(art);
    emit(CoverSetEvent { release_id, art });
}

/// Removes the album-level cover. Per-track overrides are untouched. Aborts
/// with `ENoCoverArt` if no cover art record is attached.
public fun unset_cover(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self);
    let uid = self.uid_mut(cap); // cap gate first, on every path
    assert!(df::exists(uid, ExtensionKey()), ENoCoverArt);
    df::borrow_mut<ExtensionKey, ReleaseCoverArt>(uid, ExtensionKey()).cover = option::none();
    emit(CoverUnsetEvent { release_id });
}

/// Sets (or replaces) the cover override for a specific track (by tracklist
/// index). Aborts if the index is out of range for the release.
public fun set_track_cover(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    track_index: u64,
    art: CoverArt,
) {
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    let release_id = object::id(self);
    borrow_mut_or_init(self, cap).track_covers.borrow_mut(track_index).swap_or_fill(art);
    emit(TrackCoverSetEvent { release_id, track_index, art });
}

/// Removes the cover override for a specific track — the track then falls
/// back to the album cover. Aborts if no cover art record is attached, or if
/// the index is out of range for the release.
public fun unset_track_cover(self: &mut Release, cap: &ReleaseAdminCap, track_index: u64) {
    let total_tracks = self.tracks().length();
    let release_id = object::id(self);
    let uid = self.uid_mut(cap); // cap gate first, on every path
    assert!(df::exists(uid, ExtensionKey()), ENoCoverArt);
    assert!(track_index < total_tracks, ETrackIndexOutOfBounds);
    let record = df::borrow_mut<ExtensionKey, ReleaseCoverArt>(uid, ExtensionKey());
    *record.track_covers.borrow_mut(track_index) = option::none();
    emit(TrackCoverUnsetEvent { release_id, track_index });
}

// === View Functions ===

/// Returns whether a cover art record is attached to this release.
public fun has_cover_art(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// Returns the album-level cover (none if unset). Aborts if no cover art record
/// is attached at all.
public fun cover(self: &Release): &Option<CoverArt> {
    &borrow(self.uid()).cover
}

/// Returns a track's effective cover: its per-track override if set, otherwise
/// the album cover (which may itself be none). Aborts if no cover art record is
/// attached, or if the track index is out of range.
public fun track_cover(self: &Release, track_index: u64): Option<CoverArt> {
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    let record = borrow(self.uid());
    let override = record.track_covers.borrow(track_index);
    if (override.is_some()) *override else record.cover
}

// === Private Functions ===

fun borrow(uid: &UID): &ReleaseCoverArt {
    assert!(df::exists(uid, ExtensionKey()), ENoCoverArt);
    df::borrow(uid, ExtensionKey())
}

fun borrow_mut_or_init(self: &mut Release, cap: &ReleaseAdminCap): &mut ReleaseCoverArt {
    if (!df::exists(self.uid(), ExtensionKey())) {
        // Size the per-track overrides to the tracklist up front (all empty);
        // the release's track count is fixed at creation, so this stays valid.
        let track_covers = per_track::filled(self, option::none<CoverArt>());
        df::add(
            self.uid_mut(cap),
            ExtensionKey(),
            ReleaseCoverArt { cover: option::none(), track_covers },
        );
    };
    // The branch above establishes the field on every path, so the borrow
    // needs no existence check.
    df::borrow_mut(self.uid_mut(cap), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun cover_set_event_fields(e: &CoverSetEvent): (ID, CoverArt) {
    (e.release_id, e.art)
}

#[test_only]
public fun cover_unset_event_release_id(e: &CoverUnsetEvent): ID { e.release_id }

#[test_only]
public fun track_cover_set_event_fields(e: &TrackCoverSetEvent): (ID, u64, CoverArt) {
    (e.release_id, e.track_index, e.art)
}

#[test_only]
public fun track_cover_unset_event_fields(e: &TrackCoverUnsetEvent): (ID, u64) {
    (e.release_id, e.track_index)
}
