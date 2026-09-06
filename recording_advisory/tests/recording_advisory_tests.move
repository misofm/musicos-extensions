// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_advisory::recording_advisory_tests;

use miso::recording;
use recording_advisory::recording_advisory as adv;
use std::unit_test::{assert_eq, destroy};
use sui::event;

// Phantom marker types for the share parameters. A recording's `RecordingShare`
// type uniquely identifies it — one share currency is minted per recording — so
// `RecordingAdminCap<RecordingShare>` is bound to its recording *by type*.
// `recording::uid_mut` therefore takes the cap as `_` and performs no runtime
// check. There is deliberately no wrong-cap test below: a cap for another
// recording is a different type and the call would not compile.
public struct REC {}
public struct COMP {}
public struct OTHER_REC {}

/// This package never touches the composition side of a recording — it only
/// needs a `Recording` to exist, so a bare id stands in for a real
/// `Composition` rather than constructing one.
fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(object::id_from_address(@0xC0FFEE), ctx)
}

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    assert!(!adv::has_rating(&rec));

    adv::set_rating(&mut rec, &cap, adv::explicit());
    assert!(adv::has_rating(&rec));
    assert!(adv::rating(&rec).is_explicit());

    // Setting again replaces in place — a recording has one rating, not a history.
    adv::set_rating(&mut rec, &cap, adv::cleaned());
    assert!(adv::rating(&rec).is_cleaned());
    assert!(!adv::rating(&rec).is_explicit());

    adv::unset_rating(&mut rec, &cap);
    assert!(!adv::has_rating(&rec));

    // Unset is idempotent.
    adv::unset_rating(&mut rec, &cap);
    assert!(!adv::has_rating(&rec));

    destroy(rec);
    destroy(cap);
}

/// The distinction the enum exists for: a cleaned edit is not the same claim as
/// "never explicit", and neither collapses into the other.
#[test]
fun the_three_ratings_are_mutually_exclusive() {
    let cases = vector[adv::explicit(), adv::not_explicit(), adv::cleaned()];
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

#[test]
fun names_are_stable_for_indexers() {
    assert_eq!(adv::explicit().name(), b"Explicit");
    assert_eq!(adv::not_explicit().name(), b"NotExplicit");
    assert_eq!(adv::cleaned().name(), b"Cleaned");
}

/// Absence must not read as `NotExplicit`. An unrated recording has said
/// nothing; asserting it is clean is a different, stronger claim.
#[test]
fun absence_is_not_not_explicit() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    assert!(!adv::has_rating(&rec));

    adv::set_rating(&mut rec, &cap, adv::not_explicit());
    assert!(adv::has_rating(&rec));
    assert!(adv::rating(&rec).is_not_explicit());

    adv::unset_rating(&mut rec, &cap);
    assert!(!adv::has_rating(&rec));

    destroy(rec);
    destroy(cap);
}

#[test]
fun set_emits_the_rating_and_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    adv::set_rating(&mut rec, &cap, adv::cleaned());

    let events = event::events_by_type<adv::AdvisoryRatingSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, rating) = adv::set_event_fields(&events[0]);
    assert_eq!(id, rec_id);
    assert!(rating.is_cleaned());

    destroy(rec);
    destroy(cap);
}

#[test]
fun unset_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    // Nothing attached — a no-op must stay silent rather than announce a change.
    adv::unset_rating(&mut rec, &cap);
    assert_eq!(event::events_by_type<adv::AdvisoryRatingUnsetEvent>().length(), 0);

    adv::set_rating(&mut rec, &cap, adv::explicit());
    adv::unset_rating(&mut rec, &cap);

    let events = event::events_by_type<adv::AdvisoryRatingUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(adv::unset_event_recording_id(&events[0]), rec_id);

    destroy(rec);
    destroy(cap);
}

/// Ratings live on their own recording's UID; one recording's rating is not
/// visible from another.
#[test]
fun ratings_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ctx,
    );

    adv::set_rating(&mut a, &a_cap, adv::explicit());

    assert!(adv::has_rating(&a));
    assert!(!adv::has_rating(&b));

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test, expected_failure(abort_code = adv::ENoRating)]
fun rating_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec(ctx);
    let _ = adv::rating(&rec);
    destroy(rec);
    destroy(cap);
}
