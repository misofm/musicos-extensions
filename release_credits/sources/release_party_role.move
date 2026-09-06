// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines the roles that parties can hold on a release.
/// Releases are the commercial packaging of recordings (an album, single, EP),
/// and a release credit captures top-line billing: a party is either a primary
/// artist or a featured artist on the release.
///
/// ### Design
///
/// `ReleasePartyRole` is a closed enum: variants can only be constructed and
/// matched inside this module, so the `new_*_role` constructors are the external
/// write-API and `name()` is the external read-API.
///
/// - **No level axis and no `Custom` escape hatch.** Release billing is a small,
///   fixed vocabulary: `Primary` or `Featured`.
/// - **`name()` is the canonical identifier**, returned as a stable PascalCase
///   token (`"Primary"` / `"Featured"`).
///
/// These identifiers are Miso's own canonical vocabulary; any overlap with an
/// external standard (e.g. DDEX) is coincidental, not a reproduction of it.
module release_credits::release_party_role;

use std::string::String;

// === Enums ===

/// Represents a party's billing on a release.
public enum ReleasePartyRole has copy, drop, store {
    /// A primary (headline) artist on the release.
    Primary,
    /// A featured (guest) artist on the release.
    Featured,
}

// === Public Functions ===
// roles

/// Creates a new Primary role.
public fun new_primary_role(): ReleasePartyRole {
    ReleasePartyRole::Primary
}

/// Creates a new Featured role.
public fun new_featured_role(): ReleasePartyRole {
    ReleasePartyRole::Featured
}

// === View Functions ===

/// Returns the canonical identifier of the role as a stable PascalCase token.
public fun name(self: &ReleasePartyRole): String {
    match (self) {
        ReleasePartyRole::Primary => b"Primary".to_string(),
        ReleasePartyRole::Featured => b"Featured".to_string(),
    }
}
