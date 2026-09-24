// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `CompositionPartyRole` is a closed enum with no `key`/`store` object, no
/// capability, and no shared state — every constructor is a pure function.
/// `test_scenario` machinery has nothing to exercise here, so this module
/// stays in single-transaction style.
#[test_only]
module composition_credits::composition_party_role_tests;

use composition_credits::composition_party_role as cpr;
use std::unit_test::assert_eq;
use sui::bcs::to_bytes;

/// The BCS variant index is how a consumer reads a role from an event or the
/// stored credit, so the declaration order is a wire contract.
#[test]
fun bcs_variant_indices_are_stable() {
    assert_eq!(to_bytes(&cpr::new_adapter_role()), vector[0]);
    assert_eq!(to_bytes(&cpr::new_arranger_role()), vector[1]);
    assert_eq!(to_bytes(&cpr::new_composer_role()), vector[2]);
    assert_eq!(to_bytes(&cpr::new_lyricist_role()), vector[3]);
    assert_eq!(to_bytes(&cpr::new_songwriter_role()), vector[4]);
    assert_eq!(to_bytes(&cpr::new_translator_role()), vector[5]);
}
