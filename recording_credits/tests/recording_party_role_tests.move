// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pure value tests for `recording_party_role`: role/level constructors and
/// the `name()`/`level()` readers touch no objects, capabilities, or shared
/// state — there is no ownership mechanics for `test_scenario` transaction
/// boundaries to prove here (the module under test does not even take a
/// `TxContext`), so these stay plain single-transaction value assertions.
#[test_only]
module recording_credits::recording_party_role_tests;

use miso::test_helpers;
use recording_credits::recording_party_role as rpr;
use std::unit_test::assert_eq;

fun lead(): Option<rpr::RecordingPartyRoleLevel> {
    option::some(rpr::new_lead_role_level())
}

/// Every role that carries an optional level: constructed with the same
/// level and checked against its stable PascalCase `name()`.
#[test]
fun leveled_roles_report_correct_name_and_level() {
    let names = vector[
        b"Actor".to_string(), b"Arranger".to_string(), b"BandLeader".to_string(),
        b"Choir".to_string(), b"ChoirMaster".to_string(), b"ConcertMaster".to_string(),
        b"Conductor".to_string(), b"Contractor".to_string(), b"DJ".to_string(),
        b"Editor".to_string(), b"Engineer".to_string(), b"Ensemble".to_string(),
        b"MasteringEngineer".to_string(), b"MixingEngineer".to_string(),
        b"MusicDirector".to_string(), b"MusicSupervisor".to_string(), b"Narrator".to_string(),
        b"Orchestra".to_string(), b"Orchestrator".to_string(), b"Performer".to_string(),
        b"Producer".to_string(), b"Programmer".to_string(), b"RecordingEngineer".to_string(),
        b"RemixingEngineer".to_string(), b"Soloist".to_string(), b"SoundDesigner".to_string(),
        b"Speaker".to_string(), b"Vocalist".to_string(),
    ];
    let roles = vector[
        rpr::new_actor_role(lead()), rpr::new_arranger_role(lead()), rpr::new_band_leader_role(lead()),
        rpr::new_choir_role(lead()), rpr::new_choir_master_role(lead()), rpr::new_concert_master_role(lead()),
        rpr::new_conductor_role(lead()), rpr::new_contractor_role(lead()), rpr::new_dj_role(lead()),
        rpr::new_editor_role(lead()), rpr::new_engineer_role(lead()), rpr::new_ensemble_role(lead()),
        rpr::new_mastering_engineer_role(lead()), rpr::new_mixing_engineer_role(lead()),
        rpr::new_music_director_role(lead()), rpr::new_music_supervisor_role(lead()), rpr::new_narrator_role(lead()),
        rpr::new_orchestra_role(lead()), rpr::new_orchestrator_role(lead()), rpr::new_performer_role(lead()),
        rpr::new_producer_role(lead()), rpr::new_programmer_role(lead()), rpr::new_recording_engineer_role(lead()),
        rpr::new_remixing_engineer_role(lead()), rpr::new_soloist_role(lead()), rpr::new_sound_designer_role(lead()),
        rpr::new_speaker_role(lead()), rpr::new_vocalist_role(lead()),
    ];
    assert_eq!(roles.length(), names.length());
    roles.length().do!(|i| {
        assert_eq!(roles[i].name(), names[i]);
        assert_eq!(roles[i].level(), lead());
    });
}

/// `ArtistsAndRepertoire` and `Copyist` are clerical/business roles that
/// carry no level at all — `level()` must return `none()`, not an empty
/// `Some`, and not abort.
#[test]
fun clerical_roles_have_no_level() {
    let ar = rpr::new_artists_and_repertoire_role();
    let cp = rpr::new_copyist_role();
    assert_eq!(ar.name(), b"ArtistsAndRepertoire".to_string());
    assert_eq!(ar.level(), option::none());
    assert_eq!(cp.name(), b"Copyist".to_string());
    assert_eq!(cp.level(), option::none());
}

#[test]
fun instrumentalist_role_reports_instrument_name_and_level() {
    let with_level = rpr::new_instrumentalist_role(b"Piano".to_string(), lead());
    assert_eq!(with_level.name(), b"Instrumentalist".to_string());
    assert_eq!(with_level.level(), lead());

    let without_level = rpr::new_instrumentalist_role(b"Guitar".to_string(), option::none());
    assert_eq!(without_level.name(), b"Instrumentalist".to_string());
    assert_eq!(without_level.level(), option::none());
}

#[test]
fun custom_role_reports_role_name_and_level() {
    let c = rpr::new_custom_role(b"BeatboxArtist".to_string(), lead());
    assert_eq!(c.name(), b"BeatboxArtist".to_string());
    assert_eq!(c.level(), lead());
}

#[test]
fun role_levels_round_trip() {
    assert_eq!(
        rpr::new_producer_role(option::some(rpr::new_additional_role_level())).level(),
        option::some(rpr::new_additional_role_level()),
    );
    assert_eq!(
        rpr::new_producer_role(option::some(rpr::new_assistant_role_level())).level(),
        option::some(rpr::new_assistant_role_level()),
    );
    assert_eq!(
        rpr::new_producer_role(option::some(rpr::new_associate_role_level())).level(),
        option::some(rpr::new_associate_role_level()),
    );
    assert_eq!(
        rpr::new_producer_role(option::some(rpr::new_backing_role_level())).level(),
        option::some(rpr::new_backing_role_level()),
    );
    assert_eq!(
        rpr::new_producer_role(option::some(rpr::new_executive_role_level())).level(),
        option::some(rpr::new_executive_role_level()),
    );
    assert_eq!(
        rpr::new_producer_role(option::some(rpr::new_featured_role_level())).level(),
        option::some(rpr::new_featured_role_level()),
    );
    assert_eq!(
        rpr::new_producer_role(option::some(rpr::new_lead_role_level())).level(),
        option::some(rpr::new_lead_role_level()),
    );
    assert_eq!(
        rpr::new_producer_role(option::some(rpr::new_primary_role_level())).level(),
        option::some(rpr::new_primary_role_level()),
    );
    assert_eq!(
        rpr::new_producer_role(option::some(rpr::new_principal_role_level())).level(),
        option::some(rpr::new_principal_role_level()),
    );
}

#[test, expected_failure(abort_code = 35, location = recording_credits::recording_party_role)] // EEmptyString
fun new_instrumentalist_role_rejects_empty_name() {
    let _ = rpr::new_instrumentalist_role(b"".to_string(), option::none());
    abort
}

#[test, expected_failure(abort_code = 30, location = recording_credits::recording_party_role)] // EMaxInstrumentLengthExceeded
fun new_instrumentalist_role_rejects_too_long_name() {
    let name = test_helpers::long_string(101);
    let _ = rpr::new_instrumentalist_role(name, option::none());
    abort
}

#[test]
fun new_instrumentalist_role_accepts_max_length_name() {
    let name = test_helpers::long_string(100);
    let role = rpr::new_instrumentalist_role(name, option::none());
    assert_eq!(role.name(), b"Instrumentalist".to_string());
}

#[test, expected_failure(abort_code = 35, location = recording_credits::recording_party_role)] // EEmptyString
fun new_custom_role_rejects_empty_name() {
    let _ = rpr::new_custom_role(b"".to_string(), option::none());
    abort
}

#[test, expected_failure(abort_code = 31, location = recording_credits::recording_party_role)] // EMaxCustomNameLengthExceeded
fun new_custom_role_rejects_too_long_name() {
    let name = test_helpers::long_string(101);
    let _ = rpr::new_custom_role(name, option::none());
    abort
}

#[test]
fun new_custom_role_accepts_max_length_name() {
    let name = test_helpers::long_string(100);
    let role = rpr::new_custom_role(name, option::none());
    assert_eq!(role.name(), test_helpers::long_string(100));
}
