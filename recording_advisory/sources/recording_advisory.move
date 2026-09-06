// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The parental advisory rating for a recording — whether its lyrics are
/// explicit — stored as a dynamic field on the recording's UID and written
/// through its cap-gated `uid_mut`.
///
/// This is its own package on purpose. Advisory ratings are set by a different
/// person, at a different time, for entirely different reasons than the other
/// facts about a recording, and the standard that governs them moves on its own
/// schedule. Bundling it into a general "recording metadata" object would mean
/// that revising the advisory standard drags every unrelated field through the
/// migration. Kept separate, a consumer implementing some future metadata
/// profile selects this extension or ignores it, and swapping it touches
/// nothing else.
///
/// The rating is deliberately not a boolean. Every distributor and storefront
/// distinguishes a *cleaned* edit — an explicit recording re-issued with the
/// offending content removed — from a recording that was never explicit at all.
/// They are merchandised differently and a boolean cannot express the
/// difference, so `Cleaned` is a first-class variant.
///
/// Attaching the extension IS the statement. There is no "attached but
/// undeclared" state: if a rating is present it has been asserted by the rights
/// holder, and a recording with nothing attached has simply said nothing.
module recording_advisory::recording_advisory;

use miso::recording::{Recording, RecordingAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No advisory rating is attached to this recording.
const ENoRating: u64 = 1;

// === Structs ===

/// Dynamic-field key — one advisory rating per recording.
public struct ExtensionKey() has copy, drop, store;

// === Enums ===

/// A recording's parental advisory rating.
public enum ExplicitRating has copy, drop, store {
    /// Contains explicit content.
    Explicit,
    /// Contains no explicit content, and never did.
    NotExplicit,
    /// An edited version of a recording that was originally explicit.
    Cleaned,
}

// === Events ===

/// Emitted when a rating is set or replaced. Advisory status changes what a
/// storefront may show and to whom, so an indexer needs to hear about it rather
/// than discover it on the next full re-read.
public struct AdvisoryRatingSetEvent has copy, drop {
    recording_id: ID,
    rating: ExplicitRating,
}

/// Emitted when a rating is removed.
public struct AdvisoryRatingUnsetEvent has copy, drop {
    recording_id: ID,
}

// === Public Functions ===

/// Contains explicit content.
public fun explicit(): ExplicitRating { ExplicitRating::Explicit }

/// Contains no explicit content, and never did.
public fun not_explicit(): ExplicitRating { ExplicitRating::NotExplicit }

/// An edited version of a recording that was originally explicit.
public fun cleaned(): ExplicitRating { ExplicitRating::Cleaned }

/// Sets (or replaces) the recording's advisory rating.
public fun set_rating<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    rating: ExplicitRating,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow_mut(uid, ExtensionKey()) = rating;
    } else {
        df::add(uid, ExtensionKey(), rating);
    };
    emit(AdvisoryRatingSetEvent { recording_id, rating });
}

/// Removes the rating, if any. Idempotent — the recording is left having said
/// nothing about its content, which is distinct from asserting `NotExplicit`.
public fun unset_rating<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: ExplicitRating = df::remove(uid, ExtensionKey());
        emit(AdvisoryRatingUnsetEvent { recording_id });
    }
}

// === View Functions ===

/// Whether an advisory rating is attached to this recording.
public fun has_rating<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's advisory rating. Aborts if none is attached — callers that
/// tolerate an unrated recording should check `has_rating` first, since absence
/// is a meaningful state and must not be silently read as `NotExplicit`.
public fun rating<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): ExplicitRating {
    assert!(has_rating(self), ENoRating);
    *df::borrow(self.uid(), ExtensionKey())
}

/// Whether the recording contains explicit content.
public fun is_explicit(self: &ExplicitRating): bool {
    match (self) { ExplicitRating::Explicit => true, _ => false }
}

/// Whether the recording contains no explicit content and never did.
public fun is_not_explicit(self: &ExplicitRating): bool {
    match (self) { ExplicitRating::NotExplicit => true, _ => false }
}

/// Whether the recording is an edited version of an originally explicit one.
public fun is_cleaned(self: &ExplicitRating): bool {
    match (self) { ExplicitRating::Cleaned => true, _ => false }
}

/// The rating's canonical name, for clients and indexers that need a stable
/// string rather than a Move value.
public fun name(self: &ExplicitRating): vector<u8> {
    match (self) {
        ExplicitRating::Explicit => b"Explicit",
        ExplicitRating::NotExplicit => b"NotExplicit",
        ExplicitRating::Cleaned => b"Cleaned",
    }
}

// === Test Functions ===

#[test_only]
public fun set_event_fields(e: &AdvisoryRatingSetEvent): (ID, ExplicitRating) {
    (e.recording_id, e.rating)
}

#[test_only]
public fun unset_event_recording_id(e: &AdvisoryRatingUnsetEvent): ID { e.recording_id }
