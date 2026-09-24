// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Lifecycle, boundary and event tests for the lyrics extension. Caps are
/// type-bound (`CompositionAdminCap<CompositionShare>`), so a wrong-cap
/// runtime test is impossible; `tests/check_cap_types.py` proves the
/// compile-time rejection instead.
#[test_only]
module composition_lyrics::composition_lyrics_tests;

use composition_lyrics::composition_lyrics as cl;
use language_code::language_code as lc;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::test_helpers::CompositionShare;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;
use sui::test_scenario;

fun new_composition(
    ctx: &mut TxContext,
): (Composition<CompositionShare>, CompositionAdminCap<CompositionShare>) {
    composition::new_for_testing(1500, ctx)
}

/// Asserts a set event's fields and its exact BCS layout: `composition_id`
/// (32) then the two-byte language code as a ULEB128-prefixed string (3).
fun assert_set_event(
    e: &cl::CompositionLyricsSetEvent<CompositionShare>,
    composition_id: address,
    language: vector<u8>,
) {
    let (event_id, event_language) = cl::set_event_fields(e);
    assert_eq!(event_id, composition_id);
    assert_eq!(event_language, language.to_string());

    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_vec_u8(), language);
    assert!(bytes.into_remainder_bytes().is_empty());
    assert_eq!(bcs::to_bytes(e).length(), 35);
}

/// Asserts a cleared event's fields and its exact 35-byte BCS layout.
fun assert_cleared_event(
    e: &cl::CompositionLyricsClearedEvent<CompositionShare>,
    composition_id: address,
    language: vector<u8>,
) {
    let (event_id, event_language) = cl::clear_event_fields(e);
    assert_eq!(event_id, composition_id);
    assert_eq!(event_language, language.to_string());

    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_vec_u8(), language);
    assert!(bytes.into_remainder_bytes().is_empty());
    assert_eq!(bcs::to_bytes(e).length(), 35);
}

#[test]
fun languages_are_independent_and_events_replay_transitions() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let en = lc::new(b"en".to_string());
    let ja = lc::new(b"ja".to_string());
    let id = object::id(&comp).to_address();
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

    // Equal replacement is silent; each other transition emits one event.
    let sets = event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 3);
    assert_set_event(&sets[0], id, b"en");
    assert_set_event(&sets[1], id, b"ja");
    assert_set_event(&sets[2], id, b"en");

    cl::clear_lyrics(&mut comp, &cap, en);
    cl::clear_lyrics(&mut comp, &cap, en);
    assert!(!cl::has_lyrics(&comp, en));
    assert_eq!(*cl::lyrics(&comp, ja), vector[42]);
    let clears = event::events_by_type<cl::CompositionLyricsClearedEvent<CompositionShare>>();
    assert_eq!(clears.length(), 1);
    assert_cleared_event(&clears[0], id, b"en");

    // Re-adding after a clear emits again.
    cl::set_lyrics(&mut comp, &cap, en, first);
    let sets = event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 4);
    assert_set_event(&sets[3], id, b"en");
    cl::clear_lyrics(&mut comp, &cap, en);
    cl::clear_lyrics(&mut comp, &cap, ja);
    destroy(comp);
    destroy(cap);
}

/// Setting the bytes already stored neither emits nor changes the entry.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let en = lc::new(b"en".to_string());
    let id = object::id(&comp).to_address();

    cl::set_lyrics(&mut comp, &cap, en, vector[1, 2, 3]);
    let events_after_first = event::num_events();
    cl::set_lyrics(&mut comp, &cap, en, vector[1, 2, 3]);
    assert_eq!(event::num_events(), events_after_first);
    assert_eq!(*cl::lyrics(&comp, en), vector[1, 2, 3]);

    let sets = event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 1);
    assert_set_event(&sets[0], id, b"en");
    destroy(comp);
    destroy(cap);
}

#[test]
fun views_and_absent_clear_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let en = lc::new(b"en".to_string());

    let events_before = event::num_events();
    assert!(!cl::has_lyrics(&comp, en));
    cl::clear_lyrics(&mut comp, &cap, en);
    assert_eq!(event::num_events(), events_before);

    cl::set_lyrics(&mut comp, &cap, en, vector[1]);
    let events_after_set = event::num_events();
    assert!(cl::has_lyrics(&comp, en));
    assert_eq!(*cl::lyrics(&comp, en), vector[1]);
    assert_eq!(event::num_events(), events_after_set);
    destroy(comp);
    destroy(cap);
}

#[test]
fun empty_payload_is_distinct_from_absence() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let en = lc::new(b"en".to_string());
    let id = object::id(&comp).to_address();
    cl::set_lyrics(&mut comp, &cap, en, vector[]);
    assert!(cl::has_lyrics(&comp, en));
    assert!(cl::lyrics(&comp, en).is_empty());
    cl::set_lyrics(&mut comp, &cap, en, vector[]);
    let sets = event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 1);
    assert_set_event(&sets[0], id, b"en");
    cl::clear_lyrics(&mut comp, &cap, en);
    assert!(!cl::has_lyrics(&comp, en));
    let clears = event::events_by_type<cl::CompositionLyricsClearedEvent<CompositionShare>>();
    assert_eq!(clears.length(), 1);
    assert_cleared_event(&clears[0], id, b"en");
    destroy(comp);
    destroy(cap);
}

/// The event size is fixed regardless of payload size: a full 32,768-byte
/// body produces the same 35-byte events as an empty one.
#[test]
fun maximum_payload_can_be_added_replaced_and_cleared() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let en = lc::new(b"en".to_string());
    let id = object::id(&comp).to_address();
    assert_eq!(cl::max_lyrics_length(), 32768);
    let data = vector::tabulate!(32768, |_| 255u8);
    let other = vector::tabulate!(32768, |_| 0u8);
    cl::set_lyrics(&mut comp, &cap, en, data);
    cl::set_lyrics(&mut comp, &cap, en, data);
    assert_eq!(*cl::lyrics(&comp, en), data);
    cl::set_lyrics(&mut comp, &cap, en, other);
    assert_eq!(*cl::lyrics(&comp, en), other);
    let sets = event::events_by_type<cl::CompositionLyricsSetEvent<CompositionShare>>();
    assert_eq!(sets.length(), 2);
    assert_set_event(&sets[0], id, b"en");
    assert_set_event(&sets[1], id, b"en");
    cl::clear_lyrics(&mut comp, &cap, en);
    let clears = event::events_by_type<cl::CompositionLyricsClearedEvent<CompositionShare>>();
    assert_cleared_event(&clears[0], id, b"en");
    destroy(comp);
    destroy(cap);
}

#[test, expected_failure(abort_code = cl::ELyricsTooLong)]
fun oversized_payload_aborts_on_add() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    cl::set_lyrics(&mut comp, &cap, lc::new(b"en".to_string()), vector::tabulate!(32769, |_| 0u8));
    abort
}

#[test, expected_failure(abort_code = cl::ELyricsTooLong)]
fun oversized_payload_aborts_on_replace() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    cl::set_lyrics(&mut comp, &cap, lc::new(b"en".to_string()), vector[1]);
    cl::set_lyrics(&mut comp, &cap, lc::new(b"en".to_string()), vector::tabulate!(32769, |_| 0u8));
    abort
}

#[test, expected_failure(abort_code = cl::ENoLyrics)]
fun missing_language_aborts_even_when_another_exists() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    cl::set_lyrics(&mut comp, &cap, lc::new(b"en".to_string()), vector[1]);
    cl::lyrics(&comp, lc::new(b"ja".to_string()));
    abort
}

#[test, expected_failure(abort_code = cl::ENoLyrics)]
fun cleared_language_aborts_on_read() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    cl::set_lyrics(&mut comp, &cap, lc::new(b"en".to_string()), vector[1]);
    cl::clear_lyrics(&mut comp, &cap, lc::new(b"en".to_string()));
    cl::lyrics(&comp, lc::new(b"en".to_string()));
    abort
}

#[test]
fun published_composition_supports_edits_and_permissionless_reads() {
    let mut ts = test_scenario::begin(@0xA);
    let (comp, cap) = new_composition(ts.ctx());
    comp.publish(&cap);
    transfer::public_transfer(cap, @0xA);

    ts.next_tx(@0xA);
    let mut comp = ts.take_shared<Composition<CompositionShare>>();
    let cap = ts.take_from_sender<CompositionAdminCap<CompositionShare>>();
    cl::set_lyrics(&mut comp, &cap, lc::new(b"en".to_string()), vector[1]);
    cl::set_lyrics(&mut comp, &cap, lc::new(b"ja".to_string()), vector[2]);
    ts.return_to_sender(cap);
    test_scenario::return_shared(comp);

    ts.next_tx(@0xB);
    let comp = ts.take_shared<Composition<CompositionShare>>();
    assert_eq!(*cl::lyrics(&comp, lc::new(b"en".to_string())), vector[1]);
    assert_eq!(*cl::lyrics(&comp, lc::new(b"ja".to_string())), vector[2]);
    test_scenario::return_shared(comp);

    ts.next_tx(@0xA);
    let mut comp = ts.take_shared<Composition<CompositionShare>>();
    let cap = ts.take_from_sender<CompositionAdminCap<CompositionShare>>();
    cl::set_lyrics(&mut comp, &cap, lc::new(b"en".to_string()), vector[3]);
    cl::clear_lyrics(&mut comp, &cap, lc::new(b"ja".to_string()));
    ts.return_to_sender(cap);
    test_scenario::return_shared(comp);

    ts.next_tx(@0xB);
    let comp = ts.take_shared<Composition<CompositionShare>>();
    assert_eq!(*cl::lyrics(&comp, lc::new(b"en".to_string())), vector[3]);
    assert!(!cl::has_lyrics(&comp, lc::new(b"ja".to_string())));
    test_scenario::return_shared(comp);
    ts.end();
}

public struct OtherShare has copy, drop, store {}

#[test]
fun composition_share_types_have_separate_state_and_event_streams() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = new_composition(ctx);
    let (mut other, other_cap) = composition::new_for_testing<OtherShare>(1500, ctx);
    let en = lc::new(b"en".to_string());
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
