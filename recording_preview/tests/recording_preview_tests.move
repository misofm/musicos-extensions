// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit-level coverage in single-transaction `tx_context::dummy()` style: every
/// test here is pure set/replace/unset/read logic and event-payload assertion
/// against one already-owned `Recording` value — no shared-object mechanics,
/// no cross-actor authorization to prove, so `sui::test_scenario` transaction
/// boundaries would add nothing. The production shape (a *published and
/// shared* recording operated on across real transactions by distinct
/// senders) is covered separately in `recording_preview_e2e_tests.move`.
///
/// Also see that file's header for why there is no "wrong cap" adversarial
/// test anywhere in this package: `RecordingAdminCap<RecordingShare>` is bound
/// to its recording by type, and `recording::uid_mut` performs no runtime
/// check, so a genuine wrong-cap call is a compile error, not an abort.
#[test_only]
module recording_preview::recording_preview_tests;

use miso::recording;
use miso::test_helpers;
use ori::{confidentiality, data};
use recording_preview::recording_preview as rp;
use std::unit_test::{assert_eq, destroy};
use sui::event;

// Phantom marker types for the share parameters. A recording's
// `RecordingShare` type uniquely identifies it, so `RecordingAdminCap` is
// bound to its recording by type alone.
public struct REC {}
public struct COMP {}

/// Creates a fresh `Initialized` recording against a fabricated composition
/// id — this package never reads `composition_id`, so a real `Composition`
/// would add nothing here.
fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(test_helpers::fake_id(ctx), ctx)
}

#[test]
fun set_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, rec_cap) = new_rec(ctx);

    assert!(!rp::has_preview(&rec));

    rp::set_preview(
        &mut rec,
        &rec_cap,
        data::new_blob(1, confidentiality::new_unencrypted()),
    );
    assert!(rp::has_preview(&rec));
    assert_eq!(rp::preview(&rec).blob_id(), 1);

    // Setting again replaces the existing preview in place.
    rp::set_preview(
        &mut rec,
        &rec_cap,
        data::new_blob(2, confidentiality::new_unencrypted()),
    );
    assert_eq!(rp::preview(&rec).blob_id(), 2);

    rp::unset_preview(&mut rec, &rec_cap);
    assert!(!rp::has_preview(&rec));

    // Unset is idempotent.
    rp::unset_preview(&mut rec, &rec_cap);
    assert!(!rp::has_preview(&rec));

    destroy(rec);
    destroy(rec_cap);
}

#[test]
fun encrypted_blob_is_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, rec_cap) = new_rec(ctx);

    rp::set_preview(
        &mut rec,
        &rec_cap,
        data::new_blob(3, confidentiality::new_encrypted(b"dek")),
    );
    assert!(rp::preview(&rec).blob_confidentiality().is_encrypted());

    destroy(rec);
    destroy(rec_cap);
}

#[test]
fun set_emits_the_preview_and_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, rec_cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    rp::set_preview(
        &mut rec,
        &rec_cap,
        data::new_blob(1, confidentiality::new_unencrypted()),
    );

    let events = event::events_by_type<rp::PreviewSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, preview) = rp::set_event_fields(&events[0]);
    assert_eq!(id, rec_id);
    assert_eq!(preview.blob_id(), 1);
    assert!(!preview.blob_confidentiality().is_encrypted());

    // Replacing emits a fresh event carrying the new reference, not the old.
    rp::set_preview(
        &mut rec,
        &rec_cap,
        data::new_blob(3, confidentiality::new_encrypted(b"dek")),
    );

    let events = event::events_by_type<rp::PreviewSetEvent>();
    assert_eq!(events.length(), 2);
    let (id, preview) = rp::set_event_fields(&events[1]);
    assert_eq!(id, rec_id);
    assert_eq!(preview.blob_id(), 3);
    assert!(preview.blob_confidentiality().is_encrypted());
    assert_eq!(*preview.blob_confidentiality().sealed_dek(), b"dek");

    destroy(rec);
    destroy(rec_cap);
}

#[test]
fun unset_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, rec_cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    // Nothing attached — a no-op must stay silent rather than announce a change.
    rp::unset_preview(&mut rec, &rec_cap);
    assert_eq!(event::events_by_type<rp::PreviewUnsetEvent>().length(), 0);

    rp::set_preview(
        &mut rec,
        &rec_cap,
        data::new_blob(1, confidentiality::new_unencrypted()),
    );
    rp::unset_preview(&mut rec, &rec_cap);

    let events = event::events_by_type<rp::PreviewUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(rp::unset_event_recording_id(&events[0]), rec_id);

    destroy(rec);
    destroy(rec_cap);
}

#[test, expected_failure(abort_code = 1, location = recording_preview::recording_preview)]
fun preview_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rec, rec_cap) = new_rec(ctx);

    let _ = rp::preview(&rec);

    destroy(rec);
    destroy(rec_cap);
}
