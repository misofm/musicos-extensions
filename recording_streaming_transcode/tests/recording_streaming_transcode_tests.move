// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_streaming_transcode::recording_streaming_transcode_tests;

use musicos::recording;
use musicos::test_helpers;
use ori::data;
use recording_streaming_transcode::recording_streaming_transcode as transcode;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
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
    recording::new_for_testing<REC, COMP>(test_helpers::fake_id(ctx), ctx)
}

fun new_transcode(quilt_id: u256): transcode::StreamingTranscode {
    transcode::new(data::new_quilt(quilt_id))
}

fun quilt_id(value: &transcode::StreamingTranscode): u256 {
    transcode::quilt(value).quilt_id()
}

fun assert_set_payload(
    event: &transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    had_transcode: bool,
    previous_quilt_id: u256,
    quilt_id: u256,
) {
    let (
        actual_recording_id,
        actual_composition_id,
        actual_admin_cap_id,
        actual_had_transcode,
        actual_previous_quilt_id,
        actual_quilt_id,
    ) = transcode::set_event_payload(event);
    assert_eq!(actual_recording_id, recording_id);
    assert_eq!(actual_composition_id, composition_id);
    assert_eq!(actual_admin_cap_id, admin_cap_id);
    assert_eq!(actual_had_transcode, had_transcode);
    assert_eq!(actual_previous_quilt_id, previous_quilt_id);
    assert_eq!(actual_quilt_id, quilt_id);
}

fun assert_clear_payload(
    event: &transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    quilt_id: u256,
) {
    let (
        actual_recording_id,
        actual_composition_id,
        actual_admin_cap_id,
        actual_quilt_id,
    ) = transcode::clear_event_payload(event);
    assert_eq!(actual_recording_id, recording_id);
    assert_eq!(actual_composition_id, composition_id);
    assert_eq!(actual_admin_cap_id, admin_cap_id);
    assert_eq!(actual_quilt_id, quilt_id);
}

fun assert_set_bcs(
    event: &transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    had_transcode: bool,
    previous_quilt_id: u256,
    quilt_id: u256,
) {
    let mut bytes = bcs::new(transcode::set_event_bcs(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_bool(), had_transcode);
    assert_eq!(bytes.peel_u256(), previous_quilt_id);
    assert_eq!(bytes.peel_u256(), quilt_id);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_clear_bcs(
    event: &transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    quilt_id: u256,
) {
    let mut bytes = bcs::new(transcode::clear_event_bcs(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_u256(), quilt_id);
    assert!(bytes.into_remainder_bytes().is_empty());
}

/// Replays only decoded event bytes, then compares the projection to views.
fun project_set_event(
    projected_exists: &mut bool,
    projected_quilt_id: &mut u256,
    event: &transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>,
) {
    let mut bytes = bcs::new(transcode::set_event_bcs(event));
    let _recording_id = bytes.peel_address();
    let _composition_id = bytes.peel_address();
    let _admin_cap_id = bytes.peel_address();
    let had_transcode = bytes.peel_bool();
    let previous_quilt_id = bytes.peel_u256();
    let quilt_id = bytes.peel_u256();
    assert_eq!(had_transcode, *projected_exists);
    if (had_transcode) {
        assert_eq!(previous_quilt_id, *projected_quilt_id);
    } else {
        assert_eq!(previous_quilt_id, 0);
    };
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_exists = true;
    *projected_quilt_id = quilt_id;
}

fun project_clear_event(
    projected_exists: &mut bool,
    projected_quilt_id: &mut u256,
    event: &transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>,
) {
    let mut bytes = bcs::new(transcode::clear_event_bcs(event));
    let _recording_id = bytes.peel_address();
    let _composition_id = bytes.peel_address();
    let _admin_cap_id = bytes.peel_address();
    let quilt_id = bytes.peel_u256();
    assert!(*projected_exists);
    assert_eq!(quilt_id, *projected_quilt_id);
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_exists = false;
    *projected_quilt_id = 0;
}

fun assert_projection_matches_view(
    recording: &recording::Recording<REC, COMP>,
    projected_exists: bool,
    projected_quilt_id: u256,
) {
    assert_eq!(transcode::has_streaming_transcode(recording), projected_exists);
    if (projected_exists) {
        assert_eq!(quilt_id(transcode::streaming_transcode(recording)), projected_quilt_id);
    };
}

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording).to_address();
    let composition_id = recording::composition_id(&recording).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let mut projected_exists = false;
    let mut projected_quilt_id = 0;

    assert!(!transcode::has_streaming_transcode(&recording));

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(111));
    assert!(transcode::has_streaming_transcode(&recording));
    assert_eq!(quilt_id(transcode::streaming_transcode(&recording)), 111);
    let set_events = event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 1);
    assert_set_payload(&set_events[0], recording_id, composition_id, admin_cap_id, false, 0, 111);
    project_set_event(&mut projected_exists, &mut projected_quilt_id, &set_events[0]);
    assert_projection_matches_view(&recording, projected_exists, projected_quilt_id);

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(222));
    assert_eq!(quilt_id(transcode::streaming_transcode(&recording)), 222);
    let set_events = event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 2);
    assert_set_payload(&set_events[1], recording_id, composition_id, admin_cap_id, true, 111, 222);
    project_set_event(&mut projected_exists, &mut projected_quilt_id, &set_events[1]);
    assert_projection_matches_view(&recording, projected_exists, projected_quilt_id);

    // Equal replacement is still an assignment and event.
    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(222));
    let set_events = event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 3);
    assert_set_payload(&set_events[2], recording_id, composition_id, admin_cap_id, true, 222, 222);
    project_set_event(&mut projected_exists, &mut projected_quilt_id, &set_events[2]);
    assert_projection_matches_view(&recording, projected_exists, projected_quilt_id);

    transcode::unset_streaming_transcode(&mut recording, &cap);
    assert!(!transcode::has_streaming_transcode(&recording));
    let clear_events = event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>>();
    assert_eq!(clear_events.length(), 1);
    assert_clear_payload(&clear_events[0], recording_id, composition_id, admin_cap_id, 222);
    project_clear_event(&mut projected_exists, &mut projected_quilt_id, &clear_events[0]);
    assert_projection_matches_view(&recording, projected_exists, projected_quilt_id);

    // Unset is idempotent.
    transcode::unset_streaming_transcode(&mut recording, &cap);
    assert!(!transcode::has_streaming_transcode(&recording));
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>>().length(), 1);
    assert_projection_matches_view(&recording, projected_exists, projected_quilt_id);

    // Re-set after removal is a fresh attachment, then clear it again.
    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(333));
    let set_events = event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 4);
    assert_set_payload(&set_events[3], recording_id, composition_id, admin_cap_id, false, 0, 333);
    project_set_event(&mut projected_exists, &mut projected_quilt_id, &set_events[3]);
    assert_projection_matches_view(&recording, projected_exists, projected_quilt_id);
    transcode::unset_streaming_transcode(&mut recording, &cap);
    assert!(!transcode::has_streaming_transcode(&recording));
    let clear_events = event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>>();
    assert_eq!(clear_events.length(), 2);
    assert_clear_payload(&clear_events[1], recording_id, composition_id, admin_cap_id, 333);
    project_clear_event(&mut projected_exists, &mut projected_quilt_id, &clear_events[1]);
    assert_projection_matches_view(&recording, projected_exists, projected_quilt_id);

    // Four 161-byte set events plus two 128-byte clear events compose exactly
    // 900 bytes of decoded event payloads.
    assert_eq!(transcode::set_event_bcs(&set_events[0]).length(), 161);
    assert_eq!(transcode::set_event_bcs(&set_events[1]).length(), 161);
    assert_eq!(transcode::set_event_bcs(&set_events[2]).length(), 161);
    assert_eq!(transcode::set_event_bcs(&set_events[3]).length(), 161);
    assert_eq!(transcode::clear_event_bcs(&clear_events[0]).length(), 128);
    assert_eq!(transcode::clear_event_bcs(&clear_events[1]).length(), 128);
    assert_eq!(
        transcode::set_event_bcs(&set_events[0]).length()
            + transcode::set_event_bcs(&set_events[1]).length()
            + transcode::set_event_bcs(&set_events[2]).length()
            + transcode::set_event_bcs(&set_events[3]).length()
            + transcode::clear_event_bcs(&clear_events[0]).length()
            + transcode::clear_event_bcs(&clear_events[1]).length(),
        900,
    );

    destroy(recording);
    destroy(cap);
}

#[test]
fun complete_u256_quilt_id_domain_is_preserved() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording).to_address();
    let composition_id = recording::composition_id(&recording).to_address();
    let admin_cap_id = object::id(&cap).to_address();

    let values = vector[
        0u256,
        9007199254740993u256,
        9223372036854775809u256,
        MAX_U256,
    ];
    values.do!(|value| {
        transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(value));
        assert_eq!(quilt_id(transcode::streaming_transcode(&recording)), value);
    });

    let set_events = event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 4);
    // A present field with Quilt ID zero is distinct from an absent field.
    assert_set_payload(&set_events[0], recording_id, composition_id, admin_cap_id, false, 0, 0);
    assert_set_bcs(&set_events[0], recording_id, composition_id, admin_cap_id, false, 0, 0);
    assert_set_payload(
        &set_events[1],
        recording_id,
        composition_id,
        admin_cap_id,
        true,
        0,
        9007199254740993,
    );
    assert_set_bcs(
        &set_events[1],
        recording_id,
        composition_id,
        admin_cap_id,
        true,
        0,
        9007199254740993,
    );
    assert_set_payload(
        &set_events[2],
        recording_id,
        composition_id,
        admin_cap_id,
        true,
        9007199254740993,
        9223372036854775809,
    );
    assert_set_bcs(
        &set_events[2],
        recording_id,
        composition_id,
        admin_cap_id,
        true,
        9007199254740993,
        9223372036854775809,
    );
    assert_set_payload(
        &set_events[3],
        recording_id,
        composition_id,
        admin_cap_id,
        true,
        9223372036854775809,
        MAX_U256,
    );
    assert_set_bcs(
        &set_events[3],
        recording_id,
        composition_id,
        admin_cap_id,
        true,
        9223372036854775809,
        MAX_U256,
    );

    transcode::unset_streaming_transcode(&mut recording, &cap);
    let clear_events = event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>>();
    assert_eq!(clear_events.length(), 1);
    assert_clear_payload(&clear_events[0], recording_id, composition_id, admin_cap_id, MAX_U256);
    assert_clear_bcs(&clear_events[0], recording_id, composition_id, admin_cap_id, MAX_U256);

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(0));
    transcode::unset_streaming_transcode(&mut recording, &cap);
    let clear_events = event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>>();
    assert_eq!(clear_events.length(), 2);
    assert_clear_payload(&clear_events[1], recording_id, composition_id, admin_cap_id, 0);
    assert_clear_bcs(&clear_events[1], recording_id, composition_id, admin_cap_id, 0);

    destroy(recording);
    destroy(cap);
}

#[test]
fun transcodes_are_isolated_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_recording(ctx);
    let (mut b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(
        test_helpers::fake_id(ctx),
        ctx,
    );
    let (mut c, c_cap) = recording::new_for_testing<REC, OTHER_COMP>(
        test_helpers::fake_id(ctx),
        ctx,
    );

    // Constructors and permissionless views are silent.
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<OTHER_REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<OTHER_REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, OTHER_COMP>>().length(), 0);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, OTHER_COMP>>().length(), 0);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<OTHER_REC, OTHER_COMP>>().length(), 0);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<OTHER_REC, OTHER_COMP>>().length(), 0);

    transcode::set_streaming_transcode(&mut a, &a_cap, new_transcode(9));
    transcode::set_streaming_transcode(&mut b, &b_cap, new_transcode(10));
    transcode::set_streaming_transcode(&mut c, &c_cap, new_transcode(11));

    assert!(transcode::has_streaming_transcode(&a));
    assert!(transcode::has_streaming_transcode(&b));
    assert!(transcode::has_streaming_transcode(&c));
    assert_eq!(quilt_id(transcode::streaming_transcode(&a)), 9);
    assert_eq!(quilt_id(transcode::streaming_transcode(&b)), 10);
    assert_eq!(quilt_id(transcode::streaming_transcode(&c)), 11);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<OTHER_REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, OTHER_COMP>>().length(), 1);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<OTHER_REC, OTHER_COMP>>().length(), 0);

    transcode::unset_streaming_transcode(&mut a, &a_cap);
    transcode::unset_streaming_transcode(&mut b, &b_cap);
    transcode::unset_streaming_transcode(&mut c, &c_cap);
    assert!(!transcode::has_streaming_transcode(&a));
    assert!(!transcode::has_streaming_transcode(&b));
    assert!(!transcode::has_streaming_transcode(&c));
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<OTHER_REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, OTHER_COMP>>().length(), 1);
    assert_eq!(event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<OTHER_REC, OTHER_COMP>>().length(), 0);

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
    destroy(c);
    destroy(c_cap);
}

#[test]
fun set_event_carries_recording_and_transcode() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording).to_address();
    let composition_id = recording::composition_id(&recording).to_address();
    let admin_cap_id = object::id(&cap).to_address();

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(7));

    let events = event::events_by_type<transcode::RecordingStreamingTranscodeSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    assert_set_payload(&events[0], recording_id, composition_id, admin_cap_id, false, 0, 7);
    assert_set_bcs(&events[0], recording_id, composition_id, admin_cap_id, false, 0, 7);
    let (event_recording_id, value) = transcode::set_event_fields(&events[0]);
    assert_eq!(event_recording_id, object::id_from_address(recording_id));
    assert_eq!(quilt_id(&value), 7);

    destroy(recording);
    destroy(cap);
}

#[test]
fun unset_event_is_emitted_only_after_removal() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, cap) = new_recording(ctx);
    let recording_id = object::id(&recording).to_address();
    let composition_id = recording::composition_id(&recording).to_address();
    let admin_cap_id = object::id(&cap).to_address();

    transcode::unset_streaming_transcode(&mut recording, &cap);
    assert_eq!(
        event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>>().length(),
        0,
    );

    transcode::set_streaming_transcode(&mut recording, &cap, new_transcode(5));
    transcode::unset_streaming_transcode(&mut recording, &cap);

    let events = event::events_by_type<transcode::RecordingStreamingTranscodeClearedEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    assert_clear_payload(&events[0], recording_id, composition_id, admin_cap_id, 5);
    assert_clear_bcs(&events[0], recording_id, composition_id, admin_cap_id, 5);
    assert_eq!(
        transcode::unset_event_recording_id(&events[0]),
        object::id_from_address(recording_id),
    );

    destroy(recording);
    destroy(cap);
}

#[test, expected_failure(abort_code = transcode::ENoStreamingTranscode)]
fun streaming_transcode_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (recording, cap) = new_recording(ctx);
    let _ = transcode::streaming_transcode(&recording);
    destroy(recording);
    destroy(cap);
}
