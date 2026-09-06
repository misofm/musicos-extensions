// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines the roles that parties can hold on a recording.
/// Recordings are audio performances of compositions, and these roles
/// represent the various production and performance contributions.
///
/// ### Design
///
/// `RecordingPartyRole` is a closed enum: variants can only be constructed and
/// matched inside this module, so the `new_*_role` constructors are the external
/// write-API and `name()` is the external read-API.
///
/// - **Seniority is a separate axis.** Most roles carry an optional
///   `RecordingPartyRoleLevel` (Lead, Assistant, Additional, …). Industry
///   variants like "Second Engineer" or "Additional Producer" are expressed as a
///   base role plus a level, not as their own variants — this keeps the role set
///   compact without losing the distinction.
/// - **`Custom` is the escape hatch.** The canonical variants cover the common
///   vocabulary; anything outside it is a `Custom(name, level)` whose name is
///   validated like an instrument name. Prefer a canonical variant when one fits.
/// - **`name()` is the canonical identifier**, returned as a stable PascalCase
///   token (e.g. `"MixingEngineer"`). It doubles as an on-chain match key and as
///   the seed for off-chain display/localization. For `Custom`, `name()` returns
///   the user-supplied string; for `Instrumentalist`, it returns
///   `"Instrumentalist"` (the instrument itself is read off-chain).
///
/// These identifiers are Miso's own canonical vocabulary; any overlap with an
/// external standard (e.g. DDEX) is coincidental, not a reproduction of it.
module recording_credits::recording_party_role;

use std::string::String;

// === Errors ===

// Constraint errors (30-39)
/// Instrument name exceeds maximum length.
const EMaxInstrumentLengthExceeded: u64 = 30;
/// Custom role name exceeds maximum length.
const EMaxCustomNameLengthExceeded: u64 = 31;
/// String must not be empty.
const EEmptyString: u64 = 35;

// === Constants ===

/// Maximum length of an instrument name in bytes.
const MAX_INSTRUMENT_LENGTH: u64 = 100;
/// Maximum length of a custom role name in bytes.
const MAX_CUSTOM_NAME_LENGTH: u64 = 100;

// === Enums ===

/// Represents a party's role on a recording.
/// Most roles carry an optional level to indicate seniority/prominence;
/// `ArtistsAndRepertoire` and `Copyist` are clerical/business roles that do not.
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
    /// A user-defined role not covered by a canonical variant. Carries the
    /// role name (validated like an instrument name) and an optional level.
    /// An escape hatch — prefer a canonical variant when one fits.
    Custom(String, Option<RecordingPartyRoleLevel>),
}

/// Indicates the seniority or prominence level of a party.
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

// Roles

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

/// Creates a new Instrumentalist role with instrument name and optional level.
/// The instrument name freezes into credits, so it is validated here.
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

/// Creates a new Custom role with a user-defined name and optional level.
/// The name freezes into credits, so it is validated like an instrument name.
/// Prefer a canonical variant when one fits.
public fun new_custom_role(
    role_name: String,
    level: Option<RecordingPartyRoleLevel>,
): RecordingPartyRole {
    assert!(!role_name.is_empty(), EEmptyString);
    assert!(role_name.length() <= MAX_CUSTOM_NAME_LENGTH, EMaxCustomNameLengthExceeded);
    RecordingPartyRole::Custom(role_name, level)
}

// Levels

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

/// Returns the optional level associated with this role.
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
        RecordingPartyRole::Custom(_, level) => *level,
    }
}

/// Returns the canonical identifier of the role as a stable PascalCase token.
/// For `Custom`, returns the user-supplied name; for `Instrumentalist`, returns
/// `"Instrumentalist"` (the instrument is read off-chain).
public fun name(self: &RecordingPartyRole): String {
    match (self) {
        RecordingPartyRole::Actor(_) => b"Actor".to_string(),
        RecordingPartyRole::Arranger(_) => b"Arranger".to_string(),
        RecordingPartyRole::ArtistsAndRepertoire => b"ArtistsAndRepertoire".to_string(),
        RecordingPartyRole::BandLeader(_) => b"BandLeader".to_string(),
        RecordingPartyRole::Choir(_) => b"Choir".to_string(),
        RecordingPartyRole::ChoirMaster(_) => b"ChoirMaster".to_string(),
        RecordingPartyRole::ConcertMaster(_) => b"ConcertMaster".to_string(),
        RecordingPartyRole::Conductor(_) => b"Conductor".to_string(),
        RecordingPartyRole::Contractor(_) => b"Contractor".to_string(),
        RecordingPartyRole::Copyist => b"Copyist".to_string(),
        RecordingPartyRole::DJ(_) => b"DJ".to_string(),
        RecordingPartyRole::Editor(_) => b"Editor".to_string(),
        RecordingPartyRole::Engineer(_) => b"Engineer".to_string(),
        RecordingPartyRole::Ensemble(_) => b"Ensemble".to_string(),
        RecordingPartyRole::Instrumentalist(..) => b"Instrumentalist".to_string(),
        RecordingPartyRole::MasteringEngineer(_) => b"MasteringEngineer".to_string(),
        RecordingPartyRole::MixingEngineer(_) => b"MixingEngineer".to_string(),
        RecordingPartyRole::MusicDirector(_) => b"MusicDirector".to_string(),
        RecordingPartyRole::MusicSupervisor(_) => b"MusicSupervisor".to_string(),
        RecordingPartyRole::Narrator(_) => b"Narrator".to_string(),
        RecordingPartyRole::Orchestra(_) => b"Orchestra".to_string(),
        RecordingPartyRole::Orchestrator(_) => b"Orchestrator".to_string(),
        RecordingPartyRole::Performer(_) => b"Performer".to_string(),
        RecordingPartyRole::Producer(_) => b"Producer".to_string(),
        RecordingPartyRole::Programmer(_) => b"Programmer".to_string(),
        RecordingPartyRole::RecordingEngineer(_) => b"RecordingEngineer".to_string(),
        RecordingPartyRole::RemixingEngineer(_) => b"RemixingEngineer".to_string(),
        RecordingPartyRole::Soloist(_) => b"Soloist".to_string(),
        RecordingPartyRole::SoundDesigner(_) => b"SoundDesigner".to_string(),
        RecordingPartyRole::Speaker(_) => b"Speaker".to_string(),
        RecordingPartyRole::Vocalist(_) => b"Vocalist".to_string(),
        RecordingPartyRole::Custom(role_name, _) => *role_name,
    }
}
