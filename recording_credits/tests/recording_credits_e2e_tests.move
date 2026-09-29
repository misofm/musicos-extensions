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
/// `RecordingAdminCap` is bound to one recording object. The core checks
/// this identity on each admin write; the credits live on that recording's UID.
#[test_only]
module recording_credits::recording_credits_e2e_tests;

use credit::credit;
use musicos::composition;
use musicos::recording::{Self, Recording, RecordingAdminCap};
use partyos::party;
use recording_credits::recording_credits as credits;
use recording_credits::recording_party_role as rpr;
use std::unit_test::{assert_eq, destroy};
use sui::event::events_by_type;
use sui::test_scenario::{Self, Scenario};

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

/// Creates and publishes a recording, sharing it — production's
/// create-and-publish-atomic shape (a fresh `Recording` is `key`-only with
/// no `drop`; `publish` is its sole by-value consumer). The admin cap is
/// address-owned and never shared, so it is carried as a plain local value
/// across `next_tx` calls, following the `recording_advisory` precedent; only
/// the `Recording` itself is genuinely shared and re-accessed via
/// `take_shared`.
fun publish_shared_recording(ts: &mut Scenario): RecordingAdminCap {
    let (comp, comp_cap) = composition::new(ts.ctx());
    let (rec, cap) = recording::new(&comp, ts.ctx());
    comp.publish(&comp_cap);
    destroy(comp_cap);
    rec.publish(&cap);
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
    let mut rec = ts.take_shared<Recording>();
    let (lead, lead_cap) = party::new(party::new_individual_kind(), b"Lead Party".to_string(), ts.ctx());
    let (guest, guest_cap) = party::new(party::new_individual_kind(), b"Guest Party".to_string(), ts.ctx());
    let lead_id = object::id(&lead);
    let guest_id = object::id(&guest);
    let recording_id = object::id(&rec);

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

    // Full RecordingCreditAddedEvent payloads, not just presence.
    let added = events_by_type<credits::RecordingCreditAddedEvent>();
    assert_eq!(added.length(), 2);
    let (event_object, event_party, event_roles) = credits::credit_added_event_fields(&added[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, lead_id);
    assert_eq!(event_roles, *lead_credit.roles());
    let (event_object, event_party, event_roles) = credits::credit_added_event_fields(&added[1]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, guest_id);
    assert_eq!(event_roles, *guest_credit.roles());
    assert_eq!(credits::credits(&rec)[&lead_id], lead_credit);
    assert_eq!(credits::credits(&rec)[&guest_id], guest_credit);

    // Designation payloads. These must be asserted in the same transaction
    // they were emitted in — `test_scenario::next_tx` finalizes the
    // transaction's effects, so `events_by_type` no longer sees them once
    // the scenario moves on.
    let primary_added = events_by_type<credits::RecordingPrimaryArtistAddedEvent>();
    assert_eq!(primary_added.length(), 1);
    let (event_object, event_party) = credits::primary_artist_added_event_fields(&primary_added[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, lead_id);
    let featured_added = events_by_type<credits::RecordingFeaturedArtistAddedEvent>();
    assert_eq!(featured_added.length(), 1);
    let (event_object, event_party) = credits::featured_artist_added_event_fields(&featured_added[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, guest_id);


    test_scenario::return_shared(rec);

    // --- Tx 3 (STRANGER, holds no capability whatsoever): reads the shared
    // recording back — proving reads are permissionless ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording>();
    assert_eq!(credits::credits(&rec).length(), 2);
    assert!(credits::is_primary_artist(&rec, lead_id));
    assert!(credits::is_featured_artist(&rec, guest_id));
    assert!(!credits::is_featured_artist(&rec, lead_id));
    assert!(!credits::is_primary_artist(&rec, guest_id));

    // Read-only views are silent; the new transaction contains no mutation
    // events despite reading every exposed projection.
    assert_eq!(events_by_type<credits::RecordingCreditAddedEvent>().length(), 0);
    assert_eq!(events_by_type<credits::RecordingCreditRemovedEvent>().length(), 0);
    assert_eq!(events_by_type<credits::RecordingPrimaryArtistAddedEvent>().length(), 0);
    assert_eq!(events_by_type<credits::RecordingPrimaryArtistRemovedEvent>().length(), 0);
    assert_eq!(events_by_type<credits::RecordingFeaturedArtistAddedEvent>().length(), 0);
    assert_eq!(events_by_type<credits::RecordingFeaturedArtistRemovedEvent>().length(), 0);

    test_scenario::return_shared(rec);

    destroy(cap);
    destroy(lead); destroy(lead_cap);
    destroy(guest); destroy(guest_cap);
    ts.end();
}

/// Post-publish, cross-transaction removal: the admin removes a party's
/// credit on the shared recording (cascading their primary designation with
/// its own event), a stranger confirms the removal is visible, and then a
/// later attempt to re-designate that same party as primary fails — the
/// credit is gone, not merely the designation, so "operate after remove"
/// cannot be worked around by any actor, including the admin.
#[test, expected_failure(abort_code = credits::EPartyNotCredited)]
fun remove_credit_then_add_primary_fails_on_published_recording() {
    let mut ts = test_scenario::begin(ADMIN);
    let cap = publish_shared_recording(&mut ts);

    // --- Tx 2 (ADMIN): credits, designations, then removals ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording>();
    let (p, _pc) = party::new(party::new_individual_kind(), b"Alice Party".to_string(), ts.ctx());
    let (featured, _featured_pc) = party::new(party::new_individual_kind(), b"Featured Party".to_string(), ts.ctx());
    let pid = object::id(&p);
    let featured_id = object::id(&featured);
    let recording_id = object::id(&rec);
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice Display".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_credit(&mut rec, &cap, &featured,
        credit::new(b"Featured Display".to_string(), vector[rpr::new_producer_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p);
    credits::add_featured_artist(&mut rec, &cap, &featured);
    credits::remove_credit(&mut rec, &cap, pid);
    credits::remove_credit(&mut rec, &cap, featured_id);

    let removed = events_by_type<credits::RecordingCreditRemovedEvent>();
    assert_eq!(removed.length(), 2);
    let (event_object, event_party) = credits::credit_removed_event_fields(&removed[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, pid);
    let (event_object, event_party) = credits::credit_removed_event_fields(&removed[1]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, featured_id);

    // The cascade ends both designations, each with its own event.
    let primary_removed = events_by_type<credits::RecordingPrimaryArtistRemovedEvent>();
    assert_eq!(primary_removed.length(), 1);
    let (event_object, event_party) = credits::primary_artist_removed_event_fields(&primary_removed[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, pid);
    let featured_removed = events_by_type<credits::RecordingFeaturedArtistRemovedEvent>();
    assert_eq!(featured_removed.length(), 1);
    let (event_object, event_party) = credits::featured_artist_removed_event_fields(&featured_removed[0]);
    assert_eq!(event_object, recording_id);
    assert_eq!(event_party, featured_id);
    assert!(!credits::is_primary_artist(&rec, pid));
    assert!(!credits::is_featured_artist(&rec, featured_id));

    test_scenario::return_shared(rec);

    // --- Tx 3 (STRANGER): confirms the removal is visible before the
    // adversarial re-operate attempt below ---
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording>();
    assert_eq!(credits::credits(&rec).length(), 0);
    test_scenario::return_shared(rec);

    // --- Tx 4 (ADMIN): re-operating on the removed party must abort ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording>();
    credits::add_primary_artist(&mut rec, &cap, &p);
    abort
}
