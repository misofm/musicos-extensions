// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The roles a party can hold on a composition: the writing and adaptation
/// contributions to the underlying musical work.
///
/// `CompositionPartyRole` is a closed enum constructed only through the
/// `new_*_role` functions. Unlike recording roles there is no seniority axis:
/// a writer either contributed in a capacity or did not. The vocabulary is
/// fixed to these canonical variants and is musicos's own; any overlap with
/// an external standard (e.g. DDEX) is coincidental. Consumers read a role
/// from its BCS variant index, in declaration order.
module composition_credits::composition_party_role;

// === Enums ===

/// A party's role on a composition.
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
}

// === Public Functions ===

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
