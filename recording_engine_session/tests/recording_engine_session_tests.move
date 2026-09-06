// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_engine_session::recording_engine_session_tests;

use miso::recording;
use miso::test_helpers;
use ori::{confidentiality, data};
use recording_engine_session::recording_engine_session as session;
use std::unit_test::{assert_eq, destroy};
use sui::event;

public struct REC {}
public struct COMP {}
public struct OTHER_REC {}

const MAX_U256: u256 =
    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

fun new_recording(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(test_helpers::fake_id(ctx), ctx)
}

fun new_session(blob_id: u256): session::EngineSession {
    session::new(data::new_blob(blob_id, confidentiality::new_unencrypted()))
}

fun blob_id(value: &session::EngineSession): u256 {
    session::data(value).blob_id()
}

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);

    assert!(!session::has_engine_session(&recording));

    session::set_engine_session(&mut recording, &cap, new_session(111));
    assert!(session::has_engine_session(&recording));
    assert_eq!(blob_id(session::engine_session(&recording)), 111);

    session::set_engine_session(&mut recording, &cap, new_session(222));
    assert_eq!(blob_id(session::engine_session(&recording)), 222);

    session::unset_engine_session(&mut recording, &cap);
    assert!(!session::has_engine_session(&recording));

    // Unset is idempotent.
    session::unset_engine_session(&mut recording, &cap);
    assert!(!session::has_engine_session(&recording));

    destroy(recording);
    destroy(cap);
}

#[test]
fun complete_u256_blob_id_domain_is_preserved() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);

    session::set_engine_session(&mut recording, &cap, new_session(MAX_U256));
    assert_eq!(blob_id(session::engine_session(&recording)), MAX_U256);

    destroy(recording);
    destroy(cap);
}

#[test, expected_failure(abort_code = session::EEncryptedEngineSession)]
fun encrypted_blob_is_rejected() {
    let _ = session::new(data::new_blob(
        333,
        confidentiality::new_encrypted(b"sealed-dek"),
    ));
}

#[test]
fun sessions_are_isolated_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_recording(ctx);
    let (b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(
        test_helpers::fake_id(ctx),
        ctx,
    );

    session::set_engine_session(&mut a, &a_cap, new_session(9));

    assert!(session::has_engine_session(&a));
    assert!(!session::has_engine_session(&b));

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test]
fun set_event_carries_recording_and_session() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording);

    session::set_engine_session(&mut recording, &cap, new_session(7));

    let events = event::events_by_type<session::EngineSessionSetEvent>();
    assert_eq!(events.length(), 1);
    let (event_recording_id, value) = session::set_event_fields(&events[0]);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(value, new_session(7));
    assert_eq!(blob_id(&value), 7);

    destroy(recording);
    destroy(cap);
}

#[test]
fun unset_event_is_emitted_only_after_removal() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording);

    session::unset_engine_session(&mut recording, &cap);
    assert_eq!(
        event::events_by_type<session::EngineSessionUnsetEvent>().length(),
        0,
    );

    session::set_engine_session(&mut recording, &cap, new_session(5));
    session::unset_engine_session(&mut recording, &cap);

    let events = event::events_by_type<session::EngineSessionUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(session::unset_event_recording_id(&events[0]), recording_id);

    destroy(recording);
    destroy(cap);
}

#[test, expected_failure(abort_code = session::ENoEngineSession)]
fun engine_session_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (recording, cap) = new_recording(ctx);
    let _ = session::engine_session(&recording);
    destroy(recording);
    destroy(cap);
}
