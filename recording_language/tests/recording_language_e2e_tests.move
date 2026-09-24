// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_language` against the production shape: a
/// `Recording` is published and shared first, and the extension operates on
/// it later, across real transaction boundaries and distinct senders. Reads
/// are open to anyone; writes require the admin cap.
#[test_only]
module recording_language::recording_language_e2e_tests;

use language_code::language_code::{Self, LanguageCode};
use musicos::recording::{Self, Recording};
use recording_language::recording_language::{
    Self as rl,
    RecordingLanguagesSetEvent,
    RecordingLanguagesClearedEvent,
};
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event::events_by_type;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

public struct REC {}

fun lang(code: vector<u8>): LanguageCode {
    language_code::new(code.to_string())
}

/// Creates and publishes (shares) a recording as the current sender.
fun publish_recording(ts: &mut Scenario): (ID, recording::RecordingAdminCap<REC>) {
    let (rec, cap) = recording::new_for_testing<REC>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec);
    rec.publish(&cap);
    (rec_id, cap)
}

#[test]
fun admin_sets_languages_on_a_published_shared_recording_and_a_stranger_reads_it() {
    let mut ts = ts::begin(ADMIN);

    // === Tx 1 (ADMIN): create and publish the recording — this shares it ===
    let (rec_id, rec_cap) = publish_recording(&mut ts);

    // === Tx 2 (ADMIN): take the shared recording, attach languages ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    assert!(!rl::has_languages(&rec));

    rl::set_languages(&mut rec, &rec_cap, vector[lang(b"en"), lang(b"fr")]);

    let events = events_by_type<RecordingLanguagesSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (event_id, languages) = rl::set_event_fields(&events[0]);
    assert_eq!(event_id, rec_id.to_address());
    assert_eq!(languages, vector[b"en".to_string(), b"fr".to_string()]);
    assert_eq!(to_bytes(&events[0]).length(), 39);
    ts::return_shared(rec);

    // === Tx 3 (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(rl::has_languages(&rec));
    let got = rl::languages(&rec);
    assert_eq!(got.length(), 2);
    assert_eq!(got[0].code(), b"en".to_string());
    assert_eq!(got[1].code(), b"fr".to_string());
    ts::return_shared(rec);

    // === Tx 4 (ADMIN): equal set is silent; instrumental claim; then clear ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rl::set_languages(&mut rec, &rec_cap, vector[lang(b"en"), lang(b"fr")]);
    assert_eq!(events_by_type<RecordingLanguagesSetEvent<REC>>().length(), 0);

    rl::set_languages(&mut rec, &rec_cap, vector[]);
    assert!(rl::has_languages(&rec));
    assert!(rl::languages(&rec).is_empty());
    let events = events_by_type<RecordingLanguagesSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (_, languages) = rl::set_event_fields(&events[0]);
    assert!(languages.is_empty());
    assert_eq!(to_bytes(&events[0]).length(), 33);

    rl::clear_languages(&mut rec, &rec_cap);
    assert!(!rl::has_languages(&rec));
    let cleared = events_by_type<RecordingLanguagesClearedEvent<REC>>();
    assert_eq!(cleared.length(), 1);
    assert_eq!(rl::cleared_event_fields(&cleared[0]), rec_id.to_address());
    assert_eq!(to_bytes(&cleared[0]).length(), 32);
    ts::return_shared(rec);

    // === Tx 5 (STRANGER): removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    assert!(!rl::has_languages(&rec));
    ts::return_shared(rec);

    destroy(rec_cap);
    ts.end();
}

/// Reading after an explicit clear aborts exactly like a recording nothing
/// was ever attached to — absence is absence, regardless of history.
#[test, expected_failure(abort_code = rl::ENoLanguages)]
fun reading_after_clear_aborts_for_any_reader() {
    let mut ts = ts::begin(ADMIN);
    let (_, rec_cap) = publish_recording(&mut ts);

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rl::set_languages(&mut rec, &rec_cap, vector[lang(b"en")]);
    rl::clear_languages(&mut rec, &rec_cap);
    ts::return_shared(rec);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC>>();
    let _ = rl::languages(&rec); // aborts: ENoLanguages

    ts::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}

/// Validation applies against the production shape too.
#[test, expected_failure(abort_code = rl::EDuplicateLanguage)]
fun duplicate_language_aborts_against_a_shared_recording() {
    let mut ts = ts::begin(ADMIN);
    let (_, rec_cap) = publish_recording(&mut ts);

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC>>();
    rl::set_languages(&mut rec, &rec_cap, vector[lang(b"en"), lang(b"en")]);

    ts::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}
