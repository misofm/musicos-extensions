// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenarios for this package's full use case, run under
/// `sui::test_scenario`: the `Recording` is published and shared exactly as
/// production does it (create-and-publish is atomic; there is no keep
/// function), then re-accessed via `take_shared` in later transactions, with
/// distinct senders proving who is authorized to do what — the admin
/// manages credits and artist designations, while a stranger holding no
/// capability at all can still read them back.
///
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type
/// (one share currency per recording in production), so `recording::uid_mut`
/// performs no runtime cap check — there is deliberately no "wrong cap, same
/// type" test in this package (see `recording_advisory`'s test file for the
/// precedent). The real runtime-checked isolation guarantee this package
/// offers is that credits live on the recording's own UID rather than in any
/// global table keyed by party ID — see
/// `credits_tests::credits_are_scoped_to_their_own_recording`.
#[test_only]
module recording_credits::recording_credits_e2e_tests;

use miso::recording::{Self, Recording, RecordingAdminCap};
use miso::test_helpers::{Self, RecordingShare, CompositionShare};
use miso_credit::credit;
use partyos::party;
use recording_credits::recording_credits as credits;
use recording_credits::recording_party_role as rpr;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario::{Self, Scenario};

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

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
    let rec_id = object::id(&rec);
    let clock = sui::clock::create_for_testing(ts.ctx());
    let (lead, lead_cap) =
        party::new(party::new_individual_kind(), b"Lead".to_string(), &clock, ts.ctx());
    let (guest, guest_cap) =
        party::new(party::new_individual_kind(), b"Guest".to_string(), &clock, ts.ctx());
    clock.destroy_for_testing();
    let lead_id = object::id(&lead);
    let guest_id = object::id(&guest);

    let lead_credit =
        credit::new(b"Lead".to_string(), vector[rpr::new_vocalist_role(option::some(rpr::new_lead_role_level()))]);
    let guest_credit =
        credit::new(b"Guest".to_string(), vector[rpr::new_vocalist_role(option::some(rpr::new_featured_role_level()))]);
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
    let added = event::events_by_type<credits::CreditAddedEvent>();
    assert_eq!(added.length(), 2);
    let (rid0, pid0, c0) = credits::credit_added_event_fields(&added[0]);
    assert_eq!(rid0, rec_id);
    assert_eq!(pid0, lead_id);
    assert_eq!(
        c0,
        credit::new(b"Lead".to_string(), vector[rpr::new_vocalist_role(option::some(rpr::new_lead_role_level()))]),
    );
    let (rid1, pid1, c1) = credits::credit_added_event_fields(&added[1]);
    assert_eq!(rid1, rec_id);
    assert_eq!(pid1, guest_id);
    assert_eq!(
        c1,
        credit::new(b"Guest".to_string(), vector[rpr::new_vocalist_role(option::some(rpr::new_featured_role_level()))]),
    );

    // Full PrimaryArtistAddedEvent / FeaturedArtistAddedEvent payloads. These
    // must be asserted in the same transaction they were emitted in —
    // `test_scenario::next_tx` finalizes the transaction's effects (via the
    // native `end_transaction`), so `event::events_by_type` no longer sees
    // them once the scenario moves to the next transaction.
    let primary_added = event::events_by_type<credits::PrimaryArtistAddedEvent>();
    assert_eq!(primary_added.length(), 1);
    let (rid, pid) = credits::primary_artist_added_event_fields(&primary_added[0]);
    assert_eq!(rid, rec_id);
    assert_eq!(pid, lead_id);

    let featured_added = event::events_by_type<credits::FeaturedArtistAddedEvent>();
    assert_eq!(featured_added.length(), 1);
    let (rid2, pid2) = credits::featured_artist_added_event_fields(&featured_added[0]);
    assert_eq!(rid2, rec_id);
    assert_eq!(pid2, guest_id);

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

    // --- Tx 2 (ADMIN): credit, designate primary, then remove ---
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<RecordingShare, CompositionShare>>();
    let rec_id = object::id(&rec);
    let clock = sui::clock::create_for_testing(ts.ctx());
    let (p, _pc) = party::new(party::new_individual_kind(), b"Alice".to_string(), &clock, ts.ctx());
    clock.destroy_for_testing();
    let pid = object::id(&p);
    credits::add_credit(&mut rec, &cap, &p,
        credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));
    credits::add_primary_artist(&mut rec, &cap, &p);
    credits::remove_credit(&mut rec, &cap, pid);

    let removed = event::events_by_type<credits::CreditRemovedEvent>();
    assert_eq!(removed.length(), 1);
    let (rid, removed_pid, removed_credit) = credits::credit_removed_event_fields(&removed[0]);
    assert_eq!(rid, rec_id);
    assert_eq!(removed_pid, pid);
    assert_eq!(removed_credit, credit::new(b"Alice".to_string(), vector[rpr::new_vocalist_role(option::none())]));

    let primary_removed = event::events_by_type<credits::PrimaryArtistRemovedEvent>();
    assert_eq!(primary_removed.length(), 1);
    let (rid2, pid2) = credits::primary_artist_removed_event_fields(&primary_removed[0]);
    assert_eq!(rid2, rec_id);
    assert_eq!(pid2, pid);
    assert!(!credits::is_primary_artist(&rec, pid));

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
