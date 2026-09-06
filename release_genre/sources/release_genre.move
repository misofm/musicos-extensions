// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Genre assignment for a Miso release: an album-level primary + secondary
/// genres, plus optional per-track primary overrides.
///
/// Genre is presentation, not objective recording data, so it is assigned on
/// the release (the consumer object), not the recording. Stored as a single
/// `ReleaseGenre` dynamic field on the release's UID, gated by the
/// `ReleaseAdminCap`.
///
/// A track's effective primary genre resolves as: its per-track override if
/// set, else the album primary.
///
/// A genre is either the album primary or a secondary, never both — the two
/// are kept disjoint: setting the primary to a current secondary aborts
/// (remove it from the secondaries first), and adding the current primary as
/// a secondary aborts.
module release_genre::release_genre;

use genre::genre::Genre;
use miso::release::{Release, ReleaseAdminCap};
use per_track::per_track::{Self, PerTrack};
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

// State errors (30-39)
/// An album primary genre must be set before adding secondaries or per-track overrides.
const ENoPrimaryGenre: u64 = 30;

// Conflict errors (40-49)
/// The genre is already the album primary genre.
const ESecondaryIsPrimary: u64 = 40;
/// The genre is already an album secondary genre.
const EGenreAlreadySecondary: u64 = 41;
/// The release has the maximum number of secondary genres.
const EMaxSecondaryGenres: u64 = 42;
/// The genre is not an album secondary genre on this release.
const EGenreNotSecondary: u64 = 43;
/// The genre is an album secondary genre; remove it from the secondaries
/// before making it the primary.
const EPrimaryIsSecondary: u64 = 44;

// Reference errors (50-59)
/// Track index is out of bounds for this release's track count.
const ETrackIndexOutOfBounds: u64 = 50;

// === Constants ===

/// Maximum number of album secondary genres.
const MAX_SECONDARY_GENRES: u64 = 5;

// === Structs ===

/// Dynamic-field key for a release's genre assignment.
public struct ExtensionKey() has copy, drop, store;

/// A release's genre assignment: an album-level primary + secondaries, plus
/// per-track primary overrides (a track with no override inherits the album
/// primary).
public struct ReleaseGenre has store {
    primary: ID,
    secondary: vector<ID>,
    track_primary: PerTrack<Option<ID>>,
}

// === Events ===

/// Emitted when the album primary genre is set or changed.
public struct PrimaryGenreSetEvent has copy, drop {
    release_id: ID,
    genre_id: ID,
}

/// Emitted when an album secondary genre is added.
public struct SecondaryGenreAddedEvent has copy, drop {
    release_id: ID,
    genre_id: ID,
}

/// Emitted when an album secondary genre is removed.
public struct SecondaryGenreRemovedEvent has copy, drop {
    release_id: ID,
    genre_id: ID,
}

/// Emitted when a track's primary-genre override is set or changed.
public struct TrackPrimaryGenreSetEvent has copy, drop {
    release_id: ID,
    track_index: u64,
    genre_id: ID,
}

/// Emitted when a track's primary-genre override is removed.
public struct TrackPrimaryGenreUnsetEvent has copy, drop {
    release_id: ID,
    track_index: u64,
}

// === Public Functions ===

// Album-level assignment

/// Sets (or replaces) the album primary genre. Gated by the release admin cap.
/// Aborts if the genre is currently an album secondary — remove it from the
/// secondaries first (primary and secondary are kept disjoint).
public fun set_primary_genre(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    genre: &Genre,
) {
    let release_id = object::id(self);
    let genre_id = object::id(genre);

    if (df::exists(self.uid(), ExtensionKey())) {
        let assignment: &mut ReleaseGenre = df::borrow_mut(self.uid_mut(cap), ExtensionKey());
        assert!(!assignment.secondary.contains(&genre_id), EPrimaryIsSecondary);
        assignment.primary = genre_id;
    } else {
        // First set: size the per-track overrides to the tracklist (all empty).
        let track_primary = per_track::filled(self, option::none<ID>());
        df::add(
            self.uid_mut(cap),
            ExtensionKey(),
            ReleaseGenre {
                primary: genre_id,
                secondary: vector[],
                track_primary,
            },
        );
    };

    emit(PrimaryGenreSetEvent { release_id, genre_id });
}

/// Adds an album secondary genre. Requires the album primary first. Rejects a
/// secondary equal to the primary, duplicates, and counts at/above the maximum.
public fun add_secondary_genre(self: &mut Release, cap: &ReleaseAdminCap, genre: &Genre) {
    let release_id = object::id(self);
    let genre_id = object::id(genre);

    assert!(df::exists(self.uid(), ExtensionKey()), ENoPrimaryGenre);
    let assignment: &mut ReleaseGenre = df::borrow_mut(self.uid_mut(cap), ExtensionKey());
    assert!(genre_id != assignment.primary, ESecondaryIsPrimary);
    assert!(!assignment.secondary.contains(&genre_id), EGenreAlreadySecondary);
    assert!(assignment.secondary.length() < MAX_SECONDARY_GENRES, EMaxSecondaryGenres);
    assignment.secondary.push_back(genre_id);

    emit(SecondaryGenreAddedEvent { release_id, genre_id });
}

/// Removes an album secondary genre.
public fun remove_secondary_genre(self: &mut Release, cap: &ReleaseAdminCap, genre: &Genre) {
    let release_id = object::id(self);
    let genre_id = object::id(genre);

    assert!(df::exists(self.uid(), ExtensionKey()), ENoPrimaryGenre);
    let assignment: &mut ReleaseGenre = df::borrow_mut(self.uid_mut(cap), ExtensionKey());
    let (found, idx) = assignment.secondary.index_of(&genre_id);
    assert!(found, EGenreNotSecondary);
    assignment.secondary.remove(idx);

    emit(SecondaryGenreRemovedEvent { release_id, genre_id });
}

// Per-track overrides

/// Sets (or replaces) a track's primary-genre override (by tracklist index).
/// Requires the album primary first. Aborts if the index is out of range.
public fun set_track_primary_genre(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    track_index: u64,
    genre: &Genre,
) {
    let release_id = object::id(self);
    let genre_id = object::id(genre);

    assert!(df::exists(self.uid(), ExtensionKey()), ENoPrimaryGenre);
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    let assignment: &mut ReleaseGenre = df::borrow_mut(self.uid_mut(cap), ExtensionKey());
    assignment.track_primary.borrow_mut(track_index).swap_or_fill(genre_id);

    emit(TrackPrimaryGenreSetEvent { release_id, track_index, genre_id });
}

/// Removes a track's primary-genre override — the track falls back to the album
/// primary. Aborts if the index is out of range.
public fun unset_track_primary_genre(self: &mut Release, cap: &ReleaseAdminCap, track_index: u64) {
    let release_id = object::id(self);

    assert!(df::exists(self.uid(), ExtensionKey()), ENoPrimaryGenre);
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    let assignment: &mut ReleaseGenre = df::borrow_mut(self.uid_mut(cap), ExtensionKey());
    *assignment.track_primary.borrow_mut(track_index) = option::none();

    emit(TrackPrimaryGenreUnsetEvent { release_id, track_index });
}

// === View Functions ===

/// Returns whether the release has a genre assignment.
public fun has_genre(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// Returns the album primary genre id, if set.
public fun primary_genre(self: &Release): Option<ID> {
    let uid = self.uid();
    if (df::exists(uid, ExtensionKey())) {
        option::some(df::borrow<ExtensionKey, ReleaseGenre>(uid, ExtensionKey()).primary)
    } else {
        option::none()
    }
}

/// Returns the album secondary genre ids (empty if none).
public fun secondary_genres(self: &Release): vector<ID> {
    let uid = self.uid();
    if (df::exists(uid, ExtensionKey())) {
        df::borrow<ExtensionKey, ReleaseGenre>(uid, ExtensionKey()).secondary
    } else {
        vector[]
    }
}

/// Returns a track's effective primary genre: its override if set, else the
/// album primary. None if no genre is assigned to the release. Aborts if the
/// track index is out of range (when an assignment exists).
public fun track_primary_genre(self: &Release, track_index: u64): Option<ID> {
    let uid = self.uid();
    if (!df::exists(uid, ExtensionKey())) return option::none();
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    let assignment = df::borrow<ExtensionKey, ReleaseGenre>(uid, ExtensionKey());
    let override = assignment.track_primary.borrow(track_index);
    if (override.is_some()) *override else option::some(assignment.primary)
}

// === Test Functions ===

// Event fields are module-private and carry no other public reader, so tests
// in another module need these accessors to assert the full payload rather
// than just "an event fired".

#[test_only]
public fun primary_genre_set_event_fields(event: &PrimaryGenreSetEvent): (ID, ID) {
    (event.release_id, event.genre_id)
}

#[test_only]
public fun secondary_genre_added_event_fields(event: &SecondaryGenreAddedEvent): (ID, ID) {
    (event.release_id, event.genre_id)
}

#[test_only]
public fun secondary_genre_removed_event_fields(event: &SecondaryGenreRemovedEvent): (ID, ID) {
    (event.release_id, event.genre_id)
}

#[test_only]
public fun track_primary_genre_set_event_fields(event: &TrackPrimaryGenreSetEvent): (ID, u64, ID) {
    (event.release_id, event.track_index, event.genre_id)
}

#[test_only]
public fun track_primary_genre_unset_event_fields(event: &TrackPrimaryGenreUnsetEvent): (ID, u64) {
    (event.release_id, event.track_index)
}
