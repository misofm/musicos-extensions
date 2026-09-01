// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-track pointers from a Release to public delivery descriptors.
///
/// The descriptor is a standalone, plaintext Walrus blob. Its contents describe
/// the separately encrypted delivery assets; the outer reference itself must not
/// carry an Ori sealed DEK. One optional slot is allocated for each immutable
/// release track, preserving tracklist alignment for the lifetime of the release.
module release_mix_reference::release_mix_reference;

use miso::release::{Release, ReleaseAdminCap};
use ori::walrus_data::WalrusData;
use per_track::per_track::{Self, PerTrack};
use sui::dynamic_field as df;
use sui::event::emit;

// === Errors ===

const ETrackIndexOutOfBounds: u64 = 1;
const EMixReferenceAlreadyAttached: u64 = 2;
const EMixReferenceMissing: u64 = 3;
const EEncryptedDescriptorReference: u64 = 4;

// === Structs ===

/// Dynamic-field key — one parallel array of optional references per Release.
public struct ExtensionKey() has copy, drop, store;

// === Events ===

/// Emitted only for the first attachment to a track slot.
public struct MixReferenceAttachedEvent has copy, drop {
    release_id: ID,
    track_index: u64,
    recording_id: ID,
    descriptor_reference: WalrusData,
}

/// Emitted only when an existing track-slot reference is explicitly replaced.
public struct MixReferenceReplacedEvent has copy, drop {
    release_id: ID,
    track_index: u64,
    recording_id: ID,
    descriptor_reference: WalrusData,
}

// === Public Functions ===

/// Attaches a descriptor to an empty track slot.
///
/// Aborts if the track is out of range or already has a reference. This function
/// never silently replaces an existing delivery descriptor.
public fun attach_mix_reference(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    track_index: u64,
    descriptor_reference: WalrusData,
) {
    self.authorize(cap);
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    assert_plaintext_blob(&descriptor_reference);

    let release_id = object::id(self);
    let recording_id = self.tracks()[track_index].recording_id();
    if (!df::exists(self.uid(), ExtensionKey())) {
        let references = per_track::filled(self, option::none<WalrusData>());
        df::add(self.uid_mut(cap), ExtensionKey(), references);
    };

    let slot = df::borrow_mut<ExtensionKey, PerTrack<Option<WalrusData>>>(
        self.uid_mut(cap),
        ExtensionKey(),
    ).borrow_mut(track_index);
    assert!(slot.is_none(), EMixReferenceAlreadyAttached);
    *slot = option::some(descriptor_reference);

    emit(MixReferenceAttachedEvent {
        release_id,
        track_index,
        recording_id,
        descriptor_reference,
    });
}

/// Replaces the descriptor in an occupied track slot.
///
/// Aborts if the extension or selected slot is absent. Callers must choose this
/// explicit overwrite operation rather than relying on attach-upsert behavior.
public fun replace_mix_reference(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    track_index: u64,
    descriptor_reference: WalrusData,
) {
    self.authorize(cap);
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    assert_plaintext_blob(&descriptor_reference);
    assert!(df::exists(self.uid(), ExtensionKey()), EMixReferenceMissing);

    let release_id = object::id(self);
    let recording_id = self.tracks()[track_index].recording_id();
    let slot = df::borrow_mut<ExtensionKey, PerTrack<Option<WalrusData>>>(
        self.uid_mut(cap),
        ExtensionKey(),
    ).borrow_mut(track_index);
    assert!(slot.is_some(), EMixReferenceMissing);
    *slot = option::some(descriptor_reference);

    emit(MixReferenceReplacedEvent {
        release_id,
        track_index,
        recording_id,
        descriptor_reference,
    });
}

// === View Functions ===

/// Whether a descriptor reference is attached to the selected release track.
public fun has_mix_reference(self: &Release, track_index: u64): bool {
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    if (!df::exists(self.uid(), ExtensionKey())) return false;
    df::borrow<ExtensionKey, PerTrack<Option<WalrusData>>>(
        self.uid(),
        ExtensionKey(),
    ).borrow(track_index).is_some()
}

/// The selected track's descriptor reference. Aborts when the slot is empty.
public fun mix_reference(self: &Release, track_index: u64): &WalrusData {
    assert!(track_index < self.tracks().length(), ETrackIndexOutOfBounds);
    assert!(df::exists(self.uid(), ExtensionKey()), EMixReferenceMissing);
    let slot = df::borrow<ExtensionKey, PerTrack<Option<WalrusData>>>(
        self.uid(),
        ExtensionKey(),
    ).borrow(track_index);
    assert!(slot.is_some(), EMixReferenceMissing);
    slot.borrow()
}

fun assert_plaintext_blob(reference: &WalrusData) {
    reference.assert_is_blob();
    assert!(!reference.is_encrypted(), EEncryptedDescriptorReference);
}

// === Test Functions ===

#[test_only]
public fun attached_event_fields(
    event: &MixReferenceAttachedEvent,
): (ID, u64, ID, WalrusData) {
    (
        event.release_id,
        event.track_index,
        event.recording_id,
        event.descriptor_reference,
    )
}

#[test_only]
public fun replaced_event_fields(
    event: &MixReferenceReplacedEvent,
): (ID, u64, ID, WalrusData) {
    (
        event.release_id,
        event.track_index,
        event.recording_id,
        event.descriptor_reference,
    )
}
