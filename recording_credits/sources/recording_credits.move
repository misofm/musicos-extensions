// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// First-party credits extension for recordings.
///
/// Attribution (credits + primary/featured artists) is display-oriented and
/// varies across platforms, so it lives here as a dynamic field on the recording
/// rather than in immutable core. The data is attached under `ExtensionKey()` via
/// the recording's cap-gated `uid_mut`, so every mutation is authorized by the
/// recording's admin and credits survive into any lifecycle state (they may be
/// attached before or after the recording is published).
///
/// This is Miso's canonical credits standard; because it is an extension, other
/// parties may publish their own recording-credits standard against the same
/// `Recording`. Credits are NOT read by the economics — they are attribution.
module recording_credits::recording_credits;

use miso::recording::{Recording, RecordingAdminCap};
use miso_credit::credit::Credit;
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

/// The per-recording attribution record, stored as a dynamic field on the
/// recording's UID under `ExtensionKey()`.
public struct RecordingCredits has store {
    /// Map of party IDs to their credit (display name + roles).
    credits: VecMap<ID, Credit<RecordingPartyRole>>,
    /// IDs of the primary artists. Always a subset of `credits`.
    primary_artist_ids: VecSet<ID>,
    /// IDs of the featured artists. Always a subset of `credits`.
    featured_artist_ids: VecSet<ID>,
}

// === Events ===

/// Emitted when a credit is added to a recording. Carries the full credit
/// record so an indexer can upsert its row without re-reading the object.
public struct CreditAddedEvent has copy, drop {
    recording_id: ID,
    party_id: ID,
    credit: Credit<RecordingPartyRole>,
}

/// Emitted when a credit is removed from a recording. Carries the removed
/// credit record, which is otherwise unrecoverable once the write lands.
public struct CreditRemovedEvent has copy, drop {
    recording_id: ID,
    party_id: ID,
    credit: Credit<RecordingPartyRole>,
}

/// Emitted when a party is designated a primary artist.
public struct PrimaryArtistAddedEvent has copy, drop {
    recording_id: ID,
    party_id: ID,
}

/// Emitted when a party leaves the primary-artist set — either by an explicit
/// removal or as a cascade of removing their credit.
public struct PrimaryArtistRemovedEvent has copy, drop {
    recording_id: ID,
    party_id: ID,
}

/// Emitted when a party is designated a featured artist.
public struct FeaturedArtistAddedEvent has copy, drop {
    recording_id: ID,
    party_id: ID,
}

/// Emitted when a party leaves the featured-artist set — either by an explicit
/// removal or as a cascade of removing their credit.
public struct FeaturedArtistRemovedEvent has copy, drop {
    recording_id: ID,
    party_id: ID,
}

// === Public Functions ===

/// Adds a credit for a party on the recording, lazily creating the credits
/// record on first use. Each credit must have 1-10 roles, and a party may hold
/// at most one credit. Requires the recording's admin capability.
public fun add_credit<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party: &Party,
    credit: Credit<RecordingPartyRole>,
) {
    // Non-emptiness needs no check here: `Credit`'s only constructor
    // (`miso_credit::credit::new`, private fields, no mutators) already
    // guarantees at least one role for every value that can exist.
    assert!(credit.roles().length() <= MAX_ROLES_PER_CREDIT, EExceedsMaxRoles);

    let recording_id = object::id(self);
    let party_id = object::id(party);
    let rc = borrow_mut_or_init(self.uid_mut(cap));
    assert!(rc.credits.length() < MAX_CREDITS, EMaxCreditsExceeded);
    assert!(!rc.credits.contains(&party_id), EPartyAlreadyCredited);
    rc.credits.insert(party_id, credit);

    emit(CreditAddedEvent { recording_id, party_id, credit });
}

/// Removes a party's credit. Also drops them from the primary/featured sets,
/// preserving the invariant that those are subsets of the credited parties.
/// Requires the recording's admin capability.
public fun remove_credit<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party_id: ID,
) {
    let recording_id = object::id(self);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.credits.contains(&party_id), EPartyNotCredited);
    let (_, credit) = rc.credits.remove(&party_id);

    emit(CreditRemovedEvent { recording_id, party_id, credit });

    // Cascading out of the primary/featured sets is its own logical change
    // per set, so each gets its own event.
    if (rc.primary_artist_ids.contains(&party_id)) {
        rc.primary_artist_ids.remove(&party_id);
        emit(PrimaryArtistRemovedEvent { recording_id, party_id });
    };
    if (rc.featured_artist_ids.contains(&party_id)) {
        rc.featured_artist_ids.remove(&party_id);
        emit(FeaturedArtistRemovedEvent { recording_id, party_id });
    };
}

/// Designates an already-credited party as a primary artist. The party must be
/// credited and not already a primary or featured artist.
public fun add_primary_artist<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
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

    emit(PrimaryArtistAddedEvent { recording_id, party_id });
}

/// Removes a party from the primary-artist set (leaves the credit intact).
public fun remove_primary_artist<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party_id: ID,
) {
    let recording_id = object::id(self);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.primary_artist_ids.contains(&party_id), EPartyNotCredited);
    rc.primary_artist_ids.remove(&party_id);

    emit(PrimaryArtistRemovedEvent { recording_id, party_id });
}

/// Designates an already-credited party as a featured artist. The party must be
/// credited and not already a primary or featured artist.
public fun add_featured_artist<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
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

    emit(FeaturedArtistAddedEvent { recording_id, party_id });
}

/// Removes a party from the featured-artist set (leaves the credit intact).
public fun remove_featured_artist<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party_id: ID,
) {
    let recording_id = object::id(self);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.featured_artist_ids.contains(&party_id), EPartyNotCredited);
    rc.featured_artist_ids.remove(&party_id);

    emit(FeaturedArtistRemovedEvent { recording_id, party_id });
}

// === View Functions ===

/// Returns whether a credits record has been attached to this recording yet.
public fun has_credits<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// Returns the party-to-credit map. Aborts if no credits are attached.
public fun credits<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &VecMap<ID, Credit<RecordingPartyRole>> {
    &borrow(self.uid()).credits
}

/// Returns the primary-artist IDs. Aborts if no credits are attached.
public fun primary_artist_ids<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &VecSet<ID> {
    &borrow(self.uid()).primary_artist_ids
}

/// Returns the featured-artist IDs. Aborts if no credits are attached.
public fun featured_artist_ids<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &VecSet<ID> {
    &borrow(self.uid()).featured_artist_ids
}

/// Returns whether the party is a primary artist (false if no credits attached).
public fun is_primary_artist<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
    party_id: ID,
): bool {
    has_credits(self) && borrow(self.uid()).primary_artist_ids.contains(&party_id)
}

/// Returns whether the party is a featured artist (false if no credits attached).
public fun is_featured_artist<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
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
public fun credit_added_event_fields(e: &CreditAddedEvent): (ID, ID, Credit<RecordingPartyRole>) {
    (e.recording_id, e.party_id, e.credit)
}

#[test_only]
public fun credit_removed_event_fields(e: &CreditRemovedEvent): (ID, ID, Credit<RecordingPartyRole>) {
    (e.recording_id, e.party_id, e.credit)
}

#[test_only]
public fun primary_artist_added_event_fields(e: &PrimaryArtistAddedEvent): (ID, ID) {
    (e.recording_id, e.party_id)
}

#[test_only]
public fun primary_artist_removed_event_fields(e: &PrimaryArtistRemovedEvent): (ID, ID) {
    (e.recording_id, e.party_id)
}

#[test_only]
public fun featured_artist_added_event_fields(e: &FeaturedArtistAddedEvent): (ID, ID) {
    (e.recording_id, e.party_id)
}

#[test_only]
public fun featured_artist_removed_event_fields(e: &FeaturedArtistRemovedEvent): (ID, ID) {
    (e.recording_id, e.party_id)
}
