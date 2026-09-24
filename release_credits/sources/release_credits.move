// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Top-line billing for a release: one `Credit<ReleasePartyRole>` per
/// credited `Party`, kept in a single record stored as a dynamic field on the
/// release's UID and written through its cap-gated `uid_mut`.
///
/// Attribution is display-oriented and varies across platforms, so it lives
/// here rather than in immutable core, and it may be attached before or after
/// publish. This is musicos's canonical credits standard; because it is an
/// extension, other parties may publish their own against the same `Release`.
/// Credits are not read by the economics.
///
/// A release credit carries exactly one role: a party is billed as either a
/// `Primary` or a `Featured` artist on the release.
module release_credits::release_credits;

use credit::credit::Credit;
use musicos::release::{Release, ReleaseAdminCap};
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

/// The per-release attribution record, stored under `ExtensionKey()`.
public struct ReleaseCredits has store {
    /// Party ID to credit (display name + role), in insertion order.
    credits: VecMap<ID, Credit<ReleasePartyRole>>,
}

// === Events ===

/// Emitted when a party is credited, with its one role as stored; the
/// display name stays in storage.
public struct ReleaseCreditAddedEvent has copy, drop {
    release_id: ID,
    party_id: ID,
    roles: vector<ReleasePartyRole>,
}

/// Emitted when a party's credit is removed.
public struct ReleaseCreditRemovedEvent has copy, drop {
    release_id: ID,
    party_id: ID,
}

// === Public Functions ===

/// Credits a party, creating the record on first use. A credit carries
/// exactly one role and a party holds at most one credit; re-crediting a
/// party aborts rather than silently passing. At capacity, even a duplicate
/// party reports `EMaxCreditsExceeded`.
public fun add_credit(
    self: &mut Release,
    cap: &ReleaseAdminCap,
    party: &Party,
    credit: Credit<ReleasePartyRole>,
) {
    assert!(credit.roles().length() == CREDIT_ROLE_COUNT, EInvalidCreditRoleCount);

    let release_id = object::id(self);
    let party_id = object::id(party);
    let roles = *credit.roles();
    let rc = borrow_mut_or_init(self.uid_mut(cap));
    assert!(rc.credits.length() < MAX_CREDITS, EMaxCreditsExceeded);
    assert!(!rc.credits.contains(&party_id), EPartyAlreadyCredited);
    rc.credits.insert(party_id, credit);

    emit(ReleaseCreditAddedEvent { release_id, party_id, roles });
}

/// Removes a party's credit. Aborts when no record is attached or the party
/// is not credited. Removing the last credit keeps the empty record attached.
public fun remove_credit(self: &mut Release, cap: &ReleaseAdminCap, party_id: ID) {
    let release_id = object::id(self);
    let rc = borrow_mut(self.uid_mut(cap));
    assert!(rc.credits.contains(&party_id), EPartyNotCredited);
    let (_, _) = rc.credits.remove(&party_id);

    emit(ReleaseCreditRemovedEvent { release_id, party_id });
}

// === View Functions ===

/// Whether a credits record has been attached to this release yet.
public fun has_credits(self: &Release): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The party-to-credit map. Aborts `ENoCredits` when none is attached.
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
        df::add(uid, ExtensionKey(), ReleaseCredits { credits: vec_map::empty() });
    };
    df::borrow_mut(uid, ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun added_event_fields(
    e: &ReleaseCreditAddedEvent,
): (ID, ID, vector<ReleasePartyRole>) {
    (e.release_id, e.party_id, e.roles)
}

#[test_only]
public fun removed_event_fields(e: &ReleaseCreditRemovedEvent): (ID, ID) {
    (e.release_id, e.party_id)
}
