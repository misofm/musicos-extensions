// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A release's basic descriptive metadata — its title, genre classification,
/// kind and editorial description — stored as one dynamic field on the
/// release's `UID`, written through its cap-gated `uid_mut`, and readable by
/// anyone. Supersedes the standalone `release_genre`, `release_kind` and
/// `release_description` packages and adds the title that core no longer
/// embeds.
///
/// Core stores what a release *is* — identity and everything the economics
/// read — and embeds nothing outside the release digest. Everything that
/// *describes* a release is presentation: it has more than one correct
/// rendering, the economics never read it, and no track signer consented to
/// it. It lives here, is chosen by the cap holder before or after publish,
/// and stays admin-mutable for the release's whole life.
///
/// **Storage.** One `ReleaseMetadata` record under this module's
/// `ExtensionKey()`, whose fields are the attributes. Every attribute is
/// optional and independently settable and clearable; the record is created
/// by the first write and removed by the clear that empties it, so "the
/// field is absent" and "no metadata is attached" are the same fact.
/// Attaching nothing and attaching a value are distinct states: an empty
/// string is rejected rather than stored, and a value view aborts when
/// nothing is attached.
///
/// **Title.** The one rendering every other one is a variant of: the name
/// the release is listed under. Localized, alternate and edition titles are
/// different concerns and would be different extensions. The bound is core's
/// former one — 300 bytes — so nothing that was storable in core becomes
/// unstorable here.
///
/// **Genre.** What a release, as a released product, is classified as — a
/// different claim from a recording's own genre, which lives on the
/// recording. A compilation can be "Jazz" on the shelf even when half its
/// tracks are Blues or Funk on their own terms. The intended read order for
/// a track's genre is the recording's own first, falling back to this
/// release's primary. Genre is the one attribute here with a vocabulary:
/// every add takes `&Genre`, so only an id the shared `genre` registry
/// minted can enter the list. The list is ordered, primary first, at most
/// `MAX_GENRES`; it is empty rather than absent when no genre is assigned,
/// and `genres()` returns it as such. Reordering — including promoting an
/// existing entry to primary — is `clear_genres` followed by `add_genre` in
/// the desired order, atomically within one programmable transaction block.
///
/// **Kind.** What a release calls itself — "Album", "EP", "Mixtape" — as a
/// free string rather than an enum, because deciding which
/// self-descriptions are legitimate is not the protocol's job. Nothing
/// derives or checks it for plausibility: a four-track release may call
/// itself an Album. "EP", "ep" and "Extended Play" are three distinct
/// values; clients that group by kind should normalise.
///
/// **Description.** The paragraph that runs under the title: editorial
/// prose, not a fact the protocol can check. The 8 KB ceiling is a backstop
/// against bloat in a shared object, set well above any description anyone
/// is expected to write; long-form writing belongs in a Walrus blob.
///
/// Bounds are on bytes, not characters. Strings are stored exactly as given:
/// case, whitespace, line breaks, NUL and multi-byte UTF-8 are not
/// normalised. This package is never upgraded — every publish is a fresh
/// identity — so every public function is permanent surface, and nothing
/// derivable by composing the others is offered.
///
/// **Guard order.** Validation that needs only the argument (emptiness, byte
/// bounds) runs before the cap is consulted, so an invalid value reports its
/// own code whatever cap is supplied. Anything that reads stored state —
/// existence on clear, and genre duplicate, capacity and membership — runs
/// after `uid_mut`, so a foreign cap is rejected by core before this module
/// looks at the release.
///
/// **No-ops.** A write that would leave the stored value unchanged is a
/// no-op: it performs no write and emits no event. A set of the value already
/// attached returns after the cap check without touching the record; a clear
/// of nothing returns after the cap check without emitting. Only an attached
/// value can be equalled, so a set never creates the record as a no-op.
/// Genres are a list, not a value: a duplicate add aborts rather than
/// silently succeeding, and removing or clearing nothing is silent.
module release_metadata::release_metadata;

use genre::genre::Genre;
use musicos::release::{Release, ReleaseAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

// One decade per attribute, in field order. Within a decade: `0` nothing
// attached, `1` empty input, `2` bound exceeded, `3` duplicate, `4` not
// present.

// Title (10–19)
/// No title is attached to this release.
const ENoTitle: u64 = 10;
/// The title is empty. Naming nothing is done by not attaching.
const EEmptyTitle: u64 = 11;
/// The title exceeds `MAX_TITLE_LENGTH` bytes.
const ETitleTooLong: u64 = 12;

// Genres (20–29)
/// The release already carries `MAX_GENRES` genres.
const EMaxGenres: u64 = 22;
/// The genre is already assigned to this release.
const EDuplicateGenre: u64 = 23;
/// The genre is not assigned to this release.
const EGenreNotPresent: u64 = 24;

// Kind (30–39)
/// No kind is attached to this release.
const ENoKind: u64 = 30;
/// The kind is empty. Asserting nothing should be done by not attaching.
const EEmptyKind: u64 = 31;
/// The kind exceeds `MAX_KIND_LENGTH` bytes.
const EKindTooLong: u64 = 32;

// Description (40–49)
/// No description is attached to this release.
const ENoDescription: u64 = 40;
/// The description is empty. Saying nothing is done by not attaching.
const EEmptyDescription: u64 = 41;
/// The description exceeds `MAX_DESCRIPTION_LENGTH` bytes.
const EDescriptionTooLong: u64 = 42;

// === Constants ===

/// Maximum length of a title, in bytes — the limit core enforced while the
/// title was an embedded field.
const MAX_TITLE_LENGTH: u64 = 300;

/// Maximum genres on one release: the primary plus up to five more.
const MAX_GENRES: u64 = 6;

/// Maximum length of a kind, in bytes. Comfortably fits the long forms
/// ("Extended Play", "Album (Deluxe Edition)") while keeping the field
/// bounded. A kind is what the release *is*, not its title.
const MAX_KIND_LENGTH: u64 = 32;

/// Maximum length of a description, in bytes — 8 KB, or roughly 1,300 words
/// of English prose and about 2,700 characters of CJK.
const MAX_DESCRIPTION_LENGTH: u64 = 8192;

// === Structs ===

/// Dynamic-field key — one metadata record per release.
public struct ExtensionKey() has copy, drop, store;

/// The record stored under `ExtensionKey()`. Present only while at least one
/// attribute is set; a clear that leaves every attribute unset removes the
/// field. `store` only: it is taken out by destructuring, never dropped.
public struct ReleaseMetadata has store {
    /// The release's preferred title, stored exactly as given.
    title: Option<String>,
    /// `genre::Genre` ids in order, primary first. Empty when none is
    /// assigned — an empty list is "no genre", never a distinct claim.
    genres: vector<ID>,
    /// What the release calls itself, stored exactly as given.
    kind: Option<String>,
    /// What the release says about itself, stored exactly as given.
    description: Option<String>,
}

// === Events ===

// Every event carries only what an event-only indexer could not get without
// a lookup: the release and, on a write, the value written. Prior state is
// the indexer's own previous projection; the admin cap is the derived
// address of `release_id` under `ReleaseAdminCapKey`; the sender is the
// transaction envelope. Set events fire only when the value changes — an
// equal set is a no-op and emits nothing; clear events fire only when
// something was actually removed.

/// Emitted when a release's title is set or replaced.
public struct ReleaseTitleSetEvent has copy, drop {
    release_id: address,
    title: String,
}

/// Emitted when an attached title is removed.
public struct ReleaseTitleClearedEvent has copy, drop {
    release_id: address,
}

/// Emitted when a genre is appended (`add_genre`). The new entry always
/// lands at the end of the list, so an indexer replaying these events in
/// order holds the exact list — index, count and primary included; the
/// genre's name resolves from the frozen `Genre` object or from the
/// vocabulary's own creation event.
public struct ReleaseGenreAddedEvent has copy, drop {
    release_id: address,
    genre_id: address,
}

/// Emitted when a genre is removed (`remove_genre`). Survivors keep their
/// order, so the replayed list after this event is the list before it minus
/// `genre_id`; removing the last genre is this one event, not a
/// Removed-then-Cleared pair.
public struct ReleaseGenreRemovedEvent has copy, drop {
    release_id: address,
    genre_id: address,
}

/// Emitted when `clear_genres` removes a non-empty list.
public struct ReleaseGenresClearedEvent has copy, drop {
    release_id: address,
}

/// Emitted when a release's kind is set or replaced.
public struct ReleaseKindSetEvent has copy, drop {
    release_id: address,
    kind: String,
}

/// Emitted when an attached kind is removed.
public struct ReleaseKindClearedEvent has copy, drop {
    release_id: address,
}

/// Emitted when a release's description is set or replaced.
public struct ReleaseDescriptionSetEvent has copy, drop {
    release_id: address,
    description: String,
}

/// Emitted when an attached description is removed.
public struct ReleaseDescriptionClearedEvent has copy, drop {
    release_id: address,
}

// === Public Functions ===

/// Sets (or replaces) the release's title. Aborts `EEmptyTitle` for an empty
/// string, then `ETitleTooLong` above `MAX_TITLE_LENGTH` bytes, both before
/// the cap is consulted. Creates the record on first use. Setting the title
/// already attached is a no-op after the cap check: nothing is written and
/// nothing is emitted.
public fun set_title(self: &mut Release, cap: &ReleaseAdminCap, title: String) {
    let bytes = title.as_bytes();
    assert!(!bytes.is_empty(), EEmptyTitle);
    assert!(bytes.length() <= MAX_TITLE_LENGTH, ETitleTooLong);

    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey()) && metadata(uid).title.contains(&title)) return;
    metadata_mut(uid).title = option::some(title);
    emit(ReleaseTitleSetEvent { release_id, title });
}

/// Removes the title, if any. Idempotent. Cap-gates before the existence
/// check, so a wrong cap aborts even when there is nothing to remove.
/// Removes the record when nothing else is set.
public fun clear_title(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let metadata: &mut ReleaseMetadata = df::borrow_mut(uid, ExtensionKey());
    if (metadata.title.is_none()) return;
    metadata.title = option::none();
    prune(uid);
    emit(ReleaseTitleClearedEvent { release_id });
}

/// Appends a genre to the release's list; the first genre added becomes the
/// primary. Creates the record on first use. Aborts `EDuplicateGenre` if the
/// genre is already present, then `EMaxGenres` if the release is already at
/// capacity — both after cap authorization.
public fun add_genre(self: &mut Release, cap: &ReleaseAdminCap, genre: &Genre) {
    let release_id = object::id(self).to_address();
    let genre_id = object::id(genre);
    let uid = self.uid_mut(cap);
    let genres = &mut metadata_mut(uid).genres;
    assert!(!genres.contains(&genre_id), EDuplicateGenre);
    assert!(genres.length() < MAX_GENRES, EMaxGenres);
    genres.push_back(genre_id);
    emit(ReleaseGenreAddedEvent { release_id, genre_id: genre_id.to_address() });
}

/// Removes a genre by id. If it was the primary, the next entry becomes
/// primary by now sitting at index 0. Removing the last genre leaves the
/// list empty and removes the record when nothing else is set. Aborts
/// `EGenreNotPresent` if the genre is not assigned — including when nothing
/// is attached at all — after cap authorization.
public fun remove_genre(self: &mut Release, cap: &ReleaseAdminCap, genre_id: ID) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    assert!(df::exists(uid, ExtensionKey()), EGenreNotPresent);
    let metadata: &mut ReleaseMetadata = df::borrow_mut(uid, ExtensionKey());
    let (found, index) = metadata.genres.index_of(&genre_id);
    assert!(found, EGenreNotPresent);
    metadata.genres.remove(index);
    prune(uid);
    emit(ReleaseGenreRemovedEvent { release_id, genre_id: genre_id.to_address() });
}

/// Removes the release's entire genre list. Cap-gates before the existence
/// check; an authorized clear of nothing is a silent no-op. Emits
/// `ReleaseGenresClearedEvent` only when a non-empty list was removed, and
/// removes the record when nothing else is set.
public fun clear_genres(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let metadata: &mut ReleaseMetadata = df::borrow_mut(uid, ExtensionKey());
    if (metadata.genres.is_empty()) return;
    metadata.genres = vector[];
    prune(uid);
    emit(ReleaseGenresClearedEvent { release_id });
}

/// Sets (or replaces) what the release calls itself. Aborts `EEmptyKind` for
/// an empty string, then `EKindTooLong` above `MAX_KIND_LENGTH` bytes, both
/// before the cap is consulted. Creates the record on first use. Setting the
/// kind already attached is a no-op after the cap check: nothing is written
/// and nothing is emitted.
public fun set_kind(self: &mut Release, cap: &ReleaseAdminCap, kind: String) {
    let bytes = kind.as_bytes();
    assert!(!bytes.is_empty(), EEmptyKind);
    assert!(bytes.length() <= MAX_KIND_LENGTH, EKindTooLong);

    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey()) && metadata(uid).kind.contains(&kind)) return;
    metadata_mut(uid).kind = option::some(kind);
    emit(ReleaseKindSetEvent { release_id, kind });
}

/// Removes the kind, if any. Idempotent. Cap-gates before the existence
/// check. Removes the record when nothing else is set.
public fun clear_kind(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let metadata: &mut ReleaseMetadata = df::borrow_mut(uid, ExtensionKey());
    if (metadata.kind.is_none()) return;
    metadata.kind = option::none();
    prune(uid);
    emit(ReleaseKindClearedEvent { release_id });
}

/// Sets (or replaces) what the release says about itself. Aborts
/// `EEmptyDescription` for an empty string, then `EDescriptionTooLong` above
/// `MAX_DESCRIPTION_LENGTH` bytes, both before the cap is consulted. Creates
/// the record on first use. Setting the description already attached is a
/// no-op after the cap check: nothing is written and nothing is emitted.
public fun set_description(self: &mut Release, cap: &ReleaseAdminCap, description: String) {
    let bytes = description.as_bytes();
    assert!(!bytes.is_empty(), EEmptyDescription);
    assert!(bytes.length() <= MAX_DESCRIPTION_LENGTH, EDescriptionTooLong);

    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey()) && metadata(uid).description.contains(&description)) return;
    metadata_mut(uid).description = option::some(description);
    emit(ReleaseDescriptionSetEvent { release_id, description });
}

/// Removes the description, if any. Idempotent. Cap-gates before the
/// existence check. Removes the record when nothing else is set.
public fun clear_description(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let metadata: &mut ReleaseMetadata = df::borrow_mut(uid, ExtensionKey());
    if (metadata.description.is_none()) return;
    metadata.description = option::none();
    prune(uid);
    emit(ReleaseDescriptionClearedEvent { release_id });
}

// === View Functions ===

/// Whether a title is attached to this release.
public fun has_title(self: &Release): bool {
    let uid = self.uid();
    df::exists(uid, ExtensionKey()) && metadata(uid).title.is_some()
}

/// The release's title. Aborts `ENoTitle` if nothing is attached.
public fun title(self: &Release): &String {
    assert!(has_title(self), ENoTitle);
    metadata(self.uid()).title.borrow()
}

/// The release's genre ids in order, primary first. Empty when none is
/// assigned.
public fun genres(self: &Release): vector<ID> {
    let uid = self.uid();
    if (df::exists(uid, ExtensionKey())) metadata(uid).genres else vector[]
}

/// Whether a kind is attached to this release.
public fun has_kind(self: &Release): bool {
    let uid = self.uid();
    df::exists(uid, ExtensionKey()) && metadata(uid).kind.is_some()
}

/// What the release calls itself. Aborts `ENoKind` if nothing is attached.
public fun kind(self: &Release): &String {
    assert!(has_kind(self), ENoKind);
    metadata(self.uid()).kind.borrow()
}

/// Whether a description is attached to this release.
public fun has_description(self: &Release): bool {
    let uid = self.uid();
    df::exists(uid, ExtensionKey()) && metadata(uid).description.is_some()
}

/// What the release says about itself. Aborts `ENoDescription` if nothing is
/// attached.
public fun description(self: &Release): &String {
    assert!(has_description(self), ENoDescription);
    metadata(self.uid()).description.borrow()
}

// === Test Functions ===

/// Whether the metadata record itself is attached — lets tests prove the
/// field lifecycle (absent before any write, created by the first, removed
/// by the clear that empties it) without a production predicate for it.
#[test_only]
public fun has_metadata_for_testing(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

#[test_only]
public fun title_set_event_fields(e: &ReleaseTitleSetEvent): (address, String) {
    (e.release_id, e.title)
}

#[test_only]
public fun title_cleared_event_fields(e: &ReleaseTitleClearedEvent): address {
    e.release_id
}

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

#[test_only]
public fun kind_set_event_fields(e: &ReleaseKindSetEvent): (address, String) {
    (e.release_id, e.kind)
}

#[test_only]
public fun kind_cleared_event_fields(e: &ReleaseKindClearedEvent): address {
    e.release_id
}

#[test_only]
public fun description_set_event_fields(e: &ReleaseDescriptionSetEvent): (address, String) {
    (e.release_id, e.description)
}

#[test_only]
public fun description_cleared_event_fields(e: &ReleaseDescriptionClearedEvent): address {
    e.release_id
}

// === Private Functions ===

/// The attached record. Callers check existence first.
fun metadata(uid: &UID): &ReleaseMetadata {
    df::borrow(uid, ExtensionKey())
}

/// The attached record, creating an empty one if none is attached. Every
/// write goes through here, so the record exists exactly from the first
/// write on.
fun metadata_mut(uid: &mut UID): &mut ReleaseMetadata {
    if (!df::exists(uid, ExtensionKey())) {
        df::add(
            uid,
            ExtensionKey(),
            ReleaseMetadata {
                title: option::none(),
                genres: vector[],
                kind: option::none(),
                description: option::none(),
            },
        );
    };
    df::borrow_mut(uid, ExtensionKey())
}

/// Removes the record if every attribute is unset, so that "field absent"
/// and "no metadata" stay the same fact. Callers ensure the record exists.
fun prune(uid: &mut UID) {
    let metadata = metadata(uid);
    let empty =
        metadata.title.is_none() &&
        metadata.genres.is_empty() &&
        metadata.kind.is_none() &&
        metadata.description.is_none();
    if (empty) {
        let ReleaseMetadata {
            title: _,
            genres: _,
            kind: _,
            description: _,
        } = df::remove(uid, ExtensionKey());
    }
}
