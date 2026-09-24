// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Writing credits for a composition: one `Credit<CompositionPartyRole>` per
/// credited `Party`, kept in a single record stored as a dynamic field on the
/// composition's UID and written through its cap-gated `uid_mut`.
///
/// Attribution is display-oriented and varies across platforms, so it lives
/// here rather than in immutable core, and it may be attached before or after
/// publish. This is musicos's canonical credits standard; because it is an
/// extension, other parties may publish their own against the same
/// `Composition`. Credits are not read by the economics.
module composition_credits::composition_credits;

use composition_credits::composition_party_role::CompositionPartyRole;
use credit::credit::Credit;
use musicos::composition::{Composition, CompositionAdminCap};
use partyos::party::Party;
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_map::{Self, VecMap};

// === Errors ===

// Constraint errors (30-39)
/// Credit has too many roles.
const EExceedsMaxRoles: u64 = 30;
/// Composition has too many credits.
const EMaxCreditsExceeded: u64 = 32;

// Conflict errors (40-49)
/// Party already has a credit on this composition.
const EPartyAlreadyCredited: u64 = 40;

// Reference errors (50-59)
/// No credits record is attached to this composition.
const ENoCredits: u64 = 50;
/// Party is not credited on the composition.
const EPartyNotCredited: u64 = 52;

// === Constants ===

/// Maximum number of roles a credit can have.
const MAX_ROLES_PER_CREDIT: u64 = 5;
/// Maximum number of credits allowed on a composition.
const MAX_CREDITS: u64 = 50;

// === Structs ===

/// Dynamic-field key — one canonical credits record per composition.
public struct ExtensionKey() has copy, drop, store;

/// The per-composition attribution record, stored under `ExtensionKey()`.
public struct CompositionCredits has store {
    /// Party ID to credit (display name + roles), in insertion order.
    credits: VecMap<ID, Credit<CompositionPartyRole>>,
}

// === Events ===

/// Emitted when a party is credited, with the roles as stored; the display
/// name stays in storage.
public struct CompositionCreditAddedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    party_id: address,
    roles: vector<CompositionPartyRole>,
}

/// Emitted when a party's credit is removed.
public struct CompositionCreditRemovedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    party_id: address,
}

// === Public Functions ===

/// Credits a party, creating the record on first use. A credit carries 1-5
/// roles (`credit::new` guarantees at least one) and a party holds at most
/// one credit; re-crediting a party aborts rather than silently passing. At
/// capacity, even a duplicate party reports `EMaxCreditsExceeded`.
public fun add_credit<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    party: &Party,
    credit: Credit<CompositionPartyRole>,
) {
    assert!(credit.roles().length() <= MAX_ROLES_PER_CREDIT, EExceedsMaxRoles);

    let composition_id = object::id(self).to_address();
    let party_id = object::id(party);
    let roles = *credit.roles();
    let cc = borrow_mut_or_init(self.uid_mut(cap));
    assert!(cc.credits.length() < MAX_CREDITS, EMaxCreditsExceeded);
    assert!(!cc.credits.contains(&party_id), EPartyAlreadyCredited);
    cc.credits.insert(party_id, credit);

    emit(CompositionCreditAddedEvent<CompositionShare> {
        composition_id,
        party_id: party_id.to_address(),
        roles,
    });
}

/// Removes a party's credit. Aborts when no record is attached or the party
/// is not credited. Removing the last credit keeps the empty record attached.
public fun remove_credit<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    party_id: ID,
) {
    let composition_id = object::id(self).to_address();
    let cc = borrow_mut(self.uid_mut(cap));
    assert!(cc.credits.contains(&party_id), EPartyNotCredited);
    let (_, _) = cc.credits.remove(&party_id);

    emit(CompositionCreditRemovedEvent<CompositionShare> {
        composition_id,
        party_id: party_id.to_address(),
    });
}

// === View Functions ===

/// Whether a credits record has been attached to this composition yet.
public fun has_credits<CompositionShare>(self: &Composition<CompositionShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// The party-to-credit map. Aborts `ENoCredits` when none is attached.
public fun credits<CompositionShare>(
    self: &Composition<CompositionShare>,
): &VecMap<ID, Credit<CompositionPartyRole>> {
    &borrow(self.uid()).credits
}

// === Private Functions ===

fun borrow(uid: &UID): &CompositionCredits {
    assert!(df::exists(uid, ExtensionKey()), ENoCredits);
    df::borrow(uid, ExtensionKey())
}

fun borrow_mut(uid: &mut UID): &mut CompositionCredits {
    assert!(df::exists(uid, ExtensionKey()), ENoCredits);
    df::borrow_mut(uid, ExtensionKey())
}

fun borrow_mut_or_init(uid: &mut UID): &mut CompositionCredits {
    if (!df::exists(uid, ExtensionKey())) {
        df::add(uid, ExtensionKey(), CompositionCredits { credits: vec_map::empty() });
    };
    df::borrow_mut(uid, ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun added_event_fields<CompositionShare>(
    e: &CompositionCreditAddedEvent<CompositionShare>,
): (address, address, vector<CompositionPartyRole>) {
    (e.composition_id, e.party_id, e.roles)
}

#[test_only]
public fun removed_event_fields<CompositionShare>(
    e: &CompositionCreditRemovedEvent<CompositionShare>,
): (address, address) {
    (e.composition_id, e.party_id)
}
