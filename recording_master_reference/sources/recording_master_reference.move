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
/// master flow (`audio_ingester` producing a `miso_audio::Audio`), deferred —
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

use musicos::recording::{Recording, RecordingAdminCap};
use ori::data::WalrusBlob;
use sui::dynamic_field as df;
use sui::event::emit;

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

/// Emitted when a master reference is set or replaced, carrying the reference
/// itself. What is playable for a recording changes when this does, so an
/// indexer updates its row straight from the event rather than re-reading the
/// object on its next sweep.
public struct MasterReferenceSetEvent has copy, drop {
    recording_id: ID,
    reference: WalrusBlob,
}

/// Emitted when a master reference is removed — including on the migration to an
/// attested master, which is the expected reason.
public struct MasterReferenceUnsetEvent has copy, drop {
    recording_id: ID,
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
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        *df::borrow_mut(uid, ExtensionKey()) = reference;
    } else {
        df::add(uid, ExtensionKey(), reference);
    };
    emit(MasterReferenceSetEvent { recording_id, reference });
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
    let recording_id = object::id(self);
    let uid = self.uid_mut(cap);
    if (df::exists(uid, ExtensionKey())) {
        let _: WalrusBlob = df::remove(uid, ExtensionKey());
        emit(MasterReferenceUnsetEvent { recording_id });
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
public fun set_event_fields(e: &MasterReferenceSetEvent): (ID, WalrusBlob) {
    (e.recording_id, e.reference)
}

#[test_only]
public fun unset_event_recording_id(e: &MasterReferenceUnsetEvent): ID { e.recording_id }
