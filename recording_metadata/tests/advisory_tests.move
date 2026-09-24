// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Attach/read/replace/clear mechanics of the advisory attribute against a
/// single bare `Recording` with no ownership handoff — nothing here crosses a
/// transaction boundary or changes hands between actors, so plain
/// `tx_context::dummy()` is exactly as faithful as a scenario and adds no
/// signal. The production shape — a published, shared `Recording` operated on
/// by distinct senders across real transactions — is covered separately in
/// `advisory_e2e_tests`.
///
/// A recording's `RecordingShare` type uniquely identifies it — one share
/// currency is minted per recording — so `RecordingAdminCap<RecordingShare>`
/// is bound to its recording *by type*. `recording::uid_mut` therefore takes
/// the cap as `_` and performs no runtime check. There is deliberately no
/// wrong-cap test below: a cap for another recording is a different type and
/// the call would not compile.
#[test_only]
module recording_metadata::advisory_tests;

use musicos::recording;
use recording_metadata::recording_metadata as rm;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

public struct REC {}
public struct OTHER_REC {}

/// This package never touches the composition side of a recording — it only
/// needs a `Recording` to exist, so a bare id stands in for a real
/// `Composition` rather than constructing one.
fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC>(object::id_from_address(@0xC0FFEE), ctx)
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec).to_address();

    assert!(!rm::has_advisory(&rec));

    rm::set_advisory(&mut rec, &cap, rm::explicit());
    assert!(rm::has_advisory(&rec));
    assert!(rm::advisory(&rec).is_explicit());
    let set_events = event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    let (event_rec_id, advisory) = rm::advisory_set_event_fields(&set_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert!(advisory.is_explicit());

    // Equal replacement is a no-op: nothing written, nothing emitted.
    rm::set_advisory(&mut rec, &cap, rm::explicit());
    assert!(rm::advisory(&rec).is_explicit());
    let set_events = event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>();
    assert_eq!(set_events.length(), 1);

    // Setting again replaces in place — a recording has one advisory, not a history.
    rm::set_advisory(&mut rec, &cap, rm::cleaned());
    assert!(rm::advisory(&rec).is_cleaned());
    assert!(!rm::advisory(&rec).is_explicit());
    let set_events = event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>();
    assert_eq!(set_events.length(), 2);
    let (_, advisory) = rm::advisory_set_event_fields(&set_events[1]);
    assert!(advisory.is_cleaned());

    rm::clear_advisory(&mut rec, &cap);
    assert!(!rm::has_advisory(&rec));
    let clear_events = event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>();
    assert_eq!(clear_events.length(), 1);
    assert_eq!(rm::advisory_cleared_event_fields(&clear_events[0]), rec_id);

    // Clear is idempotent and silent when nothing is attached.
    rm::clear_advisory(&mut rec, &cap);
    assert!(!rm::has_advisory(&rec));
    assert_eq!(
        event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(),
        1,
    );

    destroy(rec);
    destroy(cap);
}

/// The distinction the enum exists for: a cleaned edit is not the same claim as
/// "never explicit", and neither collapses into the other.
#[test]
fun the_three_advisories_are_mutually_exclusive() {
    let cases = vector[rm::explicit(), rm::not_explicit(), rm::cleaned()];
    let flags = vector[
        vector[true, false, false],
        vector[false, true, false],
        vector[false, false, true],
    ];
    cases.length().do!(|i| {
        let r = cases[i];
        assert_eq!(r.is_explicit(), flags[i][0]);
        assert_eq!(r.is_not_explicit(), flags[i][1]);
        assert_eq!(r.is_cleaned(), flags[i][2]);
    });
}

/// The event code is the indexer's stable representation of the advisory:
/// `Explicit = 0`, `NotExplicit = 1`, `Cleaned = 2`, one byte after the id.
#[test]
fun set_events_carry_stable_codes() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec).to_address();
    let expected = vector[0u8, 1u8, 2u8];
    3u64.do!(|i| {
        let advisory = if (i == 0) {
            rm::explicit()
        } else if (i == 1) {
            rm::not_explicit()
        } else {
            rm::cleaned()
        };
        rm::set_advisory(&mut rec, &cap, advisory);
        let sets = event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>();
        assert_eq!(sets.length(), i + 1);
        let mut bytes = bcs::new(bcs::to_bytes(&sets[i]));
        assert_eq!(bytes.peel_address(), rec_id);
        assert_eq!(bytes.peel_u8(), expected[i]);
        assert!(bytes.into_remainder_bytes().is_empty());
        assert_eq!(bcs::to_bytes(&sets[i]).length(), 33);
    });
    destroy(rec);
    destroy(cap);
}

/// Absence must not read as `NotExplicit`. An unrated recording has said
/// nothing; asserting it is clean is a different, stronger claim.
#[test]
fun absence_is_not_not_explicit() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    assert!(!rm::has_advisory(&rec));

    rm::set_advisory(&mut rec, &cap, rm::not_explicit());
    assert!(rm::has_advisory(&rec));
    assert!(rm::advisory(&rec).is_not_explicit());

    rm::clear_advisory(&mut rec, &cap);
    assert!(!rm::has_advisory(&rec));

    destroy(rec);
    destroy(cap);
}

/// Setting the advisory already attached is a no-op: nothing is written and
/// nothing is emitted. The record stays attached with its value intact, and
/// a different variant afterwards is still an ordinary replacement.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    rm::set_advisory(&mut rec, &cap, rm::cleaned());
    assert_eq!(event::num_events(), 1);

    rm::set_advisory(&mut rec, &cap, rm::cleaned());
    assert_eq!(event::num_events(), 1);
    assert!(rm::has_metadata_for_testing(&rec));
    assert!(rm::advisory(&rec).is_cleaned());

    rm::set_advisory(&mut rec, &cap, rm::not_explicit());
    assert_eq!(event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>().length(), 2);
    assert!(rm::advisory(&rec).is_not_explicit());

    // Cleared and set again to the same variant: absent, so not a no-op.
    rm::clear_advisory(&mut rec, &cap);
    assert!(!rm::has_metadata_for_testing(&rec));
    rm::set_advisory(&mut rec, &cap, rm::not_explicit());
    assert!(rm::has_metadata_for_testing(&rec));
    assert_eq!(event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>().length(), 3);

    destroy(rec);
    destroy(cap);
}

#[test]
fun set_emits_the_advisory_and_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    rm::set_advisory(&mut rec, &cap, rm::cleaned());

    let events = event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, advisory) = rm::advisory_set_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id.to_address());
    assert!(advisory.is_cleaned());
    assert_eq!(bcs::to_bytes(&events[0]).length(), 33);

    destroy(rec);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    // Nothing attached — a no-op must stay silent rather than announce a change.
    rm::clear_advisory(&mut rec, &cap);
    assert_eq!(
        event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(),
        0,
    );

    rm::set_advisory(&mut rec, &cap, rm::explicit());
    rm::clear_advisory(&mut rec, &cap);

    let events = event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(rm::advisory_cleared_event_fields(&events[0]), rec_id.to_address());
    let mut bytes = bcs::new(bcs::to_bytes(&events[0]));
    assert_eq!(bytes.peel_address(), rec_id.to_address());
    assert!(bytes.into_remainder_bytes().is_empty());
    assert_eq!(bcs::to_bytes(&events[0]).length(), 32);

    destroy(rec);
    destroy(cap);
}

#[test]
fun constructors_and_views_are_silent() {
    let explicit = rm::explicit();
    let not_explicit = rm::not_explicit();
    let cleaned = rm::cleaned();
    assert!(explicit.is_explicit());
    assert!(not_explicit.is_not_explicit());
    assert!(cleaned.is_cleaned());
    assert_eq!(event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>().length(), 0);
    assert_eq!(
        event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(),
        0,
    );

    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    assert!(!rm::has_advisory(&rec));
    rm::set_advisory(&mut rec, &cap, explicit);
    assert!(rm::has_advisory(&rec));
    assert!(rm::advisory(&rec).is_explicit());
    assert_eq!(event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>().length(), 1);
    rm::clear_advisory(&mut rec, &cap);
    assert!(!rm::has_advisory(&rec));
    assert_eq!(
        event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(),
        1,
    );

    destroy(rec);
    destroy(cap);
}

/// Advisories live on their own recording's UID; one recording's advisory is not
/// visible from another, and each share type has its own event stream.
#[test]
fun advisories_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (mut b, b_cap) = recording::new_for_testing<OTHER_REC>(
        object::id_from_address(@0xC0FFEE),
        ctx,
    );

    rm::set_advisory(&mut a, &a_cap, rm::explicit());
    assert!(rm::has_advisory(&a));
    assert!(!rm::has_advisory(&b));
    assert_eq!(event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>().length(), 1);
    assert_eq!(
        event::events_by_type<rm::RecordingAdvisorySetEvent<OTHER_REC>>().length(),
        0,
    );

    rm::set_advisory(&mut b, &b_cap, rm::not_explicit());
    assert!(rm::advisory(&a).is_explicit());
    assert!(rm::advisory(&b).is_not_explicit());
    assert_eq!(event::events_by_type<rm::RecordingAdvisorySetEvent<REC>>().length(), 1);
    assert_eq!(
        event::events_by_type<rm::RecordingAdvisorySetEvent<OTHER_REC>>().length(),
        1,
    );

    rm::clear_advisory(&mut a, &a_cap);
    assert!(!rm::has_advisory(&a));
    assert!(rm::has_advisory(&b));
    assert_eq!(
        event::events_by_type<rm::RecordingAdvisoryClearedEvent<REC>>().length(),
        1,
    );
    assert_eq!(
        event::events_by_type<rm::RecordingAdvisoryClearedEvent<OTHER_REC>>().length(),
        0,
    );

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test, expected_failure(abort_code = rm::ENoAdvisory)]
fun advisory_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec(ctx);
    let _ = rm::advisory(&rec);
    destroy(rec);
    destroy(cap);
}
