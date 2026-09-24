// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The languages sung or spoken on a recording, stored as a dynamic field on
/// the recording's UID and written through its cap-gated `uid_mut`.
///
/// One concern, one package: language is set by different people, at
/// different times, under a standard (ISO 639) that has nothing to do with
/// any other fact about the recording.
///
/// A `vector`, not a single code — bilingual and code-switching recordings are
/// ordinary. Order is the caller's: first is conventionally the predominant.
///
/// An attached empty vector means instrumental: a genuine claim that there is
/// no sung or spoken content, deliberately distinct from attaching nothing,
/// which says only that nobody has looked.
///
/// `LanguageCode` is a valid ISO 639-1 code by construction, so this package
/// checks only what construction cannot: how many, and whether any repeat.
module recording_language::recording_language;

use language_code::language_code::LanguageCode;
use musicos::recording::{Recording, RecordingAdminCap};
use std::string::String;
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

/// Maximum languages on one recording.
const MAX_LANGUAGES: u64 = 10;

// === Structs ===

/// Dynamic-field key — one `vector<LanguageCode>` per recording.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when the language list is set to a value it did not already hold.
/// `languages` holds the ordered ISO 639-1 codes; empty means instrumental.
public struct RecordingLanguagesSetEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    languages: vector<String>,
}

/// Emitted when an attached language record is removed.
public struct RecordingLanguagesClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

// === Public Functions ===

/// Sets (or replaces) the languages sung or spoken on the recording; an empty
/// vector asserts it is instrumental. Aborts `ETooManyLanguages` past
/// `MAX_LANGUAGES` and `EDuplicateLanguage` on a repeated code. Setting the
/// list already held neither writes nor emits.
public fun set_languages<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    languages: vector<LanguageCode>,
) {
    validate(&languages);
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let current: &mut vector<LanguageCode> = df::borrow_mut(uid, ExtensionKey());
        if (*current == languages) return;
        *current = languages;
    } else {
        df::add(uid, ExtensionKey(), languages);
    };
    emit(RecordingLanguagesSetEvent<RecordingShare> {
        recording_id,
        languages: languages.map_ref!(|language| language.code()),
    });
}

/// Removes the language record, if any — including an instrumental claim.
/// Silent when nothing is attached.
public fun clear_languages<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: vector<LanguageCode> = df::remove(uid, ExtensionKey());
        emit(RecordingLanguagesClearedEvent<RecordingShare> { recording_id });
    }
}

// === View Functions ===

/// Whether a language record is attached to this recording.
public fun has_languages<RecordingShare>(self: &Recording<RecordingShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's languages, in the order given; empty means instrumental.
/// Aborts `ENoLanguages` when nothing is attached — absence is distinct from
/// an empty list and must not collapse into it.
public fun languages<RecordingShare>(
    self: &Recording<RecordingShare>,
): &vector<LanguageCode> {
    assert!(has_languages(self), ENoLanguages);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields<RecordingShare>(
    e: &RecordingLanguagesSetEvent<RecordingShare>,
): (address, vector<String>) {
    (e.recording_id, e.languages)
}

#[test_only]
public fun cleared_event_fields<RecordingShare>(
    e: &RecordingLanguagesClearedEvent<RecordingShare>,
): address {
    e.recording_id
}

// === Private Functions ===

/// Each `LanguageCode` is already valid by construction, so only the count
/// and duplicates are checked here — count first.
fun validate(languages: &vector<LanguageCode>) {
    assert!(languages.length() <= MAX_LANGUAGES, ETooManyLanguages);
    let mut seen = vec_set::empty<LanguageCode>();
    languages.do_ref!(|language| {
        assert!(!seen.contains(language), EDuplicateLanguage);
        seen.insert(*language);
    });
}
