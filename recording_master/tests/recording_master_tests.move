// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Set/read/replace/clear mechanics against a bare `Recording`. Nothing here
/// crosses a transaction boundary, so `tx_context::dummy()` suffices; the
/// published, shared shape is covered in `recording_master_e2e_tests`.
///
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type —
/// one share type backs exactly one recording — so a wrong-cap call is a
/// compile error, not a runtime abort, and there is no such test here.
#[test_only]
module recording_master::recording_master_tests;

use audio::audio::{Self, Audio};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_master::recording_master::{
    Self as master_ext,
    RecordingMasterSetEvent,
    RecordingMasterClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::{events_by_type, num_events};

public struct REC {}
public struct OTHER_REC {}

/// Only a `Recording` is needed, so a bare id stands in for its composition.
fun new_rec<RecordingShare>(
    ctx: &mut TxContext,
): (Recording<RecordingShare>, RecordingAdminCap<RecordingShare>) {
    recording::new_for_testing<RecordingShare>(object::id_from_address(@0xC0FFEE), ctx)
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    assert!(!master_ext::has_master(&rec));

    master_ext::set_master(&mut rec, &cap, new_audio(111));
    assert!(master_ext::has_master(&rec));
    assert_eq!(master_ext::master(&rec).blob_id(), 111);
    assert_audio_metadata(master_ext::master(&rec));

    // Replacing points at the new blob — a recording has one master, not a list.
    master_ext::set_master(&mut rec, &cap, new_audio(222));
    assert_eq!(master_ext::master(&rec).blob_id(), 222);
    assert_audio_metadata(master_ext::master(&rec));

    master_ext::clear_master(&mut rec, &cap);
    assert!(!master_ext::has_master(&rec));

    // Clear is idempotent.
    master_ext::clear_master(&mut rec, &cap);
    assert!(!master_ext::has_master(&rec));

    destroy(rec);
    destroy(cap);
}

#[test]
fun masters_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec<REC>(ctx);
    let (b, b_cap) = new_rec<OTHER_REC>(ctx);

    master_ext::set_master(&mut a, &a_cap, new_audio(9));

    assert!(master_ext::has_master(&a));
    assert!(!master_ext::has_master(&b));

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test]
fun master_events_are_partitioned_by_recording_share_type() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec<REC>(ctx);
    let (mut b, b_cap) = new_rec<OTHER_REC>(ctx);

    master_ext::set_master(&mut a, &a_cap, new_audio(9));
    master_ext::set_master(&mut b, &b_cap, new_audio(10));

    let a_events = events_by_type<RecordingMasterSetEvent<REC>>();
    let b_events = events_by_type<RecordingMasterSetEvent<OTHER_REC>>();
    assert_eq!(a_events.length(), 1);
    assert_eq!(b_events.length(), 1);
    let (a_id, _) = master_ext::set_event_fields(&a_events[0]);
    let (b_id, _) = master_ext::set_event_fields(&b_events[0]);
    assert_eq!(a_id, object::id(&a).to_address());
    assert_eq!(b_id, object::id(&b).to_address());

    master_ext::clear_master(&mut a, &a_cap);
    assert_eq!(events_by_type<RecordingMasterClearedEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingMasterClearedEvent<OTHER_REC>>().length(), 0);

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

/// The set event is the indexer's whole feed: it carries the audio itself,
/// not just a pointer back to the object.
#[test]
fun set_emits_the_audio_and_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec).to_address();
    let audio = new_audio(7);

    // Audio construction is a pure value operation; attaching it is the
    // canonical source of the master event.
    assert_eq!(num_events(), 0);

    master_ext::set_master(&mut rec, &cap, audio);
    assert_eq!(num_events(), 1);

    let events = events_by_type<RecordingMasterSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (id, master) = master_ext::set_event_fields(&events[0]);
    assert_eq!(id, rec_id);
    assert_eq!(master, audio);
    assert_audio_metadata(&master);
    // 32-byte recording address + the 4-byte `flac` fixture's 84-byte Audio.
    assert_eq!(to_bytes(&events[0]).length(), 116);

    destroy(rec);
    destroy(cap);
}

/// `Audio`'s only variable-length field is the format name, capped at 16
/// bytes, so the set event never exceeds 128 bytes.
#[test]
fun set_event_is_at_most_128_bytes() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let widest = audio::new(
        b"abcdefghijklmnop".to_string(),
        2,
        24,
        48000,
        48000,
        vector::tabulate!(32, |_| 0x11u8),
        1,
    );

    master_ext::set_master(&mut rec, &cap, widest);

    let events = events_by_type<RecordingMasterSetEvent<REC>>();
    assert_eq!(to_bytes(&events[0]).length(), 128);

    destroy(rec);
    destroy(cap);
}

#[test]
fun equal_set_neither_writes_nor_emits() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let audio = new_audio(17);

    master_ext::set_master(&mut rec, &cap, audio);
    assert_eq!(events_by_type<RecordingMasterSetEvent<REC>>().length(), 1);
    master_ext::set_master(&mut rec, &cap, audio);
    assert_eq!(events_by_type<RecordingMasterSetEvent<REC>>().length(), 1);
    assert_eq!(master_ext::master(&rec).blob_id(), 17);

    destroy(rec);
    destroy(cap);
}

/// Equality is over the whole `Audio`, not just the blob ID.
#[test]
fun same_blob_with_changed_audio_metadata_emits() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let first = audio::new(
        b"flac".to_string(),
        2,
        24,
        48000,
        48000,
        vector::tabulate!(32, |_| 0x11u8),
        27,
    );
    let changed = audio::new(
        b"wav".to_string(),
        1,
        16,
        44100,
        88200,
        vector::tabulate!(32, |_| 0x22u8),
        27,
    );

    master_ext::set_master(&mut rec, &cap, first);
    assert_eq!(events_by_type<RecordingMasterSetEvent<REC>>().length(), 1);
    master_ext::set_master(&mut rec, &cap, changed);
    let events = events_by_type<RecordingMasterSetEvent<REC>>();
    assert_eq!(events.length(), 2);
    let (_, master) = master_ext::set_event_fields(&events[1]);
    assert_eq!(master, changed);
    assert_eq!(*master_ext::master(&rec), changed);

    destroy(rec);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec).to_address();

    // Nothing attached — a no-op must stay silent.
    master_ext::clear_master(&mut rec, &cap);
    assert_eq!(events_by_type<RecordingMasterClearedEvent<REC>>().length(), 0);

    master_ext::set_master(&mut rec, &cap, new_audio(5));
    master_ext::clear_master(&mut rec, &cap);

    let events = events_by_type<RecordingMasterClearedEvent<REC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(master_ext::cleared_event_fields(&events[0]), rec_id);
    assert_eq!(to_bytes(&events[0]).length(), 32);

    // A second clear has nothing to remove.
    master_ext::clear_master(&mut rec, &cap);
    assert_eq!(events_by_type<RecordingMasterClearedEvent<REC>>().length(), 1);

    destroy(rec);
    destroy(cap);
}

/// Removing and reattaching a master works without leaving a stale value.
#[test]
fun clear_allows_reattaching_master() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    master_ext::set_master(&mut rec, &cap, new_audio(42));
    master_ext::clear_master(&mut rec, &cap);
    assert!(!master_ext::has_master(&rec));

    master_ext::set_master(&mut rec, &cap, new_audio(43));
    assert_eq!(master_ext::master(&rec).blob_id(), 43);
    assert_audio_metadata(master_ext::master(&rec));
    assert_eq!(events_by_type<RecordingMasterSetEvent<REC>>().length(), 2);

    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = master_ext::ENoMaster)]
fun master_aborts_when_absent() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec<REC>(ctx);
    let _ = master_ext::master(&rec);
    destroy(rec);
    destroy(cap);
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
