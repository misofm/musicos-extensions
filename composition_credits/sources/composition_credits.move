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
/// This is musicos's canonical credits standard; because it is an extension, other
/// parties may publish their own composition-credits standard against the same
/// `Composition`. Credits are NOT read by the economics — they are attribution.
module composition_credits::composition_credits;

use composition_credits::composition_party_role::{Self, CompositionPartyRole};
use musicos::composition::{Composition, CompositionAdminCap};
use credit::credit::Credit;
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

/// Emitted when a credit is added for a party on the composition. The payload
/// is a primitive, bounded snapshot so an indexer can upsert its row without
/// re-reading the credits dynamic field. `CompositionShare` keeps event
/// streams for distinct composition-share currencies type-separated.
public struct CompositionCreditAddedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    composition_admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    role_kinds: vector<u8>,
    role_custom_names: vector<vector<u8>>,
    credit_count_before: u64,
    credit_count_after: u64,
    credit_index: u64,
    credits_record_existed_before: bool,
    credits_record_exists_after: bool,
}

/// Emitted when a party's credit is removed from the composition. The payload
/// contains the removed credit snapshot and insertion-order index so an
/// indexer can delete its row without re-reading state.
public struct CompositionCreditRemovedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    composition_admin_cap_id: address,
    party_id: address,
    display_name: vector<u8>,
    role_kinds: vector<u8>,
    role_custom_names: vector<vector<u8>>,
    credit_count_before: u64,
    credit_count_after: u64,
    credit_index: u64,
    credits_record_existed_before: bool,
    credits_record_exists_after: bool,
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
    // (`credit::credit::new`, private fields, no mutators) already
    // guarantees at least one role for every value that can exist.
    assert!(credit.roles().length() <= MAX_ROLES_PER_CREDIT, EExceedsMaxRoles);

    let composition_id = object::id(self).to_address();
    let composition_admin_cap_id = object::id(cap).to_address();
    let party_id = object::id(party).to_address();
    let party_key = object::id(party);
    let uid = self.uid_mut(cap);
    let credits_record_existed_before = df::exists(uid, ExtensionKey());
    let (display_name, role_kinds, role_custom_names) = encode_credit(&credit);

    let mut credit_count_before = 0;
    let mut credit_count_after = 0;
    let mut credit_index = 0;
    {
        let cc = borrow_mut_or_init(uid);
        credit_count_before = cc.credits.length();
        // Keep the existing guard order: at capacity, even a duplicate party
        // reports EMaxCreditsExceeded rather than EPartyAlreadyCredited.
        assert!(credit_count_before < MAX_CREDITS, EMaxCreditsExceeded);
        assert!(!cc.credits.contains(&party_key), EPartyAlreadyCredited);
        credit_index = credit_count_before;
        cc.credits.insert(party_key, credit);
        credit_count_after = cc.credits.length();
    };

    let credits_record_exists_after = df::exists(uid, ExtensionKey());
    emit(CompositionCreditAddedEvent<CompositionShare> {
        composition_id,
        composition_admin_cap_id,
        party_id,
        display_name,
        role_kinds,
        role_custom_names,
        credit_count_before,
        credit_count_after,
        credit_index,
        credits_record_existed_before,
        credits_record_exists_after,
    });
}

/// Removes a party's credit. Requires the composition's admin capability.
public fun remove_credit<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    party_id: ID,
) {
    let composition_id = object::id(self).to_address();
    let composition_admin_cap_id = object::id(cap).to_address();
    let party_address = party_id.to_address();
    let uid = self.uid_mut(cap);
    let (credit_count_before, credit_count_after, credit_index, credit) = {
        let cc = borrow_mut(uid);
        // Preserve the existing no-record then party-membership guard order.
        assert!(cc.credits.contains(&party_id), EPartyNotCredited);
        let credit_count_before = cc.credits.length();
        let credit_index = cc.credits.get_idx(&party_id);
        let (_, removed_credit) = cc.credits.remove(&party_id);
        let credit_count_after = cc.credits.length();
        (credit_count_before, credit_count_after, credit_index, removed_credit)
    };

    let (display_name, role_kinds, role_custom_names) = encode_credit(&credit);
    let credits_record_existed_before = true;
    // Removing the final entry intentionally retains the empty dynamic-field
    // record, so this remains true for every successful removal.
    let credits_record_exists_after = df::exists(uid, ExtensionKey());
    emit(CompositionCreditRemovedEvent<CompositionShare> {
        composition_id,
        composition_admin_cap_id,
        party_id: party_address,
        display_name,
        role_kinds,
        role_custom_names,
        credit_count_before,
        credit_count_after,
        credit_index,
        credits_record_existed_before,
        credits_record_exists_after,
    });
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

/// Returns the bounded primitive snapshot used by both mutation events. Role
/// order is intentionally preserved because it is part of the credit's
/// display semantics. Canonical role names occupy an empty custom-name slot;
/// custom names retain their exact bytes, even when they spell a canonical
/// role name.
fun encode_credit(
    credit: &Credit<CompositionPartyRole>,
): (vector<u8>, vector<u8>, vector<vector<u8>>) {
    let display_name = *credit.display_name().as_bytes();
    let mut role_kinds = vector[];
    let mut role_custom_names = vector[];
    let roles = credit.roles();
    let mut i = 0;
    while (i < roles.length()) {
        let (role_kind, custom_name) = composition_party_role::event_encoding(&roles[i]);
        role_kinds.push_back(role_kind);
        role_custom_names.push_back(custom_name);
        i = i + 1;
    };
    (display_name, role_kinds, role_custom_names)
}

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
public fun added_event_fields<CompositionShare>(
    e: &CompositionCreditAddedEvent<CompositionShare>,
): (
    address,
    address,
    address,
    vector<u8>,
    vector<u8>,
    vector<vector<u8>>,
    u64,
    u64,
    u64,
    bool,
    bool,
) {
    (
        e.composition_id,
        e.composition_admin_cap_id,
        e.party_id,
        e.display_name,
        e.role_kinds,
        e.role_custom_names,
        e.credit_count_before,
        e.credit_count_after,
        e.credit_index,
        e.credits_record_existed_before,
        e.credits_record_exists_after,
    )
}

#[test_only]
public fun removed_event_fields<CompositionShare>(
    e: &CompositionCreditRemovedEvent<CompositionShare>,
): (
    address,
    address,
    address,
    vector<u8>,
    vector<u8>,
    vector<vector<u8>>,
    u64,
    u64,
    u64,
    bool,
    bool,
) {
    (
        e.composition_id,
        e.composition_admin_cap_id,
        e.party_id,
        e.display_name,
        e.role_kinds,
        e.role_custom_names,
        e.credit_count_before,
        e.credit_count_after,
        e.credit_index,
        e.credits_record_existed_before,
        e.credits_record_exists_after,
    )
}
