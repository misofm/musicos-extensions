// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_mix_reference::release_mix_reference_tests;

use miso::release::{Release, ReleaseAdminCap};
use miso::{test_helpers, track};
use ori::walrus_data;
use release_mix_reference::release_mix_reference as mix_ref;
use std::unit_test::{assert_eq, destroy};
use sui::event;

const ENotBlob: u64 = 0;
const ETrackIndexOutOfBounds: u64 = 1;
const EMixReferenceAlreadyAttached: u64 = 2;
const EMixReferenceMissing: u64 = 3;
const EEncryptedDescriptorReference: u64 = 4;

fun new_release(ctx: &mut TxContext): (Release, ReleaseAdminCap, ID, ID) {
    let release_id = test_helpers::fake_id(ctx);
    let composition_id = test_helpers::fake_id(ctx);
    let recording_0 = test_helpers::fake_id(ctx);
    let recording_1 = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(composition_id, recording_0, release_id, 5000),
        track::new_for_testing(composition_id, recording_1, release_id, 5000),
    ];
    let (release, cap) = miso::release::new_for_testing("Mixes", tracks, ctx);
    (release, cap, recording_0, recording_1)
}

#[test]
fun attach_then_explicit_replace_updates_the_selected_slot() {
    let ctx = &mut tx_context::dummy();
    let (mut release, cap, _, recording_1) = new_release(ctx);

    assert!(!mix_ref::has_mix_reference(&release, 1));
    mix_ref::attach_mix_reference(&mut release, &cap, 1, walrus_data::new_blob(11));
    assert!(mix_ref::has_mix_reference(&release, 1));
    assert_eq!(mix_ref::mix_reference(&release, 1).blob_id(), 11);

    mix_ref::replace_mix_reference(&mut release, &cap, 1, walrus_data::new_blob(22));
    assert_eq!(mix_ref::mix_reference(&release, 1).blob_id(), 22);

    let attached = event::events_by_type<mix_ref::MixReferenceAttachedEvent>();
    let replaced = event::events_by_type<mix_ref::MixReferenceReplacedEvent>();
    assert_eq!(attached.length(), 1);
    assert_eq!(replaced.length(), 1);

    let (release_id, track_index, event_recording_id, descriptor) =
        mix_ref::attached_event_fields(&attached[0]);
    assert_eq!(release_id, object::id(&release));
    assert_eq!(track_index, 1);
    assert_eq!(event_recording_id, recording_1);
    assert_eq!(descriptor.blob_id(), 11);

    let (release_id, track_index, event_recording_id, descriptor) =
        mix_ref::replaced_event_fields(&replaced[0]);
    assert_eq!(release_id, object::id(&release));
    assert_eq!(track_index, 1);
    assert_eq!(event_recording_id, recording_1);
    assert_eq!(descriptor.blob_id(), 22);

    destroy(release);
    destroy(cap);
}

#[test, expected_failure(abort_code = EMixReferenceAlreadyAttached, location = mix_ref)]
fun attach_rejects_an_occupied_slot() {
    let ctx = &mut tx_context::dummy();
    let (mut release, cap, _, _) = new_release(ctx);
    mix_ref::attach_mix_reference(&mut release, &cap, 0, walrus_data::new_blob(1));
    mix_ref::attach_mix_reference(&mut release, &cap, 0, walrus_data::new_blob(2));
    abort
}

#[test, expected_failure(abort_code = EMixReferenceMissing, location = mix_ref)]
fun replace_rejects_an_absent_extension() {
    let ctx = &mut tx_context::dummy();
    let (mut release, cap, _, _) = new_release(ctx);
    mix_ref::replace_mix_reference(&mut release, &cap, 0, walrus_data::new_blob(1));
    abort
}

#[test, expected_failure(abort_code = EMixReferenceMissing, location = mix_ref)]
fun replace_rejects_an_empty_slot() {
    let ctx = &mut tx_context::dummy();
    let (mut release, cap, _, _) = new_release(ctx);
    mix_ref::attach_mix_reference(&mut release, &cap, 0, walrus_data::new_blob(1));
    mix_ref::replace_mix_reference(&mut release, &cap, 1, walrus_data::new_blob(2));
    abort
}

#[test, expected_failure(abort_code = ETrackIndexOutOfBounds, location = mix_ref)]
fun attach_checks_the_release_track_bound() {
    let ctx = &mut tx_context::dummy();
    let (mut release, cap, _, _) = new_release(ctx);
    mix_ref::attach_mix_reference(&mut release, &cap, 2, walrus_data::new_blob(1));
    abort
}

#[test, expected_failure(abort_code = ETrackIndexOutOfBounds, location = mix_ref)]
fun replace_checks_the_release_track_bound() {
    let ctx = &mut tx_context::dummy();
    let (mut release, cap, _, _) = new_release(ctx);
    mix_ref::replace_mix_reference(&mut release, &cap, 2, walrus_data::new_blob(1));
    abort
}

#[test, expected_failure(abort_code = ETrackIndexOutOfBounds, location = mix_ref)]
fun has_mix_reference_checks_the_release_track_bound() {
    let ctx = &mut tx_context::dummy();
    let (release, _cap, _, _) = new_release(ctx);
    mix_ref::has_mix_reference(&release, 2);
    abort
}

#[test, expected_failure(abort_code = ETrackIndexOutOfBounds, location = mix_ref)]
fun mix_reference_checks_the_release_track_bound() {
    let ctx = &mut tx_context::dummy();
    let (release, _cap, _, _) = new_release(ctx);
    mix_ref::mix_reference(&release, 2);
    abort
}

#[test, expected_failure(abort_code = EMixReferenceMissing, location = mix_ref)]
fun mix_reference_rejects_an_absent_extension() {
    let ctx = &mut tx_context::dummy();
    let (release, _cap, _, _) = new_release(ctx);
    mix_ref::mix_reference(&release, 0);
    abort
}

#[test, expected_failure(abort_code = EMixReferenceMissing, location = mix_ref)]
fun mix_reference_rejects_an_empty_slot() {
    let ctx = &mut tx_context::dummy();
    let (mut release, cap, _, _) = new_release(ctx);
    mix_ref::attach_mix_reference(&mut release, &cap, 0, walrus_data::new_blob(1));
    mix_ref::mix_reference(&release, 1);
    abort
}

#[test, expected_failure(abort_code = ENotBlob, location = ori::walrus_data)]
fun attach_rejects_a_quilt_patch() {
    let ctx = &mut tx_context::dummy();
    let (mut release, cap, _, _) = new_release(ctx);
    mix_ref::attach_mix_reference(
        &mut release,
        &cap,
        0,
        walrus_data::new_quilt_patch(1, 1, 0, 1),
    );
    abort
}

#[test, expected_failure(abort_code = EEncryptedDescriptorReference, location = mix_ref)]
fun attach_rejects_an_encrypted_outer_reference() {
    let ctx = &mut tx_context::dummy();
    let (mut release, cap, _, _) = new_release(ctx);
    mix_ref::attach_mix_reference(
        &mut release,
        &cap,
        0,
        walrus_data::new_encrypted_blob(1, b"sealed-key"),
    );
    abort
}

#[test, expected_failure(abort_code = miso::release::EUnauthorized, location = miso::release)]
fun attach_rejects_another_releases_admin_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut release, _release_cap, _, _) = new_release(ctx);
    let (_other_release, other_cap, _, _) = new_release(ctx);
    mix_ref::attach_mix_reference(
        &mut release,
        &other_cap,
        0,
        walrus_data::new_blob(1),
    );
    abort
}

#[test, expected_failure(abort_code = miso::release::EUnauthorized, location = miso::release)]
fun replace_rejects_another_releases_admin_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut release, release_cap, _, _) = new_release(ctx);
    let (_other_release, other_cap, _, _) = new_release(ctx);
    mix_ref::attach_mix_reference(&mut release, &release_cap, 0, walrus_data::new_blob(1));
    mix_ref::replace_mix_reference(
        &mut release,
        &other_cap,
        0,
        walrus_data::new_blob(2),
    );
    abort
}
