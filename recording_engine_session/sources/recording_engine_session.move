// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A recording administrator's pointer to the Miso Engine session for a
/// recording: the canonical Session V1 document plus every stem it plays.
///
/// The Session V1 document references each source by the SHA-256 digest of its
/// canonical PCM (engine `STEM_IDENTITY_V1`) and carries no locator. Walrus
/// serves blobs by blob ID. `EngineSession` therefore records, next to the
/// session blob, one `Stem` per source pairing that digest with the standalone
/// Walrus blob holding its FLAC delivery object. A client reads one value and
/// can resolve every source the session names.
///
/// Session and stems are one value and are replaced together: adding a source
/// changes the document, so a new document and a new stem set land in a single
/// `set_engine_session`. Stems are sorted by digest and unique, so the value has
/// exactly one canonical form for a given session.
///
/// Every referenced blob is unencrypted; the constructors reject encrypted
/// confidentiality. This extension asserts only which blobs the recording
/// administrator chose. It does not prove storage availability, document
/// validity, that a stem decodes to its digest, or that the digests match the
/// document's sources. Publication tooling must perform those checks before
/// attachment.
module recording_engine_session::recording_engine_session;

use miso::recording::{Recording, RecordingAdminCap};
use ori::data::WalrusBlob;
use sui::dynamic_field as df;
use sui::event::emit;

// === Constants ===

/// Byte length of a SHA-256 digest.
const DIGEST_LENGTH: u64 = 32;

// === Errors ===

/// The supplied Miso Engine session file is encrypted.
#[error]
const EEncryptedEngineSession: vector<u8> =
    b"A Miso Engine session file must be unencrypted";

/// The supplied stem blob is encrypted.
#[error]
const EEncryptedStem: vector<u8> = b"A stem blob must be unencrypted";

/// A stem digest is not exactly 32 bytes.
#[error]
const EInvalidStemDigest: vector<u8> =
    b"A stem digest must be a 32-byte SHA-256 digest";

/// Stems are not in strictly increasing digest order.
#[error]
const EUnsortedStems: vector<u8> =
    b"Stems must be sorted by digest and contain no duplicates";

/// No Miso Engine session is attached to this recording.
#[error]
const ENoEngineSession: vector<u8> =
    b"No Miso Engine session is attached to this Recording";

// === Structs ===

/// Dynamic-field key — one Miso Engine session per recording.
public struct ExtensionKey() has copy, drop, store;

/// One stem the session plays: its identity and where its bytes live.
public struct Stem has copy, drop, store {
    /// SHA-256 digest of the stem's canonical PCM serialization (engine
    /// `STEM_IDENTITY_V1`), 32 raw bytes in natural order. Equals the source's
    /// `content` identity in the Session V1 document without its `sha256:`
    /// prefix.
    digest: vector<u8>,
    /// Unencrypted standalone Walrus blob holding the stem's FLAC delivery
    /// object, which decodes to the PCM the digest commits to.
    data: WalrusBlob,
}

/// A Miso Engine session: the canonical Session V1 document and its stems.
public struct EngineSession has copy, drop, store {
    /// Unencrypted standalone Walrus blob holding the canonical Session V1
    /// JSON document, byte for byte as the engine emitted it.
    data: WalrusBlob,
    /// Every stem the document's sources reference, sorted by digest, unique.
    stems: vector<Stem>,
}

// === Events ===

/// Emitted when a Miso Engine session is set or replaced.
public struct EngineSessionSetEvent has copy, drop {
    recording_id: ID,
    session: EngineSession,
}

/// Emitted when a Miso Engine session is removed.
public struct EngineSessionUnsetEvent has copy, drop {
    recording_id: ID,
}

// === Public Functions ===

/// Creates a stem reference from a 32-byte PCM digest and an unencrypted blob.
public fun new_stem(digest: vector<u8>, data: WalrusBlob): Stem {
    assert!(digest.length() == DIGEST_LENGTH, EInvalidStemDigest);
    assert!(!data.blob_confidentiality().is_encrypted(), EEncryptedStem);
    Stem { digest, data }
}

/// Creates an engine session from an unencrypted session blob and its stems.
///
/// `stems` must be in strictly increasing digest order, which also forbids
/// duplicates. An empty vector is valid: a Session V1 document may declare no
/// sources.
public fun new(data: WalrusBlob, stems: vector<Stem>): EngineSession {
    assert!(!data.blob_confidentiality().is_encrypted(), EEncryptedEngineSession);
    let mut i = 1;
    while (i < stems.length()) {
        assert!(digest_lt(&stems[i - 1].digest, &stems[i].digest), EUnsortedStems);
        i = i + 1;
    };
    EngineSession { data, stems }
}

/// Returns the unencrypted Walrus blob containing the Session V1 document.
public fun data(self: &EngineSession): &WalrusBlob {
    &self.data
}

/// Returns the session's stems, sorted by digest.
public fun stems(self: &EngineSession): &vector<Stem> {
    &self.stems
}

/// Returns a stem's 32-byte canonical PCM digest.
public fun stem_digest(self: &Stem): &vector<u8> {
    &self.digest
}

/// Returns the unencrypted Walrus blob holding a stem's FLAC delivery object.
public fun stem_data(self: &Stem): &WalrusBlob {
    &self.data
}

/// Sets or replaces the recording's Miso Engine session.
public fun set_engine_session<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    session: EngineSession,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow_mut(uid, ExtensionKey()) = session;
    } else {
        df::add(uid, ExtensionKey(), session);
    };
    emit(EngineSessionSetEvent { recording_id, session });
}

/// Removes the recording's Miso Engine session, if present. Idempotent.
public fun unset_engine_session<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: EngineSession = df::remove(uid, ExtensionKey());
        emit(EngineSessionUnsetEvent { recording_id });
    }
}

// === View Functions ===

/// Whether a Miso Engine session is attached to the recording.
public fun has_engine_session<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's Miso Engine session. Aborts when none is attached.
public fun engine_session<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &EngineSession {
    assert!(has_engine_session(self), ENoEngineSession);
    df::borrow(self.uid(), ExtensionKey())
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
public fun set_event_fields(e: &EngineSessionSetEvent): (ID, EngineSession) {
    (e.recording_id, e.session)
}

#[test_only]
public fun unset_event_recording_id(e: &EngineSessionUnsetEvent): ID {
    e.recording_id
}
