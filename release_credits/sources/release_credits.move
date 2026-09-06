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
/// This is Miso's canonical credits standard; because it is an extension, other
/// parties may publish their own release-credits standard against the same
/// `Release`. Credits are NOT read by the economics — they are attribution.
///
/// A release credit carries exactly one role: a party is billed as either a
/// `Primary` or a `Featured` artist on the release.
module release_credits::release_credits;

use miso::release::{Release, ReleaseAdminCap};
use miso_credit::credit::Credit;
use partyos::party::Party;
use release_credits::release_party_role::ReleasePartyRole;
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

/// Emitted when a credit is added for a party on the release. Carries the
/// full credit record so an indexer can upsert its row without re-reading the
/// credits dynamic field.
public struct CreditAddedEvent has copy, drop {
    release_id: ID,
    party_id: ID,
    credit: Credit<ReleasePartyRole>,
}

/// Emitted when a party's credit is removed from the release. Carries the
/// removed record so an indexer can delete its row without re-reading state.
public struct CreditRemovedEvent has copy, drop {
    release_id: ID,
    party_id: ID,
    credit: Credit<ReleasePartyRole>,
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

    let release_id = object::id(self);
    let party_id = object::id(party);
    let rc = borrow_mut_or_init(self.uid_mut(cap));
    assert!(rc.credits.length() < MAX_CREDITS, EMaxCreditsExceeded);
    assert!(!rc.credits.contains(&party_id), EPartyAlreadyCredited);
    rc.credits.insert(party_id, credit);

    emit(CreditAddedEvent { release_id, party_id, credit });
}

/// Removes a party's credit. Requires the release's admin capability.
public fun remove_credit(self: &mut Release, cap: &ReleaseAdminCap, party_id: ID) {
    let release_id = object::id(self);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.credits.contains(&party_id), EPartyNotCredited);
    let (_, credit) = rc.credits.remove(&party_id);

    emit(CreditRemovedEvent { release_id, party_id, credit });
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

// === Test Functions ===

#[test_only]
public fun added_event_fields(e: &CreditAddedEvent): (ID, ID, Credit<ReleasePartyRole>) {
    (e.release_id, e.party_id, e.credit)
}

#[test_only]
public fun removed_event_fields(e: &CreditRemovedEvent): (ID, ID, Credit<ReleasePartyRole>) {
    (e.release_id, e.party_id, e.credit)
}
