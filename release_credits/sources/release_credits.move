// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// First-party credits extension for releases.
///
/// Attribution (top-line billing) is display-oriented and varies across
/// platforms, so it lives here as a dynamic field on the release rather than in
/// immutable core. The data is attached under `ExtensionKey()` via the release's
/// cap-gated `uid_mut`, so every mutation is authorized by the release's admin
/// and credits survive into any lifecycle state (they may be attached before or
/// after the release is published).
///
/// This is musicos's canonical credits standard; because it is an extension, other
/// parties may publish their own release-credits standard against the same
/// `Release`. Credits are NOT read by the economics — they are attribution.
///
/// A release credit carries exactly one role: a party is billed as either a
/// `Primary` or a `Featured` artist on the release.
module release_credits::release_credits;

use musicos::release::{Release, ReleaseAdminCap};
use credit::credit::Credit;
use partyos::party::Party;
use release_credits::release_party_role::{Self, ReleasePartyRole};
use sui::bcs;
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_map::{Self, VecMap};

// === Errors ===

// Constraint errors (30-39)
/// Release has too many credits.
const EMaxCreditsExceeded: u64 = 32;

// Conflict errors (40-49)
/// Party already has a credit on this release.
const EPartyAlreadyCredited: u64 = 40;

// Reference errors (50-59)
/// No credits record is attached to this release.
const ENoCredits: u64 = 50;
/// Party is not credited on the release.
const EPartyNotCredited: u64 = 52;
/// A release credit must carry exactly one role.
const EInvalidCreditRoleCount: u64 = 53;

// === Constants ===

/// Number of roles a release credit must carry (exactly one: Primary or Featured).
const CREDIT_ROLE_COUNT: u64 = 1;
/// Maximum number of credits allowed on a release.
const MAX_CREDITS: u64 = 50;

// === Structs ===

/// Dynamic-field key — one canonical credits record per release.
public struct ExtensionKey() has copy, drop, store;

/// The per-release attribution record, stored as a dynamic field on the
/// release's UID under `ExtensionKey()`.
public struct ReleaseCredits has store {
    /// Map of party IDs to their credit (display name + role).
    credits: VecMap<ID, Credit<ReleasePartyRole>>,
}

// === Events ===

/// Emitted when a credit is added for a party on the release. The bounded
/// primitive snapshot lets an indexer upsert its row without re-reading the
/// credits dynamic field.
public struct CreditAddedEvent has copy, drop {
    release_id: address,
    release_admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    role_kind: u8,
    credit_count_before: u64,
    credit_count_after: u64,
    credit_index: u64,
    credits_record_existed_before: bool,
    credits_record_exists_after: bool,
}

/// Emitted when a party's credit is removed from the release. The primitive
/// snapshot remains available after the map entry is gone.
public struct CreditRemovedEvent has copy, drop {
    release_id: address,
    release_admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    role_kind: u8,
    credit_count_before: u64,
    credit_count_after: u64,
    credit_index: u64,
    credits_record_existed_before: bool,
    credits_record_exists_after: bool,
}

// === Public Functions ===

/// Adds a credit for a party on the release, lazily creating the credits record
/// on first use. Each credit must carry exactly one role (Primary or Featured),
/// and a party may hold at most one credit. Requires the release's admin
/// capability.
public fun add_credit(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    party: &Party,
    credit: Credit<ReleasePartyRole>,
) {
    assert!(credit.roles().length() == CREDIT_ROLE_COUNT, EInvalidCreditRoleCount);

    let release_id = object::id(self).to_address();
    let release_admin_cap_id = object::id(cap).to_address();
    let party_id = object::id(party).to_address();
    let party_key = object::id(party);
    let uid = self.uid_mut(cap);
    let credits_record_existed_before = df::exists(uid, ExtensionKey());
    let (display_name, role_kind) = snapshot_credit(&credit);
    let mut credit_count_before = 0;
    let mut credit_count_after = 0;
    let mut credit_index = 0;
    {
        let rc = borrow_mut_or_init(uid);
        credit_count_before = rc.credits.length();
        // At capacity, preserve the existing precedence over duplicate-party
        // detection.
        assert!(credit_count_before < MAX_CREDITS, EMaxCreditsExceeded);
        assert!(!rc.credits.contains(&party_key), EPartyAlreadyCredited);
        rc.credits.insert(party_key, credit);
        credit_count_after = rc.credits.length();
        credit_index = rc.credits.get_idx(&party_key);
    };
    let credits_record_exists_after = df::exists(uid, ExtensionKey());

    emit(CreditAddedEvent {
        release_id,
        release_admin_cap_id,
        party_id,
        display_name,
        role_kind,
        credit_count_before,
        credit_count_after,
        credit_index,
        credits_record_existed_before,
        credits_record_exists_after,
    });
}

/// Removes a party's credit. Requires the release's admin capability.
public fun remove_credit(self: &mut Release, cap: &ReleaseAdminCap, party_id: ID) {
    let release_id = object::id(self).to_address();
    let release_admin_cap_id = object::id(cap).to_address();
    let party_address = party_id.to_address();
    let uid = self.uid_mut(cap);
    let (credit_count_before, credit_count_after, credit_index, credit) = {
        let rc = borrow_mut(uid);
        assert!(rc.credits.contains(&party_id), EPartyNotCredited);
        let credit_count_before = rc.credits.length();
        let credit_index = rc.credits.get_idx(&party_id);
        let (_, removed_credit) = rc.credits.remove(&party_id);
        let credit_count_after = rc.credits.length();
        (credit_count_before, credit_count_after, credit_index, removed_credit)
    };
    let (display_name, role_kind) = snapshot_credit(&credit);
    // Removing the final entry retains the empty dynamic-field record.
    let credits_record_existed_before = true;
    let credits_record_exists_after = df::exists(uid, ExtensionKey());

    emit(CreditRemovedEvent {
        release_id,
        release_admin_cap_id,
        party_id: party_address,
        display_name,
        role_kind,
        credit_count_before,
        credit_count_after,
        credit_index,
        credits_record_existed_before,
        credits_record_exists_after,
    });
}

// === View Functions ===

/// Returns whether a credits record has been attached to this release yet.
public fun has_credits(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// Returns the party-to-credit map. Aborts if no credits are attached.
public fun credits(self: &Release): &VecMap<ID, Credit<ReleasePartyRole>> {
    &borrow(self.uid()).credits
}

// === Private Functions ===

fun borrow(uid: &UID): &ReleaseCredits {
    assert!(df::exists(uid, ExtensionKey()), ENoCredits);
    df::borrow(uid, ExtensionKey())
}

fun borrow_mut(uid: &mut UID): &mut ReleaseCredits {
    assert!(df::exists(uid, ExtensionKey()), ENoCredits);
    df::borrow_mut(uid, ExtensionKey())
}

fun borrow_mut_or_init(uid: &mut UID): &mut ReleaseCredits {
    if (!df::exists(uid, ExtensionKey())) {
        df::add(
            uid,
            ExtensionKey(),
            ReleaseCredits {
                credits: vec_map::empty(),
            },
        );
    };
    df::borrow_mut(uid, ExtensionKey())
}

/// Returns the lossless primitive snapshot used by both mutation events. The
/// display name comes from `Credit`, not from the Party object, and the role
/// kind is the stable release-role code.
fun snapshot_credit(credit: &Credit<ReleasePartyRole>): (vector<u8>, u8) {
    let display_name = *credit.display_name().as_bytes();
    let roles = credit.roles();
    let role_kind = release_party_role::event_kind(&roles[0]);
    (display_name, role_kind)
}

// === Test Functions ===

#[test_only]
public fun added_event_fields(e: &CreditAddedEvent):
    (address, address, address, vector<u8>, u8, u64, u64, u64, bool, bool) {
    (
        e.release_id,
        e.release_admin_cap_id,
        e.party_id,
        e.display_name,
        e.role_kind,
        e.credit_count_before,
        e.credit_count_after,
        e.credit_index,
        e.credits_record_existed_before,
        e.credits_record_exists_after,
    )
}

#[test_only]
public fun removed_event_fields(e: &CreditRemovedEvent):
    (address, address, address, vector<u8>, u8, u64, u64, u64, bool, bool) {
    (
        e.release_id,
        e.release_admin_cap_id,
        e.party_id,
        e.display_name,
        e.role_kind,
        e.credit_count_before,
        e.credit_count_after,
        e.credit_index,
        e.credits_record_existed_before,
        e.credits_record_exists_after,
    )
}

#[test_only]
public fun added_event_bcs(e: &CreditAddedEvent): vector<u8> {
    bcs::to_bytes(e)
}

#[test_only]
public fun removed_event_bcs(e: &CreditRemovedEvent): vector<u8> {
    bcs::to_bytes(e)
}
