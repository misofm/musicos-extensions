// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Constructor validation and set/read/replace/clear mechanics against a bare
/// `Recording`. Nothing here crosses a transaction boundary, so
/// `tx_context::dummy()` suffices; the published, shared shape is covered in
/// `recording_engine_session_e2e_tests`.
#[test_only]
module recording_engine_session::recording_engine_session_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_engine_session::recording_engine_session::{
    Self as session,
    EngineSession,
    RecordingEngineSessionSetEvent,
    RecordingEngineSessionClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;

public struct REC {}
public struct OTHER_REC {}

const MAX_U256: u256 =
    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

/// Only a `Recording` is needed, so a bare id stands in for its composition.
fun new_rec<RecordingShare>(
    ctx: &mut TxContext,
): (Recording<RecordingShare>, RecordingAdminCap<RecordingShare>) {
    recording::new_for_testing<RecordingShare>(object::id_from_address(@0xC0FFEE), ctx)
}

/// A 32-byte digest whose first byte is `lead` and whose last byte is `tail`.
fun digest(lead: u8, tail: u8): vector<u8> {
    let mut bytes = vector[lead];
    30u64.do!(|_| bytes.push_back(0));
    bytes.push_back(tail);
    bytes
}

/// A session with `count` stems in digest order, each on its own blob.
fun session_with_stems(count: u64): EngineSession {
    let stems = vector::tabulate!(count, |i| session::new_stem(digest(i as u8, 0), 1000 + (i as u256)));
    session::new(2000 + (count as u256), stems)
}

fun new_session(blob_id: u256): EngineSession {
    session::new(blob_id, vector[])
}

fun blob_id(value: &EngineSession): u256 {
    session::blob_id(value)
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    assert!(!session::has_engine_session(&rec));

    session::set_engine_session(&mut rec, &cap, new_session(111));
    assert!(session::has_engine_session(&rec));
    assert_eq!(blob_id(session::engine_session(&rec)), 111);

    session::set_engine_session(&mut rec, &cap, new_session(222));
    assert_eq!(blob_id(session::engine_session(&rec)), 222);

    session::clear_engine_session(&mut rec, &cap);
    assert!(!session::has_engine_session(&rec));

    // Clear is idempotent.
    session::clear_engine_session(&mut rec, &cap);
    assert!(!session::has_engine_session(&rec));

    destroy(rec);
    destroy(cap);
}

#[test]
fun stems_are_stored_in_digest_order_with_their_blobs() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    let stems = vector[
        session::new_stem(digest(1, 0), 10),
        session::new_stem(digest(1, 1), 11),
        session::new_stem(digest(2, 0), 20),
    ];
    session::set_engine_session(&mut rec, &cap, session::new(1, stems));

    let stored = session::stems(session::engine_session(&rec));
    assert_eq!(stored.length(), 3);
    assert_eq!(*session::stem_digest(&stored[0]), digest(1, 0));
    assert_eq!(session::stem_blob_id(&stored[0]), 10);
    assert_eq!(*session::stem_digest(&stored[1]), digest(1, 1));
    assert_eq!(session::stem_blob_id(&stored[1]), 11);
    assert_eq!(*session::stem_digest(&stored[2]), digest(2, 0));
    assert_eq!(session::stem_blob_id(&stored[2]), 20);

    destroy(rec);
    destroy(cap);
}

#[test]
fun replacing_a_session_replaces_its_stems_atomically() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(1, vector[session::new_stem(digest(1, 0), 10)]),
    );
    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(
            2,
            vector[
                session::new_stem(digest(1, 0), 10),
                session::new_stem(digest(3, 0), 30),
            ],
        ),
    );

    let current = session::engine_session(&rec);
    assert_eq!(blob_id(current), 2);
    assert_eq!(session::stems(current).length(), 2);
    assert_eq!(session::stem_blob_id(&session::stems(current)[1]), 30);

    destroy(rec);
    destroy(cap);
}

#[test]
fun complete_u256_blob_id_domain_is_preserved() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(MAX_U256, vector[session::new_stem(digest(0, 0), MAX_U256)]),
    );
    let stored = session::engine_session(&rec);
    assert_eq!(blob_id(stored), MAX_U256);
    assert_eq!(session::stem_blob_id(&session::stems(stored)[0]), MAX_U256);

    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = session::EInvalidStemDigest)]
fun short_stem_digest_is_rejected() {
    let _ = session::new_stem(b"too-short", 1);
}

#[test, expected_failure(abort_code = session::EInvalidStemDigest)]
fun long_stem_digest_is_rejected() {
    let mut bytes = digest(0, 0);
    bytes.push_back(0);
    let _ = session::new_stem(bytes, 1);
}

#[test, expected_failure(abort_code = session::EUnsortedStems)]
fun unsorted_stems_are_rejected() {
    let _ = session::new(
        1,
        vector[
            session::new_stem(digest(2, 0), 20),
            session::new_stem(digest(1, 0), 10),
        ],
    );
}

#[test, expected_failure(abort_code = session::EUnsortedStems)]
fun stems_ordered_only_by_a_late_byte_must_still_be_sorted() {
    let _ = session::new(
        1,
        vector[
            session::new_stem(digest(1, 1), 11),
            session::new_stem(digest(1, 0), 10),
        ],
    );
}

#[test, expected_failure(abort_code = session::EUnsortedStems)]
fun duplicate_stem_digests_are_rejected() {
    let _ = session::new(
        1,
        vector[
            session::new_stem(digest(1, 0), 10),
            session::new_stem(digest(1, 0), 11),
        ],
    );
}

#[test]
fun sessions_are_isolated_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec<REC>(ctx);
    let (b, b_cap) = new_rec<OTHER_REC>(ctx);

    session::set_engine_session(&mut a, &a_cap, new_session(9));

    assert!(session::has_engine_session(&a));
    assert!(!session::has_engine_session(&b));

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

/// The set event carries the recording and the session document's blob ID;
/// stems stay in storage.
#[test]
fun set_event_carries_recording_and_session_blob() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec).to_address();

    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(7, vector[session::new_stem(digest(4, 4), 44)]),
    );

    let events = events_by_type<RecordingEngineSessionSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, event_blob_id) = session::set_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_blob_id, 7);
    assert_eq!(to_bytes(&events[0]).length(), 64);

    destroy(rec);
    destroy(cap);
}

#[test]
fun clear_event_is_emitted_only_after_removal() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec).to_address();

    session::clear_engine_session(&mut rec, &cap);
    assert_eq!(events_by_type<RecordingEngineSessionClearedEvent<REC>>().length(), 0);

    session::set_engine_session(&mut rec, &cap, new_session(5));
    session::clear_engine_session(&mut rec, &cap);

    let events = events_by_type<RecordingEngineSessionClearedEvent<REC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(session::cleared_event_fields(&events[0]), rec_id);
    assert_eq!(to_bytes(&events[0]).length(), 32);

    session::clear_engine_session(&mut rec, &cap);
    assert_eq!(events_by_type<RecordingEngineSessionClearedEvent<REC>>().length(), 1);

    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = session::ENoEngineSession)]
fun engine_session_aborts_when_absent() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec<REC>(ctx);
    let _ = session::engine_session(&rec);
    destroy(rec);
    destroy(cap);
}

/// Equality is over the whole value, stem vectors included.
#[test]
fun equal_set_neither_writes_nor_emits() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(10, vector[session::new_stem(digest(1, 0), 20)]),
    );
    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(10, vector[session::new_stem(digest(1, 0), 20)]),
    );

    let events = events_by_type<RecordingEngineSessionSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(session::stems(session::engine_session(&rec)).length(), 1);

    destroy(rec);
    destroy(cap);
}

/// A change to the session blob, a stem digest, or a stem blob each emits; a
/// stem-only change repeats the unchanged session blob ID, telling the
/// indexer to re-read the stems.
#[test]
fun every_component_change_emits() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(10, vector[session::new_stem(digest(1, 0), 20)]),
    );
    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(11, vector[session::new_stem(digest(1, 0), 20)]),
    );
    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(11, vector[session::new_stem(digest(2, 0), 20)]),
    );
    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(11, vector[session::new_stem(digest(2, 0), 21)]),
    );

    let events = events_by_type<RecordingEngineSessionSetEvent<REC>>();
    assert_eq!(events.length(), 4);
    let expected_blob_ids = vector[10u256, 11, 11, 11];
    4u64.do!(|i| {
        let (_, event_blob_id) = session::set_event_fields(&events[i]);
        assert_eq!(event_blob_id, expected_blob_ids[i]);
    });
    assert_eq!(session::stem_blob_id(&session::stems(session::engine_session(&rec))[0]), 21);

    destroy(rec);
    destroy(cap);
}

#[test]
fun same_stem_blob_id_is_preserved_for_repeated_sources() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(
            9,
            vector[
                session::new_stem(digest(1, 0), 99),
                session::new_stem(digest(2, 0), 99),
            ],
        ),
    );

    let events = events_by_type<RecordingEngineSessionSetEvent<REC>>();
    let (_, event_blob_id) = session::set_event_fields(&events[0]);
    assert_eq!(event_blob_id, 9);
    let stems = session::stems(session::engine_session(&rec));
    assert_eq!(stems.length(), 2);
    assert_eq!(session::stem_blob_id(&stems[0]), 99);
    assert_eq!(session::stem_blob_id(&stems[1]), 99);

    destroy(rec);
    destroy(cap);
}

#[test]
fun clear_after_replacement_removes_the_latest_value() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(100, vector[session::new_stem(digest(1, 0), 10)]),
    );
    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(
            200,
            vector[
                session::new_stem(digest(1, 0), 10),
                session::new_stem(digest(2, 0), 20),
            ],
        ),
    );
    session::clear_engine_session(&mut rec, &cap);

    assert!(!session::has_engine_session(&rec));
    assert_eq!(events_by_type<RecordingEngineSessionSetEvent<REC>>().length(), 2);
    assert_eq!(events_by_type<RecordingEngineSessionClearedEvent<REC>>().length(), 1);

    destroy(rec);
    destroy(cap);
}

#[test]
fun zero_and_maximum_u256_blob_ids_are_event_exact() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(0, vector[session::new_stem(digest(0, 0), 0)]),
    );
    session::set_engine_session(
        &mut rec,
        &cap,
        session::new(MAX_U256, vector[session::new_stem(digest(1, 0), MAX_U256)]),
    );

    let events = events_by_type<RecordingEngineSessionSetEvent<REC>>();
    let (_, first) = session::set_event_fields(&events[0]);
    let (_, second) = session::set_event_fields(&events[1]);
    assert_eq!(first, 0);
    assert_eq!(second, MAX_U256);
    // The blob ID is the trailing 32 little-endian bytes.
    let bytes = to_bytes(&events[1]);
    assert_eq!(bytes.length(), 64);
    32u64.do!(|i| assert_eq!(bytes[32 + i], 0xff));

    destroy(rec);
    destroy(cap);
}

#[test]
fun constructors_and_views_are_silent() {
    let stem = session::new_stem(digest(3, 4), 8);
    let value = session::new(7, vector[stem]);
    assert_eq!(session::blob_id(&value), 7);
    assert_eq!(session::stems(&value).length(), 1);
    assert_eq!(*session::stem_digest(&session::stems(&value)[0]), digest(3, 4));
    assert_eq!(session::stem_blob_id(&session::stems(&value)[0]), 8);
    assert_eq!(events_by_type<RecordingEngineSessionSetEvent<REC>>().length(), 0);
    assert_eq!(events_by_type<RecordingEngineSessionClearedEvent<REC>>().length(), 0);
}

/// `recording::uid_mut` matches the cap by type only. Two recordings of one
/// share type exist only under `new_for_testing`, so this documents the trust
/// model rather than a reachable production path.
#[test]
fun cap_is_matched_by_type_only() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, own_cap) = new_rec<REC>(ctx);
    let (foreign_rec, foreign_cap) = new_rec<REC>(ctx);

    session::set_engine_session(&mut rec, &foreign_cap, new_session(55));
    assert_eq!(blob_id(session::engine_session(&rec)), 55);
    assert!(!session::has_engine_session(&foreign_rec));

    destroy(rec);
    destroy(own_cap);
    destroy(foreign_rec);
    destroy(foreign_cap);
}

#[test]
fun event_streams_are_partitioned_by_recording_share_type() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec<REC>(ctx);
    let (mut b, b_cap) = new_rec<OTHER_REC>(ctx);

    session::set_engine_session(&mut a, &a_cap, new_session(1));
    session::set_engine_session(&mut b, &b_cap, new_session(2));

    let a_events = events_by_type<RecordingEngineSessionSetEvent<REC>>();
    let b_events = events_by_type<RecordingEngineSessionSetEvent<OTHER_REC>>();
    assert_eq!(a_events.length(), 1);
    assert_eq!(b_events.length(), 1);
    let (a_id, a_blob) = session::set_event_fields(&a_events[0]);
    let (b_id, b_blob) = session::set_event_fields(&b_events[0]);
    assert_eq!(a_id, object::id(&a).to_address());
    assert_eq!(a_blob, 1);
    assert_eq!(b_id, object::id(&b).to_address());
    assert_eq!(b_blob, 2);

    session::clear_engine_session(&mut a, &a_cap);
    assert_eq!(events_by_type<RecordingEngineSessionClearedEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingEngineSessionClearedEvent<OTHER_REC>>().length(), 0);

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

/// Stems are excluded from events, so payload size does not grow with them.
#[test]
fun event_size_is_independent_of_zero_one_and_large_stem_vectors() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let counts = vector[0u64, 1, 127, 128];

    counts.do!(|count| session::set_engine_session(&mut rec, &cap, session_with_stems(count)));
    let set_events = events_by_type<RecordingEngineSessionSetEvent<REC>>();
    assert_eq!(set_events.length(), 4);
    set_events.do_ref!(|e| assert_eq!(to_bytes(e).length(), 64));
    assert_eq!(session::stems(session::engine_session(&rec)).length(), 128);

    session::clear_engine_session(&mut rec, &cap);
    let cleared = events_by_type<RecordingEngineSessionClearedEvent<REC>>();
    assert_eq!(to_bytes(&cleared[0]).length(), 32);

    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = session::EInvalidStemDigest)]
fun invalid_stem_digest_is_rejected_before_session_use() {
    let _ = session::new_stem(b"short", 1);
}

#[test, expected_failure(abort_code = session::EUnsortedStems)]
fun unsorted_session_stems_are_rejected() {
    let _ = session::new(
        1,
        vector[
            session::new_stem(digest(2, 0), 2),
            session::new_stem(digest(1, 0), 1),
        ],
    );
}
