// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Attach/read/replace/instrumental/clear mechanics of the language attribute
/// and its validation aborts, against a single bare `Recording` with no
/// ownership handoff — nothing here crosses a transaction boundary or changes
/// hands between actors, so plain `tx_context::dummy()` is exactly as faithful
/// as a scenario and adds no signal. The production shape — a published,
/// shared `Recording` operated on by distinct senders across real
/// transactions — is covered separately in `language_e2e_tests`.
///
/// A mismatched `RecordingShare` fails compilation. A different cap value with
/// the same `RecordingShare` is accepted because `recording::uid_mut` ignores
/// the cap value.
#[test_only]
module recording_metadata::language_tests;

use language_code::language_code;
use musicos::recording;
use recording_metadata::recording_metadata as rm;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

public struct REC {}
public struct OTHER_REC {}

// This package never touches the composition side of a recording, so a bare
// id stands in for a real `Composition` — `recording::new_for_testing` only
// needs a composition `ID`, not a live `Composition` object.
fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC>(object::id_from_address(@0xC0), ctx)
}

fun lang(code: vector<u8>): language_code::LanguageCode {
    language_code::new(code.to_string())
}

/// The raw two-byte codes of a language list, in order — what the event's
/// `vector<LanguageCode>` serialises to.
fun codes(languages: &vector<language_code::LanguageCode>): vector<vector<u8>> {
    languages.map_ref!(|language| *language.code().as_bytes())
}

fun view_language_bytes(rec: &recording::Recording<REC>): vector<vector<u8>> {
    let values = rm::languages(rec);
    let mut result = vector[];
    values.do_ref!(|value| result.push_back(*value.code().as_bytes()));
    result
}

fun is_instrumental(rec: &recording::Recording<REC>): bool {
    rm::has_languages(rec) && rm::languages(rec).is_empty()
}

fun assert_projection_matches_view(
    rec: &recording::Recording<REC>,
    projected_exists: bool,
    projected_languages: &vector<vector<u8>>,
) {
    assert_eq!(rm::has_languages(rec), projected_exists);
    if (projected_exists) {
        assert_eq!(view_language_bytes(rec), *projected_languages);
        assert_eq!(is_instrumental(rec), projected_languages.is_empty());
    } else {
        assert!(projected_languages.is_empty());
        assert!(!is_instrumental(rec));
    }
}

/// Decode the serialized event in declaration order and replay only its
/// transition into a tiny projection. The final assertions compare that
/// event-only state with the permissionless storage views.
fun project_set_event(
    projected_exists: &mut bool,
    projected_languages: &mut vector<vector<u8>>,
    event: &rm::RecordingLanguagesSetEvent<REC>,
    recording_id: address,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    let languages = bytes.peel_vec_vec_u8();
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_exists = true;
    *projected_languages = languages;
}

fun project_cleared_event(
    projected_exists: &mut bool,
    projected_languages: &mut vector<vector<u8>>,
    event: &rm::RecordingLanguagesClearedEvent<REC>,
    recording_id: address,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert!(bytes.into_remainder_bytes().is_empty());
    assert!(*projected_exists);
    *projected_exists = false;
    *projected_languages = vector[];
}

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let recording_id = object::id(&rec).to_address();
    let mut projected_exists = false;
    let mut projected_languages = vector[];

    assert_projection_matches_view(&rec, projected_exists, &projected_languages);

    // Sung languages are attached first.
    rm::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr")]);
    let set_events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    project_set_event(&mut projected_exists, &mut projected_languages, &set_events[0], recording_id);
    assert_projection_matches_view(&rec, projected_exists, &projected_languages);
    assert_eq!(projected_languages, vector[b"en", b"fr"]);

    // Equal replacement is a no-op: nothing emitted, projection unchanged.
    rm::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr")]);
    let set_events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    assert_projection_matches_view(&rec, projected_exists, &projected_languages);

    // Reordering is a replacement and preserves caller order.
    rm::set_languages(&mut rec, &cap, vector[lang(b"fr"), lang(b"en")]);
    let set_events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(set_events.length(), 2);
    project_set_event(&mut projected_exists, &mut projected_languages, &set_events[1], recording_id);
    assert_projection_matches_view(&rec, projected_exists, &projected_languages);
    assert_eq!(projected_languages, vector[b"fr", b"en"]);

    // Instrumental is an attached empty value, not absence.
    rm::set_languages(&mut rec, &cap, vector[]);
    let set_events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(set_events.length(), 3);
    project_set_event(&mut projected_exists, &mut projected_languages, &set_events[2], recording_id);
    assert_projection_matches_view(&rec, projected_exists, &projected_languages);
    assert!(is_instrumental(&rec));

    // An equal instrumental claim is also a silent no-op.
    rm::set_languages(&mut rec, &cap, vector[]);
    let set_events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(set_events.length(), 3);
    assert_projection_matches_view(&rec, projected_exists, &projected_languages);
    assert!(is_instrumental(&rec));

    // Present-empty clear emits and projects absence.
    rm::clear_languages(&mut rec, &cap);
    let cleared_events = event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>();
    assert_eq!(cleared_events.length(), 1);
    project_cleared_event(&mut projected_exists, &mut projected_languages, &cleared_events[0], recording_id);
    assert_projection_matches_view(&rec, projected_exists, &projected_languages);

    // Absent clear is silent and leaves the projection unchanged.
    rm::clear_languages(&mut rec, &cap);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>().length(), 1);
    assert_projection_matches_view(&rec, projected_exists, &projected_languages);

    // A later set starts a fresh attached state after the clear.
    rm::set_languages(&mut rec, &cap, vector[lang(b"ja")]);
    let set_events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(set_events.length(), 4);
    project_set_event(&mut projected_exists, &mut projected_languages, &set_events[3], recording_id);
    assert_projection_matches_view(&rec, projected_exists, &projected_languages);
    assert_eq!(projected_languages, vector[b"ja"]);

    destroy(rec);
    destroy(cap);
}

/// Setting the list already attached — same codes, same order — is a no-op:
/// nothing is written and nothing is emitted. The same codes in a different
/// order are a different value and still replace and emit.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    rm::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr")]);
    assert_eq!(event::num_events(), 1);

    rm::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr")]);
    assert_eq!(event::num_events(), 1);
    assert!(rm::has_metadata_for_testing(&rec));
    assert_eq!(view_language_bytes(&rec), vector[b"en", b"fr"]);

    rm::set_languages(&mut rec, &cap, vector[lang(b"fr"), lang(b"en")]);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>().length(), 2);
    assert_eq!(view_language_bytes(&rec), vector[b"fr", b"en"]);

    // Cleared and set again to the same list: absent, so not a no-op.
    rm::clear_languages(&mut rec, &cap);
    assert!(!rm::has_metadata_for_testing(&rec));
    rm::set_languages(&mut rec, &cap, vector[lang(b"fr"), lang(b"en")]);
    assert!(rm::has_metadata_for_testing(&rec));
    assert_eq!(event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>().length(), 3);

    destroy(rec);
    destroy(cap);
}

/// An instrumental claim already attached is a no-op like any other equal
/// set — and is not absence: the record stays, and `clear_languages` still
/// has something to remove afterwards.
#[test]
fun equal_instrumental_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    rm::set_languages(&mut rec, &cap, vector[]);
    assert_eq!(event::num_events(), 1);

    rm::set_languages(&mut rec, &cap, vector[]);
    assert_eq!(event::num_events(), 1);
    assert!(rm::has_metadata_for_testing(&rec));
    assert!(is_instrumental(&rec));

    rm::clear_languages(&mut rec, &cap);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>().length(), 1);
    assert!(!rm::has_languages(&rec));

    destroy(rec);
    destroy(cap);
}

/// Argument validation precedes the no-op check: a list with a duplicate
/// aborts even while an equal-prefix list is attached.
#[test, expected_failure(abort_code = rm::EDuplicateLanguage)]
fun duplicate_language_aborts_on_replace() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    rm::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    rm::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"en")]);
    destroy(rec);
    destroy(cap);
}

/// Order is the caller's and must survive the round trip — the first entry is
/// conventionally the predominant language.
#[test]
fun order_is_preserved() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    rm::set_languages(&mut rec, &cap, vector[lang(b"ja"), lang(b"en"), lang(b"ko")]);
    let got = rm::languages(&rec);
    assert_eq!(got[0].code(), b"ja".to_string());
    assert_eq!(got[1].code(), b"en".to_string());
    assert_eq!(got[2].code(), b"ko".to_string());

    destroy(rec);
    destroy(cap);
}

/// The three states must stay distinct: instrumental is a claim, absence is not.
#[test]
fun instrumental_is_distinct_from_absent_and_from_sung() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    // Nothing attached: no claim either way.
    assert!(!rm::has_languages(&rec));
    assert!(!is_instrumental(&rec));
    assert_eq!(event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>().length(), 0);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>().length(), 0);

    // Attached and empty: asserts instrumental.
    rm::set_languages(&mut rec, &cap, vector[]);
    assert!(rm::has_languages(&rec));
    assert!(is_instrumental(&rec));
    assert_eq!(rm::languages(&rec).length(), 0);
    let set_events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    let (_, languages) = rm::languages_set_event_fields(&set_events[0]);
    assert_eq!(codes(&languages), vector[]);
    assert_eq!(bcs::to_bytes(&set_events[0]).length(), 33);
    // Views are silent.
    assert_eq!(event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>().length(), 1);

    // Attached with a language: not instrumental.
    rm::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    assert!(!is_instrumental(&rec));
    let set_events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(set_events.length(), 2);
    let (_, languages) = rm::languages_set_event_fields(&set_events[1]);
    assert_eq!(codes(&languages), vector[b"en"]);

    // Back to nothing attached: the instrumental claim is withdrawn, not kept.
    rm::clear_languages(&mut rec, &cap);
    assert!(!is_instrumental(&rec));
    assert!(!rm::has_languages(&rec));
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>().length(), 1);

    destroy(rec);
    destroy(cap);
}

/// The bound is inclusive — exactly MAX_LANGUAGES must be accepted, and the
/// full-size set event is the largest this module emits.
#[test]
fun exactly_max_languages_is_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    let codes = vector[b"en", b"fr", b"es", b"de", b"it", b"ja", b"ko", b"pt", b"ru", b"zh"];
    let mut langs = vector[];
    codes.do!(|c| langs.push_back(lang(c)));
    assert_eq!(langs.length(), 10);

    rm::set_languages(&mut rec, &cap, langs);
    assert_eq!(rm::languages(&rec).length(), 10);
    let set_events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(set_events.length(), 1);
    let (_, languages) = rm::languages_set_event_fields(&set_events[0]);
    assert_eq!(codes(&languages), codes);
    assert_eq!(bcs::to_bytes(&set_events[0]).length(), 63);

    rm::clear_languages(&mut rec, &cap);
    let cleared_events = event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>();
    assert_eq!(cleared_events.length(), 1);
    assert_eq!(bcs::to_bytes(&cleared_events[0]).length(), 32);

    destroy(rec);
    destroy(cap);
}

#[test]
fun set_emits_the_codes() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    rm::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr")]);

    let events = event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, languages) = rm::languages_set_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id.to_address());
    assert_eq!(codes(&languages), vector[b"en", b"fr"]);
    assert_eq!(bcs::to_bytes(&events[0]).length(), 39);

    destroy(rec);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    rm::clear_languages(&mut rec, &cap);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>().length(), 0);

    rm::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    rm::clear_languages(&mut rec, &cap);

    let events = event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(rm::languages_cleared_event_fields(&events[0]), rec_id.to_address());

    destroy(rec);
    destroy(cap);
}

#[test]
fun languages_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (mut b, b_cap) = recording::new_for_testing<OTHER_REC>(
        object::id_from_address(@0xC0),
        ctx,
    );

    rm::set_languages(&mut a, &a_cap, vector[lang(b"en")]);
    assert!(rm::has_languages(&a));
    assert!(!rm::has_languages(&b));
    rm::set_languages(&mut b, &b_cap, vector[lang(b"fr")]);

    assert_eq!(rm::languages(&a)[0].code(), b"en".to_string());
    assert_eq!(rm::languages(&b)[0].code(), b"fr".to_string());
    assert_eq!(event::events_by_type<rm::RecordingLanguagesSetEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesSetEvent<OTHER_REC>>().length(), 1);

    rm::clear_languages(&mut a, &a_cap);
    assert!(!rm::has_languages(&a));
    assert!(rm::has_languages(&b));
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<REC>>().length(), 1);
    assert_eq!(event::events_by_type<rm::RecordingLanguagesClearedEvent<OTHER_REC>>().length(), 0);

    destroy(a);
    destroy(a_cap);
    destroy(b);
    destroy(b_cap);
}

#[test, expected_failure(abort_code = rm::ENoLanguages)]
fun languages_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec(ctx);
    let _ = rm::languages(&rec);
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rm::EDuplicateLanguage)]
fun duplicate_language_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    rm::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr"), lang(b"en")]);
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rm::ETooManyLanguages)]
fun more_than_max_languages_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    // Count validation is first: this is both over capacity and duplicated.
    let codes = vector[b"en", b"fr", b"es", b"de", b"it", b"ja", b"ko", b"pt", b"ru", b"zh", b"en"];
    let mut langs = vector[];
    codes.do!(|c| langs.push_back(lang(c)));
    assert_eq!(langs.length(), 11);

    rm::set_languages(&mut rec, &cap, langs);
    destroy(rec);
    destroy(cap);
}

/// A malformed code cannot reach this package at all — `LanguageCode` validates
/// on construction, which is why `validate` here checks only count and repeats.
#[test, expected_failure(abort_code = language_code::EInvalidLanguageCode)]
fun invalid_code_is_rejected_by_the_primitive() {
    let _ = lang(b"zzz");
}
