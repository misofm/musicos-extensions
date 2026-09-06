// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines the roles that parties can hold on a composition.
/// Compositions are the underlying musical works (melody + lyrics), and these
/// roles represent the writing and adaptation contributions to them.
///
/// ### Design
///
/// `CompositionPartyRole` is a closed enum: variants can only be constructed and
/// matched inside this module, so the `new_*_role` constructors are the external
/// write-API and `name()` is the external read-API.
///
/// - **No seniority axis.** Unlike recording roles, composition roles carry no
///   level — a writer either contributed in a given capacity or did not.
/// - **`Custom` is the escape hatch.** The canonical variants cover the common
///   writing vocabulary; anything outside it is a `Custom(name)` whose name is
///   validated. Prefer a canonical variant when one fits.
/// - **`name()` is the canonical identifier**, returned as a stable PascalCase
///   token (e.g. `"Songwriter"`). For `Custom`, `name()` returns the
///   user-supplied string.
///
/// These identifiers are Miso's own canonical vocabulary; any overlap with an
/// external standard (e.g. DDEX) is coincidental, not a reproduction of it.
module composition_credits::composition_party_role;

use std::string::String;

// === Errors ===

// Constraint errors (30-39)
/// Custom role name exceeds maximum length.
const EMaxCustomNameLengthExceeded: u64 = 31;
/// String must not be empty.
const EEmptyString: u64 = 35;

// === Constants ===

/// Maximum length of a custom role name in bytes.
const MAX_CUSTOM_NAME_LENGTH: u64 = 100;

// === Enums ===

/// Represents a party's role on a composition.
public enum CompositionPartyRole has copy, drop, store {
    /// Adapted an existing work into this composition.
    Adapter,
    /// Arranged the musical parts of the composition.
    Arranger,
    /// Composed the music of the composition.
    Composer,
    /// Wrote the lyrics of the composition.
    Lyricist,
    /// Wrote both music and lyrics of the composition.
    Songwriter,
    /// Translated the lyrics of the composition.
    Translator,
    /// A user-defined role not covered by a canonical variant. Carries the role
    /// name (validated). An escape hatch — prefer a canonical variant when one fits.
    Custom(String),
}

// === Public Functions ===

// roles
/// Creates a new Adapter role.
public fun new_adapter_role(): CompositionPartyRole {
    CompositionPartyRole::Adapter
}

/// Creates a new Arranger role.
public fun new_arranger_role(): CompositionPartyRole {
    CompositionPartyRole::Arranger
}

/// Creates a new Composer role.
public fun new_composer_role(): CompositionPartyRole {
    CompositionPartyRole::Composer
}

/// Creates a new Lyricist role.
public fun new_lyricist_role(): CompositionPartyRole {
    CompositionPartyRole::Lyricist
}

/// Creates a new Songwriter role.
public fun new_songwriter_role(): CompositionPartyRole {
    CompositionPartyRole::Songwriter
}

/// Creates a new Translator role.
public fun new_translator_role(): CompositionPartyRole {
    CompositionPartyRole::Translator
}

/// Creates a new Custom role with a user-defined name.
/// The name freezes into credits, so it is validated here.
/// Prefer a canonical variant when one fits.
public fun new_custom_role(role_name: String): CompositionPartyRole {
    assert!(!role_name.is_empty(), EEmptyString);
    assert!(role_name.length() <= MAX_CUSTOM_NAME_LENGTH, EMaxCustomNameLengthExceeded);
    CompositionPartyRole::Custom(role_name)
}

// === View Functions ===

/// Returns the canonical identifier of the role as a stable PascalCase token.
/// For `Custom`, returns the user-supplied name.
public fun name(self: &CompositionPartyRole): String {
    match (self) {
        CompositionPartyRole::Adapter => b"Adapter".to_string(),
        CompositionPartyRole::Arranger => b"Arranger".to_string(),
        CompositionPartyRole::Composer => b"Composer".to_string(),
        CompositionPartyRole::Lyricist => b"Lyricist".to_string(),
        CompositionPartyRole::Songwriter => b"Songwriter".to_string(),
        CompositionPartyRole::Translator => b"Translator".to_string(),
        CompositionPartyRole::Custom(role_name) => *role_name,
    }
}
