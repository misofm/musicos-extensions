// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_preview` against the production shape: a
/// `Recording` is published and shared first, and the extension operates on
/// it later, across real transaction boundaries and distinct senders —
/// `take_shared`/`return_shared` on the object itself, exactly as client PTBs
/// compose it, rather than a value the test still holds locally.
///
/// This package never touches the composition side of a recording, so a bare
/// id stands in for a real `Composition` — `recording::new_for_testing` only
/// needs a composition `ID`, not a live `Composition` object.
///
/// `sui::event::events_by_type` only surfaces events emitted in the *current*
/// scenario transaction, so every event assertion below runs immediately
/// after the call that emits it, before the next `ts.next_tx`.
///
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type, not
/// by a runtime id check (`recording::uid_mut` takes the cap as `_`). One
/// share currency is minted per recording in production, so a "wrong cap,
/// same type" scenario would be a compile error, not a runtime abort — there
/// is deliberately no such test here. The ADMIN/STRANGER split below proves
/// what the type system does not: writes require holding the cap, reads are
/// open to anyone.
#[test_only]
module recording_preview::recording_preview_e2e_tests;

use miso::recording::{Self, Recording};
use ori::{confidentiality, data};
use recording_preview::recording_preview as rp;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

public struct REC {}
public struct COMP {}

#[test]
fun admin_sets_replaces_and_unsets_a_preview_a_stranger_reads_it() {
    let mut ts = test_scenario::begin(ADMIN);

    // === Tx 1 (ADMIN): create and publish the recording — this shares it ===
    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec);
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock); // shares the recording
    clock.destroy_for_testing();

    // === Tx 2 (ADMIN): take the shared recording, attach a preview ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(!rp::has_preview(&rec));

    rp::set_preview(
        &mut rec,
        &rec_cap,
        data::new_blob(11, confidentiality::new_unencrypted()),
    );
    assert!(rp::has_preview(&rec));
    assert_eq!(rp::preview(&rec).blob_id(), 11);
    assert!(!rp::preview(&rec).blob_confidentiality().is_encrypted());

    let set_events = event::events_by_type<rp::PreviewSetEvent>();
    assert_eq!(set_events.length(), 1);
    let (event_id, event_preview) = rp::set_event_fields(&set_events[0]);
    assert_eq!(event_id, rec_id);
    assert_eq!(event_preview, data::new_blob(11, confidentiality::new_unencrypted()));

    test_scenario::return_shared(rec);

    // === Tx 3 (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(rp::has_preview(&rec));
    assert_eq!(rp::preview(&rec).blob_id(), 11);
    test_scenario::return_shared(rec);

    // === Tx 4 (ADMIN): replaces the preview with an encrypted one ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    rp::set_preview(
        &mut rec,
        &rec_cap,
        data::new_blob(22, confidentiality::new_encrypted(b"dek")),
    );
    assert!(rp::preview(&rec).blob_confidentiality().is_encrypted());
    assert_eq!(rp::preview(&rec).blob_id(), 22);
    assert_eq!(*rp::preview(&rec).blob_confidentiality().sealed_dek(), b"dek");

    let replace_events = event::events_by_type<rp::PreviewSetEvent>();
    assert_eq!(replace_events.length(), 1);
    let (replace_id, replace_preview) = rp::set_event_fields(&replace_events[0]);
    assert_eq!(replace_id, rec_id);
    assert_eq!(replace_preview, data::new_blob(22, confidentiality::new_encrypted(b"dek")));

    test_scenario::return_shared(rec);

    // === Tx 5 (ADMIN): unsets the preview ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    rp::unset_preview(&mut rec, &rec_cap);
    assert!(!rp::has_preview(&rec));

    let unset_events = event::events_by_type<rp::PreviewUnsetEvent>();
    assert_eq!(unset_events.length(), 1);
    assert_eq!(rp::unset_event_recording_id(&unset_events[0]), rec_id);

    test_scenario::return_shared(rec);

    // === Tx 6 (STRANGER): confirms removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(!rp::has_preview(&rec));
    test_scenario::return_shared(rec);

    destroy(rec_cap);
    ts.end();
}

/// Unset on a published, shared recording that never had a preview stays
/// silent — the no-op/idempotence behavior holds under scenario mechanics
/// too, not just against a locally-held value.
#[test]
fun unset_on_a_shared_recording_without_a_preview_is_silent() {
    let mut ts = test_scenario::begin(ADMIN);

    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    rp::unset_preview(&mut rec, &rec_cap);
    assert!(!rp::has_preview(&rec));
    assert_eq!(event::events_by_type<rp::PreviewUnsetEvent>().length(), 0);

    test_scenario::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}

/// Operate-after-remove: reading a preview after it has been explicitly
/// removed aborts exactly like a recording that never had one — absence is
/// absence, regardless of history. Exercised across scenario boundaries and
/// a non-admin reader to match the production shape.
#[test, expected_failure(abort_code = rp::ENoPreview)]
fun reading_after_remove_aborts_for_any_reader() {
    let mut ts = test_scenario::begin(ADMIN);

    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    rp::set_preview(
        &mut rec,
        &rec_cap,
        data::new_blob(1, confidentiality::new_unencrypted()),
    );
    rp::unset_preview(&mut rec, &rec_cap);
    test_scenario::return_shared(rec);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    let _ = rp::preview(&rec); // aborts: ENoPreview

    test_scenario::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}
