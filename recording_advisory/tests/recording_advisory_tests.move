// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Set/read/replace/clear mechanics against a bare `Recording`. Nothing here
/// crosses a transaction boundary, so `tx_context::dummy()` suffices; the
/// published, shared shape is covered in `recording_advisory_e2e_tests`.
///
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type —
/// one share type backs exactly one recording — so a wrong-cap call is a
/// compile error, not a runtime abort, and there is no such test here.
#[test_only]
module recording_advisory::recording_advisory_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_advisory::recording_advisory::{
    Self as adv,
    RecordingAdvisorySetEvent,
    RecordingAdvisoryClearedEvent,
};
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

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);

    assert!(!adv::has_advisory(&rec));

    adv::set_advisory(&mut rec, &cap, adv::explicit());
    assert!(adv::has_advisory(&rec));
    assert!(adv::advisory(&rec).is_explicit());
    let set_events = events_by_type<RecordingAdvisorySetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    let (event_rec_id, advisory) = adv::set_event_fields(&set_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert!(advisory.is_explicit());

    // Replacement in place — a recording has one advisory, not a history.
    adv::set_advisory(&mut rec, &cap, adv::cleaned());
    assert!(adv::advisory(&rec).is_cleaned());
    assert!(!adv::advisory(&rec).is_explicit());
    let set_events = events_by_type<RecordingAdvisorySetEvent<REC>>();
    assert_eq!(set_events.length(), 2);
    let (_, advisory) = adv::set_event_fields(&set_events[1]);
    assert!(advisory.is_cleaned());

    adv::clear_advisory(&mut rec, &cap);
    assert!(!adv::has_advisory(&rec));
    let cleared = events_by_type<RecordingAdvisoryClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(adv::cleared_event_fields(&cleared[0]), rec_id);

    // Re-attachment after a clear starts fresh.
    adv::set_advisory(&mut rec, &cap, adv::not_explicit());
    assert!(adv::advisory(&rec).is_not_explicit());
    assert_eq!(events_by_type<RecordingAdvisorySetEvent<REC>>().length(), 3);

    destroy(rec);
    destroy(cap);
}

#[test]
fun equal_set_neither_writes_nor_emits() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    adv::set_advisory(&mut rec, &cap, adv::explicit());
    adv::set_advisory(&mut rec, &cap, adv::explicit());
    assert!(adv::advisory(&rec).is_explicit());
    assert_eq!(events_by_type<RecordingAdvisorySetEvent<REC>>().length(), 1);

    destroy(rec);
    destroy(cap);
}

#[test]
fun clear_when_absent_is_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    adv::clear_advisory(&mut rec, &cap);
    assert!(!adv::has_advisory(&rec));
    assert_eq!(events_by_type<RecordingAdvisoryClearedEvent<REC>>().length(), 0);

    adv::set_advisory(&mut rec, &cap, adv::explicit());
    adv::clear_advisory(&mut rec, &cap);
    adv::clear_advisory(&mut rec, &cap);
    assert_eq!(events_by_type<RecordingAdvisoryClearedEvent<REC>>().length(), 1);

    destroy(rec);
    destroy(cap);
}

/// A cleaned edit is not "never explicit", and neither collapses into the other.
#[test]
fun the_three_advisories_are_mutually_exclusive() {
    let cases = vector[adv::explicit(), adv::not_explicit(), adv::cleaned()];
    let flags = vector[
        vector[true, false, false],
        vector[false, true, false],
        vector[false, false, true],
    ];
    cases.length().do!(|i| {
        let a = cases[i];
        assert_eq!(a.is_explicit(), flags[i][0]);
        assert_eq!(a.is_not_explicit(), flags[i][1]);
        assert_eq!(a.is_cleaned(), flags[i][2]);
    });
}

/// An unrated recording has said nothing; asserting `NotExplicit` is a
/// different, stronger claim.
#[test]
fun absence_is_not_not_explicit() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    assert!(!adv::has_advisory(&rec));
    adv::set_advisory(&mut rec, &cap, adv::not_explicit());
    assert!(adv::has_advisory(&rec));
    assert!(adv::advisory(&rec).is_not_explicit());
    adv::clear_advisory(&mut rec, &cap);
    assert!(!adv::has_advisory(&rec));

    destroy(rec);
    destroy(cap);
}

/// Every transition between the three values writes and emits; the set event
/// carries the recording and the new value as a one-byte variant index.
#[test]
fun set_events_carry_the_recording_and_the_new_value() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);
    let sequence = vector[adv::cleaned(), adv::explicit(), adv::not_explicit(), adv::cleaned()];
    let variant_indices = vector[2u8, 0, 1, 2];

    sequence.length().do!(|i| {
        adv::set_advisory(&mut rec, &cap, sequence[i]);
        assert_eq!(adv::advisory(&rec), sequence[i]);
        let events = events_by_type<RecordingAdvisorySetEvent<REC>>();
        assert_eq!(events.length(), i + 1);
        let (event_rec_id, advisory) = adv::set_event_fields(&events[i]);
        assert_eq!(event_rec_id, rec_id);
        assert_eq!(advisory, sequence[i]);
        let bytes = to_bytes(&events[i]);
        assert_eq!(bytes.length(), 33);
        assert_eq!(bytes[32], variant_indices[i]);
    });

    destroy(rec);
    destroy(cap);
}

#[test]
fun cleared_event_carries_only_the_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    let rec_id = object::id(&rec);

    adv::set_advisory(&mut rec, &cap, adv::explicit());
    adv::clear_advisory(&mut rec, &cap);

    let events = events_by_type<RecordingAdvisoryClearedEvent<REC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(adv::cleared_event_fields(&events[0]), rec_id);
    assert_eq!(to_bytes(&events[0]).length(), 32);

    destroy(rec);
    destroy(cap);
}

#[test]
fun constructors_and_views_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);

    let explicit = adv::explicit();
    let not_explicit = adv::not_explicit();
    let cleaned = adv::cleaned();
    assert!(explicit.is_explicit());
    assert!(not_explicit.is_not_explicit());
    assert!(cleaned.is_cleaned());
    assert!(!adv::has_advisory(&rec));
    assert_eq!(events_by_type<RecordingAdvisorySetEvent<REC>>().length(), 0);

    adv::set_advisory(&mut rec, &cap, explicit);
    let _ = adv::has_advisory(&rec);
    let _ = adv::advisory(&rec);
    assert_eq!(events_by_type<RecordingAdvisorySetEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingAdvisoryClearedEvent<REC>>().length(), 0);

    destroy(rec);
    destroy(cap);
}

/// Advisories live on their own recording's UID and in their own share-typed
/// event stream.
#[test]
fun advisories_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec<REC>(ctx);
    let (mut b, b_cap) = new_rec<OTHER_REC>(ctx);

    adv::set_advisory(&mut a, &a_cap, adv::explicit());
    assert!(!adv::has_advisory(&b));
    assert_eq!(events_by_type<RecordingAdvisorySetEvent<OTHER_REC>>().length(), 0);

    adv::set_advisory(&mut b, &b_cap, adv::not_explicit());
    assert!(adv::advisory(&a).is_explicit());
    assert!(adv::advisory(&b).is_not_explicit());
    assert_eq!(events_by_type<RecordingAdvisorySetEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingAdvisorySetEvent<OTHER_REC>>().length(), 1);

    adv::clear_advisory(&mut a, &a_cap);
    assert!(adv::has_advisory(&b));
    assert_eq!(events_by_type<RecordingAdvisoryClearedEvent<REC>>().length(), 1);
    assert_eq!(events_by_type<RecordingAdvisoryClearedEvent<OTHER_REC>>().length(), 0);

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test, expected_failure(abort_code = adv::ENoAdvisory)]
fun advisory_aborts_when_absent() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec<REC>(ctx);
    let _ = adv::advisory(&rec);
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = adv::ENoAdvisory)]
fun advisory_aborts_after_clear() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec<REC>(ctx);
    adv::set_advisory(&mut rec, &cap, adv::explicit());
    adv::clear_advisory(&mut rec, &cap);
    let _ = adv::advisory(&rec);
    destroy(rec);
    destroy(cap);
}
