// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end coverage against a published, shared `Release` across real
/// transaction boundaries and different senders.
#[test_only]
module release_mix_reference::release_mix_reference_e2e_tests;

use miso::release::{Self, Release};
use miso::{test_helpers, track};
use ori::walrus_data;
use release_mix_reference::release_mix_reference as mix_ref;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const ADMIN: address = @0xAD;
const LISTENER: address = @0x51;

#[test]
fun published_shared_release_attach_read_replace_flow() {
    let mut scenario = test_scenario::begin(ADMIN);

    let composition_id = test_helpers::fake_id(scenario.ctx());
    let recording_id = test_helpers::fake_id(scenario.ctx());
    let placeholder_release_id = test_helpers::fake_id(scenario.ctx());
    let tracks = vector[track::new_for_testing(
        composition_id,
        recording_id,
        placeholder_release_id,
        10000u16,
    )];
    let (release, cap) = release::new_for_testing("Shared Mix", tracks, scenario.ctx());
    let release_id = object::id(&release);
    let clock = sui::clock::create_for_testing(scenario.ctx());
    release.publish(&cap, &clock);
    clock.destroy_for_testing();

    scenario.next_tx(ADMIN);
    let mut release = scenario.take_shared<Release>();
    assert!(!mix_ref::has_mix_reference(&release, 0));
    mix_ref::attach_mix_reference(&mut release, &cap, 0, walrus_data::new_blob(11));
    assert!(mix_ref::has_mix_reference(&release, 0));
    assert_eq!(mix_ref::mix_reference(&release, 0).blob_id(), 11);

    let attached = event::events_by_type<mix_ref::MixReferenceAttachedEvent>();
    assert_eq!(attached.length(), 1);
    let (event_release_id, track_index, event_recording_id, descriptor) =
        mix_ref::attached_event_fields(&attached[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(track_index, 0);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(descriptor.blob_id(), 11);
    test_scenario::return_shared(release);

    scenario.next_tx(LISTENER);
    let release = scenario.take_shared<Release>();
    assert!(mix_ref::has_mix_reference(&release, 0));
    assert_eq!(mix_ref::mix_reference(&release, 0).blob_id(), 11);
    test_scenario::return_shared(release);

    scenario.next_tx(ADMIN);
    let mut release = scenario.take_shared<Release>();
    mix_ref::replace_mix_reference(&mut release, &cap, 0, walrus_data::new_blob(22));
    assert_eq!(mix_ref::mix_reference(&release, 0).blob_id(), 22);

    let replaced = event::events_by_type<mix_ref::MixReferenceReplacedEvent>();
    assert_eq!(replaced.length(), 1);
    let (event_release_id, track_index, event_recording_id, descriptor) =
        mix_ref::replaced_event_fields(&replaced[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(track_index, 0);
    assert_eq!(event_recording_id, recording_id);
    assert_eq!(descriptor.blob_id(), 22);
    test_scenario::return_shared(release);

    scenario.next_tx(LISTENER);
    let release = scenario.take_shared<Release>();
    assert_eq!(mix_ref::mix_reference(&release, 0).blob_id(), 22);
    test_scenario::return_shared(release);

    destroy(cap);
    scenario.end();
}
