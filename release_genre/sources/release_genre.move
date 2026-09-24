// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The genre(s) a musicos `Release` is classified under as a released
/// product, stored as a dynamic field on the release's UID and written
/// through its cap-gated `uid_mut`.
///
/// A recording's own intrinsic genre lives in `recording_genre`; this package
/// holds the different, product-level claim (a compilation can be "Jazz" on
/// the shelf even when its tracks are not). Clients resolve a track's genre
/// from the recording first and fall back to this release's primary.
///
/// Genres are one ordered list of `genre::Genre` ids, primary first; the rest
/// are unranked. The value is a bare `vector<ID>`, non-empty by construction:
/// removing the last genre drops the field, so "the field exists" and "there
/// is a primary" are the same fact. Every add takes `&Genre`, so only an id
/// the shared vocabulary minted can enter the list. Reordering, including
/// changing the primary, is `clear_genres` followed by `add_genre` in the
/// desired order within one programmable transaction block. Emptiness and
/// the primary are computed client-side from `genres()`.
module release_genre::release_genre;

use genre::genre::Genre;
use musicos::release::{Release, ReleaseAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// The genre is already assigned to this release.
const EDuplicateGenre: u64 = 40;
/// The release already carries `MAX_GENRES` genres.
const EMaxGenres: u64 = 41;
/// The genre is not assigned to this release.
const EGenreNotPresent: u64 = 42;

// === Constants ===

/// Maximum genres on one release: the primary plus up to five more.
const MAX_GENRES: u64 = 6;

// === Structs ===

/// Dynamic-field key — one ordered genre list (`vector<ID>`) per release.
/// Index 0 is the primary. Non-empty by construction.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a genre is appended. The first add creates the field, making
/// that genre the primary.
public struct ReleaseGenreAddedEvent has copy, drop {
    release_id: address,
    genre_id: address,
}

/// Emitted when a genre is removed. Removing the last genre drops the field
/// and emits only this event.
public struct ReleaseGenreRemovedEvent has copy, drop {
    release_id: address,
    genre_id: address,
}

/// Emitted when an attached genre list is dropped by `clear_genres`.
public struct ReleaseGenresClearedEvent has copy, drop {
    release_id: address,
}

// === Public Functions ===

/// Appends a genre to the release's list, creating the field on first use.
/// After cap authorization, aborts `EDuplicateGenre` if the genre is already
/// present, then `EMaxGenres` if the release is at capacity.
public fun add_genre(self: &mut Release, cap: &ReleaseAdminCap, genre: &Genre) {
    let release_id = object::id(self).to_address();
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
    emit(ReleaseGenreAddedEvent { release_id, genre_id: genre_id.to_address() });
}

/// Removes a genre by id. If it was the primary, the next entry becomes
/// primary; removing the last genre drops the field. After cap
/// authorization, aborts `EGenreNotPresent` if the genre is not assigned,
/// including when the release has no genres at all.
public fun remove_genre(self: &mut Release, cap: &ReleaseAdminCap, genre_id: ID) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    assert!(df::exists(uid, ExtensionKey()), EGenreNotPresent);
    let genres: &mut vector<ID> = df::borrow_mut(uid, ExtensionKey());
    let (found, index) = genres.index_of(&genre_id);
    assert!(found, EGenreNotPresent);
    genres.remove(index);
    if (genres.is_empty()) {
        let _: vector<ID> = df::remove(uid, ExtensionKey());
    };
    emit(ReleaseGenreRemovedEvent { release_id, genre_id: genre_id.to_address() });
}

/// Removes the release's entire genre list. Authorizes first; an absent list
/// is a silent no-op.
public fun clear_genres(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: vector<ID> = df::remove(uid, ExtensionKey());
        emit(ReleaseGenresClearedEvent { release_id });
    }
}

// === View Functions ===

/// The release's genre ids, in order, primary first. Empty when nothing is
/// attached.
public fun genres(self: &Release): vector<ID> {
    let uid = self.uid();
    if (df::exists(uid, ExtensionKey())) *df::borrow(uid, ExtensionKey()) else vector[]
}

// === Test Functions ===

#[test_only]
public fun genre_added_event_fields(e: &ReleaseGenreAddedEvent): (address, address) {
    (e.release_id, e.genre_id)
}

#[test_only]
public fun genre_removed_event_fields(e: &ReleaseGenreRemovedEvent): (address, address) {
    (e.release_id, e.genre_id)
}

#[test_only]
public fun genres_cleared_event_fields(e: &ReleaseGenresClearedEvent): address {
    e.release_id
}
