// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The roles a party can hold on a recording: the production and performance
/// contributions to an audio performance of a composition.
///
/// `RecordingPartyRole` is a closed enum constructed only through the
/// `new_*_role` functions and read through `level()`. Seniority is a separate
/// axis: most roles carry an optional `RecordingPartyRoleLevel`, so
/// "Additional Producer" is `Producer` plus `Additional` rather than its own
/// variant; `ArtistsAndRepertoire` and `Copyist` carry none. `Instrumentalist`
/// also carries a validated instrument name. The vocabulary is fixed to these
/// canonical variants and is musicos's own; any overlap with an external
/// standard (e.g. DDEX) is coincidental. Consumers read a role from its BCS
/// variant index, in declaration order.
module recording_credits::recording_party_role;

use std::string::String;

// === Errors ===

// Constraint errors (30-39)
/// Instrument name exceeds maximum length.
const EMaxInstrumentLengthExceeded: u64 = 30;
/// String must not be empty.
const EEmptyString: u64 = 35;

// === Constants ===

/// Maximum length of an instrument name in bytes.
const MAX_INSTRUMENT_LENGTH: u64 = 100;

// === Enums ===

/// A party's role on a recording. Most roles carry an optional level;
/// `ArtistsAndRepertoire` and `Copyist` are clerical roles that do not.
public enum RecordingPartyRole has copy, drop, store {
    /// Performed voice acting or spoken-word performance.
    Actor(Option<RecordingPartyRoleLevel>),
    /// Arranged the musical parts for the recording.
    Arranger(Option<RecordingPartyRoleLevel>),
    /// A&R representative who discovered or developed the artist.
    ArtistsAndRepertoire,
    /// Led the band or backing ensemble.
    BandLeader(Option<RecordingPartyRoleLevel>),
    /// Performed as part of a choir.
    Choir(Option<RecordingPartyRoleLevel>),
    /// Directed the choir performance.
    ChoirMaster(Option<RecordingPartyRoleLevel>),
    /// Lead performer of an orchestra/ensemble (e.g. first-chair).
    ConcertMaster(Option<RecordingPartyRoleLevel>),
    /// Conducted the orchestra or ensemble.
    Conductor(Option<RecordingPartyRoleLevel>),
    /// Hired and managed session musicians.
    Contractor(Option<RecordingPartyRoleLevel>),
    /// Prepared written music parts for performers.
    Copyist,
    /// Performed/assembled the recording as a disc jockey.
    DJ(Option<RecordingPartyRoleLevel>),
    /// Edited and compiled audio takes.
    Editor(Option<RecordingPartyRoleLevel>),
    /// General engineering contribution not covered by a specific engineer role.
    Engineer(Option<RecordingPartyRoleLevel>),
    /// Performed as part of a musical ensemble.
    Ensemble(Option<RecordingPartyRoleLevel>),
    /// Played an instrument on the recording. Carries the instrument name.
    Instrumentalist(String, Option<RecordingPartyRoleLevel>),
    /// Mastered the final audio for distribution.
    MasteringEngineer(Option<RecordingPartyRoleLevel>),
    /// Mixed the multitrack recording into stereo/surround.
    MixingEngineer(Option<RecordingPartyRoleLevel>),
    /// Directed the musical performance.
    MusicDirector(Option<RecordingPartyRoleLevel>),
    /// Oversaw music selection and licensing.
    MusicSupervisor(Option<RecordingPartyRoleLevel>),
    /// Narrated spoken content.
    Narrator(Option<RecordingPartyRoleLevel>),
    /// Performed as part of an orchestra.
    Orchestra(Option<RecordingPartyRoleLevel>),
    /// Created orchestral arrangements.
    Orchestrator(Option<RecordingPartyRoleLevel>),
    /// Performed on the recording (general performer).
    Performer(Option<RecordingPartyRoleLevel>),
    /// Oversaw the creative and technical aspects of the recording.
    Producer(Option<RecordingPartyRoleLevel>),
    /// Programmed beats, synths, or electronic elements.
    Programmer(Option<RecordingPartyRoleLevel>),
    /// Operated recording equipment during sessions.
    RecordingEngineer(Option<RecordingPartyRoleLevel>),
    /// Created a remix of the recording.
    RemixingEngineer(Option<RecordingPartyRoleLevel>),
    /// Performed a solo part.
    Soloist(Option<RecordingPartyRoleLevel>),
    /// Created sound effects or sonic textures.
    SoundDesigner(Option<RecordingPartyRoleLevel>),
    /// Delivered spoken-word or presentation content.
    Speaker(Option<RecordingPartyRoleLevel>),
    /// Provided vocals on the recording.
    Vocalist(Option<RecordingPartyRoleLevel>),
}

/// The seniority or prominence of a party in a role.
public enum RecordingPartyRoleLevel has copy, drop, store {
    /// Additional/supplementary party.
    Additional,
    /// Assistant to the primary party.
    Assistant,
    /// Associate-level party.
    Associate,
    /// Backing/support role (e.g., backing vocals).
    Backing,
    /// Executive-level oversight role.
    Executive,
    /// Featured prominently on the recording.
    Featured,
    /// Lead/primary party in this role.
    Lead,
    /// Primary artist on the recording.
    Primary,
    /// Principal party with primary responsibility.
    Principal,
}

// === Public Functions ===

/// Creates a new Actor role with optional level.
public fun new_actor_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Actor(level)
}

/// Creates a new Arranger role with optional level.
public fun new_arranger_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Arranger(level)
}

/// Creates a new Artists & Repertoire role.
public fun new_artists_and_repertoire_role(): RecordingPartyRole {
    RecordingPartyRole::ArtistsAndRepertoire
}

/// Creates a new Band Leader role with optional level.
public fun new_band_leader_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::BandLeader(level)
}

/// Creates a new Choir role with optional level.
public fun new_choir_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Choir(level)
}

/// Creates a new Choir Master role with optional level.
public fun new_choir_master_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::ChoirMaster(level)
}

/// Creates a new Concert Master role with optional level.
public fun new_concert_master_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::ConcertMaster(level)
}

/// Creates a new Conductor role with optional level.
public fun new_conductor_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Conductor(level)
}

/// Creates a new Contractor role with optional level.
public fun new_contractor_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Contractor(level)
}

/// Creates a new Copyist role.
public fun new_copyist_role(): RecordingPartyRole {
    RecordingPartyRole::Copyist
}

/// Creates a new DJ role with optional level.
public fun new_dj_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::DJ(level)
}

/// Creates a new Editor role with optional level.
public fun new_editor_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Editor(level)
}

/// Creates a new (general) Engineer role with optional level.
public fun new_engineer_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Engineer(level)
}

/// Creates a new Ensemble role with optional level.
public fun new_ensemble_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Ensemble(level)
}

/// Creates a new Instrumentalist role. The instrument name freezes into
/// credits, so it is validated here: non-empty and at most 100 bytes.
public fun new_instrumentalist_role(
    instrument: String,
    level: Option<RecordingPartyRoleLevel>,
): RecordingPartyRole {
    assert!(!instrument.is_empty(), EEmptyString);
    assert!(instrument.length() <= MAX_INSTRUMENT_LENGTH, EMaxInstrumentLengthExceeded);
    RecordingPartyRole::Instrumentalist(instrument, level)
}

/// Creates a new Mastering Engineer role with optional level.
public fun new_mastering_engineer_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::MasteringEngineer(level)
}

/// Creates a new Mixing Engineer role with optional level.
public fun new_mixing_engineer_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::MixingEngineer(level)
}

/// Creates a new Music Director role with optional level.
public fun new_music_director_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::MusicDirector(level)
}

/// Creates a new Music Supervisor role with optional level.
public fun new_music_supervisor_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::MusicSupervisor(level)
}

/// Creates a new Narrator role with optional level.
public fun new_narrator_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Narrator(level)
}

/// Creates a new Orchestra role with optional level.
public fun new_orchestra_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Orchestra(level)
}

/// Creates a new Orchestrator role with optional level.
public fun new_orchestrator_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Orchestrator(level)
}

/// Creates a new Performer role with optional level.
public fun new_performer_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Performer(level)
}

/// Creates a new Producer role with optional level.
public fun new_producer_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Producer(level)
}

/// Creates a new Programmer role with optional level.
public fun new_programmer_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Programmer(level)
}

/// Creates a new Recording Engineer role with optional level.
public fun new_recording_engineer_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::RecordingEngineer(level)
}

/// Creates a new Remixing Engineer role with optional level.
public fun new_remixing_engineer_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::RemixingEngineer(level)
}

/// Creates a new Soloist role with optional level.
public fun new_soloist_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Soloist(level)
}

/// Creates a new Sound Designer role with optional level.
public fun new_sound_designer_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::SoundDesigner(level)
}

/// Creates a new Speaker role with optional level.
public fun new_speaker_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Speaker(level)
}

/// Creates a new Vocalist role with optional level.
public fun new_vocalist_role(level: Option<RecordingPartyRoleLevel>): RecordingPartyRole {
    RecordingPartyRole::Vocalist(level)
}

/// Creates an Additional level.
public fun new_additional_role_level(): RecordingPartyRoleLevel {
    RecordingPartyRoleLevel::Additional
}

/// Creates an Assistant level.
public fun new_assistant_role_level(): RecordingPartyRoleLevel {
    RecordingPartyRoleLevel::Assistant
}

/// Creates an Associate level.
public fun new_associate_role_level(): RecordingPartyRoleLevel {
    RecordingPartyRoleLevel::Associate
}

/// Creates a Backing level.
public fun new_backing_role_level(): RecordingPartyRoleLevel {
    RecordingPartyRoleLevel::Backing
}

/// Creates an Executive level.
public fun new_executive_role_level(): RecordingPartyRoleLevel {
    RecordingPartyRoleLevel::Executive
}

/// Creates a Featured level.
public fun new_featured_role_level(): RecordingPartyRoleLevel {
    RecordingPartyRoleLevel::Featured
}

/// Creates a Lead level.
public fun new_lead_role_level(): RecordingPartyRoleLevel {
    RecordingPartyRoleLevel::Lead
}

/// Creates a Primary level.
public fun new_primary_role_level(): RecordingPartyRoleLevel {
    RecordingPartyRoleLevel::Primary
}

/// Creates a Principal level.
public fun new_principal_role_level(): RecordingPartyRoleLevel {
    RecordingPartyRoleLevel::Principal
}

// === View Functions ===

/// The role's optional level.
public fun level(self: &RecordingPartyRole): Option<RecordingPartyRoleLevel> {
    match (self) {
        RecordingPartyRole::Actor(level) => *level,
        RecordingPartyRole::Arranger(level) => *level,
        RecordingPartyRole::ArtistsAndRepertoire => option::none(),
        RecordingPartyRole::BandLeader(level) => *level,
        RecordingPartyRole::Choir(level) => *level,
        RecordingPartyRole::ChoirMaster(level) => *level,
        RecordingPartyRole::ConcertMaster(level) => *level,
        RecordingPartyRole::Conductor(level) => *level,
        RecordingPartyRole::Contractor(level) => *level,
        RecordingPartyRole::Copyist => option::none(),
        RecordingPartyRole::DJ(level) => *level,
        RecordingPartyRole::Editor(level) => *level,
        RecordingPartyRole::Engineer(level) => *level,
        RecordingPartyRole::Ensemble(level) => *level,
        RecordingPartyRole::Instrumentalist(_, level) => *level,
        RecordingPartyRole::MasteringEngineer(level) => *level,
        RecordingPartyRole::MixingEngineer(level) => *level,
        RecordingPartyRole::MusicDirector(level) => *level,
        RecordingPartyRole::MusicSupervisor(level) => *level,
        RecordingPartyRole::Narrator(level) => *level,
        RecordingPartyRole::Orchestra(level) => *level,
        RecordingPartyRole::Orchestrator(level) => *level,
        RecordingPartyRole::Performer(level) => *level,
        RecordingPartyRole::Producer(level) => *level,
        RecordingPartyRole::Programmer(level) => *level,
        RecordingPartyRole::RecordingEngineer(level) => *level,
        RecordingPartyRole::RemixingEngineer(level) => *level,
        RecordingPartyRole::Soloist(level) => *level,
        RecordingPartyRole::SoundDesigner(level) => *level,
        RecordingPartyRole::Speaker(level) => *level,
        RecordingPartyRole::Vocalist(level) => *level,
    }
}
