// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenarios against a `Recording` that has actually been published
/// and shared — the production shape — run under `sui::test_scenario`: real
/// transaction boundaries, a genuinely shared `Recording` re-accessed via
/// `take_shared`/`return_shared`, and distinct senders. ADMIN holds the
/// `RecordingAdminCap` and performs every write; STRANGER and READER own
/// nothing and prove that the view functions are permissionless once the
/// recording is public, while the write functions are gated purely by
/// possession of the cap object (there is no `tx_context::sender` check to
/// defeat with a different signer — see the module-level note in
/// `recording_master_reference_tests` on why an incompatible cap type fails
/// compilation while a different same-type cap value is accepted).
#[test_only]
module recording_master_reference::recording_master_reference_e2e_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers;
use ori::{confidentiality, data};
use recording_master_reference::recording_master_reference as mref;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self, Scenario};

// Phantom marker types for the share parameters.
public struct REC {}
public struct COMP {}

const ADMIN: address = @0xAD;
const PAYER: address = @0xFA;
const STRANGER: address = @0x51;

/// Tx 1 (ADMIN): create a recording and publish it — `publish` shares it, the
/// production shape every other transaction in this file operates against.
fun publish_and_share_recording(ts: &mut Scenario): RecordingAdminCap<REC> {
    let (rec, cap) = recording::new_for_testing<REC, COMP>(test_helpers::fake_id(ts.ctx()), ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&cap, &clock); // shares the recording
    clock.destroy_for_testing();
    cap
}

/// The full lifecycle against a published, shared recording, across five
/// transactions and three distinct senders: ADMIN attaches and later replaces
/// and removes the master reference; STRANGER and PAYER, holding no cap at
/// all, freely read it via `take_shared` in between. Every set/unset step
/// pins the exact event payload.
#[test]
fun full_lifecycle_on_published_and_shared_recording() {
    let mut ts = test_scenario::begin(ADMIN);
    let cap = publish_and_share_recording(&mut ts);

    // --- Tx 2 (ADMIN): attach the master reference to the shared recording ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    let rec_id = object::id(&rec);
    assert!(!mref::has_master_reference(&rec));

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(111, confidentiality::new_unencrypted()),
    );
    assert!(mref::has_master_reference(&rec));
    assert_eq!(mref::master_reference(&rec).blob_id(), 111);

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
    assert_eq!(blob_id, 111);
    assert!(!is_encrypted);
    assert_eq!(sealed_dek_length, 0);
    assert_eq!(sealed_dek_digest, vector[]);
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 149);
    test_scenario::return_shared(rec);

    // --- Tx 3 (STRANGER, owns no cap): the reference is publicly readable ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(mref::has_master_reference(&rec));
    assert_eq!(mref::master_reference(&rec).blob_id(), 111);
    assert!(!mref::master_reference(&rec).blob_confidentiality().is_encrypted());
    test_scenario::return_shared(rec);

    // --- Tx 4 (ADMIN): replace with an encrypted reference — the old value
    // must not survive the swap ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(222, confidentiality::new_encrypted(b"dek")),
    );
    assert!(mref::master_reference(&rec).blob_confidentiality().is_encrypted());
    assert_eq!(mref::master_reference(&rec).blob_id(), 222);
    assert_eq!(*mref::master_reference(&rec).blob_confidentiality().sealed_dek(), b"dek");

    // `next_tx` resets the recorded event log — a fresh single-element feed,
    // exactly as a real indexer would see one transaction's events at a time.
    let events =
        event::events_by_type<mref::RecordingMasterReferenceSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_recording_id, event_composition_id, had_master_reference, previous_blob_id,
        previous_is_encrypted, previous_sealed_dek_length, previous_sealed_dek_digest,
        blob_id, is_encrypted, sealed_dek_length, sealed_dek_digest) =
        mref::set_event_fields(&events[0]);
    assert_eq!(event_recording_id, rec_id.to_address());
    assert_eq!(event_composition_id, recording::composition_id(&rec).to_address());
    assert!(had_master_reference);
    assert_eq!(previous_blob_id, 111);
    assert!(!previous_is_encrypted);
    assert_eq!(previous_sealed_dek_length, 0);
    assert_eq!(previous_sealed_dek_digest, vector[]);
    assert_eq!(blob_id, 222);
    assert!(is_encrypted);
    assert_eq!(sealed_dek_length, 3);
    assert_eq!(sealed_dek_digest, sui::hash::blake2b256(&b"dek"));
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 181);
    test_scenario::return_shared(rec);

    // --- Tx 5 (PAYER, owns no cap): the replacement is visible to anyone ---
    ts.next_tx(PAYER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(mref::master_reference(&rec).blob_confidentiality().is_encrypted());
    assert_eq!(mref::master_reference(&rec).blob_id(), 222);
    test_scenario::return_shared(rec);

    // --- Tx 6 (ADMIN): remove it — the migration path this package exists
    // for — then re-attach, proving removal is not one-way ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    mref::unset_master_reference(&mut rec, &cap);
    assert!(!mref::has_master_reference(&rec));

    let unset_events =
        event::events_by_type<mref::RecordingMasterReferenceClearedEvent<REC, COMP>>();
    assert_eq!(unset_events.length(), 1);
    let (event_recording_id, event_composition_id, removed_blob_id, removed_is_encrypted,
        removed_sealed_dek_length, removed_sealed_dek_digest) =
        mref::cleared_event_fields(&unset_events[0]);
    assert_eq!(event_recording_id, rec_id.to_address());
    assert_eq!(event_composition_id, recording::composition_id(&rec).to_address());
    assert_eq!(removed_blob_id, 222);
    assert!(removed_is_encrypted);
    assert_eq!(removed_sealed_dek_length, 3);
    assert_eq!(removed_sealed_dek_digest, sui::hash::blake2b256(&b"dek"));
    assert_eq!(sui::bcs::to_bytes(&unset_events[0]).length(), 138);

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(333, confidentiality::new_unencrypted()),
    );
    assert_eq!(mref::master_reference(&rec).blob_id(), 333);
    test_scenario::return_shared(rec);

    // --- Tx 7 (STRANGER): the re-attached reference is visible too ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert_eq!(mref::master_reference(&rec).blob_id(), 333);
    test_scenario::return_shared(rec);

    destroy(cap);
    ts.end();
}

/// A freshly published recording carries no master reference — reading it
/// aborts for anyone, cap or not, exactly as it would for the never-attached
/// case in the single-transaction tests, but here against the genuinely
/// shared object taken from a later transaction.
#[test, expected_failure(abort_code = mref::ENoMasterReference)]
fun master_reference_aborts_when_absent_on_shared_recording() {
    let mut ts = test_scenario::begin(ADMIN);
    let cap = publish_and_share_recording(&mut ts);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    let _ = mref::master_reference(&rec);

    // Unreachable, but the compiler requires every non-drop value consumed
    // on every code path.
    destroy(cap);
    test_scenario::return_shared(rec);
    ts.end();
}
