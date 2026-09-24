// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The parental advisory for a recording — whether its content is explicit —
/// stored as a dynamic field on the recording's UID and written through its
/// cap-gated `uid_mut`.
///
/// One concern, one package: the advisory is asserted by a different person,
/// at a different time, under a standard that moves on its own schedule, so it
/// is attached and replaced independently of every other fact about the
/// recording.
///
/// The value is not a boolean. A `Cleaned` edit — an explicit recording
/// re-issued with the offending content removed — is merchandised differently
/// from a recording that was never explicit, so it is a first-class variant.
///
/// Attaching the extension is the statement: a present value has been asserted
/// by the rights holder, and a recording with nothing attached has said
/// nothing. Absence is therefore distinct from `NotExplicit`.
module recording_advisory::recording_advisory;

use musicos::recording::{Recording, RecordingAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

/// No advisory is attached to this recording.
const ENoAdvisory: u64 = 1;

// === Structs ===

/// Dynamic-field key — one `Advisory` per recording.
public struct ExtensionKey() has copy, drop, store;

// === Enums ===

/// A recording's parental advisory.
public enum Advisory has copy, drop, store {
    /// Contains explicit content.
    Explicit,
    /// Contains no explicit content, and never did.
    NotExplicit,
    /// An edited version of a recording that was originally explicit.
    Cleaned,
}

// === Events ===

/// Emitted when the advisory is set to a value it did not already hold.
public struct RecordingAdvisorySetEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    advisory: Advisory,
}

/// Emitted when an attached advisory is removed.
public struct RecordingAdvisoryClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

// === Public Functions ===

/// Contains explicit content.
public fun explicit(): Advisory { Advisory::Explicit }

/// Contains no explicit content, and never did.
public fun not_explicit(): Advisory { Advisory::NotExplicit }

/// An edited version of a recording that was originally explicit.
public fun cleaned(): Advisory { Advisory::Cleaned }

/// Sets (or replaces) the recording's advisory. Setting the value already
/// held neither writes nor emits.
public fun set_advisory<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    advisory: Advisory,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let current: &mut Advisory = df::borrow_mut(uid, ExtensionKey());
        if (*current == advisory) return;
        *current = advisory;
    } else {
        df::add(uid, ExtensionKey(), advisory);
    };
    emit(RecordingAdvisorySetEvent<RecordingShare> { recording_id, advisory });
}

/// Removes the advisory, if any. Silent when nothing is attached. Leaves the
/// recording having said nothing, which is distinct from `NotExplicit`.
public fun clear_advisory<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: Advisory = df::remove(uid, ExtensionKey());
        emit(RecordingAdvisoryClearedEvent<RecordingShare> { recording_id });
    }
}

// === View Functions ===

/// Whether an advisory is attached to this recording.
public fun has_advisory<RecordingShare>(self: &Recording<RecordingShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's advisory. Aborts `ENoAdvisory` when none is attached;
/// absence must not be read as `NotExplicit`.
public fun advisory<RecordingShare>(self: &Recording<RecordingShare>): Advisory {
    assert!(has_advisory(self), ENoAdvisory);
    *df::borrow(self.uid(), ExtensionKey())
}

/// Whether the advisory is `Explicit`.
public fun is_explicit(self: &Advisory): bool {
    match (self) { Advisory::Explicit => true, _ => false }
}

/// Whether the advisory is `NotExplicit`.
public fun is_not_explicit(self: &Advisory): bool {
    match (self) { Advisory::NotExplicit => true, _ => false }
}

/// Whether the advisory is `Cleaned`.
public fun is_cleaned(self: &Advisory): bool {
    match (self) { Advisory::Cleaned => true, _ => false }
}

// === Test Functions ===

#[test_only]
public fun set_event_fields<RecordingShare>(
    e: &RecordingAdvisorySetEvent<RecordingShare>,
): (address, Advisory) {
    (e.recording_id, e.advisory)
}

#[test_only]
public fun cleared_event_fields<RecordingShare>(
    e: &RecordingAdvisoryClearedEvent<RecordingShare>,
): address {
    e.recording_id
}
