// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pure value tests for `recording_party_role`: role/level constructors and
/// the `name()`/`level()` readers touch no objects, capabilities, or shared
/// state — there is no ownership mechanics for `test_scenario` transaction
/// boundaries to prove here (the module under test does not even take a
/// `TxContext`), so these stay plain single-transaction value assertions.
#[test_only]
module recording_credits::recording_party_role_tests;

use musicos::test_helpers;
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
fun event_fields_cover_every_primitive_role_code() {
    let level = option::some(rpr::new_primary_role_level());
    let roles = vector[
        rpr::new_actor_role(level),
        rpr::new_arranger_role(level),
        rpr::new_artists_and_repertoire_role(),
        rpr::new_band_leader_role(level),
        rpr::new_choir_role(level),
        rpr::new_choir_master_role(level),
        rpr::new_concert_master_role(level),
        rpr::new_conductor_role(level),
        rpr::new_contractor_role(level),
        rpr::new_copyist_role(),
        rpr::new_dj_role(level),
        rpr::new_editor_role(level),
        rpr::new_engineer_role(level),
        rpr::new_ensemble_role(level),
        rpr::new_instrumentalist_role(b"Piano".to_string(), level),
        rpr::new_mastering_engineer_role(level),
        rpr::new_mixing_engineer_role(level),
        rpr::new_music_director_role(level),
        rpr::new_music_supervisor_role(level),
        rpr::new_narrator_role(level),
        rpr::new_orchestra_role(level),
        rpr::new_orchestrator_role(level),
        rpr::new_performer_role(level),
        rpr::new_producer_role(level),
        rpr::new_programmer_role(level),
        rpr::new_recording_engineer_role(level),
        rpr::new_remixing_engineer_role(level),
        rpr::new_soloist_role(level),
        rpr::new_sound_designer_role(level),
        rpr::new_speaker_role(level),
        rpr::new_vocalist_role(level),
        rpr::new_custom_role(b"Producer".to_string(), level),
    ];
    let names = vector[
        b"Actor", b"Arranger", b"ArtistsAndRepertoire", b"BandLeader", b"Choir",
        b"ChoirMaster", b"ConcertMaster", b"Conductor", b"Contractor", b"Copyist",
        b"DJ", b"Editor", b"Engineer", b"Ensemble", b"Instrumentalist",
        b"MasteringEngineer", b"MixingEngineer", b"MusicDirector", b"MusicSupervisor",
        b"Narrator", b"Orchestra", b"Orchestrator", b"Performer", b"Producer",
        b"Programmer", b"RecordingEngineer", b"RemixingEngineer", b"Soloist",
        b"SoundDesigner", b"Speaker", b"Vocalist", b"Producer",
    ];
    let kinds = vector[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31];
    roles.length().do!(|i| {
        let (kind, name, instrument, code) = rpr::event_fields(&roles[i]);
        assert_eq!(kind, kinds[i]);
        assert_eq!(name, names[i]);
        if (i == 2 || i == 9) {
            assert_eq!(code, 0);
        } else {
            assert_eq!(code, 8);
        };
        if (i == 14) {
            assert_eq!(instrument, b"Piano");
        } else if (i == 31) {
            assert_eq!(instrument, b"");
        } else {
            assert_eq!(instrument, b"");
        };
    });
}

#[test]
fun event_fields_cover_every_level_code() {
    let roles = vector[
        rpr::new_producer_role(option::some(rpr::new_additional_role_level())),
        rpr::new_producer_role(option::some(rpr::new_assistant_role_level())),
        rpr::new_producer_role(option::some(rpr::new_associate_role_level())),
        rpr::new_producer_role(option::some(rpr::new_backing_role_level())),
        rpr::new_producer_role(option::some(rpr::new_executive_role_level())),
        rpr::new_producer_role(option::some(rpr::new_featured_role_level())),
        rpr::new_producer_role(option::some(rpr::new_lead_role_level())),
        rpr::new_producer_role(option::some(rpr::new_primary_role_level())),
        rpr::new_producer_role(option::some(rpr::new_principal_role_level())),
    ];
    let codes = vector[1, 2, 3, 4, 5, 6, 7, 8, 9];
    roles.length().do!(|i| {
        let (_, _, _, code) = rpr::event_fields(&roles[i]);
        assert_eq!(code, codes[i]);
    });
    let none_role = rpr::new_producer_role(option::none());
    let (_, _, _, none_code) = rpr::event_fields(&none_role);
    assert_eq!(none_code, 0);
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
