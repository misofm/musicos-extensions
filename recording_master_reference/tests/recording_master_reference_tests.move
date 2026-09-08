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

    assert!(!mref::has_master_reference(&rec));

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(111, confidentiality::new_unencrypted()),
    );
    assert!(mref::has_master_reference(&rec));
    assert_eq!(mref::master_reference(&rec).blob_id(), 111);

    // Replacing points at the new blob — a recording has one master, not a list.
    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(222, confidentiality::new_unencrypted()),
    );
    assert_eq!(mref::master_reference(&rec).blob_id(), 222);

    mref::unset_master_reference(&mut rec, &cap);
    assert!(!mref::has_master_reference(&rec));

    // Unset is idempotent.
    mref::unset_master_reference(&mut rec, &cap);
    assert!(!mref::has_master_reference(&rec));

    destroy(rec);
    destroy(cap);
}

/// A sealed master is the expected shape once access control lands, and the
/// reference must carry it unchanged.
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
    let (b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(test_helpers::fake_id(ctx), ctx);

    mref::set_master_reference(
        &mut a,
        &a_cap,
        data::new_blob(9, confidentiality::new_unencrypted()),
    );

    assert!(mref::has_master_reference(&a));
    assert!(!mref::has_master_reference(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
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

    // The event is the indexer's whole feed: it must carry the reference
    // itself, not just a pointer back to the object.
    let events = event::events_by_type<mref::MasterReferenceSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, reference) = mref::set_event_fields(&events[0]);
    assert_eq!(id, rec_id);
    assert_eq!(reference, data::new_blob(7, confidentiality::new_unencrypted()));

    destroy(rec);
    destroy(cap);
}

/// An encrypted reference's sealed DEK is part of the record an indexer
/// stores, so the event must carry it through unchanged.
#[test]
fun set_emits_an_encrypted_reference_with_its_dek() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(8, confidentiality::new_encrypted(b"dek")),
    );

    let events = event::events_by_type<mref::MasterReferenceSetEvent>();
    assert_eq!(events.length(), 1);
    let (_, reference) = mref::set_event_fields(&events[0]);
    assert!(reference.blob_confidentiality().is_encrypted());
    assert_eq!(reference.blob_id(), 8);
    assert_eq!(*reference.blob_confidentiality().sealed_dek(), b"dek");

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
    assert_eq!(event::events_by_type<mref::MasterReferenceUnsetEvent>().length(), 0);

    mref::set_master_reference(
        &mut rec,
        &cap,
        data::new_blob(5, confidentiality::new_unencrypted()),
    );
    mref::unset_master_reference(&mut rec, &cap);

    let events = event::events_by_type<mref::MasterReferenceUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(mref::unset_event_recording_id(&events[0]), rec_id);

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
