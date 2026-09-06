// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `CompositionPartyRole` is a closed enum with no `key`/`store` object,
/// no capability, and no shared state — every constructor and the `name()`
/// view are pure functions of their arguments. `test_scenario` machinery
/// (transaction boundaries, shared objects, distinct senders) has nothing
/// to exercise here, so this module stays in single-transaction
/// `tx_context::dummy()` style throughout, per the methodology's stated
/// exception for pure-math/validation modules.
#[test_only]
module composition_credits::composition_party_role_tests;

use composition_credits::composition_party_role as cpr;
use miso::test_helpers;
use std::unit_test::assert_eq;

#[test]
fun canonical_role_names_round_trip() {
    assert_eq!(cpr::new_adapter_role().name(), b"Adapter".to_string());
    assert_eq!(cpr::new_arranger_role().name(), b"Arranger".to_string());
    assert_eq!(cpr::new_composer_role().name(), b"Composer".to_string());
    assert_eq!(cpr::new_lyricist_role().name(), b"Lyricist".to_string());
    assert_eq!(cpr::new_songwriter_role().name(), b"Songwriter".to_string());
    assert_eq!(cpr::new_translator_role().name(), b"Translator".to_string());
}

#[test]
fun custom_role_name_round_trips_the_supplied_string() {
    let role = cpr::new_custom_role(b"Producer".to_string());
    assert_eq!(role.name(), b"Producer".to_string());
}

#[test]
fun custom_role_accepts_name_at_max_length() {
    let role = cpr::new_custom_role(test_helpers::long_string(100));
    assert_eq!(role.name(), test_helpers::long_string(100));
}

#[test, expected_failure(abort_code = 35, location = composition_credits::composition_party_role)] // EEmptyString
fun custom_role_rejects_empty_name() {
    cpr::new_custom_role(b"".to_string());
}

#[test, expected_failure(abort_code = 31, location = composition_credits::composition_party_role)] // EMaxCustomNameLengthExceeded
fun custom_role_rejects_name_over_max_length() {
    cpr::new_custom_role(test_helpers::long_string(101));
}
