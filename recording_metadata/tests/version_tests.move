// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary and abort-path tests for the version attribute, kept in
/// single-transaction `tx_context::dummy()` style: every case here holds its
/// `Recording`/`RecordingAdminCap` pair locally, with no shared object and no
/// ownership handoff between transactions — the property under test is the
/// assertion or event payload itself (emptiness, byte bounds, exact storage),
/// not transaction-boundary mechanics. The production shape — a published,
/// shared `Recording` operated on by distinct senders via `take_shared` — is
/// covered in `version_e2e_tests`.
///
/// A mismatched `RecordingShare` fails compilation; `recording::uid_mut`
/// ignores the cap value, so there is no wrong-cap runtime abort to test.
#[test_only]
module recording_metadata::version_tests;

use musicos::recording;
use recording_metadata::recording_metadata as rm;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::dynamic_field as df;
use sui::event;

public struct REC {}
public struct OTHER_REC {}
public struct UnrelatedKey() has copy, drop, store;

/// This package never touches the composition side of a recording — it only
/// needs a `Recording` to exist, so a bare id stands in for a real
/// `Composition` rather than constructing one.
fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC>(object::id_from_address(@0xC0FFEE), ctx)
}

/// `count` copies of "é" (U+00E9, two UTF-8 bytes) — a version whose byte
/// length is twice its character count.
fun accents(count: u64): std::string::String {
    let mut bytes = vector[];
    count.do!(|_| {
        bytes.push_back(0xC3u8);
        bytes.push_back(0xA9u8);
    });
    bytes.to_string()
}

fun assert_set_payload(
    event: &rm::RecordingVersionSetEvent<REC>,
    recording_id: address,
    version: vector<u8>,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_vec_u8(), version);
    assert!(bytes.into_remainder_bytes().is_empty());
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec).to_address();

    assert!(!rm::has_version(&rec));

    rm::set_version(&mut rec, &cap, b"Live".to_string());
    assert!(rm::has_version(&rec));
    assert_eq!(*rm::version(&rec), b"Live".to_string());
    let sets = event::events_by_type<rm::RecordingVersionSetEvent<REC>>();
    assert_eq!(sets.length(), 1);
    let (event_rec_id, version) = rm::version_set_event_fields(&sets[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(version, b"Live".to_string());
    assert_set_payload(&sets[0], rec_id, b"Live");
    assert_eq!(bcs::to_bytes(&sets[0]).length(), 37);

    // Equal replacement is a no-op: nothing written, nothing emitted.
    rm::set_version(&mut rec, &cap, b"Live".to_string());
    assert_eq!(*rm::version(&rec), b"Live".to_string());
    let sets = event::events_by_type<rm::RecordingVersionSetEvent<REC>>();
    assert_eq!(sets.length(), 1);

    // Setting again replaces in place — a recording has one version, not a
    // history.
    rm::set_version(&mut rec, &cap, b"Radio Edit".to_string());
    assert_eq!(*rm::version(&rec), b"Radio Edit".to_string());
    let sets = event::events_by_type<rm::RecordingVersionSetEvent<REC>>();
    assert_eq!(sets.length(), 2);
    assert_set_payload(&sets[1], rec_id, b"Radio Edit");

    rm::clear_version(&mut rec, &cap);
    assert!(!rm::has_version(&rec));
    let clears = event::events_by_type<rm::RecordingVersionClearedEvent<REC>>();
    assert_eq!(clears.length(), 1);
    assert_eq!(rm::version_cleared_event_fields(&clears[0]), rec_id);
    let mut bytes = bcs::new(bcs::to_bytes(&clears[0]));
    assert_eq!(bytes.peel_address(), rec_id);
    assert!(bytes.into_remainder_bytes().is_empty());
    assert_eq!(bcs::to_bytes(&clears[0]).length(), 32);

    // Clear is idempotent and silent when nothing is attached.
    rm::clear_version(&mut rec, &cap);
    assert!(!rm::has_version(&rec));
    assert_eq!(event::events_by_type<rm::RecordingVersionClearedEvent<REC>>().length(), 1);

    // A later set starts fresh after the clear.
    rm::set_version(&mut rec, &cap, b"Acoustic".to_string());
    assert_eq!(*rm::version(&rec), b"Acoustic".to_string());
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<REC>>().length(), 3);

    destroy(rec);
    destroy(cap);
}

/// Setting the version already attached is a no-op: nothing is written and
/// nothing is emitted. The record stays attached with its value intact.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    rm::set_version(&mut rec, &cap, b"Live".to_string());
    assert_eq!(event::num_events(), 1);

    rm::set_version(&mut rec, &cap, b"Live".to_string());
    assert_eq!(event::num_events(), 1);
    assert!(rm::has_metadata_for_testing(&rec));
    assert_eq!(*rm::version(&rec), b"Live".to_string());

    // A different value is still a replacement; cleared and set again to
    // the same value it is absent, so not a no-op.
    rm::set_version(&mut rec, &cap, b"live".to_string());
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<REC>>().length(), 2);
    rm::clear_version(&mut rec, &cap);
    assert!(!rm::has_metadata_for_testing(&rec));
    rm::set_version(&mut rec, &cap, b"live".to_string());
    assert!(rm::has_metadata_for_testing(&rec));
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<REC>>().length(), 3);

    destroy(rec);
    destroy(cap);
}

/// The string is the recording's own word for its take: case and whitespace
/// are stored as given, and "Live", "live" and " Live " are three values.
#[test]
fun stored_exactly_as_given() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    rm::set_version(&mut rec, &cap, b" Live ".to_string());
    assert_eq!(*rm::version(&rec), b" Live ".to_string());
    assert!(*rm::version(&rec) != b"Live".to_string());

    rm::set_version(&mut rec, &cap, b"live".to_string());
    assert_eq!(*rm::version(&rec), b"live".to_string());
    assert!(*rm::version(&rec) != b"Live".to_string());

    let sets = event::events_by_type<rm::RecordingVersionSetEvent<REC>>();
    let (_, first) = rm::version_set_event_fields(&sets[0]);
    let (_, second) = rm::version_set_event_fields(&sets[1]);
    assert_eq!(first, b" Live ".to_string());
    assert_eq!(second, b"live".to_string());

    destroy(rec);
    destroy(cap);
}

/// The bound is inclusive — exactly MAX_VERSION_LENGTH bytes are accepted, on
/// insert and on replace, and the full-size set event is the largest this
/// module emits.
#[test]
fun exactly_max_length_is_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec).to_address();
    let max = vector::tabulate!(300, |_| 0x61u8);
    // A different 300-byte value exercises replacement at the bound rather
    // than repeating the same string, which would be a silent no-op.
    let different = vector::tabulate!(300, |i| if (i == 0) 0x62u8 else 0x61u8);

    rm::set_version(&mut rec, &cap, max.to_string());
    assert_eq!(*rm::version(&rec).as_bytes(), max);
    rm::set_version(&mut rec, &cap, different.to_string());
    assert_eq!(*rm::version(&rec).as_bytes(), different);

    let sets = event::events_by_type<rm::RecordingVersionSetEvent<REC>>();
    assert_eq!(sets.length(), 2);
    assert_set_payload(&sets[0], rec_id, max);
    assert_set_payload(&sets[1], rec_id, different);
    // 32 (id) + 2 (ULEB128 length of 300) + 300.
    assert_eq!(bcs::to_bytes(&sets[0]).length(), 334);
    assert_eq!(bcs::to_bytes(&sets[1]).length(), 334);

    destroy(rec);
    destroy(cap);
}

/// The bound is in UTF-8 bytes, not characters: 150 two-byte characters fill
/// it exactly and are stored and emitted byte-for-byte.
#[test]
fun bound_is_bytes_not_characters() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec).to_address();
    let version = accents(150);
    assert_eq!(version.length(), 300);

    rm::set_version(&mut rec, &cap, version);
    assert_eq!(*rm::version(&rec), version);

    let sets = event::events_by_type<rm::RecordingVersionSetEvent<REC>>();
    assert_eq!(sets.length(), 1);
    assert_set_payload(&sets[0], rec_id, *version.as_bytes());

    destroy(rec);
    destroy(cap);
}

/// Versions live on their own recording's UID; one recording's version is not
/// visible from another, and each share type has its own event stream.
#[test]
fun versions_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (mut b, b_cap) = recording::new_for_testing<OTHER_REC>(
        object::id_from_address(@0xC0FFEE),
        ctx,
    );

    rm::set_version(&mut a, &a_cap, b"Live".to_string());
    assert!(rm::has_version(&a));
    assert!(!rm::has_version(&b));
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<OTHER_REC>>().length(), 0);

    rm::set_version(&mut b, &b_cap, b"Demo".to_string());
    assert_eq!(*rm::version(&a), b"Live".to_string());
    assert_eq!(*rm::version(&b), b"Demo".to_string());
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<OTHER_REC>>().length(), 1);

    rm::clear_version(&mut a, &a_cap);
    assert!(!rm::has_version(&a));
    assert!(rm::has_version(&b));
    assert_eq!(event::events_by_type<rm::RecordingVersionClearedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingVersionClearedEvent<OTHER_REC>>().length(), 0);

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test]
fun unrelated_dynamic_field_survives_version_mutations() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    df::add(rec.uid_mut(&cap), UnrelatedKey(), 77u64);
    rm::set_version(&mut rec, &cap, b"Live".to_string());
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    rm::set_version(&mut rec, &cap, b"Demo".to_string());
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    rm::clear_version(&mut rec, &cap);
    assert_eq!(*df::borrow(rec.uid(), UnrelatedKey()), 77u64);
    let _: u64 = df::remove(rec.uid_mut(&cap), UnrelatedKey());

    destroy(rec);
    destroy(cap);
}

#[test]
fun views_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    assert!(!rm::has_version(&rec));
    rm::set_version(&mut rec, &cap, b"Live".to_string());
    let _ = rm::has_version(&rec);
    let _ = *rm::version(&rec);
    assert_eq!(event::events_by_type<rm::RecordingVersionSetEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingVersionClearedEvent<REC>>().length(), 0);
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rm::ENoVersion)]
fun version_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec(ctx);
    let _ = *rm::version(&rec);
    destroy(rec);
    destroy(cap);
}

/// Asserting nothing should be done by not attaching: an empty string is
/// rejected rather than stored as a blank take-name.
#[test, expected_failure(abort_code = rm::EEmptyVersion)]
fun empty_version_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    rm::set_version(&mut rec, &cap, b"".to_string());
    destroy(rec);
    destroy(cap);
}

/// An empty replacement is rejected too — it cannot be used to blank out an
/// attached version; `clear_version` is the way to withdraw one.
#[test, expected_failure(abort_code = rm::EEmptyVersion)]
fun empty_replacement_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    rm::set_version(&mut rec, &cap, b"Live".to_string());
    rm::set_version(&mut rec, &cap, b"".to_string());
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rm::EVersionTooLong)]
fun version_too_long_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    rm::set_version(&mut rec, &cap, vector::tabulate!(301, |_| 0x61u8).to_string());
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rm::EVersionTooLong)]
fun version_too_long_replacement_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    rm::set_version(&mut rec, &cap, b"Live".to_string());
    rm::set_version(&mut rec, &cap, vector::tabulate!(301, |_| 0x61u8).to_string());
    assert_eq!(*rm::version(&rec), b"Live".to_string());
    destroy(rec);
    destroy(cap);
}

/// 151 two-byte characters is 302 bytes: over the bound although only 151
/// characters long.
#[test, expected_failure(abort_code = rm::EVersionTooLong)]
fun multibyte_version_over_the_byte_bound_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let version = accents(151);
    assert_eq!(version.length(), 302);
    rm::set_version(&mut rec, &cap, version);
    destroy(rec);
    destroy(cap);
}
