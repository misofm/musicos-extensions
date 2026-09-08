// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The genre(s) a musicos `Release` is classified under, stored as a dynamic
/// field on the release's UID and written through its cap-gated `uid_mut`.
///
/// Genre is intrinsic to a recording — a fact about the master, not about any
/// one product it appears on — so a recording's own genre lives in the
/// sibling package `recording_genre`, on the recording itself. This package
/// carries the different claim: what a release, as a released product, is
/// classified as. A compilation can be "Jazz" on the shelf even when half its
/// tracks are Blues or Funk on their own terms; that classification belongs
/// to nobody but the release, and no amount of inspecting its recordings
/// derives it. The intended read order for a track's genre is the
/// recording's own (`recording_genre`), falling back to this release's
/// primary when the recording has none — the release is the product-level
/// default, not a per-track override, because a `Recording` carries no
/// back-reference to any release and one recording can appear on many.
///
/// Its own package, for the same reason genre is separated from every other
/// release fact: it is set by different people, at different times, under a
/// vocabulary (the shared `genre` registry) that evolves on its own schedule.
/// A consumer building a metadata profile picks this extension up or ignores
/// it, and revising it never disturbs anything else the release carries.
///
/// Genres are kept as one ordered list, primary first, rather than a primary
/// field plus a separate secondary set. A release either has a primary genre
/// or it has no genre assignment at all — there is no state where secondaries
/// exist without a primary, or where the primary and a secondary are the same
/// entry needing to be kept disjoint — so the two structures collapse to one
/// without losing anything the list needs to say. Reordering — including
/// promoting an existing entry to primary — is `clear_genres` followed by
/// `add_genre` in the desired order, atomically within one programmable
/// transaction block. That is preferable to a dedicated set-primary function:
/// one fewer function to review and keep in sync with `recording_genre`, no
/// conditional-capacity branch (insert-new-at-front vs. move-existing-to-
/// front), and the client expresses its intended final order directly instead
/// of encoding it as a sequence of promotions. Order beyond index 0 is the
/// caller's, in the same convention `recording_language` uses for its
/// language vector: first is authoritative, the rest are unranked.
///
/// The stored value is a bare `vector<ID>` under the package's own key, with
/// no wrapper struct — the same shape `party_genre` uses for its `VecSet<ID>`
/// and `recording_language` for its `vector<LanguageCode>`. The list is
/// non-empty by construction: `remove_genre` drops the field the moment the
/// last entry leaves, so "the field exists" and "there is a primary" are the
/// same fact and no reader has to handle an attached-but-empty case. Every
/// write takes `&Genre`, so only an id that the shared vocabulary actually
/// minted can ever enter the list; removal takes a bare `ID` because nothing
/// about proving membership is needed to take an entry back out.
///
/// This module exposes no function derivable by composing the others. This
/// package is never upgraded — every publish is a fresh identity at a fresh
/// address — so every public function is permanent surface: once live, it
/// must be carried, re-published, and re-audited for as long as the package
/// is in use. A predicate or accessor a caller can compute from `genres()`
/// earns nothing by also living on-chain. Concretely: emptiness is
/// `genres(release).is_empty()`, and the primary is `genres(release)[0]`
/// (valid whenever the vector is non-empty, by the non-empty-by-construction
/// invariant above).
module release_genre::release_genre;

use genre::genre::Genre;
use musicos::release::{Release, ReleaseAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

// Conflict errors (40-49)
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

/// Dynamic-field key — one ordered genre list per release. The value is a
/// bare `vector<ID>` of `genre::Genre` ids; index 0 is the primary. Non-empty
/// by construction: removing the last genre drops the field.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a genre is appended (`add_genre`).
public struct GenreAddedEvent has copy, drop {
    release_id: ID,
    genre_id: ID,
}

/// Emitted when a genre is removed (`remove_genre`).
public struct GenreRemovedEvent has copy, drop {
    release_id: ID,
    genre_id: ID,
}

/// Emitted when the release's genre list is dropped entirely — either because
/// `remove_genre` removed the last genre, or because `clear_genres` removed
/// an attached list outright.
public struct GenresClearedEvent has copy, drop {
    release_id: ID,
}

// === Public Functions ===

/// Appends a genre to the release's list. Creates the field on first use, in
/// which case that genre becomes the primary by being the only entry. Aborts
/// `EDuplicateGenre` if the genre is already present, `EMaxGenres` if the
/// release is already at capacity.
public fun add_genre(self: &mut Release, cap: &ReleaseAdminCap, genre: &Genre) {
    let release_id = object::id(self); // read before uid_mut borrows self
    let genre_id = object::id(genre);
    if (df::exists(self.uid(), ExtensionKey())) {
        // The immutable borrow above ends here, before uid_mut's mutable one.
        let genres: &mut vector<ID> = df::borrow_mut(self.uid_mut(cap), ExtensionKey());
        assert!(!genres.contains(&genre_id), EDuplicateGenre);
        assert!(genres.length() < MAX_GENRES, EMaxGenres);
        genres.push_back(genre_id);
    } else {
        df::add(self.uid_mut(cap), ExtensionKey(), vector[genre_id]);
    };
    emit(GenreAddedEvent { release_id, genre_id });
}

/// Removes a genre from the release by id. If it was the primary, the next
/// entry (if any) becomes primary by virtue of now sitting at index 0.
/// Removing the last genre drops the field entirely and additionally emits
/// `GenresClearedEvent`. Aborts `EGenreNotPresent` if the genre is not
/// currently assigned, including when the release has no genres at all.
public fun remove_genre(self: &mut Release, cap: &ReleaseAdminCap, genre_id: ID) {
    let release_id = object::id(self);
    assert!(df::exists(self.uid(), ExtensionKey()), EGenreNotPresent);
    let uid = self.uid_mut(cap);
    let genres: &mut vector<ID> = df::borrow_mut(uid, ExtensionKey());
    let (found, idx) = genres.index_of(&genre_id);
    assert!(found, EGenreNotPresent);
    genres.remove(idx);
    let now_empty = genres.is_empty(); // last read of `genres`, before reuse of `uid`
    emit(GenreRemovedEvent { release_id, genre_id });
    if (now_empty) {
        let _: vector<ID> = df::remove(uid, ExtensionKey()); // vector<ID> has drop
        emit(GenresClearedEvent { release_id });
    }
}

/// Removes the release's entire genre list. A no-op when nothing is
/// attached. Emits `GenresClearedEvent` only when a list was actually
/// removed.
public fun clear_genres(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: vector<ID> = df::remove(uid, ExtensionKey());
        emit(GenresClearedEvent { release_id });
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

// Event fields are module-private and carry no other public reader, so tests
// in another module need these accessors to assert the full payload rather
// than just "an event fired".

#[test_only]
public fun genre_added_event_fields(e: &GenreAddedEvent): (ID, ID) {
    (e.release_id, e.genre_id)
}

#[test_only]
public fun genre_removed_event_fields(e: &GenreRemovedEvent): (ID, ID) {
    (e.release_id, e.genre_id)
}

#[test_only]
public fun genres_cleared_event_release_id(e: &GenresClearedEvent): ID {
    e.release_id
}
