// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenarios for this package's full use case, run under
/// `sui::test_scenario`: the `Recording` is published and shared exactly as
/// production does it (create-and-publish is atomic; there is no keep
/// function), then re-accessed via `take_shared` in later transactions, with
/// distinct senders proving the shared-object round trip and permissionless
/// reads. The admin supplies the typed capability for mutations, while a
/// stranger holding no capability at all can still read the resulting state
/// back in a transaction of their own.
///
/// `RecordingAdminCap<RecordingShare>` is a type-level capability parameter;
/// the pinned `recording::uid_mut` ignores cap ID, sender, and recording
/// lifecycle. This package therefore makes no per-recording cap-identity
/// claim. Its storage isolation guarantee is that credits live on the
/// recording's own UID rather than in any global table keyed by party ID — see
/// `credits_tests::credits_are_scoped_to_their_own_recording`.
#[test_only]
module recording_credits::recording_credits_e2e_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers::{Self, RecordingShare, CompositionShare};
use credit::credit;
use partyos::party;
use recording_credits::recording_credits as credits;
use recording_credits::recording_party_role as rpr;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;
use sui::test_scenario::{Self, Scenario};

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

fun expected_credit_added(
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    role_kinds: vector<u8>,
    role_names: vector<vector<u8>>,
    role_instruments: vector<vector<u8>>,
    role_levels: vector<u8>,
    credit_index: u64,
    credit_count_before: u64,
    credit_count_after: u64,
    credits_initialized: bool,
): vector<u8> {
    let mut bytes = vector[];
    bytes.append(bcs::to_bytes(&recording_id));
    bytes.append(bcs::to_bytes(&composition_id));
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&party_id));
    bytes.append(bcs::to_bytes(&display_name));
    bytes.append(bcs::to_bytes(&role_kinds));
    bytes.append(bcs::to_bytes(&role_names));
    bytes.append(bcs::to_bytes(&role_instruments));
    bytes.append(bcs::to_bytes(&role_levels));
    bytes.append(bcs::to_bytes(&credit_index));
    bytes.append(bcs::to_bytes(&credit_count_before));
    bytes.append(bcs::to_bytes(&credit_count_after));
    bytes.append(bcs::to_bytes(&credits_initialized));
    bytes
}

fun expected_credit_removed(
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    role_kinds: vector<u8>,
    role_names: vector<vector<u8>>,
    role_instruments: vector<vector<u8>>,
    role_levels: vector<u8>,
    credit_index: u64,
    credit_count_before: u64,
    credit_count_after: u64,
    was_primary_artist: bool,
    was_featured_artist: bool,
): vector<u8> {
    let mut bytes = expected_credit_added(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        display_name,
        role_kinds,
        role_names,
        role_instruments,
        role_levels,
        credit_index,
        credit_count_before,
        credit_count_after,
        false,
    );
    bytes.pop_back();
    bytes.append(bcs::to_bytes(&was_primary_artist));
    bytes.append(bcs::to_bytes(&was_featured_artist));
    bytes
}

fun expected_artist_added(
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    artist_index: u64,
    artist_count_before: u64,
    artist_count_after: u64,
    credit_count_after: u64,
): vector<u8> {
    let mut bytes = vector[];
    bytes.append(bcs::to_bytes(&recording_id));
    bytes.append(bcs::to_bytes(&composition_id));
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&party_id));
    bytes.append(bcs::to_bytes(&display_name));
    bytes.append(bcs::to_bytes(&artist_index));
    bytes.append(bcs::to_bytes(&artist_count_before));
    bytes.append(bcs::to_bytes(&artist_count_after));
    bytes.append(bcs::to_bytes(&credit_count_after));
    bytes
}

fun expected_artist_removed(
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    artist_index: u64,
    artist_count_before: u64,
    artist_count_after: u64,
    credit_count_after: u64,
    caused_by_credit_removal: bool,
): vector<u8> {
    let mut bytes = expected_artist_added(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        display_name,
        artist_index,
        artist_count_before,
        artist_count_after,
        credit_count_after,
    );
    bytes.append(bcs::to_bytes(&caused_by_credit_removal));
    bytes
}

/// Creates and publishes a recording, sharing it — production's
/// create-and-publish-atomic shape (a fresh `Recording` is `key`-only with
/// no `drop`; `publish` is its sole by-value consumer). The admin cap is
/// address-owned and never shared, so it is carried as a plain local value
/// across `next_tx` calls, following the `recording_advisory` precedent; only
/// the `Recording` itself is genuinely
/// shared and re-accessed via `take_shared`.
fun publish_shared_recording(
    ts: &mut Scenario,
): RecordingAdminCap<RecordingShare> {
    let comp_id = test_helpers::fake_id(ts.ctx());
    let (rec, cap) = recording::new_for_testing<RecordingShare, CompositionShare>(comp_id, ts.ctx());
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&cap, &clock);
    clock.destroy_for_testing();
    cap
}

/// The flagship path: a recording is published and shared, the admin credits
/// two parties and designates one primary / one featured across a later
/// transaction (asserting the full event payloads emitted along the way),
/// and a stranger holding no capability at all reads the exact same
/// resulting state back in a transaction of their own.
#[test]
fun full_credit_lifecycle_on_published_shared_recording() {
    let mut ts = test_scenario::begin(ADMIN);
    let cap = publish_shared_recording(&mut ts);

    // --- Tx 2 (ADMIN): the recording is now a shared object; take it and
    // run the full write lifecycle against it ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<RecordingShare, CompositionShare>>();
    let clock = sui::clock::create_for_testing(ts.ctx());
    let (lead, lead_cap) =
        party::new(party::new_individual_kind(), b"Lead Party".to_string(), &clock, ts.ctx());
    let (guest, guest_cap) =
        party::new(party::new_individual_kind(), b"Guest Party".to_string(), &clock, ts.ctx());
    clock.destroy_for_testing();
    let lead_id = object::id(&lead);
    let guest_id = object::id(&guest);
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let lead_address = lead_id.to_address();
    let guest_address = guest_id.to_address();

    let lead_credit =
        credit::new(b"Lead Display".to_string(), vector[rpr::new_vocalist_role(option::some(rpr::new_lead_role_level()))]);
    let guest_credit =
        credit::new(b"Guest Display".to_string(), vector[rpr::new_vocalist_role(option::some(rpr::new_featured_role_level()))]);
    credits::add_credit(&mut rec, &cap, &lead, lead_credit);
    credits::add_credit(&mut rec, &cap, &guest, guest_credit);
    credits::add_primary_artist(&mut rec, &cap, &lead);
    credits::add_featured_artist(&mut rec, &cap, &guest);

    assert_eq!(credits::credits(&rec).length(), 2);
    assert!(credits::is_primary_artist(&rec, lead_id));
    assert!(credits::is_featured_artist(&rec, guest_id));
    assert!(!credits::is_featured_artist(&rec, lead_id));
    assert!(!credits::is_primary_artist(&rec, guest_id));

    // Full CreditAddedEvent payloads, not just presence.
    let added = event::events_by_type<credits::CreditAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(added.length(), 2);
    assert_eq!(credits::credit_added_event_fields(&added[0]), expected_credit_added(
        recording_id,
        composition_id,
        admin_cap_id,
        lead_address,
        b"Lead Display",
        vector[30],
        vector[b"Vocalist"],
        vector[b""],
        vector[7],
        0,
        0,
        1,
        true,
    ));
    assert_eq!(credits::credit_added_event_fields(&added[1]), expected_credit_added(
        recording_id,
        composition_id,
        admin_cap_id,
        guest_address,
        b"Guest Display",
        vector[30],
        vector[b"Vocalist"],
        vector[b""],
        vector[6],
        1,
        1,
        2,
        false,
    ));

    // Full PrimaryArtistAddedEvent / FeaturedArtistAddedEvent payloads. These
    // must be asserted in the same transaction they were emitted in —
    // `test_scenario::next_tx` finalizes the transaction's effects (via the
    // native `end_transaction`), so `event::events_by_type` no longer sees
    // them once the scenario moves to the next transaction.
    let primary_added = event::events_by_type<credits::PrimaryArtistAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(primary_added.length(), 1);
    assert_eq!(credits::primary_artist_added_event_fields(&primary_added[0]), expected_artist_added(
        recording_id,
        composition_id,
        admin_cap_id,
        lead_address,
        b"Lead Display",
        0,
        0,
        1,
        2,
    ));

    let featured_added = event::events_by_type<credits::FeaturedArtistAddedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(featured_added.length(), 1);
    assert_eq!(credits::featured_artist_added_event_fields(&featured_added[0]), expected_artist_added(
        recording_id,
        composition_id,
        admin_cap_id,
        guest_address,
        b"Guest Display",
        0,
        0,
        1,
        2,
    ));

    // Each phantom parameter is part of the event type filter. A filter with
    // only one matching share type must not include this event family.
    assert_eq!(event::events_by_type<credits::CreditAddedEvent<RecordingShare, bool>>().length(), 0);
    assert_eq!(event::events_by_type<credits::CreditAddedEvent<bool, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::PrimaryArtistAddedEvent<RecordingShare, bool>>().length(), 0);
    assert_eq!(event::events_by_type<credits::PrimaryArtistAddedEvent<bool, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::FeaturedArtistAddedEvent<RecordingShare, bool>>().length(), 0);
    assert_eq!(event::events_by_type<credits::FeaturedArtistAddedEvent<bool, CompositionShare>>().length(), 0);

    test_scenario::return_shared(rec);

    // --- Tx 3 (STRANGER, holds no capability whatsoever): reads the shared
    // recording back — proving reads are permissionless ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<RecordingShare, CompositionShare>>();
    assert_eq!(credits::credits(&rec).length(), 2);
    assert!(credits::is_primary_artist(&rec, lead_id));
    assert!(credits::is_featured_artist(&rec, guest_id));
    assert!(!credits::is_featured_artist(&rec, lead_id));
    assert!(!credits::is_primary_artist(&rec, guest_id));

    // Read-only views are silent; the new transaction contains no mutation
    // events despite reading every exposed projection.
    assert_eq!(event::events_by_type<credits::CreditAddedEvent<RecordingShare, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::CreditRemovedEvent<RecordingShare, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::PrimaryArtistAddedEvent<RecordingShare, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::PrimaryArtistRemovedEvent<RecordingShare, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::FeaturedArtistAddedEvent<RecordingShare, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::FeaturedArtistRemovedEvent<RecordingShare, CompositionShare>>().length(), 0);

    test_scenario::return_shared(rec);

    destroy(cap);
    destroy(lead); destroy(lead_cap);
    destroy(guest); destroy(guest_cap);
    ts.end();
}

/// Post-publish, cross-transaction removal: the admin removes a party's
/// credit on the shared recording (cascading their primary designation), a
/// stranger confirms the removal is visible, and then a later attempt to
/// re-designate that same party as primary fails — the credit is gone, not
/// merely the designation, so "operate after remove" cannot be worked around
/// by any actor, including the admin.
#[test, expected_failure(abort_code = 52, location = recording_credits::recording_credits)] // EPartyNotCredited
fun remove_credit_then_add_primary_fails_on_published_recording() {
    let mut ts = test_scenario::begin(ADMIN);
    let cap = publish_shared_recording(&mut ts);

    // --- Tx 2 (ADMIN): credits, designations, then removals ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<RecordingShare, CompositionShare>>();
    let clock = sui::clock::create_for_testing(ts.ctx());
    let (p, _pc) = party::new(party::new_individual_kind(), b"Alice Party".to_string(), &clock, ts.ctx());
    let (featured, _featured_pc) = party::new(party::new_individual_kind(), b"Featured Party".to_string(), &clock, ts.ctx());
    clock.destroy_for_testing();
    let pid = object::id(&p);
    let featured_id = object::id(&featured);
    let recording_id = object::id(&rec).to_address();
    let composition_id = recording::composition_id(&rec).to_address();
    let admin_cap_id = object::id(&cap).to_address();
    let party_id = pid.to_address();
    let featured_party_id = featured_id.to_address();
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice Display".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &featured,
        credit::new(b"Featured Display".to_string(), vector[rpr::new_producer_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p);
    credits::add_featured_artist(&mut rec, &cap, &featured);
    credits::remove_credit(&mut rec, &cap, pid);
    credits::remove_credit(&mut rec, &cap, featured_id);

    let removed = event::events_by_type<credits::CreditRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(removed.length(), 2);
    assert_eq!(credits::credit_removed_event_fields(&removed[0]), expected_credit_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        b"Alice Display",
        vector[30],
        vector[b"Vocalist"],
        vector[b""],
        vector[0],
        0,
        2,
        1,
        true,
        false,
    ));
    assert_eq!(credits::credit_removed_event_fields(&removed[1]), expected_credit_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        featured_party_id,
        b"Featured Display",
        vector[23],
        vector[b"Producer"],
        vector[b""],
        vector[0],
        0,
        1,
        0,
        false,
        true,
    ));

    let primary_removed = event::events_by_type<credits::PrimaryArtistRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(primary_removed.length(), 1);
    assert_eq!(credits::primary_artist_removed_event_fields(&primary_removed[0]), expected_artist_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        party_id,
        b"Alice Display",
        0,
        1,
        0,
        1,
        true,
    ));
    let featured_removed = event::events_by_type<credits::FeaturedArtistRemovedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(featured_removed.length(), 1);
    assert_eq!(credits::featured_artist_removed_event_fields(&featured_removed[0]), expected_artist_removed(
        recording_id,
        composition_id,
        admin_cap_id,
        featured_party_id,
        b"Featured Display",
        0,
        1,
        0,
        0,
        true,
    ));
    assert_eq!(event::events_by_type<credits::CreditRemovedEvent<RecordingShare, bool>>().length(), 0);
    assert_eq!(event::events_by_type<credits::CreditRemovedEvent<bool, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::PrimaryArtistRemovedEvent<RecordingShare, bool>>().length(), 0);
    assert_eq!(event::events_by_type<credits::PrimaryArtistRemovedEvent<bool, CompositionShare>>().length(), 0);
    assert_eq!(event::events_by_type<credits::FeaturedArtistRemovedEvent<RecordingShare, bool>>().length(), 0);
    assert_eq!(event::events_by_type<credits::FeaturedArtistRemovedEvent<bool, CompositionShare>>().length(), 0);
    assert!(!credits::is_primary_artist(&rec, pid));
    assert!(!credits::is_featured_artist(&rec, featured_id));

    test_scenario::return_shared(rec);

    // --- Tx 3 (STRANGER): confirms the removal is visible before the
    // adversarial re-operate attempt below ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<RecordingShare, CompositionShare>>();
    assert_eq!(credits::credits(&rec).length(), 0);
    test_scenario::return_shared(rec);

    // --- Tx 4 (ADMIN): re-operating on the removed party must abort ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<RecordingShare, CompositionShare>>();
    credits::add_primary_artist(&mut rec, &cap, &p);
    abort
}
