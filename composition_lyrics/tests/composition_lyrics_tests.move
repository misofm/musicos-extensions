// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_lyrics::composition_lyrics_tests;

use composition_lyrics::composition_lyrics as cl;
use language_code::language_code as lc;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::test_helpers::CompositionShare;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

fun new_composition(
    ctx: &mut TxContext,
): (Composition<CompositionShare>, CompositionAdminCap<CompositionShare>) {
    composition::new_for_testing("Song", 1500, ctx)
}

#[test]
fun languages_are_independent_and_events_replay_transitions() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let en = lc::new("en");
    let ja = lc::new("ja");
    let id = object::id(&comp).to_address();
    let cap_id = object::id(&cap).to_address();
    assert!(!cl::has_lyrics(&comp, en));
    cl::clear_lyrics(&mut comp, &cap, en);
    assert!(event::events_by_type<cl::CompositionLyricsClearedEvent<CompositionShare>>().is_empty());

    // Deliberately opaque, non-UTF-8 data: only size and authority are enforced.
    let first = vector[0u8, 255, 128];
    cl::set_lyrics(&mut comp, &cap, en, first);
    cl::set_lyrics(&mut comp, &cap, ja, vector[42]);
    cl::set_lyrics(&mut comp, &cap, en, vector[7]);
    cl::set_lyrics(&mut comp, &cap, en, vector[7]);
    assert_eq!(*cl::lyrics(&comp, en), vector[7]);
    assert_eq!(*cl::lyrics(&comp, ja), vector[42]);

    let sets = event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 4);
    assert_set_event(&sets[0], id, cap_id, b"en", false, vector[], first);
    assert_set_event(&sets[1], id, cap_id, b"ja", false, vector[], vector[42]);
    assert_set_event(&sets[2], id, cap_id, b"en", true, first, vector[7]);
    assert_set_event(&sets[3], id, cap_id, b"en", true, vector[7], vector[7]);

    cl::clear_lyrics(&mut comp, &cap, en);
    cl::clear_lyrics(&mut comp, &cap, en);
    assert!(!cl::has_lyrics(&comp, en));
    assert_eq!(*cl::lyrics(&comp, ja), vector[42]);
    let clears = event::events_by_type<cl::CompositionLyricsClearedEvent<CompositionShare>>();
    assert_eq!(clears.length(), 1);
    let (event_id, event_cap, event_language, before) = cl::clear_event_fields(&clears[0]);
    assert_eq!(event_id, id);
    assert_eq!(event_cap, cap_id);
    assert_eq!(event_language, b"en");
    assert_eq!(before, vector[7]);

    cl::set_lyrics(&mut comp, &cap, en, first);
    let sets = event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>();
    assert_set_event(&sets[4], id, cap_id, b"en", false, vector[], first);
    cl::clear_lyrics(&mut comp, &cap, en);
    cl::clear_lyrics(&mut comp, &cap, ja);
    destroy(comp);
    destroy(cap);
}

#[test]
fun empty_payload_is_distinct_from_absence() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let en = lc::new("en");
    cl::set_lyrics(&mut comp, &cap, en, vector[]);
    assert!(cl::has_lyrics(&comp, en));
    assert!(cl::lyrics(&comp, en).is_empty());
    cl::set_lyrics(&mut comp, &cap, en, vector[]);
    let sets = event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>();
    let (_, _, _, existed, before, after) = cl::set_event_fields(&sets[1]);
    assert!(existed);
    assert!(before.is_empty() && after.is_empty());
    cl::clear_lyrics(&mut comp, &cap, en);
    assert!(!cl::has_lyrics(&comp, en));
    assert_eq!(event::events_by_type<cl::CompositionLyricsClearedEvent<CompositionShare>>().length(), 1);
    destroy(comp);
    destroy(cap);
}

#[test]
fun maximum_payload_can_be_added_replaced_and_cleared() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let en = lc::new("en");
    assert_eq!(cl::max_lyrics_length(), 32768);
    let data = vector::tabulate!(32768, |_| 255u8);
    cl::set_lyrics(&mut comp, &cap, en, data);
    cl::set_lyrics(&mut comp, &cap, en, data);
    assert_eq!(*cl::lyrics(&comp, en), data);
    let sets = event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>();
    let (_, _, _, existed, before, after) = cl::set_event_fields(&sets[1]);
    assert!(existed);
    assert_eq!(before, data);
    assert_eq!(after, data);
    cl::clear_lyrics(&mut comp, &cap, en);
    let clears = event::events_by_type<cl::CompositionLyricsClearedEvent<CompositionShare>>();
    let (_, _, _, before) = cl::clear_event_fields(&clears[0]);
    assert_eq!(before, data);
    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = cl::EMaxLyricsLengthExceeded)]
fun oversized_payload_aborts_on_add() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, _cap) = new_composition(ctx);
    cl::set_lyrics(&mut comp, &_cap, lc::new("en"), vector::tabulate!(32769, |_| 0u8));
    abort
}

#[test, expected_failure(abort_code = cl::EMaxLyricsLengthExceeded)]
fun oversized_payload_aborts_on_replace() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    cl::set_lyrics(&mut comp, &cap, lc::new("en"), vector[1]);
    cl::set_lyrics(&mut comp, &cap, lc::new("en"), vector::tabulate!(32769, |_| 0u8));
    abort
}

#[test, expected_failure(abort_code = cl::ENoLyrics)]
fun missing_language_aborts_even_when_another_exists() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    cl::set_lyrics(&mut comp, &cap, lc::new("en"), vector[1]);
    cl::lyrics(&comp, lc::new("ja"));
    abort
}

#[test, expected_failure(abort_code = cl::ENoLyrics)]
fun cleared_language_aborts_on_read() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    cl::set_lyrics(&mut comp, &cap, lc::new("en"), vector[1]);
    cl::clear_lyrics(&mut comp, &cap, lc::new("en"));
    cl::lyrics(&comp, lc::new("en"));
    abort
}

#[test]
fun published_composition_supports_edits_and_permissionless_reads() {
    let mut ts = test_scenario::begin(@0xA);
    let (comp, cap) = new_composition(ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    comp.publish(&cap, &clock);
    clock.destroy_for_testing();
    transfer::public_transfer(cap, @0xA);

    ts.next_tx(@0xA);
    let mut comp = ts.take_shared<Composition<CompositionShare>>();
    let cap = ts.take_from_sender<CompositionAdminCap<CompositionShare>>();
    cl::set_lyrics(&mut comp, &cap, lc::new("en"), vector[1]);
    cl::set_lyrics(&mut comp, &cap, lc::new("ja"), vector[2]);
    ts.return_to_sender(cap);
    test_scenario::return_shared(comp);

    ts.next_tx(@0xB);
    let comp = ts.take_shared<Composition<CompositionShare>>();
    assert_eq!(*cl::lyrics(&comp, lc::new("en")), vector[1]);
    assert_eq!(*cl::lyrics(&comp, lc::new("ja")), vector[2]);
    test_scenario::return_shared(comp);

    ts.next_tx(@0xA);
    let mut comp = ts.take_shared<Composition<CompositionShare>>();
    let cap = ts.take_from_sender<CompositionAdminCap<CompositionShare>>();
    cl::set_lyrics(&mut comp, &cap, lc::new("en"), vector[3]);
    cl::clear_lyrics(&mut comp, &cap, lc::new("ja"));
    ts.return_to_sender(cap);
    test_scenario::return_shared(comp);

    ts.next_tx(@0xB);
    let comp = ts.take_shared<Composition<CompositionShare>>();
    assert_eq!(*cl::lyrics(&comp, lc::new("en")), vector[3]);
    assert!(!cl::has_lyrics(&comp, lc::new("ja")));
    test_scenario::return_shared(comp);
    ts.end();
}

public struct OtherShare has copy, drop, store {}

#[test]
fun composition_share_types_have_separate_state_and_event_streams() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let (mut other, other_cap) = composition::new_for_testing<OtherShare>("Other", 1500, ctx);
    let en = lc::new("en");
    cl::set_lyrics(&mut comp, &cap, en, vector[1]);
    cl::set_lyrics(&mut other, &other_cap, en, vector[2]);
    assert_eq!(*cl::lyrics(&comp, en), vector[1]);
    assert_eq!(*cl::lyrics(&other, en), vector[2]);
    assert_eq!(event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>().length(), 1);
    assert_eq!(event::events_by_type<cl::CompositionLyricsSetEvent<OtherShare>>().length(), 1);
    cl::clear_lyrics(&mut comp, &cap, en);
    assert_eq!(*cl::lyrics(&other, en), vector[2]);
    assert_eq!(event::events_by_type<cl::CompositionLyricsClearedEvent<CompositionShare>>().length(), 1);
    assert!(event::events_by_type<cl::CompositionLyricsClearedEvent<OtherShare>>().is_empty());
    cl::clear_lyrics(&mut other, &other_cap, en);
    destroy(comp);
    destroy(cap);
    destroy(other);
    destroy(other_cap);
}

fun assert_set_event(
    e: &cl::CompositionLyricsSetEvent<CompositionShare>,
    id: address,
    cap: address,
    language: vector<u8>,
    existed: bool,
    before: vector<u8>,
    after: vector<u8>,
) {
    let (actual_id, actual_cap, actual_language, actual_existed, actual_before, actual_after) =
        cl::set_event_fields(e);
    assert_eq!(actual_id, id);
    assert_eq!(actual_cap, cap);
    assert_eq!(actual_language, language);
    assert_eq!(actual_existed, existed);
    assert_eq!(actual_before, before);
    assert_eq!(actual_after, after);
}
