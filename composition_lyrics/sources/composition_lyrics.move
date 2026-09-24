// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Language-specific lyrics attached to a composition, one entry per ISO
/// 639-1 language code. The payload convention is UTF-8 text compressed into
/// one self-contained Zstandard frame without an external dictionary. Move
/// stores opaque bytes: it does not decode, inspect frame headers, validate
/// text, or attest to the lyrics or their language.
///
/// Writes require the composition's matching admin cap; reads are
/// permissionless. Events carry the composition and the language key only;
/// the compressed body is read from the dynamic field.
module composition_lyrics::composition_lyrics;

use language_code::language_code::LanguageCode;
use musicos::composition::{Composition, CompositionAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No lyrics are attached for this language.
const ENoLyrics: u64 = 1;
/// The compressed lyrics exceed `MAX_LYRICS_LENGTH` bytes.
const ELyricsTooLong: u64 = 2;

// === Constants ===

/// Storage bound per language, in compressed bytes. Not a decoded text limit.
const MAX_LYRICS_LENGTH: u64 = 32768;

// === Structs ===

/// Dynamic-field key — one compressed payload (`vector<u8>`) per language.
public struct ExtensionKey(LanguageCode) has copy, drop, store;

// === Events ===

/// Emitted when a language's lyrics are set or replaced with different bytes.
public struct CompositionLyricsSetEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    language: String,
}

/// Emitted when a language's lyrics are removed.
public struct CompositionLyricsClearedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    language: String,
}

// === Public Functions ===

/// Adds or replaces one language, preserving the supplied bytes exactly.
/// Aborts `ELyricsTooLong` past `MAX_LYRICS_LENGTH` bytes, before cap
/// authorization. Empty and malformed frames are left for clients to
/// interpret. Setting the bytes already stored neither writes nor emits.
public fun set_lyrics<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    language: LanguageCode,
    lyrics: vector<u8>,
) {
    assert!(lyrics.length() <= MAX_LYRICS_LENGTH, ELyricsTooLong);

    let composition_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    let key = ExtensionKey(language);
    if (df::exists(uid, key)) {
        let stored: &mut vector<u8> = df::borrow_mut(uid, key);
        if (*stored == lyrics) return;
        *stored = lyrics;
    } else {
        df::add(uid, key, lyrics);
    };
    emit(CompositionLyricsSetEvent<CompositionShare> { composition_id, language: language.code() });
}

/// Removes only this language. Authorizes first; an absent entry is a silent
/// no-op.
public fun clear_lyrics<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    language: LanguageCode,
) {
    let composition_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    let key = ExtensionKey(language);
    if (df::exists(uid, key)) {
        let _: vector<u8> = df::remove(uid, key);
        emit(CompositionLyricsClearedEvent<CompositionShare> {
            composition_id,
            language: language.code(),
        });
    }
}

// === View Functions ===

/// Whether lyrics are attached for this language.
public fun has_lyrics<CompositionShare>(
    self: &Composition<CompositionShare>,
    language: LanguageCode,
): bool {
    df::exists(self.uid(), ExtensionKey(language))
}

/// Borrows the compressed bytes. Aborts `ENoLyrics` when this language has
/// no entry.
public fun lyrics<CompositionShare>(
    self: &Composition<CompositionShare>,
    language: LanguageCode,
): &vector<u8> {
    assert!(has_lyrics(self, language), ENoLyrics);
    df::borrow(self.uid(), ExtensionKey(language))
}

/// Maximum stored payload size per language, in bytes.
public fun max_lyrics_length(): u64 { MAX_LYRICS_LENGTH }

// === Test Functions ===

#[test_only]
public fun set_event_fields<CompositionShare>(
    e: &CompositionLyricsSetEvent<CompositionShare>,
): (address, String) {
    (e.composition_id, e.language)
}

#[test_only]
public fun clear_event_fields<CompositionShare>(
    e: &CompositionLyricsClearedEvent<CompositionShare>,
): (address, String) {
    (e.composition_id, e.language)
}
