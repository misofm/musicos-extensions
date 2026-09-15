// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Single-transaction unit tests against a bare (never-published, never-shared)
/// `Recording`. None of these exercise ownership mechanics — the recording is
/// created and mutated in one transaction and never crosses a shared-object
/// boundary — so plain `tx_context::dummy()` mechanics add nothing that
/// `sui::test_scenario` would strengthen. The production shape (a published,
/// shared `Recording` operated on across transaction boundaries by distinct
/// senders) is covered separately in `recording_master_e2e_tests`.
#[test_only]
module recording_master::recording_master_tests;

use musicos::recording;
use musicos::test_helpers;
use audio::audio::{Self, Audio};
use recording_master::recording_master as master_ext;
use std::unit_test::{assert_eq, destroy};
use sui::event;

// A recording's `RecordingShare` type uniquely identifies it, so
// `RecordingAdminCap<RecordingShare>` is bound to its recording by type and
// `recording::uid_mut` performs no runtime check. A wrong-cap test is therefore
// not expressible here — the call would fail to compile rather than abort.
public struct REC {}
public struct COMP {}
public struct OTHER_REC {}

fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(test_helpers::fake_id(ctx), ctx)
}

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    assert!(!master_ext::has_master(&rec));

    master_ext::set_master(
        &mut rec,
        &cap,
        new_audio(111),
    );
    assert!(master_ext::has_master(&rec));
    assert_eq!(master_ext::master(&rec).blob_id(), 111);
    assert_audio_metadata(master_ext::master(&rec));

    // Replacing points at the new blob — a recording has one master, not a list.
    master_ext::set_master(
        &mut rec,
        &cap,
        new_audio(222),
    );
    assert_eq!(master_ext::master(&rec).blob_id(), 222);
    assert_audio_metadata(master_ext::master(&rec));

    master_ext::unset_master(&mut rec, &cap);
    assert!(!master_ext::has_master(&rec));

    // Unset is idempotent.
    master_ext::unset_master(&mut rec, &cap);
    assert!(!master_ext::has_master(&rec));

    destroy(rec);
    destroy(cap);
}

#[test]
fun masters_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(test_helpers::fake_id(ctx), ctx);

    master_ext::set_master(
        &mut a,
        &a_cap,
        new_audio(9),
    );

    assert!(master_ext::has_master(&a));
    assert!(!master_ext::has_master(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

#[test]
fun set_emits_the_audio_and_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);
    let audio = new_audio(7);

    // Audio construction is a pure value operation; attaching it is the
    // canonical source of the master event.
    assert_eq!(sui::event::num_events(), 0);

    master_ext::set_master(&mut rec, &cap, audio);
    assert_eq!(sui::event::num_events(), 1);

    // The event is the indexer's whole feed: it must carry the audio
    // itself, not just a pointer back to the object.
    let events = event::events_by_type<master_ext::MasterSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, master) = master_ext::set_event_fields(&events[0]);
    assert_audio_metadata(&master);
    assert_eq!(id, rec_id);
    assert_eq!(master.blob_id(), 7);

    destroy(rec);
    destroy(cap);
}

#[test]
fun equal_master_assignment_is_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let audio = new_audio(17);

    master_ext::set_master(&mut rec, &cap, audio);
    assert_eq!(event::events_by_type<master_ext::MasterSetEvent>().length(), 1);
    master_ext::set_master(&mut rec, &cap, audio);
    assert_eq!(event::events_by_type<master_ext::MasterSetEvent>().length(), 1);
    assert_eq!(master_ext::master(&rec).blob_id(), 17);

    destroy(rec);
    destroy(cap);
}

#[test]
fun same_blob_with_changed_audio_metadata_emits() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let digest = vector[0x11u8, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11];
    let first = audio::new(
        b"flac".to_string(), 2, 24, 48000, 48000, digest,
        27,
    );
    let changed = audio::new(
        b"wav".to_string(), 1, 16, 44100, 88200, vector::tabulate!(32, |_| 0x22u8),
        27,
    );

    master_ext::set_master(&mut rec, &cap, first);
    assert_eq!(event::events_by_type<master_ext::MasterSetEvent>().length(), 1);
    master_ext::set_master(&mut rec, &cap, changed);
    let events = event::events_by_type<master_ext::MasterSetEvent>();
    assert_eq!(events.length(), 2);
    let (_, master) = master_ext::set_event_fields(&events[1]);
    assert_eq!(master.blob_id(), 27);
    assert_eq!(*audio::format(&master), b"wav".to_string());
    assert_eq!(master.channels(), 1);
    assert_eq!(master.bit_depth(), 16);
    assert_eq!(master.sample_rate_hz(), 44100);
    assert_eq!(master.samples(), 88200);
    assert_eq!(*master.pcm_digest(), vector::tabulate!(32, |_| 0x22u8));

    destroy(rec);
    destroy(cap);
}

#[test]
fun unset_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    // Nothing attached — a no-op must stay silent.
    master_ext::unset_master(&mut rec, &cap);
    assert_eq!(event::events_by_type<master_ext::MasterUnsetEvent>().length(), 0);

    master_ext::set_master(
        &mut rec,
        &cap,
        new_audio(5),
    );
    master_ext::unset_master(&mut rec, &cap);

    let events = event::events_by_type<master_ext::MasterUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(master_ext::unset_event_recording_id(&events[0]), rec_id);

    destroy(rec);
    destroy(cap);
}

/// Removing and reattaching a master works without leaving a stale value.
#[test]
fun unset_allows_reattaching_master() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    master_ext::set_master(
        &mut rec,
        &cap,
        new_audio(42),
    );
    master_ext::unset_master(&mut rec, &cap);

    assert!(!master_ext::has_master(&rec));

    // And re-attaching afterwards still works, so removal is not one-way.
    master_ext::set_master(
        &mut rec,
        &cap,
        new_audio(43),
    );
    assert_eq!(master_ext::master(&rec).blob_id(), 43);
    assert_audio_metadata(master_ext::master(&rec));

    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = master_ext::ENoMaster)]
fun master_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec(ctx);
    let _ = master_ext::master(&rec);
    destroy(rec);
    destroy(cap);
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
