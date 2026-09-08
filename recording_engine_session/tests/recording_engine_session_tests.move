// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_engine_session::recording_engine_session_tests;

use musicos::recording;
use musicos::test_helpers;
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

fun plain_blob(blob_id: u256): data::WalrusBlob {
    data::new_blob(blob_id, confidentiality::new_unencrypted())
}

/// A 32-byte digest whose first byte is `lead` and whose last byte is `tail`.
fun digest(lead: u8, tail: u8): vector<u8> {
    let mut bytes = vector[lead];
    let mut i = 1u64;
    while (i < 31) {
        bytes.push_back(0);
        i = i + 1;
    };
    bytes.push_back(tail);
    bytes
}

fun new_session(blob_id: u256): session::EngineSession {
    session::new(plain_blob(blob_id), vector[])
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
fun stems_are_stored_in_digest_order_with_their_blobs() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);

    let stems = vector[
        session::new_stem(digest(1, 0), plain_blob(10)),
        session::new_stem(digest(1, 1), plain_blob(11)),
        session::new_stem(digest(2, 0), plain_blob(20)),
    ];
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(1), stems),
    );

    let stored = session::stems(session::engine_session(&recording));
    assert_eq!(stored.length(), 3);
    assert_eq!(*session::stem_digest(&stored[0]), digest(1, 0));
    assert_eq!(session::stem_data(&stored[0]).blob_id(), 10);
    assert_eq!(*session::stem_digest(&stored[1]), digest(1, 1));
    assert_eq!(session::stem_data(&stored[1]).blob_id(), 11);
    assert_eq!(*session::stem_digest(&stored[2]), digest(2, 0));
    assert_eq!(session::stem_data(&stored[2]).blob_id(), 20);

    destroy(recording);
    destroy(cap);
}

#[test]
fun replacing_a_session_replaces_its_stems_atomically() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);

    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(1), vector[session::new_stem(digest(1, 0), plain_blob(10))]),
    );
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(
            plain_blob(2),
            vector[
                session::new_stem(digest(1, 0), plain_blob(10)),
                session::new_stem(digest(3, 0), plain_blob(30)),
            ],
        ),
    );

    let current = session::engine_session(&recording);
    assert_eq!(blob_id(current), 2);
    assert_eq!(session::stems(current).length(), 2);
    assert_eq!(session::stem_data(&session::stems(current)[1]).blob_id(), 30);

    destroy(recording);
    destroy(cap);
}

#[test]
fun complete_u256_blob_id_domain_is_preserved() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);

    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(
            plain_blob(MAX_U256),
            vector[session::new_stem(digest(0, 0), plain_blob(MAX_U256))],
        ),
    );
    let stored = session::engine_session(&recording);
    assert_eq!(blob_id(stored), MAX_U256);
    assert_eq!(session::stem_data(&session::stems(stored)[0]).blob_id(), MAX_U256);

    destroy(recording);
    destroy(cap);
}

#[test, expected_failure(abort_code = session::EEncryptedEngineSession)]
fun encrypted_session_blob_is_rejected() {
    let _ = session::new(
        data::new_blob(333, confidentiality::new_encrypted(b"sealed-dek")),
        vector[],
    );
}

#[test, expected_failure(abort_code = session::EEncryptedStem)]
fun encrypted_stem_blob_is_rejected() {
    let _ = session::new_stem(
        digest(0, 0),
        data::new_blob(333, confidentiality::new_encrypted(b"sealed-dek")),
    );
}

#[test, expected_failure(abort_code = session::EInvalidStemDigest)]
fun short_stem_digest_is_rejected() {
    let _ = session::new_stem(b"too-short", plain_blob(1));
}

#[test, expected_failure(abort_code = session::EInvalidStemDigest)]
fun long_stem_digest_is_rejected() {
    let mut bytes = digest(0, 0);
    bytes.push_back(0);
    let _ = session::new_stem(bytes, plain_blob(1));
}

#[test, expected_failure(abort_code = session::EUnsortedStems)]
fun unsorted_stems_are_rejected() {
    let _ = session::new(
        plain_blob(1),
        vector[
            session::new_stem(digest(2, 0), plain_blob(20)),
            session::new_stem(digest(1, 0), plain_blob(10)),
        ],
    );
}

#[test, expected_failure(abort_code = session::EUnsortedStems)]
fun stems_ordered_only_by_a_late_byte_must_still_be_sorted() {
    let _ = session::new(
        plain_blob(1),
        vector[
            session::new_stem(digest(1, 1), plain_blob(11)),
            session::new_stem(digest(1, 0), plain_blob(10)),
        ],
    );
}

#[test, expected_failure(abort_code = session::EUnsortedStems)]
fun duplicate_stem_digests_are_rejected() {
    let _ = session::new(
        plain_blob(1),
        vector[
            session::new_stem(digest(1, 0), plain_blob(10)),
            session::new_stem(digest(1, 0), plain_blob(11)),
        ],
    );
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
fun set_event_carries_recording_session_and_stems() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording);

    let value = session::new(
        plain_blob(7),
        vector[session::new_stem(digest(4, 4), plain_blob(44))],
    );
    session::set_engine_session(&mut recording, &cap, value);

    let events = event::events_by_type<session::EngineSessionSetEvent>();
    assert_eq!(events.length(), 1);
    let (event_recording_id, emitted) = session::set_event_fields(&events[0]);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(emitted, value);
    assert_eq!(blob_id(&emitted), 7);
    assert_eq!(session::stem_data(&session::stems(&emitted)[0]).blob_id(), 44);

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
