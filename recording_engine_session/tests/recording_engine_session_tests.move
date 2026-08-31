// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_engine_session::recording_engine_session_tests;

use miso::recording;
use miso::test_helpers;
use ori::walrus_data;
use recording_engine_session::recording_engine_session as session;
use std::unit_test::{assert_eq, destroy};
use sui::event;

public struct REC {}
public struct COMP {}
public struct OTHER_REC {}

const ENotBlob: u64 = 0;
const EEngineSessionAlreadyAttached: u64 = 1;
const EEngineSessionMissing: u64 = 2;
const EEncryptedEngineSession: u64 = 3;

fun new_recording(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(test_helpers::fake_id(ctx), ctx)
}

#[test]
fun attach_replace_unset_lifecycle_is_explicit() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording);

    assert!(!session::has_engine_session(&recording));
    session::attach_engine_session(&mut recording, &cap, walrus_data::new_blob(11));
    assert_eq!(session::engine_session(&recording).reference().blob_id(), 11);

    session::replace_engine_session(&mut recording, &cap, walrus_data::new_blob(22));
    assert_eq!(session::engine_session(&recording).reference().blob_id(), 22);

    let attached = event::events_by_type<session::EngineSessionAttachedEvent>();
    let replaced = event::events_by_type<session::EngineSessionReplacedEvent>();
    assert_eq!(attached.length(), 1);
    assert_eq!(replaced.length(), 1);
    let (attached_id, attached_reference) = session::attached_event_fields(&attached[0]);
    let (replaced_id, replaced_reference) = session::replaced_event_fields(&replaced[0]);
    assert_eq!(attached_id, recording_id);
    assert_eq!(attached_reference.blob_id(), 11);
    assert_eq!(replaced_id, recording_id);
    assert_eq!(replaced_reference.blob_id(), 22);

    session::unset_engine_session(&mut recording, &cap);
    assert!(!session::has_engine_session(&recording));
    let unset = event::events_by_type<session::EngineSessionUnsetEvent>();
    assert_eq!(unset.length(), 1);
    assert_eq!(session::unset_event_recording_id(&unset[0]), recording_id);

    // Unset is idempotent and does not emit a fictional second mutation.
    session::unset_engine_session(&mut recording, &cap);
    assert_eq!(event::events_by_type<session::EngineSessionUnsetEvent>().length(), 1);

    destroy(recording);
    destroy(cap);
}

#[test]
fun sessions_are_scoped_to_their_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut first, first_cap) = new_recording(ctx);
    let (second, second_cap) = recording::new_for_testing<OTHER_REC, COMP>(
        test_helpers::fake_id(ctx),
        ctx,
    );

    session::attach_engine_session(&mut first, &first_cap, walrus_data::new_blob(7));
    assert!(session::has_engine_session(&first));
    assert!(!session::has_engine_session(&second));

    destroy(first);
    destroy(first_cap);
    destroy(second);
    destroy(second_cap);
}

#[test, expected_failure(abort_code = EEngineSessionAlreadyAttached, location = session)]
fun attach_rejects_an_occupied_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    session::attach_engine_session(&mut recording, &cap, walrus_data::new_blob(1));
    session::attach_engine_session(&mut recording, &cap, walrus_data::new_blob(2));
    abort
}

#[test, expected_failure(abort_code = EEngineSessionMissing, location = session)]
fun replace_rejects_an_empty_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    session::replace_engine_session(&mut recording, &cap, walrus_data::new_blob(1));
    abort
}

#[test, expected_failure(abort_code = EEngineSessionMissing, location = session)]
fun reading_an_empty_recording_aborts() {
    let ctx = &mut tx_context::dummy();
    let (recording, cap) = new_recording(ctx);
    let _ = session::engine_session(&recording);
    destroy(recording);
    destroy(cap);
}

#[test, expected_failure(abort_code = ENotBlob, location = ori::walrus_data)]
fun attach_rejects_a_quilt_patch() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    session::attach_engine_session(
        &mut recording,
        &cap,
        walrus_data::new_quilt_patch(1, 1, 0, 1),
    );
    abort
}

#[test, expected_failure(abort_code = EEncryptedEngineSession, location = session)]
fun attach_rejects_an_encrypted_outer_reference() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    session::attach_engine_session(
        &mut recording,
        &cap,
        walrus_data::new_encrypted_blob(1, b"dek"),
    );
    abort
}

#[test, expected_failure(abort_code = EEncryptedEngineSession, location = session)]
fun replace_rejects_an_encrypted_outer_reference() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    session::attach_engine_session(&mut recording, &cap, walrus_data::new_blob(1));
    session::replace_engine_session(
        &mut recording,
        &cap,
        walrus_data::new_encrypted_blob(2, b"dek"),
    );
    abort
}
