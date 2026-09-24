// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The roles a party can hold on a release: top-line billing as a `Primary`
/// or `Featured` artist on the commercial packaging of recordings.
///
/// `ReleasePartyRole` is a closed enum constructed only through the
/// `new_*_role` functions. Release billing is a small, fixed vocabulary:
/// there is no level axis. The vocabulary is musicos's own; any overlap with
/// an external standard (e.g. DDEX) is coincidental. Consumers read a role
/// from its BCS variant index: `Primary = 0`, `Featured = 1`.
module release_credits::release_party_role;

// === Enums ===

/// A party's billing on a release.
public enum ReleasePartyRole has copy, drop, store {
    /// A primary (headline) artist on the release.
    Primary,
    /// A featured (guest) artist on the release.
    Featured,
}

// === Public Functions ===

/// Creates a new Primary role.
public fun new_primary_role(): ReleasePartyRole {
    ReleasePartyRole::Primary
}

/// Creates a new Featured role.
public fun new_featured_role(): ReleasePartyRole {
    ReleasePartyRole::Featured
}
