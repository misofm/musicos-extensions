// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The genres that classify a recording, in order with the primary first,
/// stored as a dynamic field on the recording's UID and written through its
/// cap-gated `uid_mut`.
///
/// One concern, one package: genre is classified by different people, at
/// different times, against a vocabulary (`genre`) that evolves on its own
/// schedule. It lives on the recording, not the release, because it is a fact
/// about the audio: one published `Recording` can be a track on many releases,
/// and only the recording's own admin has standing to classify it.
/// `release_genre` keeps the separate product-level claim.
///
/// The value is a bare `vector<ID>` of `genre::Genre` ids, index 0 the
/// primary, capped at `MAX_GENRES`. Every add takes `&Genre`, so only ids
/// that resolve to a real vocabulary entry can enter; removal takes a bare
/// `ID`. Non-empty by construction: removing the last genre drops the field.
/// Reordering, including changing the primary, is `clear_genres` followed by
/// `add_genre` in the desired order within one transaction block.
module recording_genre::recording_genre;

use genre::genre::Genre;
use musicos::recording::{Recording, RecordingAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

// Conflict errors (40-49)
/// The genre is already assigned to this recording.
const EDuplicateGenre: u64 = 40;
/// The recording already carries `MAX_GENRES` genres.
const EMaxGenres: u64 = 41;
/// The genre is not assigned to this recording.
const EGenreNotPresent: u64 = 42;

// === Constants ===

/// Maximum genres on one recording: the primary plus up to five more.
const MAX_GENRES: u64 = 6;

// === Structs ===

/// Dynamic-field key — one ordered `vector<ID>` of genres per recording.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a genre is appended; the first add makes it the primary.
public struct RecordingGenreAddedEvent<phantom RecordingShare> has copy, drop {
    recording_id: ID,
    genre_id: ID,
}

/// Emitted when a genre is removed. Removing the last genre drops the field
/// and emits only this event.
public struct RecordingGenreRemovedEvent<phantom RecordingShare> has copy, drop {
    recording_id: ID,
    genre_id: ID,
}

/// Emitted when `clear_genres` removes an attached list.
public struct RecordingGenresClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: ID,
}

// === Public Functions ===

/// Appends a genre to the recording's list, creating the field on first use
/// so that genre becomes the primary. Aborts `EDuplicateGenre` if already
/// present, then `EMaxGenres` if the recording is at capacity.
public fun add_genre<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    genre: &Genre,
) {
    let recording_id = object::id(self);
    let genre_id = object::id(genre);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let genres: &mut vector<ID> = df::borrow_mut(uid, ExtensionKey());
        assert!(!genres.contains(&genre_id), EDuplicateGenre);
        assert!(genres.length() < MAX_GENRES, EMaxGenres);
        genres.push_back(genre_id);
    } else {
        df::add(uid, ExtensionKey(), vector[genre_id]);
    };
    emit(RecordingGenreAddedEvent<RecordingShare> {
        recording_id,
        genre_id,
    });
}

/// Removes a genre by id; if it was the primary, the next genre becomes
/// primary. Removing the last genre drops the field. Aborts
/// `EGenreNotPresent` if the genre is not assigned, including when nothing is
/// attached.
public fun remove_genre<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    genre_id: ID,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    assert!(df::exists(uid, ExtensionKey()), EGenreNotPresent);
    let genres: &mut vector<ID> = df::borrow_mut(uid, ExtensionKey());
    let (found, index) = genres.index_of(&genre_id);
    assert!(found, EGenreNotPresent);
    genres.remove(index);
    if (genres.is_empty()) {
        let _: vector<ID> = df::remove(uid, ExtensionKey());
    };
    emit(RecordingGenreRemovedEvent<RecordingShare> {
        recording_id,
        genre_id,
    });
}

/// Removes the recording's entire genre list. Silent when nothing is attached.
public fun clear_genres<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: vector<ID> = df::remove(uid, ExtensionKey());
        emit(RecordingGenresClearedEvent<RecordingShare> { recording_id });
    }
}

// === View Functions ===

/// The recording's genre ids in order, primary first. Empty when nothing is
/// attached.
public fun genres<RecordingShare>(self: &Recording<RecordingShare>): vector<ID> {
    let uid = self.uid();
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow(uid, ExtensionKey())
    } else {
        vector[]
    }
}

// === Test Functions ===

#[test_only]
public fun added_event_fields<RecordingShare>(
    e: &RecordingGenreAddedEvent<RecordingShare>,
): (ID, ID) {
    (e.recording_id, e.genre_id)
}

#[test_only]
public fun removed_event_fields<RecordingShare>(
    e: &RecordingGenreRemovedEvent<RecordingShare>,
): (ID, ID) {
    (e.recording_id, e.genre_id)
}

#[test_only]
public fun cleared_event_fields<RecordingShare>(
    e: &RecordingGenresClearedEvent<RecordingShare>,
): ID {
    e.recording_id
}
