// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// What a release says about itself — the paragraph that runs under the title,
/// written by whoever holds the release's admin cap, and believed.
///
/// A free string, deliberately. Nothing on-chain reads it and nothing derives
/// from it: this is editorial prose, not a fact the protocol can check. The
/// facts a release carries that *are* checkable — its tracklist, its splits, its
/// state — live on the core object, and the claims two releases have to agree
/// about to be comparable (genre, credits, languages) each get their own typed
/// extension so they can be queried rather than read. What is left over is what
/// a person wants to say, and the only useful thing to do with it is store it
/// and attribute it to the cap holder.
///
/// One slot, not a set. A release has one thing to say about itself; per-track
/// notes and per-language translations are different concerns and would be
/// different extensions. Folding either in here would turn a paragraph into a
/// schema, and a schema is exactly what prose is not.
///
/// The 8 KB ceiling is storage hygiene, not an editorial opinion — a backstop
/// against pathological bloat in a shared object, deliberately set well above
/// any description anyone is expected to write. It is the most generous free-text
/// bound in the stack, and that is the intended asymmetry: this package publishes
/// immutable, so a ceiling that turns out to be too low can never be raised,
/// while one that is too high costs only the gas of the writer who fills it. A
/// description is also edited rarely, so the cost of rewriting the field in full
/// lands on almost nobody.
///
/// Genuinely long-form writing — an essay, a full set of liner notes — still
/// belongs where the artwork goes, in a Walrus blob referenced by an extension.
/// Nothing here stops someone using the whole 8 KB; the bound is a limit, not a
/// recommendation.
///
/// Attaching nothing and attaching a description are distinct states: absence
/// means nobody has written one, which is why an empty string is rejected rather
/// than stored. There is no such thing as an empty description.
module release_description::release_description;

use miso::release::{Release, ReleaseAdminCap};
use std::string::String;
use sui::dynamic_field as df;
use sui::event::emit;

// === Constants ===

/// Maximum length of a description, in bytes — 8 KB, or roughly 1,300 words of
/// English prose. The bound is on bytes, not characters: the same allowance is
/// about 2,700 characters of CJK, and a client that wants to show a character
/// count must derive it itself. That is the correct trade for a backstop whose
/// job is to cap storage rather than to count words.
const MAX_DESCRIPTION_LENGTH: u64 = 8192;

// === Errors ===

// Validation errors
#[error]
const EEmptyDescription: vector<u8> = b"Description must not be empty; attach nothing instead";

// Constraint errors
#[error]
const EMaxDescriptionLengthExceeded: vector<u8> = b"Description exceeds the maximum length";

// Reference errors
#[error]
const ENoDescription: vector<u8> = b"No description is attached to this release";

// === Structs ===

/// Dynamic-field key — one description per release.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a release's description is set or replaced. Carries the prose
/// itself so an indexer can write the row without re-reading the object.
public struct DescriptionSetEvent has copy, drop {
    release_id: ID,
    description: String,
}

/// Emitted when a release's description is removed.
public struct DescriptionClearedEvent has copy, drop {
    release_id: ID,
}

// === Public Functions ===

/// Sets (or replaces) what the release says about itself.
///
/// Stored exactly as given — whitespace, line breaks and case included. It is
/// the release's own words, and normalising them here would be the protocol
/// editing prose it has already declined to interpret.
public fun set_description(self: &mut Release, cap: &ReleaseAdminCap, description: String) {
    let bytes = description.as_bytes();
    assert!(!bytes.is_empty(), EEmptyDescription);
    assert!(bytes.length() <= MAX_DESCRIPTION_LENGTH, EMaxDescriptionLengthExceeded);

    let release_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow_mut(uid, ExtensionKey()) = description;
    } else {
        df::add(uid, ExtensionKey(), description);
    };
    emit(DescriptionSetEvent { release_id, description });
}

/// Removes the description, if any. Idempotent. Leaves the release having said
/// nothing about itself, which is where every release starts.
public fun clear_description(self: &mut Release, cap: &ReleaseAdminCap) {
    let release_id = object::id(self);
    // Cap-gate before the existence check, so a wrong cap aborts even when there
    // is nothing attached to remove.
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: String = df::remove(uid, ExtensionKey());
        emit(DescriptionClearedEvent { release_id });
    }
}

// === View Functions ===

/// Whether a description is attached to this release.
public fun has_description(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// What the release says about itself. Aborts if nothing is attached — absence
/// is a distinct state and must not collapse into an empty string.
public fun description(self: &Release): &String {
    assert!(has_description(self), ENoDescription);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields(e: &DescriptionSetEvent): (ID, String) { (e.release_id, e.description) }

#[test_only]
public fun cleared_event_release_id(e: &DescriptionClearedEvent): ID { e.release_id }
