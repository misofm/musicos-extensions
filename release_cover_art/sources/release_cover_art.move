// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Release cover art: an album-level cover plus optional per-track overrides,
/// stored as one record under a dynamic field on the release's UID and
/// written through its cap-gated `uid_mut`. Reads are permissionless.
///
/// Cover art is presentation, not objective recording data, so it lives on
/// the release rather than the recording. A track's effective cover resolves
/// to its override if set, else the album cover. The overrides are a
/// `PerTrack<Option<CoverArt>>` — one slot per track, aligned to the
/// release's tracklist by construction.
module release_cover_art::release_cover_art;

use cover_art::cover_art::CoverArt;
use musicos::release::{Release, ReleaseAdminCap};
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

/// Emitted when the album cover is set to a value it did not already hold.
/// The blob IDs are the value; a blob's confidentiality envelope (sealed DEK)
/// is unbounded and is read from the release.
public struct ReleaseCoverArtSetEvent has copy, drop {
    release_id: address,
    still_blob_id: u256,
    animated_blob_id: Option<u256>,
}

/// Emitted when an attached album cover is removed. Overrides are unaffected.
public struct ReleaseCoverArtClearedEvent has copy, drop {
    release_id: address,
}

/// Emitted when a track's override is set to a value it did not already hold.
public struct ReleaseTrackCoverArtSetEvent has copy, drop {
    release_id: address,
    track_index: u64,
    still_blob_id: u256,
    animated_blob_id: Option<u256>,
}

/// Emitted when an attached track override is removed; the track falls back
/// to the album cover.
public struct ReleaseTrackCoverArtClearedEvent has copy, drop {
    release_id: address,
    track_index: u64,
}

// === Public Functions ===

/// Sets (or replaces) the album cover, attaching the record on first use.
/// Setting the value already held neither writes nor emits.
public fun set_cover(self: &mut Release, cap: &ReleaseAdminCap, art: CoverArt) {
    let release_id = object::id(self).to_address();
    let cover = &mut borrow_mut_or_init(self, cap).cover;
    if (cover.contains(&art)) return;
    cover.swap_or_fill(art);
    let (still_blob_id, animated_blob_id) = blob_ids(&art);
    emit(ReleaseCoverArtSetEvent { release_id, still_blob_id, animated_blob_id });
}

/// Removes the album cover, if any. Overrides are untouched. Silent when no
/// record is attached or the album cover is already absent.
public fun clear_cover(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let record: &mut ReleaseCoverArt = df::borrow_mut(uid, ExtensionKey());
    if (record.cover.is_none()) return;
    record.cover = option::none();
    emit(ReleaseCoverArtClearedEvent { release_id });
}

/// Sets (or replaces) the override for the track at `track_index`, attaching
/// the record on first use. Aborts `ETrackIndexOutOfBounds` past the
/// tracklist. Setting the value already held neither writes nor emits.
public fun set_track_cover(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    track_index: u64,
    art: CoverArt,
) {
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    let release_id = object::id(self).to_address();
    let slot = borrow_mut_or_init(self, cap).track_covers.borrow_mut(track_index);
    if (slot.contains(&art)) return;
    slot.swap_or_fill(art);
    let (still_blob_id, animated_blob_id) = blob_ids(&art);
    emit(ReleaseTrackCoverArtSetEvent {
        release_id,
        track_index,
        still_blob_id,
        animated_blob_id,
    });
}

/// Removes the override for the track at `track_index`, if any; the track
/// then falls back to the album cover. Aborts `ETrackIndexOutOfBounds` past
/// the tracklist. Silent when no record is attached or the override is
/// already absent.
public fun clear_track_cover(self: &mut Release, cap: &ReleaseAdminCap, track_index: u64) {
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let record: &mut ReleaseCoverArt = df::borrow_mut(uid, ExtensionKey());
    let slot = record.track_covers.borrow_mut(track_index);
    if (slot.is_none()) return;
    *slot = option::none();
    emit(ReleaseTrackCoverArtClearedEvent { release_id, track_index });
}

// === View Functions ===

/// Whether a cover art record is attached to this release.
public fun has_cover_art(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The album cover (none if unset). Aborts `ENoCoverArt` when no record is
/// attached.
public fun cover(self: &Release): &Option<CoverArt> {
    &borrow(self.uid()).cover
}

/// A track's effective cover: its override if set, otherwise the album cover
/// (which may itself be none). Aborts `ETrackIndexOutOfBounds` past the
/// tracklist and `ENoCoverArt` when no record is attached.
public fun track_cover(self: &Release, track_index: u64): Option<CoverArt> {
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    let record = borrow(self.uid());
    let override = record.track_covers.borrow(track_index);
    if (override.is_some()) *override else record.cover
}

// === Private Functions ===

/// The still and optional animated blob IDs an event carries for `art`.
fun blob_ids(art: &CoverArt): (u256, Option<u256>) {
    (art.still().blob_id(), art.animated().map_ref!(|blob| blob.blob_id()))
}

fun borrow(uid: &UID): &ReleaseCoverArt {
    assert!(df::exists(uid, ExtensionKey()), ENoCoverArt);
    df::borrow(uid, ExtensionKey())
}

/// The record, attached on first use with every override empty. The
/// tracklist is fixed at release creation, so the overrides stay aligned.
/// The cap gate runs before the existence check on every path.
fun borrow_mut_or_init(self: &mut Release, cap: &ReleaseAdminCap): &mut ReleaseCoverArt {
    if (!df::exists(self.uid_mut(cap), ExtensionKey())) {
        let track_covers = per_track::filled(self, option::none<CoverArt>());
        df::add(
            self.uid_mut(cap),
            ExtensionKey(),
            ReleaseCoverArt { cover: option::none(), track_covers },
        );
    };
    df::borrow_mut(self.uid_mut(cap), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields(e: &ReleaseCoverArtSetEvent): (address, u256, Option<u256>) {
    (e.release_id, e.still_blob_id, e.animated_blob_id)
}

#[test_only]
public fun cleared_event_fields(e: &ReleaseCoverArtClearedEvent): address {
    e.release_id
}

#[test_only]
public fun track_set_event_fields(
    e: &ReleaseTrackCoverArtSetEvent,
): (address, u64, u256, Option<u256>) {
    (e.release_id, e.track_index, e.still_blob_id, e.animated_blob_id)
}

#[test_only]
public fun track_cleared_event_fields(e: &ReleaseTrackCoverArtClearedEvent): (address, u64) {
    (e.release_id, e.track_index)
}
