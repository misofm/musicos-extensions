// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The genres that classify a recording, in order with the primary first,
/// stored as a dynamic field on the recording's UID and written through its
/// cap-gated `uid_mut`.
///
/// This is its own package on purpose. Genre is classified by different
/// people, at different times, against a vocabulary that evolves on its own
/// schedule — exactly the split behind `recording_advisory` and
/// `recording_language`. A consumer implementing some future classification
/// profile picks this extension up or ignores it, and replacing it never
/// disturbs anything else attached to the recording.
///
/// **Why the recording, and not the release.** `musicos::track`'s module doc is
/// explicit that a `Track` embeds only facts "genuinely release-specific and
/// not derivable from the recording" — title and cover art were excluded for
/// exactly this reason. Genre is not release-specific: it is a fact about the
/// audio itself, and `track::new` can be called repeatedly against one
/// published `Recording` with different target releases, so one master can be
/// a track on many releases at once. `Recording` holds no back-reference to
/// any release. A per-track genre override written from the release side is
/// therefore N independent classifications of one master, made by whichever
/// compilation curator happens to hold that release's cap — someone who does
/// not own the master and has no standing to assert what genre it is. The
/// recording's own admin is the party entitled to classify it, and does so
/// once, here.
///
/// **Division of labour with `release_genre`.** Release-level genre is a
/// separate, legitimate claim: a compilation is "Jazz" *as a product* even
/// when the recordings inside it are not, individually, jazz. `release_genre`
/// keeps that product-level classification. A client resolving a track's
/// genre should read this package first — the recording's own classification —
/// and fall back to the release's primary genre only when the recording has
/// none.
///
/// **Shape.** One ordered `vector<ID>` of `genre::Genre` object ids, index 0
/// the primary, capped at `MAX_GENRES` — the house precedent is
/// `recording_language`: "Order is the caller's: first is conventionally the
/// predominant one." The old release-side design split a single ordered
/// concept into `primary: ID` plus `secondary: vector<ID>`, and three of its
/// six error codes existed only to police the boundary between the two halves
/// — states that cannot exist in a single list. Reordering — including
/// promoting an existing entry to primary — is `clear_genres` followed by
/// `add_genre` in the desired order, atomically within one programmable
/// transaction block: one fewer function to keep in lockstep with
/// `release_genre`, no conditional-capacity branch (insert-new-at-front vs.
/// move-existing-to-front), and the client states its intended final order
/// directly instead of encoding it as a sequence of promotions.
///
/// The stored value is a bare `vector<ID>` under the package's own key, no
/// wrapper struct — the same choice `party_genre` makes for its `VecSet<ID>`
/// and `recording_language` makes for its `vector<LanguageCode>`. `vector<ID>`
/// has `drop`, so removing the field is `let _: vector<ID> = df::remove(...)`
/// with no destructuring required.
///
/// Non-empty by construction: removing the last genre drops the field, so
/// "the field is attached" always implies "there is a primary" — there is no
/// attached-but-empty state to special-case.
///
/// Every write takes `&Genre` — a real, name-derived object from the shared
/// vocabulary — so only ids that resolve to a genuine vocabulary entry can
/// ever enter the list. Removal takes a bare `ID`, since the object itself is
/// not needed to drop a reference to it.
///
/// This module exposes no function derivable by composing the others. This
/// package is never upgraded — every publish is a fresh identity at a fresh
/// address — so every public function is permanent surface: once live, it
/// must be carried, re-published, and re-audited for as long as the package
/// is in use. A predicate or accessor a caller can compute from `genres()`
/// earns nothing by also living on-chain. Concretely: emptiness is
/// `genres(recording).is_empty()`, and the primary is `genres(recording)[0]`
/// (valid whenever the vector is non-empty, by the non-empty-by-construction
/// invariant above).
module recording_genre::recording_genre;

use genre::genre::{Self, Genre};
use musicos::recording::{Self, Recording, RecordingAdminCap};
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

/// Dynamic-field key — one ordered genre list per recording. The value is a
/// bare `vector<ID>` of `genre::Genre` ids; index 0 is the primary. Non-empty
/// by construction: removing the last genre drops the field.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a genre is appended (`add_genre`).
public struct RecordingGenreAddedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    genre_id: address,
    genre_name: vector<u8>,
    genre_index: u64,
    genres_before: vector<address>,
    genres_after: vector<address>,
    genre_count_before: u64,
    genre_count_after: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    had_primary_before: bool,
    has_primary_after: bool,
    primary_genre_id_before: address,
    primary_genre_id_after: address,
    primary_changed: bool,
}

/// Emitted when a genre is removed (`remove_genre`).
public struct RecordingGenreRemovedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    genre_id: address,
    genre_index: u64,
    genres_before: vector<address>,
    genres_after: vector<address>,
    genre_count_before: u64,
    genre_count_after: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    had_primary_before: bool,
    has_primary_after: bool,
    primary_genre_id_before: address,
    primary_genre_id_after: address,
    primary_changed: bool,
}

/// Emitted when the recording's genre list is dropped entirely — either
/// because `remove_genre` removed the last genre, or because `clear_genres`
/// removed an attached list outright.
public struct RecordingGenresClearedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    clear_cause: u8,
    trigger_genre_id: address,
    genres_before: vector<address>,
    genres_after: vector<address>,
    genre_count_before: u64,
    genre_count_after: u64,
    field_existed_before: bool,
    field_exists_after: bool,
    had_primary_before: bool,
    has_primary_after: bool,
    primary_genre_id_before: address,
    primary_genre_id_after: address,
    primary_changed: bool,
}

// === Public Functions ===

/// Appends a genre to the recording's list. Creates the field on first use,
/// in which case the appended genre becomes the primary. Aborts
/// `EDuplicateGenre` if the genre is already present, `EMaxGenres` if the
/// recording is already at capacity.
public fun add_genre<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    genre: &Genre,
) {
    // Read the id before `uid_mut` so we don't need `self` again afterward.
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let genre_object_id = object::id(genre);
    let genre_id = genre_object_id.to_address();
    let genre_name = *genre::name(genre).as_bytes();
    let field_existed_before = df::exists(self.uid(), ExtensionKey());
    let (
        genre_index,
        genres_before,
        genres_after,
        genre_count_before,
        genre_count_after,
        had_primary_before,
        has_primary_after,
        primary_genre_id_before,
        primary_genre_id_after,
        primary_changed,
    ) = if (field_existed_before) {
        // The immutable borrow above ends here, before `uid_mut` is taken.
        let uid = self.uid_mut(cap);
        let genres: &mut vector<ID> = df::borrow_mut(uid, ExtensionKey());
        let before = *genres;
        let genres_before = ids_to_addresses(&before);
        let genre_count_before = before.length();
        let (had_primary, primary_id_before) = primary_state(&before);
        assert!(!genres.contains(&genre_object_id), EDuplicateGenre);
        assert!(genres.length() < MAX_GENRES, EMaxGenres);
        let genre_index = genres.length();
        genres.push_back(genre_object_id);
        let after = *genres;
        let genres_after = ids_to_addresses(&after);
        let genre_count_after = after.length();
        let (has_primary, primary_id_after) = primary_state(&after);
        let primary_changed = had_primary != has_primary
            || primary_id_before != primary_id_after;
        (
            genre_index,
            genres_before,
            genres_after,
            genre_count_before,
            genre_count_after,
            had_primary,
            has_primary,
            primary_id_before,
            primary_id_after,
            primary_changed,
        )
    } else {
        let uid = self.uid_mut(cap);
        df::add(uid, ExtensionKey(), vector[genre_object_id]);
        (
            0,
            vector[],
            vector[genre_id],
            0,
            1,
            false,
            true,
            @0x0,
            genre_id,
            true,
        )
    };
    emit(RecordingGenreAddedEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        admin_cap_id,
        genre_id,
        genre_name,
        genre_index,
        genres_before,
        genres_after,
        genre_count_before,
        genre_count_after,
        field_existed_before,
        field_exists_after: true,
        had_primary_before,
        has_primary_after,
        primary_genre_id_before,
        primary_genre_id_after,
        primary_changed,
    });
}

/// Removes a genre by id. If it was the primary, the next genre in the list
/// becomes primary. Removing the last remaining genre drops the field
/// entirely and additionally emits `RecordingGenresClearedEvent`. Aborts
/// `EGenreNotPresent` if the genre is not assigned — including when nothing
/// is attached at all.
public fun remove_genre<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    genre_id: ID,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let genre_address = genre_id.to_address();
    assert!(df::exists(self.uid(), ExtensionKey()), EGenreNotPresent);
    let uid = self.uid_mut(cap);
    let genres: &mut vector<ID> = df::borrow_mut(uid, ExtensionKey());
    let (found, idx) = genres.index_of(&genre_id);
    assert!(found, EGenreNotPresent);
    let before = *genres;
    let genres_before = ids_to_addresses(&before);
    let genre_count_before = before.length();
    let (had_primary_before, primary_genre_id_before) = primary_state(&before);
    genres.remove(idx);
    let after = *genres;
    let genres_after = ids_to_addresses(&after);
    let genre_count_after = after.length();
    let (has_primary_after, primary_genre_id_after) = primary_state(&after);
    // Last read of `genres` — bind the result before it goes out of scope so
    // `uid` is free to be reused below for the field removal.
    let now_empty = after.is_empty();
    let primary_changed = had_primary_before != has_primary_after
        || primary_genre_id_before != primary_genre_id_after;
    emit(RecordingGenreRemovedEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        admin_cap_id,
        genre_id: genre_address,
        genre_index: idx,
        genres_before,
        genres_after,
        genre_count_before,
        genre_count_after,
        field_existed_before: true,
        field_exists_after: true,
        had_primary_before,
        has_primary_after,
        primary_genre_id_before,
        primary_genre_id_after,
        primary_changed,
    });
    if (now_empty) {
        let _: vector<ID> = df::remove(uid, ExtensionKey()); // vector<ID> has drop
        emit(RecordingGenresClearedEvent<RecordingShare, CompositionShare> {
            recording_id,
            composition_id,
            admin_cap_id,
            clear_cause: 1,
            trigger_genre_id: genre_address,
            genres_before: vector[],
            genres_after: vector[],
            genre_count_before: 0,
            genre_count_after: 0,
            field_existed_before: true,
            field_exists_after: false,
            had_primary_before: false,
            has_primary_after: false,
            primary_genre_id_before: @0x0,
            primary_genre_id_after: @0x0,
            primary_changed: false,
        });
    }
}

/// Removes the recording's entire genre list. A no-op when nothing is
/// attached. Emits `RecordingGenresClearedEvent` only when a list was actually
/// removed.
public fun clear_genres<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let removed: vector<ID> = df::remove(uid, ExtensionKey());
        let genres_before = ids_to_addresses(&removed);
        let genre_count_before = removed.length();
        let (had_primary_before, primary_genre_id_before) = primary_state(&removed);
        emit(RecordingGenresClearedEvent<RecordingShare, CompositionShare> {
            recording_id,
            composition_id,
            admin_cap_id,
            clear_cause: 0,
            trigger_genre_id: @0x0,
            genres_before,
            genres_after: vector[],
            genre_count_before,
            genre_count_after: 0,
            field_existed_before: true,
            field_exists_after: false,
            had_primary_before,
            has_primary_after: false,
            primary_genre_id_before,
            primary_genre_id_after: @0x0,
            primary_changed: had_primary_before
                || primary_genre_id_before != @0x0,
        });
    }
}

// === View Functions ===

/// The recording's genre ids in order, primary first. Empty when nothing is
/// attached.
public fun genres<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): vector<ID> {
    let uid = self.uid();
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow(uid, ExtensionKey())
    } else {
        vector[]
    }
}

// === Test Functions ===

// Event fields are module-private. Test-only BCS accessors let the tests peel
// every primitive in declaration order without adding production readers.

#[test_only]
public fun added_event_bcs<RecordingShare, CompositionShare>(
    e: &RecordingGenreAddedEvent<RecordingShare, CompositionShare>,
): vector<u8> {
    sui::bcs::to_bytes(e)
}

#[test_only]
public fun removed_event_bcs<RecordingShare, CompositionShare>(
    e: &RecordingGenreRemovedEvent<RecordingShare, CompositionShare>,
): vector<u8> {
    sui::bcs::to_bytes(e)
}

#[test_only]
public fun cleared_event_bcs<RecordingShare, CompositionShare>(
    e: &RecordingGenresClearedEvent<RecordingShare, CompositionShare>,
): vector<u8> {
    sui::bcs::to_bytes(e)
}

#[test_only]
public fun genre_added_event_fields<RecordingShare, CompositionShare>(
    e: &RecordingGenreAddedEvent<RecordingShare, CompositionShare>,
): (ID, ID) {
    (object::id_from_address(e.recording_id), object::id_from_address(e.genre_id))
}

#[test_only]
public fun genre_removed_event_fields<RecordingShare, CompositionShare>(
    e: &RecordingGenreRemovedEvent<RecordingShare, CompositionShare>,
): (ID, ID) {
    (object::id_from_address(e.recording_id), object::id_from_address(e.genre_id))
}

#[test_only]
public fun genres_cleared_event_recording_id<RecordingShare, CompositionShare>(
    e: &RecordingGenresClearedEvent<RecordingShare, CompositionShare>,
): ID {
    object::id_from_address(e.recording_id)
}

#[test_only]
public fun add_empty_field_for_testing<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let empty: vector<ID> = vector[];
    df::add(self.uid_mut(cap), ExtensionKey(), empty);
}

// === Private Functions ===

fun ids_to_addresses(values: &vector<ID>): vector<address> {
    let mut result = vector[];
    values.do_ref!(|value| result.push_back(value.to_address()));
    result
}

fun primary_state(values: &vector<ID>): (bool, address) {
    if (values.is_empty()) {
        (false, @0x0)
    } else {
        (true, values[0].to_address())
    }
}
