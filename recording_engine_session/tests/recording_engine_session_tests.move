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
public struct OTHER_COMP {}

const MAX_U256: u256 =
    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

fun new_recording(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    let composition_id = test_helpers::fake_id(ctx);
    new_recording_with_composition(ctx, composition_id)
}

fun new_recording_with_composition(
    ctx: &mut TxContext,
    composition_id: ID,
): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(composition_id, ctx)
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

fun digest_for_index(index: u64): vector<u8> {
    let mut lead = 0u8;
    let mut i = 0;
    while (i < index) {
        lead = lead + 1;
        i = i + 1;
    };
    digest(lead, 0)
}

fun blob_for_index(index: u64): u256 {
    let mut value = 1000u256;
    let mut i = 0;
    while (i < index) {
        value = value + 1;
        i = i + 1;
    };
    value
}

fun session_with_stems(count: u64): session::EngineSession {
    let mut stems = vector[];
    let mut i = 0;
    while (i < count) {
        stems.push_back(session::new_stem(digest_for_index(i), plain_blob(blob_for_index(i))));
        i = i + 1;
    };
    session::new(plain_blob(blob_for_index(count + 1000)), stems)
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
    let composition_id = test_helpers::fake_id(ctx);
    let (mut recording, cap) = new_recording_with_composition(ctx, composition_id);
    let recording_id = object::id(&recording);
    let admin_cap_id = object::id(&cap);
    let stem_digest = digest(4, 4);

    let value = session::new(
        plain_blob(7),
        vector[session::new_stem(stem_digest, plain_blob(44))],
    );
    session::set_engine_session(&mut recording, &cap, value);

    let events = event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_recording_id, event_composition_id, event_admin_cap_id, had_previous,
        value_changed, previous_blob_id, previous_stem_count, event_blob_id, stem_count,
        stem_digests, stem_blob_ids) = session::set_event_fields(&events[0]);
    assert_eq!(event_recording_id, recording_id.to_address());
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_admin_cap_id, admin_cap_id.to_address());
    assert!(!had_previous);
    assert!(value_changed);
    assert_eq!(previous_blob_id, 0);
    assert_eq!(previous_stem_count, 0);
    assert_eq!(event_blob_id, 7);
    assert_eq!(stem_count, 1);
    assert_eq!(stem_digests, vector[stem_digest]);
    assert_eq!(stem_blob_ids, vector[44]);

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
        event::events_by_type<session::EngineSessionUnsetEvent<REC, COMP>>().length(),
        0,
    );

    session::set_engine_session(&mut recording, &cap, new_session(5));
    session::unset_engine_session(&mut recording, &cap);

    let events = event::events_by_type<session::EngineSessionUnsetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_recording_id, event_composition_id, event_admin_cap_id, removed_blob_id,
        removed_stem_count, removed_digests, removed_blob_ids) =
        session::unset_event_fields(&events[0]);
    assert_eq!(event_recording_id, recording_id.to_address());
    assert_eq!(event_composition_id, recording::composition_id(&recording).to_address());
    assert_eq!(event_admin_cap_id, object::id(&cap).to_address());
    assert_eq!(removed_blob_id, 5);
    assert_eq!(removed_stem_count, 0);
    assert_eq!(removed_digests, vector[]);
    assert_eq!(removed_blob_ids, vector[]);

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

#[test]
fun set_events_report_insert_equal_and_each_component_change() {
    let ctx = &mut tx_context::dummy();
    let composition_id = test_helpers::fake_id(ctx);
    let (mut recording, cap) = new_recording_with_composition(ctx, composition_id);
    let recording_id = object::id(&recording).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let first_digest = digest(1, 0);

    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(10), vector[session::new_stem(first_digest, plain_blob(20))]),
    );
    // Full equality, including stem vectors, reports false on replacement.
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(10), vector[session::new_stem(first_digest, plain_blob(20))]),
    );
    let events = event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 2);
    let (event_recording_id, event_composition_id, event_admin_cap_id, had_previous,
        value_changed, previous_blob_id, previous_stem_count, current_blob_id, stem_count,
        stem_digests, stem_blob_ids) = session::set_event_fields(&events[0]);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_admin_cap_id, admin_cap_id);
    assert!(!had_previous);
    assert!(value_changed);
    assert_eq!(previous_blob_id, 0);
    assert_eq!(previous_stem_count, 0);
    assert_eq!(current_blob_id, 10);
    assert_eq!(stem_count, 1);
    assert_eq!(stem_digests, vector[first_digest]);
    assert_eq!(stem_blob_ids, vector[20]);

    let (_, _, _, had_previous, value_changed, previous_blob_id, previous_stem_count,
        current_blob_id, stem_count, stem_digests, stem_blob_ids) =
        session::set_event_fields(&events[1]);
    assert!(had_previous);
    assert!(!value_changed);
    assert_eq!(previous_blob_id, 10);
    assert_eq!(previous_stem_count, 1);
    assert_eq!(current_blob_id, 10);
    assert_eq!(stem_count, 1);
    assert_eq!(stem_digests, vector[first_digest]);
    assert_eq!(stem_blob_ids, vector[20]);

    destroy(recording);
    destroy(cap);
}

#[test]
fun set_events_report_changes_to_blob_digest_and_stem_blob() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let first_digest = digest(1, 0);
    let second_digest = digest(2, 0);
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(10), vector[session::new_stem(first_digest, plain_blob(20))]),
    );
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(11), vector[session::new_stem(first_digest, plain_blob(20))]),
    );
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(11), vector[session::new_stem(second_digest, plain_blob(20))]),
    );
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(11), vector[session::new_stem(second_digest, plain_blob(21))]),
    );
    let events = event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 4);
    let (_, _, _, had_previous, value_changed, previous_blob_id, previous_stem_count,
        current_blob_id, _, stem_digests, stem_blob_ids) = session::set_event_fields(&events[1]);
    assert!(had_previous);
    assert!(value_changed);
    assert_eq!(previous_blob_id, 10);
    assert_eq!(previous_stem_count, 1);
    assert_eq!(current_blob_id, 11);
    assert_eq!(stem_digests, vector[first_digest]);
    assert_eq!(stem_blob_ids, vector[20]);
    let (_, _, _, had_previous, value_changed, previous_blob_id, previous_stem_count,
        current_blob_id, _, stem_digests, stem_blob_ids) = session::set_event_fields(&events[2]);
    assert!(had_previous);
    assert!(value_changed);
    assert_eq!(previous_blob_id, 11);
    assert_eq!(previous_stem_count, 1);
    assert_eq!(current_blob_id, 11);
    assert_eq!(stem_digests, vector[second_digest]);
    assert_eq!(stem_blob_ids, vector[20]);
    let (_, _, _, had_previous, value_changed, previous_blob_id, previous_stem_count,
        current_blob_id, _, stem_digests, stem_blob_ids) = session::set_event_fields(&events[3]);
    assert!(had_previous);
    assert!(value_changed);
    assert_eq!(previous_blob_id, 11);
    assert_eq!(previous_stem_count, 1);
    assert_eq!(current_blob_id, 11);
    assert_eq!(stem_digests, vector[second_digest]);
    assert_eq!(stem_blob_ids, vector[21]);
    destroy(recording);
    destroy(cap);
}

#[test]
fun same_stem_blob_id_is_preserved_for_repeated_sources() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let first_digest = digest(1, 0);
    let second_digest = digest(2, 0);
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(
            plain_blob(9),
            vector[
                session::new_stem(first_digest, plain_blob(99)),
                session::new_stem(second_digest, plain_blob(99)),
            ],
        ),
    );
    let events = event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>();
    let (_, _, _, _, _, _, _, blob, count, digests, blob_ids) =
        session::set_event_fields(&events[0]);
    assert_eq!(blob, 9);
    assert_eq!(count, 2);
    assert_eq!(digests, vector[first_digest, second_digest]);
    assert_eq!(blob_ids, vector[99, 99]);
    assert_eq!(session::stems(session::engine_session(&recording)).length(), 2);
    destroy(recording);
    destroy(cap);
}

#[test]
fun unset_event_snapshots_the_latest_value() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let first_digest = digest(1, 0);
    let second_digest = digest(2, 0);
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(100), vector[session::new_stem(first_digest, plain_blob(10))]),
    );
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(
            plain_blob(200),
            vector[
                session::new_stem(first_digest, plain_blob(10)),
                session::new_stem(second_digest, plain_blob(20)),
            ],
        ),
    );
    session::unset_engine_session(&mut recording, &cap);
    assert!(!session::has_engine_session(&recording));
    let events = event::events_by_type<session::EngineSessionUnsetEvent<REC, COMP>>();
    let (_, _, _, blob, count, digests, blob_ids) = session::unset_event_fields(&events[0]);
    assert_eq!(blob, 200);
    assert_eq!(count, 2);
    assert_eq!(digests, vector[first_digest, second_digest]);
    assert_eq!(blob_ids, vector[10, 20]);
    destroy(recording);
    destroy(cap);
}

#[test]
fun zero_and_maximum_u256_blob_ids_are_event_exact() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(0), vector[session::new_stem(digest(0, 0), plain_blob(0))]),
    );
    session::set_engine_session(
        &mut recording,
        &cap,
        session::new(plain_blob(MAX_U256), vector[session::new_stem(digest(1, 0), plain_blob(MAX_U256))]),
    );
    let events = event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>();
    let (_, _, _, _, _, previous_blob_id, _, current_blob_id, _, _, blob_ids) =
        session::set_event_fields(&events[1]);
    assert_eq!(previous_blob_id, 0);
    assert_eq!(current_blob_id, MAX_U256);
    assert_eq!(blob_ids, vector[MAX_U256]);
    destroy(recording);
    destroy(cap);
}

#[test]
fun constructors_and_views_are_silent() {
    let stem_digest = digest(3, 4);
    let stem = session::new_stem(stem_digest, plain_blob(8));
    let value = session::new(plain_blob(7), vector[stem]);
    assert_eq!(session::data(&value).blob_id(), 7);
    assert_eq!(session::stems(&value).length(), 1);
    assert_eq!(*session::stem_digest(&session::stems(&value)[0]), stem_digest);
    assert_eq!(session::stem_data(&session::stems(&value)[0]).blob_id(), 8);
    assert_eq!(event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<session::EngineSessionUnsetEvent<REC, COMP>>().length(), 0);
}

#[test]
fun same_share_foreign_cap_is_observationally_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, own_cap) = new_recording(ctx);
    let (foreign_recording, foreign_cap) = new_recording(ctx);
    let foreign_cap_id = object::id(&foreign_cap).to_address();
    session::set_engine_session(&mut recording, &foreign_cap, new_session(55));
    assert_eq!(blob_id(session::engine_session(&recording)), 55);
    let events = event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>();
    let (_, _, admin_cap_id, _, _, _, _, _, _, _, _) = session::set_event_fields(&events[0]);
    assert_eq!(admin_cap_id, foreign_cap_id);
    destroy(recording);
    destroy(own_cap);
    destroy(foreign_recording);
    destroy(foreign_cap);
}

#[test]
fun independent_phantom_dimensions_have_independent_event_streams() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let (mut other_recording, other_cap) =
        recording::new_for_testing<REC, OTHER_COMP>(test_helpers::fake_id(ctx), ctx);
    session::set_engine_session(&mut recording, &cap, new_session(1));
    session::set_engine_session(&mut other_recording, &other_cap, new_session(2));
    assert_eq!(event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<session::EngineSessionSetEvent<REC, OTHER_COMP>>().length(), 1);
    destroy(recording);
    destroy(cap);
    destroy(other_recording);
    destroy(other_cap);
}

#[test]
fun bcs_sizes_match_zero_one_and_large_stem_vectors() {
    let ctx = &mut tx_context::dummy();
    let (mut r0, c0) = new_recording(ctx);
    let (mut r1, c1) = new_recording(ctx);
    let (mut r127, c127) = new_recording(ctx);
    let (mut r128, c128) = new_recording(ctx);
    session::set_engine_session(&mut r0, &c0, session_with_stems(0));
    session::set_engine_session(&mut r1, &c1, session_with_stems(1));
    session::set_engine_session(&mut r127, &c127, session_with_stems(127));
    session::set_engine_session(&mut r128, &c128, session_with_stems(128));
    let set_events = event::events_by_type<session::EngineSessionSetEvent<REC, COMP>>();
    assert_eq!(session::set_event_bcs(&set_events[0]).length(), 180);
    assert_eq!(session::set_event_bcs(&set_events[1]).length(), 245);
    assert_eq!(session::set_event_bcs(&set_events[2]).length(), 8435);
    assert_eq!(session::set_event_bcs(&set_events[3]).length(), 8502);

    session::unset_engine_session(&mut r0, &c0);
    session::unset_engine_session(&mut r1, &c1);
    session::unset_engine_session(&mut r127, &c127);
    session::unset_engine_session(&mut r128, &c128);
    let unset_events = event::events_by_type<session::EngineSessionUnsetEvent<REC, COMP>>();
    assert_eq!(session::unset_event_bcs(&unset_events[0]).length(), 138);
    assert_eq!(session::unset_event_bcs(&unset_events[1]).length(), 203);
    assert_eq!(session::unset_event_bcs(&unset_events[2]).length(), 8393);
    assert_eq!(session::unset_event_bcs(&unset_events[3]).length(), 8460);
    destroy(r0); destroy(c0); destroy(r1); destroy(c1);
    destroy(r127); destroy(c127); destroy(r128); destroy(c128);
}

#[test, expected_failure(abort_code = session::EInvalidStemDigest)]
fun invalid_digest_precedes_encrypted_stem_guard() {
    let _ = session::new_stem(
        b"short",
        data::new_blob(1, confidentiality::new_encrypted(b"dek")),
    );
}

#[test, expected_failure(abort_code = session::EEncryptedEngineSession)]
fun encrypted_session_precedes_unsorted_stem_guard() {
    let _ = session::new(
        data::new_blob(1, confidentiality::new_encrypted(b"dek")),
        vector[
            session::new_stem(digest(2, 0), plain_blob(2)),
            session::new_stem(digest(1, 0), plain_blob(1)),
        ],
    );
}
