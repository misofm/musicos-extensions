// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A recording administrator's pointer to the Miso Engine session for a
/// recording: the canonical Session V1 document plus every stem it plays,
/// stored as one value under a dynamic field on the recording's UID and
/// written through its cap-gated `uid_mut`. Reads are permissionless.
///
/// The Session V1 document references each source by the SHA-256 digest of
/// its canonical PCM (engine `STEM_IDENTITY_V1`) and carries no locator;
/// Walrus serves blobs by blob ID. `EngineSession` therefore pairs the
/// session blob ID with one `Stem` per source — that digest and the blob ID
/// holding its FLAC delivery object — so a client reads one value and can
/// resolve every source the session names. Stems are sorted by digest and
/// unique, so a session has exactly one canonical form; session and stems are
/// replaced together because adding a source changes the document.
///
/// Every reference is a bare blob ID: the extension asserts only which blobs
/// the administrator chose, not storage availability, document validity, or
/// that a stem decodes to its digest. Publication tooling checks those first.
module recording_engine_session::recording_engine_session;

use musicos::recording::{Recording, RecordingAdminCap};
use sui::dynamic_field as df;
use sui::event::emit;

// === Constants ===

/// Byte length of a SHA-256 digest.
const DIGEST_LENGTH: u64 = 32;

// === Errors ===

/// No Miso Engine session is attached to this recording.
const ENoEngineSession: u64 = 1;
/// A stem digest is not exactly 32 bytes.
const EInvalidStemDigest: u64 = 2;
/// Stems are not in strictly increasing digest order.
const EUnsortedStems: u64 = 3;

// === Structs ===

/// Dynamic-field key — one Miso Engine session per recording.
public struct ExtensionKey() has copy, drop, store;

/// One stem the session plays: its identity and where its bytes live.
public struct Stem has copy, drop, store {
    /// SHA-256 digest of the stem's canonical PCM (engine `STEM_IDENTITY_V1`),
    /// 32 raw bytes: the source's `content` identity in the Session V1
    /// document without its `sha256:` prefix.
    digest: vector<u8>,
    /// Standalone Walrus blob ID holding the stem's FLAC delivery object.
    blob_id: u256,
}

/// A Miso Engine session: the canonical Session V1 document and its stems.
public struct EngineSession has copy, drop, store {
    /// Standalone Walrus blob ID holding the canonical Session V1 JSON
    /// document, byte for byte as the engine emitted it.
    blob_id: u256,
    /// Every stem the document's sources reference, sorted by digest, unique.
    stems: vector<Stem>,
}

// === Events ===

/// Emitted when the session is set to a value it did not already hold.
/// Carries the session document's blob ID; the stem list is unbounded and is
/// read from the recording, so a set event with an unchanged blob ID means
/// the stems changed.
public struct RecordingEngineSessionSetEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    blob_id: u256,
}

/// Emitted when an attached session is removed.
public struct RecordingEngineSessionClearedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
}

// === Public Functions ===

/// Creates a stem reference. Aborts `EInvalidStemDigest` unless `digest` is
/// exactly 32 bytes.
public fun new_stem(digest: vector<u8>, blob_id: u256): Stem {
    assert!(digest.length() == DIGEST_LENGTH, EInvalidStemDigest);
    Stem { digest, blob_id }
}

/// Creates a session from a session blob ID and its stems. Aborts
/// `EUnsortedStems` unless `stems` is in strictly increasing digest order,
/// which also forbids duplicates. An empty vector is valid: a Session V1
/// document may declare no sources.
public fun new(blob_id: u256, stems: vector<Stem>): EngineSession {
    let mut i = 1;
    while (i < stems.length()) {
        assert!(digest_lt(&stems[i - 1].digest, &stems[i].digest), EUnsortedStems);
        i = i + 1;
    };
    EngineSession { blob_id, stems }
}

/// Sets (or replaces) the recording's session. Setting the value already
/// held neither writes nor emits.
public fun set_engine_session<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    session: EngineSession,
) {
    let recording_id = object::id(self).to_address();
    let blob_id = session.blob_id;
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let current: &mut EngineSession = df::borrow_mut(uid, ExtensionKey());
        if (*current == session) return;
        *current = session;
    } else {
        df::add(uid, ExtensionKey(), session);
    };
    emit(RecordingEngineSessionSetEvent<RecordingShare> { recording_id, blob_id });
}

/// Removes the recording's session, if any. Silent when nothing is attached.
public fun clear_engine_session<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: EngineSession = df::remove(uid, ExtensionKey());
        emit(RecordingEngineSessionClearedEvent<RecordingShare> { recording_id });
    }
}

// === View Functions ===

/// Whether a Miso Engine session is attached to the recording.
public fun has_engine_session<RecordingShare>(self: &Recording<RecordingShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's session. Aborts `ENoEngineSession` when none is attached.
public fun engine_session<RecordingShare>(self: &Recording<RecordingShare>): &EngineSession {
    assert!(has_engine_session(self), ENoEngineSession);
    df::borrow(self.uid(), ExtensionKey())
}

/// The Walrus blob ID holding the Session V1 document.
public fun blob_id(self: &EngineSession): u256 {
    self.blob_id
}

/// The session's stems, sorted by digest.
public fun stems(self: &EngineSession): &vector<Stem> {
    &self.stems
}

/// A stem's 32-byte canonical PCM digest.
public fun stem_digest(self: &Stem): &vector<u8> {
    &self.digest
}

/// The Walrus blob ID holding a stem's FLAC delivery object.
public fun stem_blob_id(self: &Stem): u256 {
    self.blob_id
}

// === Private Functions ===

/// Strict lexicographic byte order over two 32-byte digests.
fun digest_lt(a: &vector<u8>, b: &vector<u8>): bool {
    let mut i = 0;
    while (i < DIGEST_LENGTH) {
        if (a[i] != b[i]) return a[i] < b[i];
        i = i + 1;
    };
    false
}

// === Test Functions ===

#[test_only]
public fun set_event_fields<RecordingShare>(
    e: &RecordingEngineSessionSetEvent<RecordingShare>,
): (address, u256) {
    (e.recording_id, e.blob_id)
}

#[test_only]
public fun cleared_event_fields<RecordingShare>(
    e: &RecordingEngineSessionClearedEvent<RecordingShare>,
): address {
    e.recording_id
}
