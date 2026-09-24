// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A recording's basic descriptive metadata — its genres, the languages sung
/// or spoken on it, its parental advisory and what names this take —
/// stored as one dynamic field on the recording's `UID`, written through its
/// cap-gated `uid_mut`, and readable by anyone. Supersedes the standalone
/// `recording_genre`, `recording_language` and `recording_advisory` packages
/// and adds the version.
///
/// musicos core keeps only a recording's identity and what the economics
/// read; everything that describes the take lives here. A recording carries
/// no name of its own in core, and neither does its composition: a recording
/// is a take of its composition, so its display title is the composition's
/// title (from `composition_metadata`) plus whatever names this take.
///
/// **Storage.** One `RecordingMetadata` record under this module's
/// `ExtensionKey()`, whose fields are the attributes. Every attribute is
/// optional and independently settable and clearable; the record is created
/// by the first write and removed by the clear that empties it, so "the
/// field is absent" and "no metadata is attached" are the same fact.
///
/// **Genres.** Which genres classify the audio itself, in order with the
/// primary first — a fact about the master, not about any release it
/// appears on, which is why it lives on the recording. Every add takes
/// `&Genre`, a real, name-derived object from the shared vocabulary, so only
/// ids that resolve to a genuine entry can ever enter the list; removal
/// takes a bare `ID`. The list is at most `MAX_GENRES`, and it is empty
/// rather than absent when no genre is assigned. Reordering — including
/// promoting an existing entry to primary — is `clear_genres` followed by
/// `add_genre` in the desired order, atomically within one programmable
/// transaction block.
///
/// **Languages.** A vector, not a single code — bilingual and code-switching
/// recordings are ordinary. Order is the caller's: first is conventionally
/// the predominant one. **An empty vector means instrumental** — attached,
/// and asserting there is no sung or spoken content at all. That is a
/// genuine claim about the recording and is deliberately distinct from
/// attaching nothing, which says only that nobody has looked. The three
/// states are: absent (`has_languages` is false), instrumental (attached
/// and `languages()` is empty), and sung. `LanguageCode` is a valid ISO
/// 639-1 code by construction, so only count and duplicates are checked.
///
/// **Advisory.** Deliberately not a boolean: a *cleaned* edit — an
/// explicit recording re-issued with the offending content removed — is
/// merchandised differently from a recording that was never explicit, so
/// `Cleaned` is a first-class variant. Attaching the advisory IS the
/// statement; a recording with nothing attached has said nothing, which
/// must never be read as `NotExplicit`.
///
/// **Version.** What names this particular take — "Live", "Radio Edit",
/// "Acoustic" — as a free string rather than an enum, because which
/// take-names are legitimate is not the protocol's job. The separator used
/// to render "Song (Live)" is presentation and is not stored. Absence means
/// the recording has not distinguished itself from other takes, so an empty
/// string is rejected rather than stored as a blank name.
///
/// Bounds are on bytes, not characters; strings are stored exactly as
/// given. This package is never upgraded — every publish is a fresh
/// identity — so every public function is permanent surface, and nothing
/// derivable by composing the others is offered: an instrumental claim is
/// `set_languages(recording, cap, vector[])`, and the primary genre is
/// `genres(recording)[0]`.
///
/// **Guard order.** Validation that needs only the argument (emptiness,
/// byte bounds, language count and duplicates) runs before the cap is
/// consulted, so an invalid value reports its own code whatever cap is
/// supplied. Anything that reads stored state — existence on clear, and
/// genre duplicate, capacity and membership — runs after `uid_mut`.
///
/// **No-ops.** A write that would leave the stored value unchanged is a
/// no-op: it performs no write and emits no event. A set of the value already
/// attached returns after the cap check without touching the record; a clear
/// of nothing returns after the cap check without emitting. Only an attached
/// value can be equalled, so a set never creates the record as a no-op.
/// Genres are a list, not a value: a duplicate add aborts rather than
/// silently succeeding, and removing or clearing nothing is silent.
module recording_metadata::recording_metadata;

use genre::genre::Genre;
use language_code::language_code::LanguageCode;
use musicos::recording::{Recording, RecordingAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_set;

// === Errors ===

// One decade per attribute, in field order. Within a decade: `0` nothing
// attached, `1` empty input, `2` bound exceeded, `3` duplicate, `4` not
// present.

// Genres (10–19)
/// The recording already carries `MAX_GENRES` genres.
const EMaxGenres: u64 = 12;
/// The genre is already assigned to this recording.
const EDuplicateGenre: u64 = 13;
/// The genre is not assigned to this recording.
const EGenreNotPresent: u64 = 14;

// Languages (20–29)
/// No language record is attached to this recording.
const ENoLanguages: u64 = 20;
/// More than `MAX_LANGUAGES` were supplied.
const ETooManyLanguages: u64 = 22;
/// The same language appears twice.
const EDuplicateLanguage: u64 = 23;

// Advisory (30–39)
/// No advisory is attached to this recording.
const ENoAdvisory: u64 = 30;

// Version (40–49)
/// No version is attached to this recording.
const ENoVersion: u64 = 40;
/// The version is empty. Asserting nothing should be done by not attaching.
const EEmptyVersion: u64 = 41;
/// The version exceeds `MAX_VERSION_LENGTH` bytes.
const EVersionTooLong: u64 = 42;

// === Constants ===

/// Maximum genres on one recording: the primary plus up to five more.
const MAX_GENRES: u64 = 6;

/// Maximum languages on one recording — far above any real recording, low
/// enough to keep the field bounded.
const MAX_LANGUAGES: u64 = 10;

/// Maximum length of a version, in UTF-8 bytes. A version names a take, not
/// a description of it; the bound leaves room for long forms in multi-byte
/// scripts while keeping the field bounded.
const MAX_VERSION_LENGTH: u64 = 300;

// === Structs ===

/// Dynamic-field key — one metadata record per recording.
public struct ExtensionKey() has copy, drop, store;

/// The record stored under `ExtensionKey()`. Present only while at least one
/// attribute is set; a clear that leaves every attribute unset removes the
/// field. `store` only: it is taken out by destructuring, never dropped.
public struct RecordingMetadata has store {
    /// `genre::Genre` ids in order, primary first. Empty when none is
    /// assigned — an empty list is "no genre", never a distinct claim.
    genres: vector<ID>,
    /// The languages sung or spoken, in the order given. `Some(empty)` is
    /// an instrumental claim; `None` is no claim at all.
    languages: Option<vector<LanguageCode>>,
    /// The parental advisory. `None` is not `NotExplicit`.
    advisory: Option<Advisory>,
    /// What names this take, stored exactly as given.
    version: Option<String>,
}

// === Enums ===

/// A recording's parental advisory. The variants are private to this
/// module, as Move requires, so the three constructors and three predicates
/// are the whole vocabulary a caller needs.
public enum Advisory has copy, drop, store {
    /// Contains explicit content.
    Explicit,
    /// Contains no explicit content, and never did.
    NotExplicit,
    /// An edited version of a recording that was originally explicit.
    Cleaned,
}

// === Events ===

// Every event is phantom-typed by `RecordingShare`, like `Recording` itself,
// and carries only what an event-only indexer could not get without a
// lookup: the recording and, on a write, the value written. Prior state is
// the indexer's own previous projection; the admin cap is the derived
// address of `recording_id` under `RecordingAdminCapKey`; the sender is the
// transaction envelope; the share type is the type argument. Set events fire
// only when the value changes — an equal set is a no-op and emits nothing;
// clear events fire only when something was actually removed.

/// Emitted when a genre is appended (`add_genre`). The genre lands at the
/// end of the list, so an indexer replaying this stream knows its index and
/// whether it became the primary; the genre's name is carried by the
/// vocabulary's own `genre::GenreCreatedEvent`.
public struct RecordingGenreAddedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    genre_id: address,
}

/// Emitted when a genre is removed (`remove_genre`). Survivors keep their
/// order, so the replayed list after this event is the list before it minus
/// `genre_id`; removing the last genre is this one event, not a
/// Removed-then-Cleared pair.
public struct RecordingGenreRemovedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    genre_id: address,
}

/// Emitted when `clear_genres` removes a non-empty list.
public struct RecordingGenresClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

/// Emitted when a recording's languages are set or replaced. `languages` is
/// the ordered list now attached, each code serialised as its two-byte ISO
/// 639-1 string; empty is an instrumental claim.
public struct RecordingLanguagesSetEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    languages: vector<LanguageCode>,
}

/// Emitted when an attached language record — sung or instrumental — is
/// removed.
public struct RecordingLanguagesClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

/// Emitted when an advisory is set or replaced. `advisory` serialises as its
/// variant index: `Explicit = 0`, `NotExplicit = 1`, `Cleaned = 2`.
public struct RecordingAdvisorySetEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    advisory: Advisory,
}

/// Emitted when an attached advisory is removed.
public struct RecordingAdvisoryClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

/// Emitted when a recording's version is set or replaced.
public struct RecordingVersionSetEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    version: String,
}

/// Emitted when an attached version is removed.
public struct RecordingVersionClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

// === Public Functions ===

/// Contains explicit content.
public fun explicit(): Advisory { Advisory::Explicit }

/// Contains no explicit content, and never did.
public fun not_explicit(): Advisory { Advisory::NotExplicit }

/// An edited version of a recording that was originally explicit.
public fun cleaned(): Advisory { Advisory::Cleaned }

/// Appends a genre to the recording's list; the first genre added becomes
/// the primary. Creates the record on first use. Aborts `EDuplicateGenre` if
/// the genre is already present, then `EMaxGenres` if the recording is
/// already at capacity — both after cap authorization.
public fun add_genre<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    genre: &Genre,
) {
    let recording_id = object::id(self).to_address();
    let genre_id = object::id(genre);
    let uid = self.uid_mut(cap);
    let genres = &mut metadata_mut(uid).genres;
    assert!(!genres.contains(&genre_id), EDuplicateGenre);
    assert!(genres.length() < MAX_GENRES, EMaxGenres);
    genres.push_back(genre_id);
    emit(RecordingGenreAddedEvent<RecordingShare> {
        recording_id,
        genre_id: genre_id.to_address(),
    });
}

/// Removes a genre by id. If it was the primary, the next entry becomes
/// primary by now sitting at index 0. Removing the last genre leaves the
/// list empty and removes the record when nothing else is set. Aborts
/// `EGenreNotPresent` if the genre is not assigned — including when nothing
/// is attached at all — after cap authorization.
public fun remove_genre<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    genre_id: ID,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    assert!(df::exists(uid, ExtensionKey()), EGenreNotPresent);
    let metadata: &mut RecordingMetadata = df::borrow_mut(uid, ExtensionKey());
    let (found, index) = metadata.genres.index_of(&genre_id);
    assert!(found, EGenreNotPresent);
    metadata.genres.remove(index);
    prune(uid);
    emit(RecordingGenreRemovedEvent<RecordingShare> {
        recording_id,
        genre_id: genre_id.to_address(),
    });
}

/// Removes the recording's entire genre list. Cap-gates before the existence
/// check; an authorized clear of nothing is a silent no-op. Emits
/// `RecordingGenresClearedEvent` only when a non-empty list was removed, and
/// removes the record when nothing else is set.
public fun clear_genres<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let metadata: &mut RecordingMetadata = df::borrow_mut(uid, ExtensionKey());
    if (metadata.genres.is_empty()) return;
    metadata.genres = vector[];
    prune(uid);
    emit(RecordingGenresClearedEvent<RecordingShare> { recording_id });
}

/// Sets (or replaces) the languages sung or spoken on the recording. Passing
/// an empty vector asserts the recording is instrumental. Aborts
/// `ETooManyLanguages` above `MAX_LANGUAGES`, then `EDuplicateLanguage` if a
/// code repeats, both before the cap is consulted. Creates the record on
/// first use. Setting the list already attached — same codes, same order —
/// is a no-op after the cap check: nothing is written and nothing is emitted.
public fun set_languages<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    languages: vector<LanguageCode>,
) {
    assert!(languages.length() <= MAX_LANGUAGES, ETooManyLanguages);
    let mut seen = vec_set::empty<LanguageCode>();
    languages.do_ref!(|language| {
        assert!(!seen.contains(language), EDuplicateLanguage);
        seen.insert(*language);
    });

    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey()) && metadata(uid).languages.contains(&languages)) return;
    metadata_mut(uid).languages = option::some(languages);
    emit(RecordingLanguagesSetEvent<RecordingShare> { recording_id, languages });
}

/// Removes the language record, if any. Idempotent. Cap-gates before the
/// existence check. Leaves the recording having said nothing — which is not
/// the same as asserting it is instrumental — and removes the record when
/// nothing else is set.
public fun clear_languages<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let metadata: &mut RecordingMetadata = df::borrow_mut(uid, ExtensionKey());
    if (metadata.languages.is_none()) return;
    metadata.languages = option::none();
    prune(uid);
    emit(RecordingLanguagesClearedEvent<RecordingShare> { recording_id });
}

/// Sets (or replaces) the recording's advisory. Creates the record on
/// first use. Setting the advisory already attached is a no-op after the cap
/// check: nothing is written and nothing is emitted.
public fun set_advisory<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    advisory: Advisory,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey()) && metadata(uid).advisory.contains(&advisory)) return;
    metadata_mut(uid).advisory = option::some(advisory);
    emit(RecordingAdvisorySetEvent<RecordingShare> { recording_id, advisory });
}

/// Removes the advisory, if any. Idempotent. Cap-gates before the existence
/// check. Leaves the recording having said nothing about its content, which
/// is distinct from asserting `NotExplicit`, and removes the record when
/// nothing else is set.
public fun clear_advisory<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let metadata: &mut RecordingMetadata = df::borrow_mut(uid, ExtensionKey());
    if (metadata.advisory.is_none()) return;
    metadata.advisory = option::none();
    prune(uid);
    emit(RecordingAdvisoryClearedEvent<RecordingShare> { recording_id });
}

/// Sets (or replaces) what names this take. Aborts `EEmptyVersion` for an
/// empty string, then `EVersionTooLong` above `MAX_VERSION_LENGTH` bytes,
/// both before the cap is consulted. Creates the record on first use.
/// Setting the version already attached is a no-op after the cap check:
/// nothing is written and nothing is emitted.
public fun set_version<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    version: String,
) {
    let bytes = version.as_bytes();
    assert!(!bytes.is_empty(), EEmptyVersion);
    assert!(bytes.length() <= MAX_VERSION_LENGTH, EVersionTooLong);

    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey()) && metadata(uid).version.contains(&version)) return;
    metadata_mut(uid).version = option::some(version);
    emit(RecordingVersionSetEvent<RecordingShare> { recording_id, version });
}

/// Removes the version, if any. Idempotent. Cap-gates before the existence
/// check. Leaves the recording as an undistinguished take of its composition
/// and removes the record when nothing else is set.
public fun clear_version<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (!df::exists(uid, ExtensionKey())) return;
    let metadata: &mut RecordingMetadata = df::borrow_mut(uid, ExtensionKey());
    if (metadata.version.is_none()) return;
    metadata.version = option::none();
    prune(uid);
    emit(RecordingVersionClearedEvent<RecordingShare> { recording_id });
}

// === View Functions ===

/// The recording's genre ids in order, primary first. Empty when none is
/// assigned.
public fun genres<RecordingShare>(self: &Recording<RecordingShare>): vector<ID> {
    let uid = self.uid();
    if (df::exists(uid, ExtensionKey())) metadata(uid).genres else vector[]
}

/// Whether a language record is attached to this recording.
public fun has_languages<RecordingShare>(self: &Recording<RecordingShare>): bool {
    let uid = self.uid();
    df::exists(uid, ExtensionKey()) && metadata(uid).languages.is_some()
}

/// The recording's languages, in the order given. Empty means instrumental.
/// Aborts `ENoLanguages` if nothing is attached — absence is a distinct
/// state from an empty vector and must not collapse into it.
public fun languages<RecordingShare>(
    self: &Recording<RecordingShare>,
): vector<LanguageCode> {
    assert!(has_languages(self), ENoLanguages);
    *metadata(self.uid()).languages.borrow()
}

/// Whether an advisory is attached to this recording.
public fun has_advisory<RecordingShare>(self: &Recording<RecordingShare>): bool {
    let uid = self.uid();
    df::exists(uid, ExtensionKey()) && metadata(uid).advisory.is_some()
}

/// The recording's advisory. Aborts `ENoAdvisory` if none is attached —
/// callers that tolerate an unrated recording should check `has_advisory`
/// first, since absence must not be silently read as `NotExplicit`.
public fun advisory<RecordingShare>(self: &Recording<RecordingShare>): Advisory {
    assert!(has_advisory(self), ENoAdvisory);
    *metadata(self.uid()).advisory.borrow()
}

/// Whether a version is attached to this recording.
public fun has_version<RecordingShare>(self: &Recording<RecordingShare>): bool {
    let uid = self.uid();
    df::exists(uid, ExtensionKey()) && metadata(uid).version.is_some()
}

/// What names this take. Aborts `ENoVersion` if nothing is attached.
public fun version<RecordingShare>(self: &Recording<RecordingShare>): &String {
    assert!(has_version(self), ENoVersion);
    metadata(self.uid()).version.borrow()
}

/// Whether the recording contains explicit content.
public fun is_explicit(self: &Advisory): bool {
    match (self) { Advisory::Explicit => true, _ => false }
}

/// Whether the recording contains no explicit content and never did.
public fun is_not_explicit(self: &Advisory): bool {
    match (self) { Advisory::NotExplicit => true, _ => false }
}

/// Whether the recording is an edited version of an originally explicit one.
public fun is_cleaned(self: &Advisory): bool {
    match (self) { Advisory::Cleaned => true, _ => false }
}

// === Test Functions ===

/// Whether the metadata record itself is attached — lets tests prove the
/// field lifecycle (absent before any write, created by the first, removed
/// by the clear that empties it) without a production predicate for it.
#[test_only]
public fun has_metadata_for_testing<RecordingShare>(
    self: &Recording<RecordingShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

#[test_only]
public fun genre_added_event_fields<RecordingShare>(
    e: &RecordingGenreAddedEvent<RecordingShare>,
): (address, address) {
    (e.recording_id, e.genre_id)
}

#[test_only]
public fun genre_removed_event_fields<RecordingShare>(
    e: &RecordingGenreRemovedEvent<RecordingShare>,
): (address, address) {
    (e.recording_id, e.genre_id)
}

#[test_only]
public fun genres_cleared_event_fields<RecordingShare>(
    e: &RecordingGenresClearedEvent<RecordingShare>,
): address {
    e.recording_id
}

#[test_only]
public fun languages_set_event_fields<RecordingShare>(
    e: &RecordingLanguagesSetEvent<RecordingShare>,
): (address, vector<LanguageCode>) {
    (e.recording_id, e.languages)
}

#[test_only]
public fun languages_cleared_event_fields<RecordingShare>(
    e: &RecordingLanguagesClearedEvent<RecordingShare>,
): address {
    e.recording_id
}

#[test_only]
public fun advisory_set_event_fields<RecordingShare>(
    e: &RecordingAdvisorySetEvent<RecordingShare>,
): (address, Advisory) {
    (e.recording_id, e.advisory)
}

#[test_only]
public fun advisory_cleared_event_fields<RecordingShare>(
    e: &RecordingAdvisoryClearedEvent<RecordingShare>,
): address {
    e.recording_id
}

#[test_only]
public fun version_set_event_fields<RecordingShare>(
    e: &RecordingVersionSetEvent<RecordingShare>,
): (address, String) {
    (e.recording_id, e.version)
}

#[test_only]
public fun version_cleared_event_fields<RecordingShare>(
    e: &RecordingVersionClearedEvent<RecordingShare>,
): address {
    e.recording_id
}

// === Private Functions ===

/// The attached record. Callers check existence first.
fun metadata(uid: &UID): &RecordingMetadata {
    df::borrow(uid, ExtensionKey())
}

/// The attached record, creating an empty one if none is attached. Every
/// write goes through here, so the record exists exactly from the first
/// write on.
fun metadata_mut(uid: &mut UID): &mut RecordingMetadata {
    if (!df::exists(uid, ExtensionKey())) {
        df::add(
            uid,
            ExtensionKey(),
            RecordingMetadata {
                genres: vector[],
                languages: option::none(),
                advisory: option::none(),
                version: option::none(),
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
        metadata.genres.is_empty() &&
        metadata.languages.is_none() &&
        metadata.advisory.is_none() &&
        metadata.version.is_none();
    if (empty) {
        let RecordingMetadata {
            genres: _,
            languages: _,
            advisory: _,
            version: _,
        } = df::remove(uid, ExtensionKey());
    }
}
