// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Language-specific lyrics attached to a composition. The payload convention
/// is UTF-8 text compressed into one self-contained Zstandard frame without an
/// external dictionary. Move stores opaque bytes: it does not decode, inspect
/// frame headers, validate text, or attest to the lyrics or their language.
/// Writes require the composition's matching admin cap; reads are permissionless.
module composition_lyrics::composition_lyrics;

use language_code::language_code::LanguageCode;
use musicos::composition::{Composition, CompositionAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;

// === Constants ===

/// Storage bound per language, in compressed bytes. Not a decoded text limit.
const MAX_LYRICS_LENGTH: u64 = 32768;

// === Errors ===

#[error]
const EMaxLyricsLengthExceeded: vector<u8> = b"Compressed lyrics exceed the maximum length";
#[error]
const ENoLyrics: vector<u8> = b"No lyrics are attached for this language";

// === Structs ===

/// The wrapper reserves this extension's namespace; the value selects a language.
public struct ExtensionKey(LanguageCode) has copy, drop, store;

// === Events ===

/// Compact change notifications; content remains in the dynamic field.
/// See EVENT_PAYLOADS.md for retained context and BCS bounds.
public struct CompositionLyricsSetEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    composition_admin_cap_id: address,
    language: vector<u8>,
    lyrics_existed_before: bool,
}

/// Emitted only when an existing language entry is removed.
public struct CompositionLyricsClearedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    composition_admin_cap_id: address,
    language: vector<u8>,
}

// === Public Functions ===

/// Adds or replaces one language, preserving the supplied bytes exactly.
/// Authorization precedes storage validation. Empty and malformed frames are
/// left for clients to interpret. Equal replacements still write the value but
/// do not emit a change event.
public fun set_lyrics<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    language: LanguageCode,
    lyrics: vector<u8>,
) {
    let composition_id = object::id(self).to_address();
    let composition_admin_cap_id = object::id(cap).to_address();
    let uid = self.uid_mut(cap);
    assert!(lyrics.length() <= MAX_LYRICS_LENGTH, EMaxLyricsLengthExceeded);
    let key = ExtensionKey(language);
    let lyrics_existed_before = df::exists(uid, key);
    let lyrics_changed = if (lyrics_existed_before) {
        let stored: &mut vector<u8> = df::borrow_mut(uid, key);
        let lyrics_changed = *stored != lyrics;
        *stored = lyrics;
        lyrics_changed
    } else {
        df::add(uid, key, lyrics);
        true
    };
    if (lyrics_changed) {
        emit(CompositionLyricsSetEvent<CompositionShare> {
            composition_id,
            composition_admin_cap_id,
            language: *language.code().as_bytes(),
            lyrics_existed_before,
        });
    };
}

/// Removes only this language. An absent entry is an authorized, silent no-op.
public fun clear_lyrics<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    language: LanguageCode,
) {
    let composition_id = object::id(self).to_address();
    let composition_admin_cap_id = object::id(cap).to_address();
    let uid = self.uid_mut(cap);
    let key = ExtensionKey(language);
    if (df::exists(uid, key)) {
        let _: vector<u8> = df::remove(uid, key);
        emit(CompositionLyricsClearedEvent<CompositionShare> {
            composition_id,
            composition_admin_cap_id,
            language: *language.code().as_bytes(),
        });
    }
}

// === View Functions ===

public fun has_lyrics<CompositionShare>(
    self: &Composition<CompositionShare>,
    language: LanguageCode,
): bool {
    df::exists(self.uid(), ExtensionKey(language))
}

/// Borrows the compressed bytes. Aborts when this language has no entry.
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
): (address, address, vector<u8>, bool) {
    (e.composition_id, e.composition_admin_cap_id, e.language, e.lyrics_existed_before)
}

#[test_only]
public fun clear_event_fields<CompositionShare>(
    e: &CompositionLyricsClearedEvent<CompositionShare>,
): (address, address, vector<u8>) {
    (e.composition_id, e.composition_admin_cap_id, e.language)
}
