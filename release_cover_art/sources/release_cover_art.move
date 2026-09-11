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
use musicos::release::{Release, ReleaseAdminCap};
use musicos::track;
use per_track::per_track::{Self, PerTrack};
use sui::dynamic_field as df;
use sui::event::emit;
use sui::hash::blake2b256;

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
public struct ReleaseCoverArtSetEvent has copy, drop {
    release_id: address,
    admin_cap_id: address,
    track_count: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    previous_present: bool,
    previous_still_blob_id: u256,
    previous_still_is_encrypted: bool,
    previous_still_sealed_dek_length: u64,
    previous_still_sealed_dek_digest: vector<u8>,
    previous_has_animated: bool,
    previous_animated_blob_id: u256,
    previous_animated_is_encrypted: bool,
    previous_animated_sealed_dek_length: u64,
    previous_animated_sealed_dek_digest: vector<u8>,
    current_present: bool,
    current_still_blob_id: u256,
    current_still_is_encrypted: bool,
    current_still_sealed_dek_length: u64,
    current_still_sealed_dek_digest: vector<u8>,
    current_has_animated: bool,
    current_animated_blob_id: u256,
    current_animated_is_encrypted: bool,
    current_animated_sealed_dek_length: u64,
    current_animated_sealed_dek_digest: vector<u8>,
}

/// Emitted when the album-level cover is removed. Per-track overrides are
/// unaffected.
public struct ReleaseCoverArtUnsetEvent has copy, drop {
    release_id: address,
    admin_cap_id: address,
    track_count: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    previous_present: bool,
    previous_still_blob_id: u256,
    previous_still_is_encrypted: bool,
    previous_still_sealed_dek_length: u64,
    previous_still_sealed_dek_digest: vector<u8>,
    previous_has_animated: bool,
    previous_animated_blob_id: u256,
    previous_animated_is_encrypted: bool,
    previous_animated_sealed_dek_length: u64,
    previous_animated_sealed_dek_digest: vector<u8>,
    current_present: bool,
    current_still_blob_id: u256,
    current_still_is_encrypted: bool,
    current_still_sealed_dek_length: u64,
    current_still_sealed_dek_digest: vector<u8>,
    current_has_animated: bool,
    current_animated_blob_id: u256,
    current_animated_is_encrypted: bool,
    current_animated_sealed_dek_length: u64,
    current_animated_sealed_dek_digest: vector<u8>,
}

/// Emitted when a track's cover override is set or replaced.
public struct ReleaseTrackCoverArtSetEvent has copy, drop {
    release_id: address,
    admin_cap_id: address,
    track_count: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    track_index: u64,
    recording_id: address,
    composition_id: address,
    previous_present: bool,
    previous_still_blob_id: u256,
    previous_still_is_encrypted: bool,
    previous_still_sealed_dek_length: u64,
    previous_still_sealed_dek_digest: vector<u8>,
    previous_has_animated: bool,
    previous_animated_blob_id: u256,
    previous_animated_is_encrypted: bool,
    previous_animated_sealed_dek_length: u64,
    previous_animated_sealed_dek_digest: vector<u8>,
    current_present: bool,
    current_still_blob_id: u256,
    current_still_is_encrypted: bool,
    current_still_sealed_dek_length: u64,
    current_still_sealed_dek_digest: vector<u8>,
    current_has_animated: bool,
    current_animated_blob_id: u256,
    current_animated_is_encrypted: bool,
    current_animated_sealed_dek_length: u64,
    current_animated_sealed_dek_digest: vector<u8>,
    album_present: bool,
    album_still_blob_id: u256,
    album_still_is_encrypted: bool,
    album_still_sealed_dek_length: u64,
    album_still_sealed_dek_digest: vector<u8>,
    album_has_animated: bool,
    album_animated_blob_id: u256,
    album_animated_is_encrypted: bool,
    album_animated_sealed_dek_length: u64,
    album_animated_sealed_dek_digest: vector<u8>,
}

/// Emitted when a track's cover override is removed — the track falls back to
/// the album cover.
public struct ReleaseTrackCoverArtUnsetEvent has copy, drop {
    release_id: address,
    admin_cap_id: address,
    track_count: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    track_index: u64,
    recording_id: address,
    composition_id: address,
    previous_present: bool,
    previous_still_blob_id: u256,
    previous_still_is_encrypted: bool,
    previous_still_sealed_dek_length: u64,
    previous_still_sealed_dek_digest: vector<u8>,
    previous_has_animated: bool,
    previous_animated_blob_id: u256,
    previous_animated_is_encrypted: bool,
    previous_animated_sealed_dek_length: u64,
    previous_animated_sealed_dek_digest: vector<u8>,
    current_present: bool,
    current_still_blob_id: u256,
    current_still_is_encrypted: bool,
    current_still_sealed_dek_length: u64,
    current_still_sealed_dek_digest: vector<u8>,
    current_has_animated: bool,
    current_animated_blob_id: u256,
    current_animated_is_encrypted: bool,
    current_animated_sealed_dek_length: u64,
    current_animated_sealed_dek_digest: vector<u8>,
    album_present: bool,
    album_still_blob_id: u256,
    album_still_is_encrypted: bool,
    album_still_sealed_dek_length: u64,
    album_still_sealed_dek_digest: vector<u8>,
    album_has_animated: bool,
    album_animated_blob_id: u256,
    album_animated_is_encrypted: bool,
    album_animated_sealed_dek_length: u64,
    album_animated_sealed_dek_digest: vector<u8>,
}

// === Public Functions ===

/// Sets (or replaces) the album-level cover.
public fun set_cover(self: &mut Release, cap: &ReleaseAdminCap, art: CoverArt) {
    let release_id = object::id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let track_count = self.tracks().length();
    let field_existed_before = df::exists(self.uid(), ExtensionKey());
    let (previous, current) = {
        let record = borrow_mut_or_init(self, cap);
        let previous = record.cover;
        record.cover.swap_or_fill(art);
        let current = record.cover;
        (previous, current)
    };
    let (
        previous_present,
        previous_still_blob_id,
        previous_still_is_encrypted,
        previous_still_sealed_dek_length,
        previous_still_sealed_dek_digest,
        previous_has_animated,
        previous_animated_blob_id,
        previous_animated_is_encrypted,
        previous_animated_sealed_dek_length,
        previous_animated_sealed_dek_digest,
    ) = cover_snapshot(&previous);
    let (
        current_present,
        current_still_blob_id,
        current_still_is_encrypted,
        current_still_sealed_dek_length,
        current_still_sealed_dek_digest,
        current_has_animated,
        current_animated_blob_id,
        current_animated_is_encrypted,
        current_animated_sealed_dek_length,
        current_animated_sealed_dek_digest,
    ) = cover_snapshot(&current);
    emit(ReleaseCoverArtSetEvent {
        release_id,
        admin_cap_id,
        track_count,
        field_existed_before,
        field_exists_after: true,
        previous_present,
        previous_still_blob_id,
        previous_still_is_encrypted,
        previous_still_sealed_dek_length,
        previous_still_sealed_dek_digest,
        previous_has_animated,
        previous_animated_blob_id,
        previous_animated_is_encrypted,
        previous_animated_sealed_dek_length,
        previous_animated_sealed_dek_digest,
        current_present,
        current_still_blob_id,
        current_still_is_encrypted,
        current_still_sealed_dek_length,
        current_still_sealed_dek_digest,
        current_has_animated,
        current_animated_blob_id,
        current_animated_is_encrypted,
        current_animated_sealed_dek_length,
        current_animated_sealed_dek_digest,
    });
}

/// Removes the album-level cover. Per-track overrides are untouched. Aborts
/// with `ENoCoverArt` if no cover art record is attached.
public fun unset_cover(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let track_count = self.tracks().length();
    let uid = self.uid_mut(cap); // cap gate first, on every path
    assert!(df::exists(uid, ExtensionKey()), ENoCoverArt);
    let (previous, current) = {
        let record = df::borrow_mut<ExtensionKey, ReleaseCoverArt>(uid, ExtensionKey());
        let previous = record.cover;
        record.cover = option::none();
        let current = record.cover;
        (previous, current)
    };
    let (
        previous_present,
        previous_still_blob_id,
        previous_still_is_encrypted,
        previous_still_sealed_dek_length,
        previous_still_sealed_dek_digest,
        previous_has_animated,
        previous_animated_blob_id,
        previous_animated_is_encrypted,
        previous_animated_sealed_dek_length,
        previous_animated_sealed_dek_digest,
    ) = cover_snapshot(&previous);
    let (
        current_present,
        current_still_blob_id,
        current_still_is_encrypted,
        current_still_sealed_dek_length,
        current_still_sealed_dek_digest,
        current_has_animated,
        current_animated_blob_id,
        current_animated_is_encrypted,
        current_animated_sealed_dek_length,
        current_animated_sealed_dek_digest,
    ) = cover_snapshot(&current);
    emit(ReleaseCoverArtUnsetEvent {
        release_id,
        admin_cap_id,
        track_count,
        field_existed_before: true,
        field_exists_after: true,
        previous_present,
        previous_still_blob_id,
        previous_still_is_encrypted,
        previous_still_sealed_dek_length,
        previous_still_sealed_dek_digest,
        previous_has_animated,
        previous_animated_blob_id,
        previous_animated_is_encrypted,
        previous_animated_sealed_dek_length,
        previous_animated_sealed_dek_digest,
        current_present,
        current_still_blob_id,
        current_still_is_encrypted,
        current_still_sealed_dek_length,
        current_still_sealed_dek_digest,
        current_has_animated,
        current_animated_blob_id,
        current_animated_is_encrypted,
        current_animated_sealed_dek_length,
        current_animated_sealed_dek_digest,
    });
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
    let release_id = object::id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let track_count = self.tracks().length();
    let field_existed_before = df::exists(self.uid(), ExtensionKey());
    let selected_track = &self.tracks()[track_index];
    let recording_id = track::recording_id(selected_track).to_address();
    let composition_id = track::composition_id(selected_track).to_address();
    let (previous, current, album) = {
        let record = borrow_mut_or_init(self, cap);
        let album = record.cover;
        let slot = record.track_covers.borrow_mut(track_index);
        let previous = *slot;
        slot.swap_or_fill(art);
        let current = *slot;
        (previous, current, album)
    };
    let (
        previous_present,
        previous_still_blob_id,
        previous_still_is_encrypted,
        previous_still_sealed_dek_length,
        previous_still_sealed_dek_digest,
        previous_has_animated,
        previous_animated_blob_id,
        previous_animated_is_encrypted,
        previous_animated_sealed_dek_length,
        previous_animated_sealed_dek_digest,
    ) = cover_snapshot(&previous);
    let (
        current_present,
        current_still_blob_id,
        current_still_is_encrypted,
        current_still_sealed_dek_length,
        current_still_sealed_dek_digest,
        current_has_animated,
        current_animated_blob_id,
        current_animated_is_encrypted,
        current_animated_sealed_dek_length,
        current_animated_sealed_dek_digest,
    ) = cover_snapshot(&current);
    let (
        album_present,
        album_still_blob_id,
        album_still_is_encrypted,
        album_still_sealed_dek_length,
        album_still_sealed_dek_digest,
        album_has_animated,
        album_animated_blob_id,
        album_animated_is_encrypted,
        album_animated_sealed_dek_length,
        album_animated_sealed_dek_digest,
    ) = cover_snapshot(&album);
    emit(ReleaseTrackCoverArtSetEvent {
        release_id,
        admin_cap_id,
        track_count,
        field_existed_before,
        field_exists_after: true,
        track_index,
        recording_id,
        composition_id,
        previous_present,
        previous_still_blob_id,
        previous_still_is_encrypted,
        previous_still_sealed_dek_length,
        previous_still_sealed_dek_digest,
        previous_has_animated,
        previous_animated_blob_id,
        previous_animated_is_encrypted,
        previous_animated_sealed_dek_length,
        previous_animated_sealed_dek_digest,
        current_present,
        current_still_blob_id,
        current_still_is_encrypted,
        current_still_sealed_dek_length,
        current_still_sealed_dek_digest,
        current_has_animated,
        current_animated_blob_id,
        current_animated_is_encrypted,
        current_animated_sealed_dek_length,
        current_animated_sealed_dek_digest,
        album_present,
        album_still_blob_id,
        album_still_is_encrypted,
        album_still_sealed_dek_length,
        album_still_sealed_dek_digest,
        album_has_animated,
        album_animated_blob_id,
        album_animated_is_encrypted,
        album_animated_sealed_dek_length,
        album_animated_sealed_dek_digest,
    });
}

/// Removes the cover override for a specific track — the track then falls
/// back to the album cover. Aborts if no cover art record is attached, or if
/// the index is out of range for the release.
public fun unset_track_cover(self: &mut Release, cap: &ReleaseAdminCap, track_index: u64) {
    let total_tracks = self.tracks().length();
    let release_id = object::id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    self.uid_mut(cap); // cap gate first, on every path
    assert!(df::exists(self.uid(), ExtensionKey()), ENoCoverArt);
    assert!(track_index < total_tracks, ETrackIndexOutOfBounds);
    let track_count = total_tracks;
    let selected_track = &self.tracks()[track_index];
    let recording_id = track::recording_id(selected_track).to_address();
    let composition_id = track::composition_id(selected_track).to_address();
    let (previous, current, album) = {
        let uid = self.uid_mut(cap);
        let record = df::borrow_mut<ExtensionKey, ReleaseCoverArt>(uid, ExtensionKey());
        let album = record.cover;
        let slot = record.track_covers.borrow_mut(track_index);
        let previous = *slot;
        *slot = option::none();
        let current = *slot;
        (previous, current, album)
    };
    let (
        previous_present,
        previous_still_blob_id,
        previous_still_is_encrypted,
        previous_still_sealed_dek_length,
        previous_still_sealed_dek_digest,
        previous_has_animated,
        previous_animated_blob_id,
        previous_animated_is_encrypted,
        previous_animated_sealed_dek_length,
        previous_animated_sealed_dek_digest,
    ) = cover_snapshot(&previous);
    let (
        current_present,
        current_still_blob_id,
        current_still_is_encrypted,
        current_still_sealed_dek_length,
        current_still_sealed_dek_digest,
        current_has_animated,
        current_animated_blob_id,
        current_animated_is_encrypted,
        current_animated_sealed_dek_length,
        current_animated_sealed_dek_digest,
    ) = cover_snapshot(&current);
    let (
        album_present,
        album_still_blob_id,
        album_still_is_encrypted,
        album_still_sealed_dek_length,
        album_still_sealed_dek_digest,
        album_has_animated,
        album_animated_blob_id,
        album_animated_is_encrypted,
        album_animated_sealed_dek_length,
        album_animated_sealed_dek_digest,
    ) = cover_snapshot(&album);
    emit(ReleaseTrackCoverArtUnsetEvent {
        release_id,
        admin_cap_id,
        track_count,
        field_existed_before: true,
        field_exists_after: true,
        track_index,
        recording_id,
        composition_id,
        previous_present,
        previous_still_blob_id,
        previous_still_is_encrypted,
        previous_still_sealed_dek_length,
        previous_still_sealed_dek_digest,
        previous_has_animated,
        previous_animated_blob_id,
        previous_animated_is_encrypted,
        previous_animated_sealed_dek_length,
        previous_animated_sealed_dek_digest,
        current_present,
        current_still_blob_id,
        current_still_is_encrypted,
        current_still_sealed_dek_length,
        current_still_sealed_dek_digest,
        current_has_animated,
        current_animated_blob_id,
        current_animated_is_encrypted,
        current_animated_sealed_dek_length,
        current_animated_sealed_dek_digest,
        album_present,
        album_still_blob_id,
        album_still_is_encrypted,
        album_still_sealed_dek_length,
        album_still_sealed_dek_digest,
        album_has_animated,
        album_animated_blob_id,
        album_animated_is_encrypted,
        album_animated_sealed_dek_length,
        album_animated_sealed_dek_digest,
    });
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

fun cover_snapshot(
    cover: &Option<CoverArt>,
): (bool, u256, bool, u64, vector<u8>, bool, u256, bool, u64, vector<u8>) {
    if (cover.is_none()) {
        (false, 0, false, 0, vector[], false, 0, false, 0, vector[])
    } else {
        let art = cover.borrow();
        let still = art.still();
        let still_confidentiality = still.blob_confidentiality();
        let (
            still_is_encrypted,
            still_sealed_dek_length,
            still_sealed_dek_digest,
        ) = if (still_confidentiality.is_encrypted()) {
            let sealed_dek = still_confidentiality.sealed_dek();
            (true, sealed_dek.length(), blake2b256(sealed_dek))
        } else {
            (false, 0, vector[])
        };
        let still_blob_id = still.blob_id();
        let (
            has_animated,
            animated_blob_id,
            animated_is_encrypted,
            animated_sealed_dek_length,
            animated_sealed_dek_digest,
        ) = if (art.animated().is_some()) {
            let animated = art.animated().borrow();
            let confidentiality = animated.blob_confidentiality();
            let (is_encrypted, sealed_dek_length, sealed_dek_digest) =
                if (confidentiality.is_encrypted()) {
                    let sealed_dek = confidentiality.sealed_dek();
                    (true, sealed_dek.length(), blake2b256(sealed_dek))
                } else {
                    (false, 0, vector[])
                };
            (
                true,
                animated.blob_id(),
                is_encrypted,
                sealed_dek_length,
                sealed_dek_digest,
            )
        } else {
            (false, 0, false, 0, vector[])
        };
        (
            true,
            still_blob_id,
            still_is_encrypted,
            still_sealed_dek_length,
            still_sealed_dek_digest,
            has_animated,
            animated_blob_id,
            animated_is_encrypted,
            animated_sealed_dek_length,
            animated_sealed_dek_digest,
        )
    }
}

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
public fun release_cover_art_set_event_bcs(e: &ReleaseCoverArtSetEvent): vector<u8> {
    sui::bcs::to_bytes(e)
}

#[test_only]
public fun release_cover_art_unset_event_bcs(e: &ReleaseCoverArtUnsetEvent): vector<u8> {
    sui::bcs::to_bytes(e)
}

#[test_only]
public fun release_track_cover_art_set_event_bcs(e: &ReleaseTrackCoverArtSetEvent): vector<u8> {
    sui::bcs::to_bytes(e)
}

#[test_only]
public fun release_track_cover_art_unset_event_bcs(e: &ReleaseTrackCoverArtUnsetEvent): vector<u8> {
    sui::bcs::to_bytes(e)
}

#[test_only]
public fun release_cover_art_set_event_header(
    e: &ReleaseCoverArtSetEvent,
): (address, address, u64, bool, bool) {
    (e.release_id, e.admin_cap_id, e.track_count, e.field_existed_before, e.field_exists_after)
}

#[test_only]
public fun release_cover_art_unset_event_header(
    e: &ReleaseCoverArtUnsetEvent,
): (address, address, u64, bool, bool) {
    (e.release_id, e.admin_cap_id, e.track_count, e.field_existed_before, e.field_exists_after)
}

#[test_only]
public fun release_track_cover_art_set_event_header(
    e: &ReleaseTrackCoverArtSetEvent,
): (address, address, u64, bool, bool, u64, address, address) {
    (
        e.release_id,
        e.admin_cap_id,
        e.track_count,
        e.field_existed_before,
        e.field_exists_after,
        e.track_index,
        e.recording_id,
        e.composition_id,
    )
}

#[test_only]
public fun release_track_cover_art_unset_event_header(
    e: &ReleaseTrackCoverArtUnsetEvent,
): (address, address, u64, bool, bool, u64, address, address) {
    (
        e.release_id,
        e.admin_cap_id,
        e.track_count,
        e.field_existed_before,
        e.field_exists_after,
        e.track_index,
        e.recording_id,
        e.composition_id,
    )
}
