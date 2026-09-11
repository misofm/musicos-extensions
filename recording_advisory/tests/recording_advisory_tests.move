// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_advisory::recording_advisory_tests;

use musicos::recording;
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
public struct OTHER_COMP {}

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
    let rec_id = object::id(&rec).to_address();
    let comp_id = @0xC0FFEE;
    let cap_id = object::id(&cap).to_address();

    assert!(!adv::has_rating(&rec));

    adv::set_rating(&mut rec, &cap, adv::explicit());
    assert!(adv::has_rating(&rec));
    assert!(adv::rating(&rec).is_explicit());
    let set_events = event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 1);
    let (event_rec_id, event_comp_id, event_cap_id, had_rating, previous_rating, rating) =
        adv::set_event_fields(&set_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_comp_id, comp_id);
    assert_eq!(event_cap_id, cap_id);
    assert!(!had_rating);
    assert_eq!(previous_rating, 0);
    assert_eq!(rating, 0);

    // Equal replacement still emits once and snapshots the prior value.
    adv::set_rating(&mut rec, &cap, adv::explicit());
    let set_events = event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 2);
    let (_, _, _, had_rating, previous_rating, rating) = adv::set_event_fields(&set_events[1]);
    assert!(had_rating);
    assert_eq!(previous_rating, 0);
    assert_eq!(rating, 0);

    // Setting again replaces in place — a recording has one rating, not a history.
    adv::set_rating(&mut rec, &cap, adv::cleaned());
    assert!(adv::rating(&rec).is_cleaned());
    assert!(!adv::rating(&rec).is_explicit());
    let set_events = event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 3);
    let (_, _, _, had_rating, previous_rating, rating) = adv::set_event_fields(&set_events[2]);
    assert!(had_rating);
    assert_eq!(previous_rating, 0);
    assert_eq!(rating, 2);

    adv::unset_rating(&mut rec, &cap);
    assert!(!adv::has_rating(&rec));
    let clear_events =
        event::events_by_type<adv::RecordingAdvisoryRatingClearedEvent<REC, COMP>>();
    assert_eq!(clear_events.length(), 1);
    let (event_rec_id, event_comp_id, event_cap_id, previous_rating) =
        adv::clear_event_fields(&clear_events[0]);
    assert_eq!(event_rec_id, rec_id);
    assert_eq!(event_comp_id, comp_id);
    assert_eq!(event_cap_id, cap_id);
    assert_eq!(previous_rating, 2);

    // Unset is idempotent.
    adv::unset_rating(&mut rec, &cap);
    assert!(!adv::has_rating(&rec));
    assert_eq!(
        event::events_by_type<adv::RecordingAdvisoryRatingClearedEvent<REC, COMP>>().length(),
        1,
    );

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

    let events = event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, event_comp_id, event_cap_id, had_rating, previous_rating, rating) =
        adv::set_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id.to_address());
    assert_eq!(event_comp_id, @0xC0FFEE);
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert!(!had_rating);
    assert_eq!(previous_rating, 0);
    assert_eq!(rating, 2);
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 99);

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
    assert_eq!(
        event::events_by_type<adv::RecordingAdvisoryRatingClearedEvent<REC, COMP>>().length(),
        0,
    );

    adv::set_rating(&mut rec, &cap, adv::explicit());
    adv::unset_rating(&mut rec, &cap);

    let events = event::events_by_type<adv::RecordingAdvisoryRatingClearedEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, event_comp_id, event_cap_id, previous_rating) =
        adv::cleared_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id.to_address());
    assert_eq!(event_comp_id, @0xC0FFEE);
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert_eq!(previous_rating, 0);
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 97);

    destroy(rec);
    destroy(cap);
}

#[test]
fun clear_events_snapshot_each_rating_code() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let expected = vector[0u8, 1u8, 2u8];
    3u64.do!(|i| {
        let rating = if (i == 0) {
            adv::explicit()
        } else if (i == 1) {
            adv::not_explicit()
        } else {
            adv::cleaned()
        };
        adv::set_rating(&mut rec, &cap, rating);
        adv::unset_rating(&mut rec, &cap);

        let clears =
            event::events_by_type<adv::RecordingAdvisoryRatingClearedEvent<REC, COMP>>();
        assert_eq!(clears.length(), i + 1);
        let (_, event_comp_id, event_cap_id, previous_rating) =
            adv::clear_event_fields(&clears[i]);
        assert_eq!(event_comp_id, @0xC0FFEE);
        assert_eq!(event_cap_id, object::id(&cap).to_address());
        assert_eq!(previous_rating, expected[i]);
        assert_eq!(sui::bcs::to_bytes(&clears[i]).length(), 97);
    });
    assert!(!adv::has_rating(&rec));
    destroy(rec);
    destroy(cap);
}

#[test]
fun constructors_and_views_are_silent() {
    let before_set =
        event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, COMP>>().length();
    let before_clear =
        event::events_by_type<adv::RecordingAdvisoryRatingClearedEvent<REC, COMP>>().length();

    let explicit = adv::explicit();
    let not_explicit = adv::not_explicit();
    let cleaned = adv::cleaned();
    assert_eq!(explicit.name(), b"Explicit");
    assert_eq!(not_explicit.name(), b"NotExplicit");
    assert_eq!(cleaned.name(), b"Cleaned");
    assert!(explicit.is_explicit());
    assert!(not_explicit.is_not_explicit());
    assert!(cleaned.is_cleaned());
    assert_eq!(
        event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, COMP>>().length(),
        before_set,
    );
    assert_eq!(
        event::events_by_type<adv::RecordingAdvisoryRatingClearedEvent<REC, COMP>>().length(),
        before_clear,
    );

    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    assert!(!adv::has_rating(&rec));
    adv::set_rating(&mut rec, &cap, explicit);
    let after_set =
        event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, COMP>>().length();
    assert!(adv::has_rating(&rec));
    assert!(adv::rating(&rec).is_explicit());
    assert_eq!(
        event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, COMP>>().length(),
        after_set,
    );
    adv::unset_rating(&mut rec, &cap);
    let after_clear =
        event::events_by_type<adv::RecordingAdvisoryRatingClearedEvent<REC, COMP>>().length();
    assert!(!adv::has_rating(&rec));
    assert_eq!(
        event::events_by_type<adv::RecordingAdvisoryRatingClearedEvent<REC, COMP>>().length(),
        after_clear,
    );

    destroy(rec);
    destroy(cap);
}

/// Ratings live on their own recording's UID; one recording's rating is not
/// visible from another.
#[test]
fun ratings_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (mut b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ctx,
    );
    let (mut c, c_cap) = recording::new_for_testing<REC, OTHER_COMP>(
        object::id_from_address(@0xC0FFEE),
        ctx,
    );

    adv::set_rating(&mut a, &a_cap, adv::explicit());
    adv::set_rating(&mut b, &b_cap, adv::not_explicit());
    adv::set_rating(&mut c, &c_cap, adv::cleaned());

    assert!(adv::has_rating(&a));
    assert!(adv::has_rating(&b));
    assert!(adv::has_rating(&c));
    assert!(adv::rating(&a).is_explicit());
    assert!(adv::rating(&b).is_not_explicit());
    assert!(adv::rating(&c).is_cleaned());
    assert_eq!(
        event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, COMP>>().length(),
        1,
    );
    assert_eq!(
        event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<OTHER_REC, COMP>>().length(),
        1,
    );
    assert_eq!(
        event::events_by_type<adv::RecordingAdvisoryRatingSetEvent<REC, OTHER_COMP>>().length(),
        1,
    );

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
    destroy(c);
    destroy(c_cap);
}

#[test, expected_failure(abort_code = adv::ENoRating)]
fun rating_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec(ctx);
    let _ = adv::rating(&rec);
    destroy(rec);
    destroy(cap);
}
