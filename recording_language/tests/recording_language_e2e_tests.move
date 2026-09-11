// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scenario coverage of `recording_language` against the production shape: a
/// `Recording` is published and shared first, and the extension operates on
/// it later, across real transaction boundaries and distinct senders.
///
/// This package never touches the composition side of a recording, so a bare
/// id stands in for a real `Composition` — `recording::new_for_testing` only
/// needs a composition `ID`, not a live `Composition` object.
///
/// `RecordingAdminCap<RecordingShare>` is selected by its `RecordingShare`
/// type, not by a runtime id check (`recording::uid_mut` takes the cap as `_`).
/// A mismatched `RecordingShare` fails to compile; a different cap value with
/// the same `RecordingShare` type succeeds because there is no cap-value
/// authentication. See the ADMIN-only-write assertions below instead: the
/// module has no notion of a non-admin actor at the type level, so what a
/// distinct sender can prove is that reads are open to anyone while writes
/// require holding the cap.
#[test_only]
module recording_language::recording_language_e2e_tests;

use language_code::language_code;
use musicos::recording::{Self, Recording};
use recording_language::recording_language as rl;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;

const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

public struct REC {}
public struct COMP {}

fun lang(code: vector<u8>): language_code::LanguageCode {
    language_code::new(code.to_string())
}

#[test]
fun admin_sets_languages_on_a_published_shared_recording_and_a_stranger_reads_it() {
    let mut ts = test_scenario::begin(ADMIN);

    // === Tx 1 (ADMIN): create and publish the recording — this shares it ===
    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let rec_id = object::id(&rec);
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock); // shares the recording
    clock.destroy_for_testing();

    // === Tx 2 (ADMIN): take the shared recording, attach languages ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(!rl::has_languages(&rec));

    rl::set_languages(&mut rec, &rec_cap, vector[lang(b"en"), lang(b"fr")]);

    let events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_id, event_comp_id, event_cap_id, had_languages, previous_languages,
        event_langs, language_count_before, language_count_after, was_instrumental,
        is_instrumental, max_languages) = rl::set_event_fields(&events[0]);
    assert_eq!(event_id, rec_id.to_address());
    assert_eq!(event_comp_id, @0xC0FFEE);
    assert_eq!(event_cap_id, object::id(&rec_cap).to_address());
    assert!(!had_languages);
    assert_eq!(previous_languages, vector[]);
    assert_eq!(event_langs, vector[b"en", b"fr"]);
    assert_eq!(language_count_before, 0);
    assert_eq!(language_count_after, 2);
    assert!(!was_instrumental);
    assert!(!is_instrumental);
    assert_eq!(max_languages, 10);
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 131);

    test_scenario::return_shared(rec);

    // === Tx 3 (STRANGER): reads are open to anyone, no cap required ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(rl::has_languages(&rec));
    assert!(!rl::is_instrumental(&rec));
    let got = rl::languages(&rec);
    assert_eq!(got.length(), 2);
    assert_eq!(got[0].code(), b"en".to_string());
    assert_eq!(got[1].code(), b"fr".to_string());
    test_scenario::return_shared(rec);

    // === Tx 4 (ADMIN): replaces with an instrumental claim, then unsets ===
    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    rl::set_instrumental(&mut rec, &rec_cap);
    assert!(rl::is_instrumental(&rec));
    assert_eq!(rl::languages(&rec).length(), 0);

    // `test_scenario::next_tx` clears the event log, so only this
    // transaction's set event is visible here — not tx 2's.
    let instrumental_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(instrumental_events.length(), 1);
    let (last_event_id, last_event_comp_id, last_event_cap_id, had_languages,
        previous_languages, last_event_langs, language_count_before, language_count_after,
        was_instrumental, is_instrumental, max_languages) =
        rl::set_event_fields(&instrumental_events[0]);
    assert_eq!(last_event_id, rec_id.to_address());
    assert_eq!(last_event_comp_id, @0xC0FFEE);
    assert_eq!(last_event_cap_id, object::id(&rec_cap).to_address());
    assert!(had_languages);
    assert_eq!(previous_languages, vector[b"en", b"fr"]);
    assert_eq!(last_event_langs, vector[]);
    assert_eq!(language_count_before, 2);
    assert_eq!(language_count_after, 0);
    assert!(!was_instrumental);
    assert!(is_instrumental);
    assert_eq!(max_languages, 10);
    assert_eq!(sui::bcs::to_bytes(&instrumental_events[0]).length(), 131);

    rl::unset_languages(&mut rec, &rec_cap);
    assert!(!rl::has_languages(&rec));
    // Unsetting withdraws the instrumental claim entirely — it is not left
    // reading as instrumental once nothing is attached.
    assert!(!rl::is_instrumental(&rec));

    let unset_events = event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, COMP>>();
    assert_eq!(unset_events.length(), 1);
    let (unset_id, unset_comp_id, unset_cap_id, removed_languages,
        language_count_before, was_instrumental) = rl::unset_event_fields(&unset_events[0]);
    assert_eq!(unset_id, rec_id.to_address());
    assert_eq!(unset_comp_id, @0xC0FFEE);
    assert_eq!(unset_cap_id, object::id(&rec_cap).to_address());
    assert_eq!(removed_languages, vector[]);
    assert_eq!(language_count_before, 0);
    assert!(was_instrumental);
    assert_eq!(sui::bcs::to_bytes(&unset_events[0]).length(), 106);

    test_scenario::return_shared(rec);

    // === Tx 5 (STRANGER): confirms removal is visible to any reader ===
    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    assert!(!rl::has_languages(&rec));
    assert!(!rl::is_instrumental(&rec));
    test_scenario::return_shared(rec);

    destroy(rec_cap);
    ts.end();
}

/// Operate-after-remove: reading languages after they have been explicitly
/// removed aborts exactly like a recording nothing was ever attached to —
/// absence is absence, regardless of history. Exercised across scenario
/// boundaries and a non-admin reader to match the production shape.
#[test, expected_failure(abort_code = rl::ENoLanguages)]
fun reading_after_remove_aborts_for_any_reader() {
    let mut ts = test_scenario::begin(ADMIN);

    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    rl::set_languages(&mut rec, &rec_cap, vector[lang(b"en")]);
    rl::unset_languages(&mut rec, &rec_cap);
    test_scenario::return_shared(rec);

    ts.next_tx(STRANGER);
    let rec = ts.take_shared<Recording<REC, COMP>>();
    let _ = rl::languages(&rec); // aborts: ENoLanguages

    test_scenario::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}

/// The validation aborts also apply against the production shape: a
/// duplicate or over-count set on a published, shared recording aborts the
/// same as it does in the bare-object unit tests.
#[test, expected_failure(abort_code = rl::EDuplicateLanguage)]
fun duplicate_language_aborts_against_a_shared_recording() {
    let mut ts = test_scenario::begin(ADMIN);

    let (rec, rec_cap) = recording::new_for_testing<REC, COMP>(
        object::id_from_address(@0xC0FFEE),
        ts.ctx(),
    );
    let clock = sui::clock::create_for_testing(ts.ctx());
    rec.publish(&rec_cap, &clock);
    clock.destroy_for_testing();

    ts.next_tx(ADMIN);
    let mut rec = ts.take_shared<Recording<REC, COMP>>();
    rl::set_languages(&mut rec, &rec_cap, vector[lang(b"en"), lang(b"en")]);

    test_scenario::return_shared(rec);
    destroy(rec_cap);
    ts.end();
}
