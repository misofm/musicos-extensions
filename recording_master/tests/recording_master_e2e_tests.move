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
/// `recording_master_tests` on why a "wrong cap" test is not
/// expressible for this package).
#[test_only]
module recording_master::recording_master_e2e_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers;
use audio::audio::{Self, Audio};
use recording_master::recording_master as master_ext;
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
/// and removes the master audio; STRANGER and PAYER, holding no cap at
/// all, freely read it via `take_shared` in between. Every set/unset step
/// pins the exact event payload.
#[test]
fun full_lifecycle_on_published_and_shared_recording() {
    let mut ts = test_scenario::begin(ADMIN);
    let cap = publish_and_share_recording(&mut ts);

    // --- Tx 2 (ADMIN): attach the master audio to the shared recording ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    let rec_id = object::id(&rec);
    assert!(!master_ext::has_master(&rec));

    master_ext::set_master(
        &mut rec,
        &cap,
        new_audio(111),
    );
    assert!(master_ext::has_master(&rec));
    assert_eq!(master_ext::master(&rec).blob_id(), 111);
    assert_audio_metadata(master_ext::master(&rec));

    let events = event::events_by_type<master_ext::MasterSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, master) = master_ext::set_event_fields(&events[0]);
    assert_audio_metadata(&master);
    assert_eq!(id, rec_id);
    assert_eq!(master.blob_id(), 111);
    test_scenario::return_shared(rec);

    // --- Tx 3 (STRANGER, owns no cap): the master is publicly readable ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(master_ext::has_master(&rec));
    assert_eq!(master_ext::master(&rec).blob_id(), 111);
    assert_audio_metadata(master_ext::master(&rec));
    test_scenario::return_shared(rec);

    // --- Tx 4 (ADMIN): replace with a new master — the old value
    // must not survive the swap ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    master_ext::set_master(
        &mut rec,
        &cap,
        new_audio(222),
    );
    assert_eq!(master_ext::master(&rec).blob_id(), 222);
    assert_audio_metadata(master_ext::master(&rec));

    // `next_tx` resets the recorded event log — a fresh single-element feed,
    // exactly as a real indexer would see one transaction's events at a time.
    let events = event::events_by_type<master_ext::MasterSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, master) = master_ext::set_event_fields(&events[0]);
    assert_audio_metadata(&master);
    assert_eq!(id, rec_id);
    assert_eq!(master.blob_id(), 222);
    test_scenario::return_shared(rec);

    // --- Tx 5 (PAYER, owns no cap): the replacement is visible to anyone ---
    ts.next_tx(PAYER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert_eq!(master_ext::master(&rec).blob_id(), 222);
    assert_audio_metadata(master_ext::master(&rec));
    test_scenario::return_shared(rec);

    // --- Tx 6 (ADMIN): remove and reattach the master ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    master_ext::unset_master(&mut rec, &cap);
    assert!(!master_ext::has_master(&rec));

    let unset_events = event::events_by_type<master_ext::MasterUnsetEvent>();
    assert_eq!(unset_events.length(), 1);
    assert_eq!(master_ext::unset_event_recording_id(&unset_events[0]), rec_id);

    master_ext::set_master(
        &mut rec,
        &cap,
        new_audio(333),
    );
    assert_eq!(master_ext::master(&rec).blob_id(), 333);
    assert_audio_metadata(master_ext::master(&rec));
    test_scenario::return_shared(rec);

    // --- Tx 7 (STRANGER): the re-attached master is visible too ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert_eq!(master_ext::master(&rec).blob_id(), 333);
    assert_audio_metadata(master_ext::master(&rec));
    test_scenario::return_shared(rec);

    destroy(cap);
    ts.end();
}

/// A freshly published recording carries no master audio — reading it
/// aborts for anyone, cap or not, exactly as it would for the never-attached
/// case in the single-transaction tests, but here against the genuinely
/// shared object taken from a later transaction.
#[test, expected_failure(abort_code = master_ext::ENoMaster)]
fun master_aborts_when_absent_on_shared_recording() {
    let mut ts = test_scenario::begin(ADMIN);
    let cap = publish_and_share_recording(&mut ts);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    let _ = master_ext::master(&rec);

    // Unreachable, but the compiler requires every non-drop value consumed
    // on every code path.
    destroy(cap);
    test_scenario::return_shared(rec);
    ts.end();
}

/// Distinct metadata for each fixture catches stale fields when replacing a master.
fun new_audio(blob_id: u256): Audio {
    let alternate = blob_id % 2 == 0;
    audio::new(
        if (alternate) "wav" else "flac",
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
    assert_eq!(*master.format(), if (alternate) "wav" else "flac");
    assert_eq!(master.channels(), if (alternate) 1 else 2);
    assert_eq!(master.bit_depth(), if (alternate) 16 else 24);
    assert_eq!(master.sample_rate_hz(), if (alternate) 44100 else 48000);
    assert_eq!(master.samples(), if (alternate) 88200 else 48000);
    assert_eq!(master.duration_ms(), if (alternate) 2000 else 1000);
    assert_eq!(*master.pcm_digest(), if (alternate) vector::tabulate!(32, |_| 0x22u8) else vector::tabulate!(32, |_| 0x11u8));
}
