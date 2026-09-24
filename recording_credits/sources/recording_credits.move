// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Credits for a recording: one `Credit<RecordingPartyRole>` per credited
/// `Party` plus primary and featured artist designations, kept in a single
/// record stored as a dynamic field on the recording's UID and written
/// through its cap-gated `uid_mut`.
///
/// Attribution is display-oriented and varies across platforms, so it lives
/// here rather than in immutable core, and it may be attached before or after
/// publish. This is musicos's canonical credits standard; because it is an
/// extension, other parties may publish their own against the same
/// `Recording`. Credits are not read by the economics.
///
/// The primary and featured sets are disjoint subsets of the credited
/// parties: removing a credit ends any designation the party held.
module recording_credits::recording_credits;

use credit::credit::Credit;
use musicos::recording::{Recording, RecordingAdminCap};
use partyos::party::Party;
use recording_credits::recording_party_role::RecordingPartyRole;
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

// === Errors ===

// Constraint errors (30-39)
/// Credit has too many roles.
const EExceedsMaxRoles: u64 = 30;
/// Recording has too many credits.
const EMaxCreditsExceeded: u64 = 32;
/// Recording has too many primary artists.
const EMaxPrimaryArtistsExceeded: u64 = 34;
/// Recording has too many featured artists.
const EMaxFeaturedArtistsExceeded: u64 = 35;

// Conflict errors (40-49)
/// Party already has a credit on this recording.
const EPartyAlreadyCredited: u64 = 40;
/// Party is already a primary artist.
const EAlreadyPrimaryArtist: u64 = 41;
/// Party is already a featured artist.
const EAlreadyFeaturedArtist: u64 = 42;

// Reference errors (50-59)
/// No credits record is attached to this recording.
const ENoCredits: u64 = 50;
/// Party is not credited on the recording.
const EPartyNotCredited: u64 = 52;

// === Constants ===

/// Maximum number of roles a credit can have.
const MAX_ROLES_PER_CREDIT: u64 = 10;
/// Maximum number of credits allowed on a recording.
const MAX_CREDITS: u64 = 150;
/// Maximum number of primary artists allowed on a recording.
const MAX_PRIMARY_ARTISTS: u64 = 20;
/// Maximum number of featured artists allowed on a recording.
const MAX_FEATURED_ARTISTS: u64 = 50;

// === Structs ===

/// Dynamic-field key — one canonical credits record per recording.
public struct ExtensionKey() has copy, drop, store;

/// The per-recording attribution record, stored under `ExtensionKey()`.
public struct RecordingCredits has store {
    /// Party ID to credit (display name + roles), in insertion order.
    credits: VecMap<ID, Credit<RecordingPartyRole>>,
    /// IDs of the primary artists. Always a subset of `credits`.
    primary_artist_ids: VecSet<ID>,
    /// IDs of the featured artists. Always a subset of `credits`.
    featured_artist_ids: VecSet<ID>,
}

// === Events ===

/// Emitted when a party is credited, with the roles as stored (instrument
/// names and levels included); the display name stays in storage.
public struct RecordingCreditAddedEvent<phantom RecordingShare> has copy, drop {
    recording_id: ID,
    party_id: ID,
    roles: vector<RecordingPartyRole>,
}

/// Emitted when a party's credit is removed, after the artist-removed event
/// for any designation the party held.
public struct RecordingCreditRemovedEvent<phantom RecordingShare> has copy, drop {
    recording_id: ID,
    party_id: ID,
}

/// Emitted when a credited party is designated a primary artist.
public struct RecordingPrimaryArtistAddedEvent<phantom RecordingShare> has copy, drop {
    recording_id: ID,
    party_id: ID,
}

/// Emitted when a primary artist is un-designated, explicitly or because
/// their credit is removed (then before `RecordingCreditRemovedEvent`).
public struct RecordingPrimaryArtistRemovedEvent<phantom RecordingShare> has copy, drop {
    recording_id: ID,
    party_id: ID,
}

/// Emitted when a credited party is designated a featured artist.
public struct RecordingFeaturedArtistAddedEvent<phantom RecordingShare> has copy, drop {
    recording_id: ID,
    party_id: ID,
}

/// Emitted when a featured artist is un-designated, explicitly or because
/// their credit is removed (then before `RecordingCreditRemovedEvent`).
public struct RecordingFeaturedArtistRemovedEvent<phantom RecordingShare> has copy, drop {
    recording_id: ID,
    party_id: ID,
}

// === Public Functions ===

/// Credits a party, creating the record on first use. A credit carries 1-10
/// roles (`credit::new` guarantees at least one) and a party holds at most
/// one credit; re-crediting a party aborts rather than silently passing. At
/// capacity, even a duplicate party reports `EMaxCreditsExceeded`.
public fun add_credit<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party: &Party,
    credit: Credit<RecordingPartyRole>,
) {
    assert!(credit.roles().length() <= MAX_ROLES_PER_CREDIT, EExceedsMaxRoles);

    let recording_id = object::id(self);
    let party_id = object::id(party);
    let roles = *credit.roles();
    let rc = borrow_mut_or_init(self.uid_mut(cap));
    assert!(rc.credits.length() < MAX_CREDITS, EMaxCreditsExceeded);
    assert!(!rc.credits.contains(&party_id), EPartyAlreadyCredited);
    rc.credits.insert(party_id, credit);

    emit(RecordingCreditAddedEvent<RecordingShare> {
        recording_id,
        party_id,
        roles,
    });
}

/// Removes a party's credit and, with it, any primary or featured
/// designation. A cleared designation emits its artist-removed event first,
/// then the credit removal is emitted, so the stream never shows a
/// designated party who is uncredited. Aborts when no record is attached or
/// the party is not credited. Removing the last credit keeps the empty record
/// attached.
public fun remove_credit<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party_id: ID,
) {
    let recording_id = object::id(self);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.credits.contains(&party_id), EPartyNotCredited);
    if (rc.primary_artist_ids.contains(&party_id)) {
        rc.primary_artist_ids.remove(&party_id);
        emit(RecordingPrimaryArtistRemovedEvent<RecordingShare> { recording_id, party_id });
    };
    if (rc.featured_artist_ids.contains(&party_id)) {
        rc.featured_artist_ids.remove(&party_id);
        emit(RecordingFeaturedArtistRemovedEvent<RecordingShare> { recording_id, party_id });
    };
    let (_, _) = rc.credits.remove(&party_id);

    emit(RecordingCreditRemovedEvent<RecordingShare> { recording_id, party_id });
}

/// Designates a credited party as a primary artist. Aborts if the party is
/// uncredited, already primary or featured, or the primary set is full.
public fun add_primary_artist<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party: &Party,
) {
    let recording_id = object::id(self);
    let party_id = object::id(party);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.primary_artist_ids.length() < MAX_PRIMARY_ARTISTS, EMaxPrimaryArtistsExceeded);
    assert!(rc.credits.contains(&party_id), EPartyNotCredited);
    assert!(!rc.featured_artist_ids.contains(&party_id), EAlreadyFeaturedArtist);
    assert!(!rc.primary_artist_ids.contains(&party_id), EAlreadyPrimaryArtist);
    rc.primary_artist_ids.insert(party_id);

    emit(RecordingPrimaryArtistAddedEvent<RecordingShare> {
        recording_id,
        party_id,
    });
}

/// Removes a party's primary designation, leaving the credit intact. Aborts
/// `EPartyNotCredited` if the party is not a primary artist.
public fun remove_primary_artist<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party_id: ID,
) {
    let recording_id = object::id(self);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.primary_artist_ids.contains(&party_id), EPartyNotCredited);
    rc.primary_artist_ids.remove(&party_id);

    emit(RecordingPrimaryArtistRemovedEvent<RecordingShare> {
        recording_id,
        party_id,
    });
}

/// Designates a credited party as a featured artist. Aborts if the party is
/// uncredited, already primary or featured, or the featured set is full.
public fun add_featured_artist<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party: &Party,
) {
    let recording_id = object::id(self);
    let party_id = object::id(party);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.featured_artist_ids.length() < MAX_FEATURED_ARTISTS, EMaxFeaturedArtistsExceeded);
    assert!(rc.credits.contains(&party_id), EPartyNotCredited);
    assert!(!rc.primary_artist_ids.contains(&party_id), EAlreadyPrimaryArtist);
    assert!(!rc.featured_artist_ids.contains(&party_id), EAlreadyFeaturedArtist);
    rc.featured_artist_ids.insert(party_id);

    emit(RecordingFeaturedArtistAddedEvent<RecordingShare> {
        recording_id,
        party_id,
    });
}

/// Removes a party's featured designation, leaving the credit intact. Aborts
/// `EPartyNotCredited` if the party is not a featured artist.
public fun remove_featured_artist<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party_id: ID,
) {
    let recording_id = object::id(self);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.featured_artist_ids.contains(&party_id), EPartyNotCredited);
    rc.featured_artist_ids.remove(&party_id);

    emit(RecordingFeaturedArtistRemovedEvent<RecordingShare> {
        recording_id,
        party_id,
    });
}

// === View Functions ===

/// Whether a credits record has been attached to this recording yet.
public fun has_credits<RecordingShare>(self: &Recording<RecordingShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The party-to-credit map. Aborts `ENoCredits` when none is attached.
public fun credits<RecordingShare>(
    self: &Recording<RecordingShare>,
): &VecMap<ID, Credit<RecordingPartyRole>> {
    &borrow(self.uid()).credits
}

/// The primary-artist IDs. Aborts `ENoCredits` when none is attached.
public fun primary_artist_ids<RecordingShare>(self: &Recording<RecordingShare>): &VecSet<ID> {
    &borrow(self.uid()).primary_artist_ids
}

/// The featured-artist IDs. Aborts `ENoCredits` when none is attached.
public fun featured_artist_ids<RecordingShare>(self: &Recording<RecordingShare>): &VecSet<ID> {
    &borrow(self.uid()).featured_artist_ids
}

/// Whether the party is a primary artist (false if no record is attached).
public fun is_primary_artist<RecordingShare>(
    self: &Recording<RecordingShare>,
    party_id: ID,
): bool {
    has_credits(self) && borrow(self.uid()).primary_artist_ids.contains(&party_id)
}

/// Whether the party is a featured artist (false if no record is attached).
public fun is_featured_artist<RecordingShare>(
    self: &Recording<RecordingShare>,
    party_id: ID,
): bool {
    has_credits(self) && borrow(self.uid()).featured_artist_ids.contains(&party_id)
}

// === Private Functions ===

fun borrow(uid: &UID): &RecordingCredits {
    assert!(df::exists(uid, ExtensionKey()), ENoCredits);
    df::borrow(uid, ExtensionKey())
}

fun borrow_mut(uid: &mut UID): &mut RecordingCredits {
    assert!(df::exists(uid, ExtensionKey()), ENoCredits);
    df::borrow_mut(uid, ExtensionKey())
}

fun borrow_mut_or_init(uid: &mut UID): &mut RecordingCredits {
    if (!df::exists(uid, ExtensionKey())) {
        df::add(
            uid,
            ExtensionKey(),
            RecordingCredits {
                credits: vec_map::empty(),
                primary_artist_ids: vec_set::empty(),
                featured_artist_ids: vec_set::empty(),
            },
        );
    };
    df::borrow_mut(uid, ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun credit_added_event_fields<RecordingShare>(
    e: &RecordingCreditAddedEvent<RecordingShare>,
): (ID, ID, vector<RecordingPartyRole>) {
    (e.recording_id, e.party_id, e.roles)
}

#[test_only]
public fun credit_removed_event_fields<RecordingShare>(
    e: &RecordingCreditRemovedEvent<RecordingShare>,
): (ID, ID) {
    (e.recording_id, e.party_id)
}

#[test_only]
public fun primary_artist_added_event_fields<RecordingShare>(
    e: &RecordingPrimaryArtistAddedEvent<RecordingShare>,
): (ID, ID) {
    (e.recording_id, e.party_id)
}

#[test_only]
public fun primary_artist_removed_event_fields<RecordingShare>(
    e: &RecordingPrimaryArtistRemovedEvent<RecordingShare>,
): (ID, ID) {
    (e.recording_id, e.party_id)
}

#[test_only]
public fun featured_artist_added_event_fields<RecordingShare>(
    e: &RecordingFeaturedArtistAddedEvent<RecordingShare>,
): (ID, ID) {
    (e.recording_id, e.party_id)
}

#[test_only]
public fun featured_artist_removed_event_fields<RecordingShare>(
    e: &RecordingFeaturedArtistRemovedEvent<RecordingShare>,
): (ID, ID) {
    (e.recording_id, e.party_id)
}
