// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A pointer to a recording's master audio — nothing more.
///
/// The value is a bare `ori::data::WalrusBlob` reference. This extension makes no
/// claim about what the blob contains: not its codec, not its sample rate, not
/// its duration, not that it is even audio. The only assertion is that the
/// holder of the recording's admin cap says this blob is the master. Everything
/// else is client-side convention.
///
/// That thinness is the point. Miso's attested path — the Nautilus-verified
/// master flow (`audio_ingester` producing a `audio::Audio`), deferred —
/// carries channel count, bit depth, sample rate, sample count and a PCM digest,
/// and every one of those is backed by a Nautilus enclave signature over the
/// measured audio. Until that path is running, stating the same fields
/// *unverified* would dress an assertion up as a measurement. A pointer cannot
/// be mistaken for a measurement.
///
/// # This extension is a holdover
///
/// It exists to carry the catalogue until enclave ingestion is ready, and it is
/// meant to be removed rather than grown. When a recording's master is ingested
/// for real, attach the attested master via the ingester's master flow and call
/// `unset_master_reference` here. The two never need to coexist, and this package
/// deliberately holds nothing the attested path cannot restate.
///
/// Resist adding fields. Anything worth asserting about the audio is worth
/// attesting, and belongs in the ingested `Audio` rather than here.
module recording_master_reference::recording_master_reference;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use ori::data::WalrusBlob;
use sui::dynamic_field as df;
use sui::event::emit;
use sui::hash::blake2b256;

// === Errors ===

/// No master reference is attached to this recording.
const ENoMasterReference: u64 = 1;

// === Structs ===

/// Dynamic-field key — one master reference per recording.
///
/// Single, not keyed by format or digest: this is "the master" for a recording
/// during the holdover, and keeping it singular means removal is one call rather
/// than an enumeration.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted when a master reference is set or replaced. The primitive previous
/// and current snapshots let an indexer replay the transition without reading
/// the dynamic field.
public struct RecordingMasterReferenceSetEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    had_master_reference: bool,
    previous_blob_id: u256,
    previous_is_encrypted: bool,
    previous_sealed_dek_length: u64,
    previous_sealed_dek_digest: vector<u8>,
    blob_id: u256,
    is_encrypted: bool,
    sealed_dek_length: u64,
    sealed_dek_digest: vector<u8>,
}

/// Emitted when a master reference is removed — including on the migration to an
/// attested master, which is the expected reason.
public struct RecordingMasterReferenceClearedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    removed_blob_id: u256,
    removed_is_encrypted: bool,
    removed_sealed_dek_length: u64,
    removed_sealed_dek_digest: vector<u8>,
}

// === Public Functions ===

/// Sets (or replaces) the recording's master reference.
///
/// The reference is a standalone blob by type. Encrypted blobs are accepted —
/// a sealed master is the expected shape once access control lands, and the
/// reference is the same either way.
public fun set_master_reference<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    reference: WalrusBlob,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let uid = self.uid_mut(cap);
    let had_master_reference = df::exists(uid, ExtensionKey());
    let mut previous_blob_id = 0;
    let mut previous_is_encrypted = false;
    let mut previous_sealed_dek_length = 0;
    let mut previous_sealed_dek_digest = vector[];
    if (had_master_reference) {
        let previous = df::borrow(uid, ExtensionKey());
        (
            previous_blob_id,
            previous_is_encrypted,
            previous_sealed_dek_length,
            previous_sealed_dek_digest,
        ) = snapshot(previous);
        *df::borrow_mut(uid, ExtensionKey()) = reference;
    } else {
        df::add(uid, ExtensionKey(), reference);
    };
    let current = df::borrow(uid, ExtensionKey());
    let (blob_id, is_encrypted, sealed_dek_length, sealed_dek_digest) = snapshot(current);
    emit(RecordingMasterReferenceSetEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        had_master_reference,
        previous_blob_id,
        previous_is_encrypted,
        previous_sealed_dek_length,
        previous_sealed_dek_digest,
        blob_id,
        is_encrypted,
        sealed_dek_length,
        sealed_dek_digest,
    });
}

/// Removes the master reference, if any. Idempotent.
///
/// The intended use is migration: once an attested master is attached via the
/// Nautilus-verified master flow (deferred), this reference has nothing left to
/// say and should go.
public fun unset_master_reference<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let removed = df::remove(uid, ExtensionKey());
        let (removed_blob_id, removed_is_encrypted, removed_sealed_dek_length,
            removed_sealed_dek_digest) = snapshot(&removed);
        emit(RecordingMasterReferenceClearedEvent<RecordingShare, CompositionShare> {
            recording_id,
            composition_id,
            removed_blob_id,
            removed_is_encrypted,
            removed_sealed_dek_length,
            removed_sealed_dek_digest,
        });
    }
}

// === View Functions ===

/// Whether a master reference is attached to this recording.
public fun has_master_reference<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The recording's master reference. Aborts if none is attached.
public fun master_reference<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &WalrusBlob {
    assert!(has_master_reference(self), ENoMasterReference);
    df::borrow(self.uid(), ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun set_event_fields<RecordingShare, CompositionShare>(
    e: &RecordingMasterReferenceSetEvent<RecordingShare, CompositionShare>,
): (
    address,
    address,
    bool,
    u256,
    bool,
    u64,
    vector<u8>,
    u256,
    bool,
    u64,
    vector<u8>,
) {
    (
        e.recording_id,
        e.composition_id,
        e.had_master_reference,
        e.previous_blob_id,
        e.previous_is_encrypted,
        e.previous_sealed_dek_length,
        e.previous_sealed_dek_digest,
        e.blob_id,
        e.is_encrypted,
        e.sealed_dek_length,
        e.sealed_dek_digest,
    )
}

#[test_only]
public fun cleared_event_fields<RecordingShare, CompositionShare>(
    e: &RecordingMasterReferenceClearedEvent<RecordingShare, CompositionShare>,
): (address, address, u256, bool, u64, vector<u8>) {
    (
        e.recording_id,
        e.composition_id,
        e.removed_blob_id,
        e.removed_is_encrypted,
        e.removed_sealed_dek_length,
        e.removed_sealed_dek_digest,
    )
}

#[test_only]
public fun unset_event_recording_id<RecordingShare, CompositionShare>(
    e: &RecordingMasterReferenceClearedEvent<RecordingShare, CompositionShare>,
): ID { e.recording_id.to_id() }

// === Private Functions ===

/// Projects a blob reference into bounded event metadata without exposing the
/// sealed DEK itself. Plaintext uses the canonical zero/empty representation.
fun snapshot(reference: &WalrusBlob): (u256, bool, u64, vector<u8>) {
    if (reference.blob_confidentiality().is_encrypted()) {
        let sealed_dek = reference.blob_confidentiality().sealed_dek();
        (
            reference.blob_id(),
            true,
            sealed_dek.length() as u64,
            blake2b256(sealed_dek),
        )
    } else {
        (reference.blob_id(), false, 0, vector[])
    }
}
