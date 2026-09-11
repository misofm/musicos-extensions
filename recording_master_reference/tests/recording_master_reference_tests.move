// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Single-transaction unit tests against a bare (never-published, never-shared)
/// `Recording`. None of these exercise ownership mechanics — the recording is
/// created and mutated in one transaction and never crosses a shared-object
/// boundary — so plain `tx_context::dummy()` mechanics add nothing that
/// `sui::test_scenario` would strengthen. The production shape (a published,
/// shared `Recording` operated on across transaction boundaries by distinct
/// senders) is covered separately in `recording_master_reference_e2e_tests`.
#[test_only]
module recording_master_reference::recording_master_reference_tests;

use musicos::recording;
use musicos::test_helpers;
use ori::{confidentiality, data};
use recording_master_reference::recording_master_reference as mref;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

// A recording's `RecordingShare` type uniquely identifies it, so
// `RecordingAdminCap<RecordingShare>` is bound to its recording by type and
// `recording::uid_mut` performs no runtime check. An incompatible cap type
// fails compilation; a different value with the same `RecordingShare` type is
// accepted because the cap value is ignored.
public struct REC {}
public struct COMP {}
public struct OTHER_REC {}
public struct OTHER_COMP {}

const MAX_U256: u256 =
    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
const LARGE_DEK_LENGTH: u64 = 256_001;

fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(test_helpers::fake_id(ctx), ctx)
}

fun sealed_dek_digest(): vector<u8> {
    x"2e2948bc873e96c254dd7ae8446b802908957fb713129cb726b700fa07434b80"
}

fun large_dek_digest(): vector<u8> {
    x"9e10d156c8054fdb1b37250e3c192aedcaa4182d4ecba5f9d72d0b2aea02cc6e"
}

fun assert_view_matches_projection(
    rec: &recording::Recording<REC, COMP>,
    projected_exists: bool,
    projected_blob_id: u256,
    projected_is_encrypted: bool,
    projected_sealed_dek_length: u64,
    projected_sealed_dek_digest: &vector<u8>,
) {
    assert_eq!(mref::has_master_reference(rec), projected_exists);
    if (projected_exists) {
        let reference = mref::master_reference(rec);
        assert_eq!(reference.blob_id(), projected_blob_id);
        assert_eq!(
            reference.blob_confidentiality().is_encrypted(),
            projected_is_encrypted,
        );
        if (projected_is_encrypted) {
            let sealed_dek = reference.blob_confidentiality().sealed_dek();
            assert_eq!(sealed_dek.length() as u64, projected_sealed_dek_length);
            assert_eq!(sui::hash::blake2b256(sealed_dek), *projected_sealed_dek_digest);
        } else {
            assert_eq!(projected_sealed_dek_length, 0);
            assert!(projected_sealed_dek_digest.is_empty());
        }
    } else {
        assert_eq!(projected_blob_id, 0);
        assert!(!projected_is_encrypted);
        assert_eq!(projected_sealed_dek_length, 0);
        assert!(projected_sealed_dek_digest.is_empty());
    }
}

/// Decode every Set field in declaration order, check the prior snapshot, and
/// replay only the current primitive metadata into an indexer projection.
fun project_set_event(
    projected_exists: &mut bool,
    projected_blob_id: &mut u256,
    projected_is_encrypted: &mut bool,
    projected_sealed_dek_length: &mut u64,
    projected_sealed_dek_digest: &mut vector<u8>,
    event: &mref::RecordingMasterReferenceSetEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), composition_id);
    let had_master_reference = bytes.peel_bool();
    let previous_blob_id = bytes.peel_u256();
    let previous_is_encrypted = bytes.peel_bool();
    let previous_sealed_dek_length = bytes.peel_u64();
    let previous_sealed_dek_digest = bytes.peel_vec_u8();
    let blob_id = bytes.peel_u256();
    let is_encrypted = bytes.peel_bool();
    let sealed_dek_length = bytes.peel_u64();
    let sealed_dek_digest = bytes.peel_vec_u8();
    assert_eq!(had_master_reference, *projected_exists);
    if (had_master_reference) {
        assert_eq!(previous_blob_id, *projected_blob_id);
        assert_eq!(previous_is_encrypted, *projected_is_encrypted);
        assert_eq!(previous_sealed_dek_length, *projected_sealed_dek_length);
        assert_eq!(previous_sealed_dek_digest, *projected_sealed_dek_digest);
    } else {
        assert_eq!(previous_blob_id, 0);
        assert!(!previous_is_encrypted);
        assert_eq!(previous_sealed_dek_length, 0);
        assert!(previous_sealed_dek_digest.is_empty());
    };
    if (is_encrypted) {
        assert_eq!(sealed_dek_digest.length(), 32);
    } else {
        assert_eq!(sealed_dek_length, 0);
        assert!(sealed_dek_digest.is_empty());
    };
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_exists = true;
    *projected_blob_id = blob_id;
    *projected_is_encrypted = is_encrypted;
    *projected_sealed_dek_length = sealed_dek_length;
    *projected_sealed_dek_digest = sealed_dek_digest;
}

/// Decode every Cleared field in declaration order, replay removal, and leave
/// the projection in the same absent state as the storage view.
fun project_cleared_event(
    projected_exists: &mut bool,
    projected_blob_id: &mut u256,
    projected_is_encrypted: &mut bool,
    projected_sealed_dek_length: &mut u64,
    projected_sealed_dek_digest: &mut vector<u8>,
    event: &mref::RecordingMasterReferenceClearedEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), composition_id);
    let removed_blob_id = bytes.peel_u256();
    let removed_is_encrypted = bytes.peel_bool();
    let removed_sealed_dek_length = bytes.peel_u64();
    let removed_sealed_dek_digest = bytes.peel_vec_u8();
    assert!(*projected_exists);
    assert_eq!(removed_blob_id, *projected_blob_id);
    assert_eq!(removed_is_encrypted, *projected_is_encrypted);
    assert_eq!(removed_sealed_dek_length, *projected_sealed_dek_length);
    assert_eq!(removed_sealed_dek_digest, *projected_sealed_dek_digest);
    if (removed_is_encrypted) {
        assert_eq!(removed_sealed_dek_digest.length(), 32);
    };
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_exists = false;
    *projected_blob_id = 0;
    *projected_is_encrypted = false;
    *projected_sealed_dek_length = 0;
    *projected_sealed_dek_digest = vector[];
}

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let mut projected_exists = false;
    let mut projected_blob_id = 0u256;
    let mut projected_is_encrypted = false;
    let mut projected_sealed_dek_length = 0u64;
    let mut projected_sealed_dek_digest = vector[];
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(111, confidentiality::new_unencrypted()),
    );
    let set_events = event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 1);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &set_events[0],
        recording_id,
        composition_id,
    );
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    // Plaintext replacement carries the prior plaintext snapshot.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(222, confidentiality::new_unencrypted()),
    );
    let set_events = event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 2);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &set_events[1],
        recording_id,
        composition_id,
    );
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    // Encryption replacement carries the exact sealed-DEK length and digest.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(333, confidentiality::new_encrypted(b"sealed-dek")),
    );
    let set_events = event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 3);
    assert_eq!(sui::bcs::to_bytes(&set_events[2]).length(), 181);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &set_events[2],
        recording_id,
        composition_id,
    );
    assert_eq!(projected_sealed_dek_length, 10);
    assert_eq!(projected_sealed_dek_digest, sealed_dek_digest());
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    // A different encrypted DEK on the same blob ID still exposes both
    // snapshots: the previous digest is the first DEK and the current digest
    // is the replacement DEK.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(333, confidentiality::new_encrypted(b"other-dek")),
    );
    let set_events = event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 4);
    assert_eq!(sui::bcs::to_bytes(&set_events[3]).length(), 213);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &set_events[3],
        recording_id,
        composition_id,
    );
    let (_, _, _, previous_blob_id, previous_is_encrypted, previous_sealed_dek_length,
        previous_sealed_dek_digest, blob_id, is_encrypted, sealed_dek_length,
        sealed_dek_digest) = mref::set_event_fields(&set_events[3]);
    assert_eq!(previous_blob_id, 333);
    assert!(previous_is_encrypted);
    assert_eq!(previous_sealed_dek_length, 10);
    assert_eq!(previous_sealed_dek_digest, sealed_dek_digest());
    assert_eq!(blob_id, 333);
    assert!(is_encrypted);
    assert_eq!(sealed_dek_length, 9);
    assert_eq!(sealed_dek_digest, sui::hash::blake2b256(&b"other-dek"));
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    // An identical encrypted replacement still emits one event. Its complete
    // BCS payload has identical previous/current encrypted metadata.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(333, confidentiality::new_encrypted(b"other-dek")),
    );
    let set_events = event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 5);
    assert_eq!(sui::bcs::to_bytes(&set_events[4]).length(), 213);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &set_events[4],
        recording_id,
        composition_id,
    );
    let (_, _, had_master_reference, previous_blob_id, previous_is_encrypted,
        previous_sealed_dek_length, previous_sealed_dek_digest, blob_id,
        is_encrypted, sealed_dek_length, sealed_dek_digest) =
        mref::set_event_fields(&set_events[4]);
    assert!(had_master_reference);
    assert_eq!(previous_blob_id, 333);
    assert!(previous_is_encrypted);
    assert_eq!(previous_sealed_dek_length, 9);
    assert_eq!(previous_sealed_dek_digest, sui::hash::blake2b256(&b"other-dek"));
    assert_eq!(blob_id, 333);
    assert!(is_encrypted);
    assert_eq!(sealed_dek_length, 9);
    assert_eq!(sealed_dek_digest, sui::hash::blake2b256(&b"other-dek"));
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    // Encrypted-to-plaintext replay retains the prior encrypted snapshot and
    // restores canonical plaintext metadata for the current side.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(334, confidentiality::new_unencrypted()),
    );
    let set_events = event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 6);
    assert_eq!(sui::bcs::to_bytes(&set_events[5]).length(), 181);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &set_events[5],
        recording_id,
        composition_id,
    );
    let (_, _, _, previous_blob_id, previous_is_encrypted, previous_sealed_dek_length,
        previous_sealed_dek_digest, blob_id, is_encrypted, sealed_dek_length,
        sealed_dek_digest) = mref::set_event_fields(&set_events[5]);
    assert_eq!(previous_blob_id, 333);
    assert!(previous_is_encrypted);
    assert_eq!(previous_sealed_dek_length, 9);
    assert_eq!(previous_sealed_dek_digest, sui::hash::blake2b256(&b"other-dek"));
    assert_eq!(blob_id, 334);
    assert!(!is_encrypted);
    assert_eq!(sealed_dek_length, 0);
    assert!(sealed_dek_digest.is_empty());
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    mref::unset_master_reference(&mut rec, &cap);
    let cleared_events =
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(sui::bcs::to_bytes(&cleared_events[0]).length(), 106);
    project_cleared_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &cleared_events[0],
        recording_id,
        composition_id,
    );
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    // Unset is idempotent.
    mref::unset_master_reference(&mut rec, &cap);
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>().length(),
        1,
    );
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    // Re-attachment after removal is a fresh absent-to-plaintext transition.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(444, confidentiality::new_unencrypted()),
    );
    let set_events = event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 7);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &set_events[6],
        recording_id,
        composition_id,
    );
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    destroy(rec);
    destroy(cap);
}

/// The stored encrypted reference retains the original sealed DEK bytes, while
/// the event exposes only its length and digest.
#[test]
fun encrypted_blob_is_accepted_and_keeps_its_dek() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(333, confidentiality::new_encrypted(b"dek")),
    );

    let r = mref::master_reference(&rec);
    assert!(r.blob_confidentiality().is_encrypted());
    assert_eq!(r.blob_id(), 333);
    assert_eq!(*r.blob_confidentiality().sealed_dek(), b"dek");

    destroy(rec);
    destroy(cap);
}

/// Replacing an encrypted reference with a plain one must not leave the old
/// sealed state behind — the whole value is swapped, not merged.
#[test]
fun replacing_encrypted_with_plain_clears_encryption() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(1, confidentiality::new_encrypted(b"dek")),
    );
    assert!(mref::master_reference(&rec).blob_confidentiality().is_encrypted());

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(2, confidentiality::new_unencrypted()),
    );
    assert!(!mref::master_reference(&rec).blob_confidentiality().is_encrypted());
    assert_eq!(mref::master_reference(&rec).blob_id(), 2);

    destroy(rec);
    destroy(cap);
}

#[test]
fun references_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (mut b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(
        test_helpers::fake_id(ctx),
        ctx,
    );
    let (mut c, c_cap) = recording::new_for_testing<REC, OTHER_COMP>(
        test_helpers::fake_id(ctx),
        ctx,
    );

    mref::set_master_reference(
        &mut a,
        &a_cap,
        data::new_blob(9, confidentiality::new_unencrypted()),
    );
    mref::set_master_reference(
        &mut b,
        &b_cap,
        data::new_blob(10, confidentiality::new_unencrypted()),
    );
    mref::set_master_reference(
        &mut c,
        &c_cap,
        data::new_blob(11, confidentiality::new_unencrypted()),
    );

    assert!(mref::has_master_reference(&a));
    assert!(mref::has_master_reference(&b));
    assert!(mref::has_master_reference(&c));
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>().length(),
        1,
    );
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<OTHER_REC, COMP>>().length(),
        1,
    );
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, OTHER_COMP>>().length(),
        1,
    );
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<OTHER_REC, OTHER_COMP>>().length(),
        0,
    );

    mref::unset_master_reference(&mut a, &a_cap);
    mref::unset_master_reference(&mut b, &b_cap);
    mref::unset_master_reference(&mut c, &c_cap);
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>().length(),
        1,
    );
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<OTHER_REC, COMP>>().length(),
        1,
    );
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, OTHER_COMP>>().length(),
        1,
    );
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<OTHER_REC, OTHER_COMP>>().length(),
        0,
    );

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap); destroy(c); destroy(c_cap);
}

#[test]
fun set_emits_the_reference_and_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(7, confidentiality::new_unencrypted()),
    );

    // The primitive snapshot is the indexer's whole feed; it never carries
    // the sealed-DEK bytes themselves.
    let events =
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_recording_id, event_composition_id, had_master_reference, previous_blob_id,
        previous_is_encrypted, previous_sealed_dek_length, previous_sealed_dek_digest,
        blob_id, is_encrypted, sealed_dek_length, sealed_dek_digest) =
        mref::set_event_fields(&events[0]);
    assert_eq!(event_recording_id, rec_id.to_address());
    assert_eq!(event_composition_id, recording::composition_id(&rec).to_address());
    assert!(!had_master_reference);
    assert_eq!(previous_blob_id, 0);
    assert!(!previous_is_encrypted);
    assert_eq!(previous_sealed_dek_length, 0);
    assert_eq!(previous_sealed_dek_digest, vector[]);
    assert_eq!(blob_id, 7);
    assert!(!is_encrypted);
    assert_eq!(sealed_dek_length, 0);
    assert_eq!(sealed_dek_digest, vector[]);
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 149);

    destroy(rec);
    destroy(cap);
}

/// An encrypted reference retains its sealed DEK in storage, while the event
/// carries only the length and digest needed for its primitive projection.
#[test]
fun set_emits_an_encrypted_reference_with_its_dek() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(8, confidentiality::new_encrypted(b"dek")),
    );

    let events =
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (_, _, had_master_reference, previous_blob_id, previous_is_encrypted,
        previous_sealed_dek_length, previous_sealed_dek_digest, blob_id, is_encrypted,
        sealed_dek_length, sealed_dek_digest) = mref::set_event_fields(&events[0]);
    assert!(!had_master_reference);
    assert_eq!(previous_blob_id, 0);
    assert!(!previous_is_encrypted);
    assert_eq!(previous_sealed_dek_length, 0);
    assert_eq!(previous_sealed_dek_digest, vector[]);
    assert_eq!(blob_id, 8);
    assert!(is_encrypted);
    assert_eq!(sealed_dek_length, 3);
    assert_eq!(sealed_dek_digest.length(), 32);
    assert_eq!(sealed_dek_digest, sui::hash::blake2b256(&b"dek"));
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 181);

    destroy(rec);
    destroy(cap);
}

#[test]
fun zero_and_maximum_blob_ids_are_event_exact() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let mut projected_exists = false;
    let mut projected_blob_id = 0u256;
    let mut projected_is_encrypted = false;
    let mut projected_sealed_dek_length = 0u64;
    let mut projected_sealed_dek_digest = vector[];

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(0, confidentiality::new_unencrypted()),
    );
    let events =
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 149);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &events[0],
        recording_id,
        composition_id,
    );
    let (_, _, had_master_reference, previous_blob_id, _, _, _, blob_id, _, _, _) =
        mref::set_event_fields(&events[0]);
    assert!(!had_master_reference);
    assert_eq!(previous_blob_id, 0);
    assert_eq!(blob_id, 0);
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    // Replace while the zero-ID value is present. The prior zero must remain
    // distinguishable from an absent previous side via had_master_reference.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(1, confidentiality::new_unencrypted()),
    );
    let events =
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 2);
    assert_eq!(sui::bcs::to_bytes(&events[1]).length(), 149);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &events[1],
        recording_id,
        composition_id,
    );
    let (_, _, had_master_reference, previous_blob_id, _, _, _, blob_id, _, _, _) =
        mref::set_event_fields(&events[1]);
    assert!(had_master_reference);
    assert_eq!(previous_blob_id, 0);
    assert_eq!(blob_id, 1);
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    // Restore the zero-ID value so the following clear decodes a present zero
    // rather than an absent sentinel.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(0, confidentiality::new_unencrypted()),
    );
    let events =
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 3);
    assert_eq!(sui::bcs::to_bytes(&events[2]).length(), 149);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &events[2],
        recording_id,
        composition_id,
    );
    let (_, _, had_master_reference, previous_blob_id, _, _, _, blob_id, _, _, _) =
        mref::set_event_fields(&events[2]);
    assert!(had_master_reference);
    assert_eq!(previous_blob_id, 1);
    assert_eq!(blob_id, 0);
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    mref::unset_master_reference(&mut rec, &cap);
    let cleared =
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(sui::bcs::to_bytes(&cleared[0]).length(), 106);
    project_cleared_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &cleared[0],
        recording_id,
        composition_id,
    );
    let (_, _, removed_blob_id, _, _, _) = mref::cleared_event_fields(&cleared[0]);
    assert_eq!(removed_blob_id, 0);
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(MAX_U256, confidentiality::new_unencrypted()),
    );
    let events =
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 4);
    assert_eq!(sui::bcs::to_bytes(&events[3]).length(), 149);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &events[3],
        recording_id,
        composition_id,
    );
    let (_, _, had_master_reference, previous_blob_id, _, _, _, blob_id, _, _, _) =
        mref::set_event_fields(&events[3]);
    assert!(!had_master_reference);
    assert_eq!(previous_blob_id, 0);
    assert_eq!(blob_id, MAX_U256);
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    mref::unset_master_reference(&mut rec, &cap);
    let cleared =
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 2);
    assert_eq!(sui::bcs::to_bytes(&cleared[1]).length(), 106);
    project_cleared_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &cleared[1],
        recording_id,
        composition_id,
    );
    let (_, _, removed_blob_id, _, _, _) = mref::cleared_event_fields(&cleared[1]);
    assert_eq!(removed_blob_id, MAX_U256);
    assert_view_matches_projection(
        &rec,
        projected_exists,
        projected_blob_id,
        projected_is_encrypted,
        projected_sealed_dek_length,
        &projected_sealed_dek_digest,
    );

    destroy(rec);
    destroy(cap);
}

#[test]
fun encrypted_dek_minimum_length_is_event_exact() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    // ori rejects an empty sealed DEK, so one byte is the valid minimum.
    let sealed_dek = b"x";
    let mut projected_exists = false;
    let mut projected_blob_id = 0u256;
    let mut projected_is_encrypted = false;
    let mut projected_sealed_dek_length = 0u64;
    let mut projected_sealed_dek_digest = vector[];

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(600, confidentiality::new_encrypted(sealed_dek)),
    );
    let events =
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 181);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &events[0],
        recording_id,
        composition_id,
    );
    let (_, _, _, _, _, _, _, blob_id, is_encrypted, sealed_dek_length,
        sealed_dek_digest) = mref::set_event_fields(&events[0]);
    assert_eq!(blob_id, 600);
    assert!(is_encrypted);
    assert_eq!(sealed_dek_length, 1);
    assert_eq!(sealed_dek_digest, sui::hash::blake2b256(&sealed_dek));
    assert!(mref::master_reference(&rec).blob_confidentiality().is_encrypted());
    assert_eq!(
        *mref::master_reference(&rec).blob_confidentiality().sealed_dek(),
        sealed_dek,
    );

    mref::unset_master_reference(&mut rec, &cap);
    let cleared =
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(sui::bcs::to_bytes(&cleared[0]).length(), 138);
    project_cleared_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &cleared[0],
        recording_id,
        composition_id,
    );
    assert!(!mref::has_master_reference(&rec));

    destroy(rec);
    destroy(cap);
}

#[test]
fun large_encrypted_dek_is_stored_but_event_is_bounded() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let sealed_dek = vector::tabulate!(LARGE_DEK_LENGTH, |_| 0u8);
    let mut projected_exists = false;
    let mut projected_blob_id = 0u256;
    let mut projected_is_encrypted = false;
    let mut projected_sealed_dek_length = 0u64;
    let mut projected_sealed_dek_digest = vector[];

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(256001, confidentiality::new_encrypted(sealed_dek)),
    );
    let stored = mref::master_reference(&rec);
    assert_eq!(stored.blob_confidentiality().sealed_dek().length(), LARGE_DEK_LENGTH);
    assert_eq!(*stored.blob_confidentiality().sealed_dek(), sealed_dek);

    let events =
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    // The 256001-byte input never appears in the 181-byte event payload.
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 181);
    project_set_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &events[0],
        recording_id,
        composition_id,
    );
    let (_, _, _, _, _, _, _, blob_id, is_encrypted, sealed_dek_length,
        sealed_dek_digest) = mref::set_event_fields(&events[0]);
    assert_eq!(blob_id, 256001);
    assert!(is_encrypted);
    assert_eq!(sealed_dek_length, LARGE_DEK_LENGTH);
    assert_eq!(sealed_dek_digest, large_dek_digest());
    assert_eq!(projected_sealed_dek_length, LARGE_DEK_LENGTH);
    assert_eq!(projected_sealed_dek_digest, large_dek_digest());

    mref::unset_master_reference(&mut rec, &cap);
    let cleared =
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(sui::bcs::to_bytes(&cleared[0]).length(), 138);
    project_cleared_event(
        &mut projected_exists,
        &mut projected_blob_id,
        &mut projected_is_encrypted,
        &mut projected_sealed_dek_length,
        &mut projected_sealed_dek_digest,
        &cleared[0],
        recording_id,
        composition_id,
    );
    assert!(!mref::has_master_reference(&rec));

    destroy(rec);
    destroy(cap);
}

#[test]
fun unset_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    // Nothing attached — a no-op must stay silent.
    mref::unset_master_reference(&mut rec, &cap);
    assert_eq!(
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>().length(),
        0,
    );

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(5, confidentiality::new_unencrypted()),
    );
    mref::unset_master_reference(&mut rec, &cap);

    let events =
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_recording_id, event_composition_id, removed_blob_id, removed_is_encrypted,
        removed_sealed_dek_length, removed_sealed_dek_digest) =
        mref::cleared_event_fields(&events[0]);
    assert_eq!(event_recording_id, rec_id.to_address());
    assert_eq!(event_composition_id, recording::composition_id(&rec).to_address());
    assert_eq!(removed_blob_id, 5);
    assert!(!removed_is_encrypted);
    assert_eq!(removed_sealed_dek_length, 0);
    assert_eq!(removed_sealed_dek_digest, vector[]);
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 106);

    destroy(rec);
    destroy(cap);
}

/// The migration this package is built to end in: the reference goes away, and
/// the recording is left clean for the attested master to take over.
#[test]
fun unset_leaves_no_trace_for_the_attested_path() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(42, confidentiality::new_unencrypted()),
    );
    mref::unset_master_reference(&mut rec, &cap);

    assert!(!mref::has_master_reference(&rec));

    // And re-attaching afterwards still works, so removal is not one-way.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(43, confidentiality::new_unencrypted()),
    );
    assert_eq!(mref::master_reference(&rec).blob_id(), 43);

    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = mref::ENoMasterReference)]
fun master_reference_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec(ctx);
    let _ = mref::master_reference(&rec);
    destroy(rec);
    destroy(cap);
}
