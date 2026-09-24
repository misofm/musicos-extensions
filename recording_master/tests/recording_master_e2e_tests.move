// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_master` against the production shape: a
/// `Recording` is published and shared first, and the extension operates on
/// it later, across real transaction boundaries and distinct senders. ADMIN
/// holds the `RecordingAdminCap` and performs every write; STRANGER and
/// PAYER own nothing and prove the views are permissionless once the
/// recording is public. Writes are gated purely by possession of the cap
/// object (there is no sender check to defeat with a different signer; see
/// `recording_master_tests` on why a wrong-cap test is not expressible).
#[test_only]
module recording_master::recording_master_e2e_tests;

use audio::audio::{Self, Audio};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_master::recording_master::{
    Self as master_ext,
    RecordingMasterSetEvent,
    RecordingMasterClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;
use sui::test_scenario::{Self as ts, Scenario};

public struct REC {}

const ADMIN: address = @0xAD;
const PAYER: address = @0xFA;
const STRANGER: address = @0x51;

/// Tx 1 (ADMIN): create a recording and publish it — `publish` shares it, the
/// production shape every other transaction in this file operates against.
fun publish_and_share_recording(ts: &mut Scenario): RecordingAdminCap<REC> {
    let (rec, cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    rec.publish(&cap);
    cap
}

/// The full lifecycle against a published, shared recording, across seven
/// transactions and three distinct senders: ADMIN attaches and later replaces
/// and removes the master; STRANGER and PAYER, holding no cap, freely read it
/// via `take_shared` in between. Every write pins the exact event payload.
#[test]
fun full_lifecycle_on_published_and_shared_recording() {
    let mut ts = ts::begin(ADMIN);
    let cap = publish_and_share_recording(&mut ts);

    // --- Tx 2 (ADMIN): attach the master to the shared recording ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    let rec_id = object::id(&rec).to_address();
    assert!(!master_ext::has_master(&rec));

    master_ext::set_master(&mut rec, &cap, new_audio(111));
    assert!(master_ext::has_master(&rec));
    assert_eq!(master_ext::master(&rec).blob_id(), 111);
    assert_audio_metadata(master_ext::master(&rec));

    let events = events_by_type<RecordingMasterSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (id, master) = master_ext::set_event_fields(&events[0]);
    assert_eq!(id, rec_id);
    assert_eq!(master, new_audio(111));
    assert_eq!(to_bytes(&events[0]).length(), 116);
    ts::return_shared(rec);

    // --- Tx 3 (STRANGER, owns no cap): the master is publicly readable ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(master_ext::has_master(&rec));
    assert_eq!(master_ext::master(&rec).blob_id(), 111);
    assert_audio_metadata(master_ext::master(&rec));
    ts::return_shared(rec);

    // --- Tx 4 (ADMIN): equal set is silent; replace — the old value must
    // not survive the swap ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    master_ext::set_master(&mut rec, &cap, new_audio(111));
    assert_eq!(events_by_type<RecordingMasterSetEvent<REC>>().length(), 0);

    master_ext::set_master(&mut rec, &cap, new_audio(222));
    assert_eq!(master_ext::master(&rec).blob_id(), 222);
    assert_audio_metadata(master_ext::master(&rec));

    // `next_tx` resets the recorded event log — a fresh single-element feed,
    // exactly as a real indexer would see one transaction's events at a time.
    let events = events_by_type<RecordingMasterSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (id, master) = master_ext::set_event_fields(&events[0]);
    assert_eq!(id, rec_id);
    assert_eq!(master, new_audio(222));
    assert_eq!(to_bytes(&events[0]).length(), 115);
    ts::return_shared(rec);

    // --- Tx 5 (PAYER, owns no cap): the replacement is visible to anyone ---
    ts.next_tx(PAYER);
    let rec = ts.take_shared<Recording<REC>>();
    assert_eq!(master_ext::master(&rec).blob_id(), 222);
    assert_audio_metadata(master_ext::master(&rec));
    ts::return_shared(rec);

    // --- Tx 6 (ADMIN): remove and reattach the master ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    master_ext::clear_master(&mut rec, &cap);
    assert!(!master_ext::has_master(&rec));

    let cleared = events_by_type<RecordingMasterClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(master_ext::cleared_event_fields(&cleared[0]), rec_id);
    assert_eq!(to_bytes(&cleared[0]).length(), 32);

    master_ext::set_master(&mut rec, &cap, new_audio(333));
    assert_eq!(master_ext::master(&rec).blob_id(), 333);
    assert_audio_metadata(master_ext::master(&rec));
    ts::return_shared(rec);

    // --- Tx 7 (STRANGER): the re-attached master is visible too ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert_eq!(master_ext::master(&rec).blob_id(), 333);
    assert_audio_metadata(master_ext::master(&rec));
    ts::return_shared(rec);

    destroy(cap);
    ts.end();
}

/// A freshly published recording carries no master — reading it aborts for
/// anyone, cap or not, against the genuinely shared object taken from a
/// later transaction.
#[test, expected_failure(abort_code = master_ext::ENoMaster)]
fun master_aborts_when_absent_on_shared_recording() {
    let mut ts = ts::begin(ADMIN);
    let cap = publish_and_share_recording(&mut ts);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    let _ = master_ext::master(&rec);

    destroy(cap);
    ts::return_shared(rec);
    ts.end();
}

/// Distinct metadata for each fixture catches stale fields when replacing a master.
fun new_audio(blob_id: u256): Audio {
    let alternate = blob_id % 2 == 0;
    audio::new(
        if (alternate) b"wav".to_string() else b"flac".to_string(),
        if (alternate) 1 else 2,
        if (alternate) 16 else 24,
        if (alternate) 44100 else 48000,
        if (alternate) 88200 else 48000,
        if (alternate) vector::tabulate!(32, |_| 0x22u8) else vector::tabulate!(32, |_| 0x11u8),
        blob_id,
    )
}

fun assert_audio_metadata(master: &Audio) {
    let alternate = master.blob_id() % 2 == 0;
    assert_eq!(*master.format(), if (alternate) b"wav".to_string() else b"flac".to_string());
    assert_eq!(master.channels(), if (alternate) 1 else 2);
    assert_eq!(master.bit_depth(), if (alternate) 16 else 24);
    assert_eq!(master.sample_rate_hz(), if (alternate) 44100 else 48000);
    assert_eq!(master.samples(), if (alternate) 88200 else 48000);
    assert_eq!(master.duration_ms(), if (alternate) 2000 else 1000);
    assert_eq!(
        *master.pcm_digest(),
        if (alternate) vector::tabulate!(32, |_| 0x22u8) else vector::tabulate!(32, |_| 0x11u8),
    );
}
