// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// First-party credits extension for compositions.
///
/// Attribution (writing credits) is display-oriented and varies across
/// platforms, so it lives here as a dynamic field on the composition rather than
/// in immutable core. The data is attached under `ExtensionKey()` via the
/// composition's cap-gated `uid_mut`, so every mutation is authorized by the
/// composition's admin and credits survive into any lifecycle state (they may be
/// attached before or after the composition is published).
///
/// This is Miso's canonical credits standard; because it is an extension, other
/// parties may publish their own composition-credits standard against the same
/// `Composition`. Credits are NOT read by the economics — they are attribution.
module composition_credits::composition_credits;

use composition_credits::composition_party_role::CompositionPartyRole;
use miso::composition::{Composition, CompositionAdminCap};
use miso_credit::credit::Credit;
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

/// The per-composition attribution record, stored as a dynamic field on the
/// composition's UID under `ExtensionKey()`.
public struct CompositionCredits has store {
    /// Map of party IDs to their credit (display name + roles).
    credits: VecMap<ID, Credit<CompositionPartyRole>>,
}

// === Events ===

/// Emitted when a credit is added for a party on the composition. Carries the
/// full credit record so an indexer can upsert its row without re-reading the
/// credits dynamic field.
public struct CreditAddedEvent has copy, drop {
    composition_id: ID,
    party_id: ID,
    credit: Credit<CompositionPartyRole>,
}

/// Emitted when a party's credit is removed from the composition. Carries the
/// removed record so an indexer can delete its row without re-reading state.
public struct CreditRemovedEvent has copy, drop {
    composition_id: ID,
    party_id: ID,
    credit: Credit<CompositionPartyRole>,
}

// === Public Functions ===

/// Adds a credit for a party on the composition, lazily creating the credits
/// record on first use. Each credit must have 1-5 roles, and a party may hold at
/// most one credit. Requires the composition's admin capability.
public fun add_credit<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    party: &Party,
    credit: Credit<CompositionPartyRole>,
) {
    // Non-emptiness needs no check here: `Credit`'s only constructor
    // (`miso_credit::credit::new`, private fields, no mutators) already
    // guarantees at least one role for every value that can exist.
    assert!(credit.roles().length() <= MAX_ROLES_PER_CREDIT, EExceedsMaxRoles);

    let composition_id = object::id(self);
    let party_id = object::id(party);
    let cc = borrow_mut_or_init(self.uid_mut(cap));
    assert!(cc.credits.length() < MAX_CREDITS, EMaxCreditsExceeded);
    assert!(!cc.credits.contains(&party_id), EPartyAlreadyCredited);
    cc.credits.insert(party_id, credit);

    emit(CreditAddedEvent { composition_id, party_id, credit });
}

/// Removes a party's credit. Requires the composition's admin capability.
public fun remove_credit<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    party_id: ID,
) {
    let composition_id = object::id(self);
    let cc = borrow_mut(self.uid_mut(cap));
    assert!(cc.credits.contains(&party_id), EPartyNotCredited);
    let (_, credit) = cc.credits.remove(&party_id);

    emit(CreditRemovedEvent { composition_id, party_id, credit });
}

// === View Functions ===

/// Returns whether a credits record has been attached to this composition yet.
public fun has_credits<CompositionShare>(self: &Composition<CompositionShare>): bool {
    df::exists(self.uid(), ExtensionKey())
}

/// Returns the party-to-credit map. Aborts if no credits are attached.
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
        df::add(
            uid,
            ExtensionKey(),
            CompositionCredits {
                credits: vec_map::empty(),
            },
        );
    };
    df::borrow_mut(uid, ExtensionKey())
}

// === Test Functions ===

#[test_only]
public fun added_event_fields(e: &CreditAddedEvent): (ID, ID, Credit<CompositionPartyRole>) {
    (e.composition_id, e.party_id, e.credit)
}

#[test_only]
public fun removed_event_fields(e: &CreditRemovedEvent): (ID, ID, Credit<CompositionPartyRole>) {
    (e.composition_id, e.party_id, e.credit)
}
