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
/// This is musicos's canonical credits standard; because it is an extension, other
/// parties may publish their own recording-credits standard against the same
/// `Recording`. Credits are NOT read by the economics — they are attribution.
module recording_credits::recording_credits;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use credit::credit::Credit;
use partyos::party::Party;
use recording_credits::recording_party_role::{Self, RecordingPartyRole};
use sui::dynamic_field as df;
use sui::bcs;
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

/// Emitted when a credit is added to a recording. The primitive snapshot is
/// sufficient for an indexer to upsert the row without re-reading storage.
public struct CreditAddedEvent<phantom RecordingShare, phantom CompositionShare> has copy, drop {
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
}

/// Emitted when a credit is removed from a recording. The snapshot remains
/// available after the map entry is gone and records designation cascades.
public struct CreditRemovedEvent<phantom RecordingShare, phantom CompositionShare> has copy, drop {
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
}

/// Emitted when a party is designated a primary artist.
public struct PrimaryArtistAddedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    primary_artist_index: u64,
    primary_artist_count_before: u64,
    primary_artist_count_after: u64,
    credit_count_after: u64,
}

/// Emitted when a party leaves the primary-artist set — either by an explicit
/// removal or as a cascade of removing their credit.
public struct PrimaryArtistRemovedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    primary_artist_index: u64,
    primary_artist_count_before: u64,
    primary_artist_count_after: u64,
    credit_count_after: u64,
    caused_by_credit_removal: bool,
}

/// Emitted when a party is designated a featured artist.
public struct FeaturedArtistAddedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    featured_artist_index: u64,
    featured_artist_count_before: u64,
    featured_artist_count_after: u64,
    credit_count_after: u64,
}

/// Emitted when a party leaves the featured-artist set — either by an explicit
/// removal or as a cascade of removing their credit.
public struct FeaturedArtistRemovedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    featured_artist_index: u64,
    featured_artist_count_before: u64,
    featured_artist_count_after: u64,
    credit_count_after: u64,
    caused_by_credit_removal: bool,
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
    // (`credit::credit::new`, private fields, no mutators) already
    // guarantees at least one role for every value that can exist.
    assert!(credit.roles().length() <= MAX_ROLES_PER_CREDIT, EExceedsMaxRoles);

    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let party_id = object::id(party).to_address();
    let party_key = object::id(party);
    let uid = self.uid_mut(cap);
    let credits_existed_before = df::exists(uid, ExtensionKey());
    let (display_name, role_kinds, role_names, role_instruments, role_levels) =
        snapshot_credit(&credit);
    let mut credit_count_before = 0;
    let mut credit_count_after = 0;
    let mut credit_index = 0;
    {
        let rc = borrow_mut_or_init(uid);
        credit_count_before = rc.credits.length();
        assert!(credit_count_before < MAX_CREDITS, EMaxCreditsExceeded);
        assert!(!rc.credits.contains(&party_key), EPartyAlreadyCredited);
        rc.credits.insert(party_key, credit);
        credit_count_after = rc.credits.length();
        credit_index = rc.credits.get_idx(&party_key);
    };

    emit(CreditAddedEvent<RecordingShare, CompositionShare> {
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
        credits_initialized: !credits_existed_before,
    });
}

/// Removes a party's credit. Also drops them from the primary/featured sets,
/// preserving the invariant that those are subsets of the credited parties.
/// Requires the recording's admin capability.
public fun remove_credit<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party_id: ID,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let party_address = party_id.to_address();
    let uid = self.uid_mut(cap);
    let (
        credit_count_before,
        credit_count_after,
        credit_index,
        credit,
        was_primary_artist,
        was_featured_artist,
    ) = {
        let rc = borrow_mut(uid);
        assert!(rc.credits.contains(&party_id), EPartyNotCredited);
        let credit_count_before = rc.credits.length();
        let credit_index = rc.credits.get_idx(&party_id);
        let was_primary_artist = rc.primary_artist_ids.contains(&party_id);
        let was_featured_artist = rc.featured_artist_ids.contains(&party_id);
        let (_, credit) = rc.credits.remove(&party_id);
        let credit_count_after = rc.credits.length();
        (
            credit_count_before,
            credit_count_after,
            credit_index,
            credit,
            was_primary_artist,
            was_featured_artist,
        )
    };
    let (display_name, role_kinds, role_names, role_instruments, role_levels) =
        snapshot_credit(&credit);

    emit(CreditRemovedEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        admin_cap_id,
        party_id: party_address,
        display_name,
        role_kinds,
        role_names,
        role_instruments,
        role_levels,
        credit_index,
        credit_count_before,
        credit_count_after,
        was_primary_artist,
        was_featured_artist,
    });

    // Cascading out of the primary/featured sets is its own logical change
    // per set, so each gets its own event after that set's mutation.
    if (was_primary_artist) {
        let (
            primary_artist_index,
            primary_artist_count_before,
            primary_artist_count_after,
            credit_count_after,
        ) = {
            let rc = borrow_mut(uid);
            let primary_artist_count_before = rc.primary_artist_ids.length();
            let primary_artist_index = set_index(&rc.primary_artist_ids, &party_id);
            rc.primary_artist_ids.remove(&party_id);
            let primary_artist_count_after = rc.primary_artist_ids.length();
            (
                primary_artist_index,
                primary_artist_count_before,
                primary_artist_count_after,
                rc.credits.length(),
            )
        };
        emit(PrimaryArtistRemovedEvent<RecordingShare, CompositionShare> {
            recording_id,
            composition_id,
            admin_cap_id,
            party_id: party_address,
            display_name,
            primary_artist_index,
            primary_artist_count_before,
            primary_artist_count_after,
            credit_count_after,
            caused_by_credit_removal: true,
        });
    };
    if (was_featured_artist) {
        let (
            featured_artist_index,
            featured_artist_count_before,
            featured_artist_count_after,
            credit_count_after,
        ) = {
            let rc = borrow_mut(uid);
            let featured_artist_count_before = rc.featured_artist_ids.length();
            let featured_artist_index = set_index(&rc.featured_artist_ids, &party_id);
            rc.featured_artist_ids.remove(&party_id);
            let featured_artist_count_after = rc.featured_artist_ids.length();
            (
                featured_artist_index,
                featured_artist_count_before,
                featured_artist_count_after,
                rc.credits.length(),
            )
        };
        emit(FeaturedArtistRemovedEvent<RecordingShare, CompositionShare> {
            recording_id,
            composition_id,
            admin_cap_id,
            party_id: party_address,
            display_name,
            featured_artist_index,
            featured_artist_count_before,
            featured_artist_count_after,
            credit_count_after,
            caused_by_credit_removal: true,
        });
    };
}

/// Designates an already-credited party as a primary artist. The party must be
/// credited and not already a primary or featured artist.
public fun add_primary_artist<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party: &Party,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let party_address = object::id(party).to_address();
    let party_id = object::id(party);
    let uid = self.uid_mut(cap);
    let (
        display_name,
        primary_artist_index,
        primary_artist_count_before,
        primary_artist_count_after,
        credit_count_after,
    ) = {
        let rc = borrow_mut(uid);
        let primary_artist_count_before = rc.primary_artist_ids.length();
        assert!(primary_artist_count_before < MAX_PRIMARY_ARTISTS, EMaxPrimaryArtistsExceeded);
        assert!(rc.credits.contains(&party_id), EPartyNotCredited);
        assert!(!rc.featured_artist_ids.contains(&party_id), EAlreadyFeaturedArtist);
        assert!(!rc.primary_artist_ids.contains(&party_id), EAlreadyPrimaryArtist);
        let (display_name, _, _, _, _) =
            snapshot_credit(rc.credits.get(&party_id));
        rc.primary_artist_ids.insert(party_id);
        let primary_artist_index = set_index(&rc.primary_artist_ids, &party_id);
        let primary_artist_count_after = rc.primary_artist_ids.length();
        let credit_count_after = rc.credits.length();
        (
            display_name,
            primary_artist_index,
            primary_artist_count_before,
            primary_artist_count_after,
            credit_count_after,
        )
    };

    emit(PrimaryArtistAddedEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        admin_cap_id,
        party_id: party_address,
        display_name,
        primary_artist_index,
        primary_artist_count_before,
        primary_artist_count_after,
        credit_count_after,
    });
}

/// Removes a party from the primary-artist set (leaves the credit intact).
public fun remove_primary_artist<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party_id: ID,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let party_address = party_id.to_address();
    let uid = self.uid_mut(cap);
    let (
        display_name,
        primary_artist_index,
        primary_artist_count_before,
        primary_artist_count_after,
        credit_count_after,
    ) = {
        let rc = borrow_mut(uid);
        assert!(rc.primary_artist_ids.contains(&party_id), EPartyNotCredited);
        let primary_artist_count_before = rc.primary_artist_ids.length();
        let primary_artist_index = set_index(&rc.primary_artist_ids, &party_id);
        let (display_name, _, _, _, _) =
            snapshot_credit(rc.credits.get(&party_id));
        rc.primary_artist_ids.remove(&party_id);
        let primary_artist_count_after = rc.primary_artist_ids.length();
        let credit_count_after = rc.credits.length();
        (
            display_name,
            primary_artist_index,
            primary_artist_count_before,
            primary_artist_count_after,
            credit_count_after,
        )
    };

    emit(PrimaryArtistRemovedEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        admin_cap_id,
        party_id: party_address,
        display_name,
        primary_artist_index,
        primary_artist_count_before,
        primary_artist_count_after,
        credit_count_after,
        caused_by_credit_removal: false,
    });
}

/// Designates an already-credited party as a featured artist. The party must be
/// credited and not already a primary or featured artist.
public fun add_featured_artist<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party: &Party,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let party_address = object::id(party).to_address();
    let party_id = object::id(party);
    let uid = self.uid_mut(cap);
    let (
        display_name,
        featured_artist_index,
        featured_artist_count_before,
        featured_artist_count_after,
        credit_count_after,
    ) = {
        let rc = borrow_mut(uid);
        let featured_artist_count_before = rc.featured_artist_ids.length();
        assert!(featured_artist_count_before < MAX_FEATURED_ARTISTS, EMaxFeaturedArtistsExceeded);
        assert!(rc.credits.contains(&party_id), EPartyNotCredited);
        assert!(!rc.primary_artist_ids.contains(&party_id), EAlreadyPrimaryArtist);
        assert!(!rc.featured_artist_ids.contains(&party_id), EAlreadyFeaturedArtist);
        let (display_name, _, _, _, _) =
            snapshot_credit(rc.credits.get(&party_id));
        rc.featured_artist_ids.insert(party_id);
        let featured_artist_index = set_index(&rc.featured_artist_ids, &party_id);
        let featured_artist_count_after = rc.featured_artist_ids.length();
        let credit_count_after = rc.credits.length();
        (
            display_name,
            featured_artist_index,
            featured_artist_count_before,
            featured_artist_count_after,
            credit_count_after,
        )
    };

    emit(FeaturedArtistAddedEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        admin_cap_id,
        party_id: party_address,
        display_name,
        featured_artist_index,
        featured_artist_count_before,
        featured_artist_count_after,
        credit_count_after,
    });
}

/// Removes a party from the featured-artist set (leaves the credit intact).
public fun remove_featured_artist<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
    cap: &RecordingAdminCap<RecordingShare>,
    party_id: ID,
) {
    let recording_id = object::id(self).to_address();
    let composition_id = recording::composition_id(self).to_address();
    let admin_cap_id = object::id(cap).to_address();
    let party_address = party_id.to_address();
    let uid = self.uid_mut(cap);
    let (
        display_name,
        featured_artist_index,
        featured_artist_count_before,
        featured_artist_count_after,
        credit_count_after,
    ) = {
        let rc = borrow_mut(uid);
        assert!(rc.featured_artist_ids.contains(&party_id), EPartyNotCredited);
        let featured_artist_count_before = rc.featured_artist_ids.length();
        let featured_artist_index = set_index(&rc.featured_artist_ids, &party_id);
        let (display_name, _, _, _, _) =
            snapshot_credit(rc.credits.get(&party_id));
        rc.featured_artist_ids.remove(&party_id);
        let featured_artist_count_after = rc.featured_artist_ids.length();
        let credit_count_after = rc.credits.length();
        (
            display_name,
            featured_artist_index,
            featured_artist_count_before,
            featured_artist_count_after,
            credit_count_after,
        )
    };

    emit(FeaturedArtistRemovedEvent<RecordingShare, CompositionShare> {
        recording_id,
        composition_id,
        admin_cap_id,
        party_id: party_address,
        display_name,
        featured_artist_index,
        featured_artist_count_before,
        featured_artist_count_after,
        credit_count_after,
        caused_by_credit_removal: false,
    });
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

fun snapshot_credit(
    credit: &Credit<RecordingPartyRole>,
): (vector<u8>, vector<u8>, vector<vector<u8>>, vector<vector<u8>>, vector<u8>) {
    let display_name = *credit.display_name().as_bytes();
    let mut role_kinds = vector[];
    let mut role_names = vector[];
    let mut role_instruments = vector[];
    let mut role_levels = vector[];
    let roles = credit.roles();
    let mut index = 0;
    while (index < roles.length()) {
        let (kind, name, instrument, level) = recording_party_role::event_fields(&roles[index]);
        role_kinds.push_back(kind);
        role_names.push_back(name);
        role_instruments.push_back(instrument);
        role_levels.push_back(level);
        index = index + 1;
    };
    (display_name, role_kinds, role_names, role_instruments, role_levels)
}

fun set_index(set: &VecSet<ID>, key: &ID): u64 {
    let (_, index) = set.keys().index_of(key);
    index
}

#[test_only]
/// Exhaustive test-only accessors return the lossless BCS payload, preserving
/// every event field without adding production read APIs.
public fun credit_added_event_fields<R, C>(e: &CreditAddedEvent<R, C>): vector<u8> {
    bcs::to_bytes(e)
}

#[test_only]
public fun credit_removed_event_fields<R, C>(e: &CreditRemovedEvent<R, C>): vector<u8> {
    bcs::to_bytes(e)
}

#[test_only]
public fun primary_artist_added_event_fields<R, C>(e: &PrimaryArtistAddedEvent<R, C>): vector<u8> {
    bcs::to_bytes(e)
}

#[test_only]
public fun primary_artist_removed_event_fields<R, C>(e: &PrimaryArtistRemovedEvent<R, C>): vector<u8> {
    bcs::to_bytes(e)
}

#[test_only]
public fun featured_artist_added_event_fields<R, C>(e: &FeaturedArtistAddedEvent<R, C>): vector<u8> {
    bcs::to_bytes(e)
}

#[test_only]
public fun featured_artist_removed_event_fields<R, C>(e: &FeaturedArtistRemovedEvent<R, C>): vector<u8> {
    bcs::to_bytes(e)
}
