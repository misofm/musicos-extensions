// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The languages sung or spoken on a recording, stored as a dynamic field on
/// the recording's UID and written through its cap-gated `uid_mut`.
///
/// Its own package, for the same reason the advisory rating is: language is set
/// by different people, at different times, and governed by a standard (ISO 639)
/// that has nothing to do with any other fact about the recording. A consumer
/// implementing a metadata profile picks this extension up or leaves it, and
/// replacing it never disturbs anything else attached to the work.
///
/// A `vector`, not a single code — bilingual and code-switching recordings are
/// ordinary, and forcing one language would mean choosing which of them to
/// erase. Order is the caller's: first is conventionally the predominant one.
///
/// **An empty vector means instrumental** — attached, and asserting there is no
/// sung or spoken content at all. That is a genuine claim about the recording
/// and is deliberately distinct from attaching nothing, which says only that
/// nobody has looked. `set_instrumental` exists so that claim reads as intent
/// at the call site rather than as an empty argument someone might mistake for
/// an oversight.
///
/// `LanguageCode` is a valid ISO 639-1 code by construction, so this package
/// checks only what construction cannot: how many, and whether any repeat.
module recording_language::recording_language;

use language_code::language_code::LanguageCode;
use musicos::recording::{Self, Recording, RecordingAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_set;

// === Errors ===

/// No language record is attached to this recording.
const ENoLanguages: u64 = 1;
/// More than `MAX_LANGUAGES` were supplied.
const ETooManyLanguages: u64 = 2;
/// The same language appears twice.
const EDuplicateLanguage: u64 = 3;

// === Constants ===

/// Maximum languages on one recording. Matches `party_profile`'s bound — far
/// above any real recording, low enough to keep the field bounded.
const MAX_LANGUAGES: u64 = 10;

// === Structs ===

/// Dynamic-field key — one language record per recording.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a recording's languages are set or replaced. Carries primitive
/// ordered code snapshots so an indexer can replay the transition directly.
public struct LanguagesSetEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    had_languages: bool,
    previous_languages: vector<vector<u8>>,
    languages: vector<vector<u8>>,
    language_count_before: u64,
    language_count_after: u64,
    was_instrumental: bool,
    is_instrumental: bool,
    max_languages: u64,
}

/// Emitted when the language record is removed.
public struct LanguagesUnsetEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    removed_languages: vector<vector<u8>>,
    language_count_before: u64,
    was_instrumental: bool,
}

// === Public Functions ===

/// Sets (or replaces) the languages sung or spoken on the recording.
///
/// Passing an empty vector asserts the recording is instrumental; prefer
/// `set_instrumental`, which says so at the call site.
public fun set_languages<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    languages: vector<LanguageCode>,
) {
    validate(&languages);
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let uid = self.uid_mut(cap);
    let had_languages = df::exists(uid, ExtensionKey());
    let mut previous_languages = vector[];
    let mut language_count_before = 0;
    let mut was_instrumental = false;
    if (had_languages) {
        let previous = df::borrow(uid, ExtensionKey());
        previous_languages = encode_languages(previous);
        language_count_before = previous.length();
        was_instrumental = previous.is_empty();
        *df::borrow_mut(uid, ExtensionKey()) = languages;
    } else {
        df::add(uid, ExtensionKey(), languages);
    };
    let current = df::borrow(uid, ExtensionKey());
    let current_languages = encode_languages(current);
    let language_count_after = current.length();
    let is_instrumental = current.is_empty();
    emit(LanguagesSetEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        admin_cap_id,
        had_languages,
        previous_languages,
        languages: current_languages,
        language_count_before,
        language_count_after,
        was_instrumental,
        is_instrumental,
        max_languages: MAX_LANGUAGES,
    });
}

/// Asserts the recording has no sung or spoken content.
public fun set_instrumental<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    set_languages(self, cap, vector[]);
}

/// Removes the language record, if any. Idempotent. Leaves the recording having
/// said nothing — which is not the same as asserting it is instrumental.
public fun unset_languages<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let removed = df::remove(uid, ExtensionKey());
        let removed_languages = encode_languages(&removed);
        let language_count_before = removed.length();
        let was_instrumental = removed.is_empty();
        emit(LanguagesUnsetEvent<RecordingShare, CompositionShare> {
            recording_id,
            composition_id,
            admin_cap_id,
            removed_languages,
            language_count_before,
            was_instrumental,
        });
    }
}

// === View Functions ===

/// Whether a language record is attached to this recording.
public fun has_languages<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's languages, in the order given. Empty means instrumental.
/// Aborts if nothing is attached — absence is a distinct state from an empty
/// vector and must not collapse into it.
public fun languages<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): vector<LanguageCode> {
    assert!(has_languages(self), ENoLanguages);
    *df::borrow(self.uid(), ExtensionKey())
}

/// Whether the recording asserts it is instrumental: attached, and empty.
/// False when nothing is attached, because that asserts nothing.
public fun is_instrumental<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    has_languages(self) && df::borrow<ExtensionKey, vector<LanguageCode>>(
        self.uid(),
        ExtensionKey(),
    ).is_empty()
}

// === Private Functions ===

/// Each `LanguageCode` is already a valid ISO 639-1 code by construction, so
/// only the count and duplicates are checked here.
fun validate(languages: &vector<LanguageCode>) {
    assert!(languages.length() <= MAX_LANGUAGES, ETooManyLanguages);
    let mut seen = vec_set::empty<LanguageCode>();
    languages.do_ref!(|l| {
        assert!(!seen.contains(l), EDuplicateLanguage);
        seen.insert(*l);
    });
}

// === Test Functions ===

#[test_only]
public fun set_event_fields<RecordingShare, CompositionShare>(
    e: &LanguagesSetEvent<RecordingShare, CompositionShare>,
): (
    address,
    address,
    address,
    bool,
    vector<vector<u8>>,
    vector<vector<u8>>,
    u64,
    u64,
    bool,
    bool,
    u64,
) {
    (
        e.recording_id,
        e.composition_id,
        e.admin_cap_id,
        e.had_languages,
        e.previous_languages,
        e.languages,
        e.language_count_before,
        e.language_count_after,
        e.was_instrumental,
        e.is_instrumental,
        e.max_languages,
    )
}

#[test_only]
public fun unset_event_fields<RecordingShare, CompositionShare>(
    e: &LanguagesUnsetEvent<RecordingShare, CompositionShare>,
): (address, address, address, vector<vector<u8>>, u64, bool) {
    (
        e.recording_id,
        e.composition_id,
        e.admin_cap_id,
        e.removed_languages,
        e.language_count_before,
        e.was_instrumental,
    )
}

#[test_only]
public fun unset_event_recording_id<RecordingShare, CompositionShare>(
    e: &LanguagesUnsetEvent<RecordingShare, CompositionShare>,
): ID { e.recording_id.to_id() }

// === Private Functions ===

/// Encodes validated language codes as their raw ordered two-byte values.
fun encode_languages(values: &vector<LanguageCode>): vector<vector<u8>> {
    let mut result = vector[];
    values.do_ref!(|value| {
        let code = language_code::language_code::code(value);
        result.push_back(*code.as_bytes());
    });
    result
}
