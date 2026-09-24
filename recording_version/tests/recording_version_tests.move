// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Set/read/replace/clear mechanics and the validation aborts against a bare
/// `Recording`. Nothing here crosses a transaction boundary, so
/// `tx_context::dummy()` suffices; the published, shared shape is covered in
/// `recording_version_e2e_tests`.
///
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type —
/// one share type backs exactly one recording — so a wrong-cap call is a
/// compile error, not a runtime abort, and there is no such test here.
#[test_only]
module recording_version::recording_version_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_version::recording_version::{
    Self as rv,
    RecordingVersionSetEvent,
    RecordingVersionClearedEvent,
};
use std::string::String;
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;

public struct REC {}
public struct OTHER_REC {}

/// Only a `Recording` is needed, so a bare id stands in for its composition.
fun new_rec<RecordingShare>(
    ctx: &mut TxContext,
): (Recording<RecordingShare>, RecordingAdminCap<RecordingShare>) {
    recording::new_for_testing<RecordingShare>(object::id_from_address(@0xC0FFEE), ctx)
}

/// A string of `n` ASCII bytes.
fun ascii_of_length(n: u64): String {
    let mut bytes = vector[];
    n.do!(|_| bytes.push_back(b"A"[0]));
    bytes.to_string()
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);

    assert!(!rv::has_version(&rec));

    rv::set_version(&mut rec, &cap, b"Live".to_string());
    assert!(rv::has_version(&rec));
    assert_eq!(*rv::version(&rec), b"Live".to_string());
    let set_events = events_by_type<RecordingVersionSetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    let (event_rec_id, version) = rv::set_event_fields(&set_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(version, b"Live".to_string());

    // Replacement in place — a recording has one version name, not a history.
    rv::set_version(&mut rec, &cap, b"Radio Edit".to_string());
    assert_eq!(*rv::version(&rec), b"Radio Edit".to_string());
    let set_events = events_by_type<RecordingVersionSetEvent<REC>>();
    assert_eq!(set_events.length(), 2);
    let (_, version) = rv::set_event_fields(&set_events[1]);
    assert_eq!(version, b"Radio Edit".to_string());

    rv::clear_version(&mut rec, &cap);
    assert!(!rv::has_version(&rec));
    let cleared = events_by_type<RecordingVersionClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(rv::cleared_event_fields(&cleared[0]), rec_id);

    // Re-attachment after a clear starts fresh.
    rv::set_version(&mut rec, &cap, b"Acoustic".to_string());
    assert_eq!(*rv::version(&rec), b"Acoustic".to_string());
    assert_eq!(events_by_type<RecordingVersionSetEvent<REC>>().length(), 3);

    destroy(rec);
    destroy(cap);
}

#[test]
fun equal_set_neither_writes_nor_emits() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    rv::set_version(&mut rec, &cap, b"Live".to_string());
    rv::set_version(&mut rec, &cap, b"Live".to_string());
    assert_eq!(*rv::version(&rec), b"Live".to_string());
    assert_eq!(events_by_type<RecordingVersionSetEvent<REC>>().length(), 1);

    // Case and whitespace are content: a near-equal value is a real change.
    rv::set_version(&mut rec, &cap, b"live".to_string());
    assert_eq!(events_by_type<RecordingVersionSetEvent<REC>>().length(), 2);

    destroy(rec);
    destroy(cap);
}

#[test]
fun clear_when_absent_is_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    rv::clear_version(&mut rec, &cap);
    assert!(!rv::has_version(&rec));
    assert_eq!(events_by_type<RecordingVersionClearedEvent<REC>>().length(), 0);

    rv::set_version(&mut rec, &cap, b"Live".to_string());
    rv::clear_version(&mut rec, &cap);
    rv::clear_version(&mut rec, &cap);
    assert_eq!(events_by_type<RecordingVersionClearedEvent<REC>>().length(), 1);

    destroy(rec);
    destroy(cap);
}

/// The set event is the recording id plus the BCS string: one length
/// byte below 128 bytes, two at the 300-byte maximum.
#[test]
fun set_event_carries_the_recording_and_the_new_value() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);

    rv::set_version(&mut rec, &cap, b"Live".to_string());
    let events = events_by_type<RecordingVersionSetEvent<REC>>();
    let (event_rec_id, version) = rv::set_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(version, b"Live".to_string());
    assert_eq!(to_bytes(&events[0]).length(), 32 + 1 + 4);

    // Multi-byte UTF-8 is measured in bytes, in storage and on the wire.
    rv::set_version(&mut rec, &cap, b"Acoustique \xc3\xa0 Paris".to_string());
    let events = events_by_type<RecordingVersionSetEvent<REC>>();
    assert_eq!(events.length(), 2);
    assert_eq!(to_bytes(&events[1]).length(), 32 + 1 + 19);

    rv::set_version(&mut rec, &cap, ascii_of_length(300));
    let events = events_by_type<RecordingVersionSetEvent<REC>>();
    assert_eq!(events.length(), 3);
    assert_eq!(to_bytes(&events[2]).length(), 32 + 2 + 300);

    destroy(rec);
    destroy(cap);
}

#[test]
fun cleared_event_carries_only_the_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);

    rv::set_version(&mut rec, &cap, b"Live".to_string());
    rv::clear_version(&mut rec, &cap);

    let events = events_by_type<RecordingVersionClearedEvent<REC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(rv::cleared_event_fields(&events[0]), rec_id);
    assert_eq!(to_bytes(&events[0]).length(), 32);

    destroy(rec);
    destroy(cap);
}

/// The bound is inclusive: exactly `MAX_VERSION_LENGTH` bytes is accepted,
/// and a single byte is enough to be non-empty.
#[test]
fun length_bounds_are_inclusive() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    rv::set_version(&mut rec, &cap, ascii_of_length(1));
    assert_eq!(rv::version(&rec).length(), 1);

    rv::set_version(&mut rec, &cap, ascii_of_length(300));
    assert_eq!(rv::version(&rec).length(), 300);

    destroy(rec);
    destroy(cap);
}

#[test]
fun views_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    assert!(!rv::has_version(&rec));
    rv::set_version(&mut rec, &cap, b"Live".to_string());
    let _ = rv::has_version(&rec);
    let _ = rv::version(&rec);
    assert_eq!(events_by_type<RecordingVersionSetEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingVersionClearedEvent<REC>>().length(), 0);

    destroy(rec);
    destroy(cap);
}

/// Version names live on their own recording's UID and in their own
/// share-typed event stream.
#[test]
fun versions_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec<REC>(ctx);
    let (mut b, b_cap) = new_rec<OTHER_REC>(ctx);

    rv::set_version(&mut a, &a_cap, b"Live".to_string());
    assert!(!rv::has_version(&b));
    assert_eq!(events_by_type<RecordingVersionSetEvent<OTHER_REC>>().length(), 0);

    rv::set_version(&mut b, &b_cap, b"Acoustic".to_string());
    assert_eq!(*rv::version(&a), b"Live".to_string());
    assert_eq!(*rv::version(&b), b"Acoustic".to_string());
    assert_eq!(events_by_type<RecordingVersionSetEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingVersionSetEvent<OTHER_REC>>().length(), 1);

    rv::clear_version(&mut a, &a_cap);
    assert!(rv::has_version(&b));
    assert_eq!(events_by_type<RecordingVersionClearedEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingVersionClearedEvent<OTHER_REC>>().length(), 0);

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test, expected_failure(abort_code = rv::ENoVersion)]
fun version_aborts_when_absent() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec<REC>(ctx);
    let _ = rv::version(&rec);
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rv::ENoVersion)]
fun version_aborts_after_clear() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    rv::set_version(&mut rec, &cap, b"Live".to_string());
    rv::clear_version(&mut rec, &cap);
    let _ = rv::version(&rec);
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rv::EEmptyVersion)]
fun empty_version_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    rv::set_version(&mut rec, &cap, b"".to_string());
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rv::EVersionTooLong)]
fun version_over_the_maximum_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    rv::set_version(&mut rec, &cap, ascii_of_length(301));
    destroy(rec);
    destroy(cap);
}

/// An over-long replacement is rejected before any stored-state check, so the
/// existing value survives an aborted set.
#[test, expected_failure(abort_code = rv::EVersionTooLong)]
fun invalid_replacement_aborts_without_touching_the_stored_value() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    rv::set_version(&mut rec, &cap, b"Live".to_string());
    rv::set_version(&mut rec, &cap, ascii_of_length(301));
    destroy(rec);
    destroy(cap);
}
