// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Attach/read/replace/instrumental/unset mechanics and the validation aborts,
/// against a single bare `Recording` with no ownership handoff — nothing here
/// crosses a transaction boundary or changes hands between actors, so plain
/// `tx_context::dummy()` is exactly as faithful as a scenario and adds no
/// signal. The production shape — a published, shared `Recording` operated on
/// by distinct senders across real transactions — is covered separately in
/// `recording_language_e2e_tests`.
///
/// A mismatched `RecordingShare` fails compilation. A different cap value with
/// the same `RecordingShare` is accepted because `recording::uid_mut` ignores
/// the cap value.
#[test_only]
module recording_language::recording_language_tests;

use language_code::language_code;
use musicos::recording;
use recording_language::recording_language as rl;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

public struct REC {}
public struct COMP {}
public struct OTHER_REC {}
public struct OTHER_COMP {}

// This package never touches the composition side of a recording, so a bare
// id stands in for a real `Composition` — `recording::new_for_testing` only
// needs a composition `ID`, not a live `Composition` object.
fun new_rec(ctx: &mut TxContext): (
    recording::Recording<REC, COMP>,
    recording::RecordingAdminCap<REC>,
) {
    recording::new_for_testing<REC, COMP>(object::id_from_address(@0xC0), ctx)
}

fun lang(code: vector<u8>): language_code::LanguageCode {
    language_code::new(code.to_string())
}

fun view_language_bytes(
    rec: &recording::Recording<REC, COMP>,
): vector<vector<u8>> {
    let values = rl::languages(rec);
    let mut result = vector[];
    values.do_ref!(|value| {
        let code = language_code::code(value);
        result.push_back(*code.as_bytes());
    });
    result
}

fun assert_projection_matches_view(
    rec: &recording::Recording<REC, COMP>,
    projected_exists: bool,
    projected_languages: &vector<vector<u8>>,
    projected_instrumental: bool,
) {
    assert_eq!(rl::has_languages(rec), projected_exists);
    assert_eq!(rl::is_instrumental(rec), projected_instrumental);
    if (projected_exists) {
        assert_eq!(view_language_bytes(rec), *projected_languages);
    } else {
        assert!(projected_languages.is_empty());
    }
}

/// Decode the serialized event in declaration order and replay only its
/// transition into a tiny projection. The final assertions compare that
/// event-only state with the permissionless storage views.
fun project_set_event(
    projected_exists: &mut bool,
    projected_languages: &mut vector<vector<u8>>,
    projected_instrumental: &mut bool,
    event: &rl::RecordingLanguagesSetEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    let had_languages = bytes.peel_bool();
    let previous_languages = bytes.peel_vec_vec_u8();
    let languages = bytes.peel_vec_vec_u8();
    let language_count_before = bytes.peel_u64();
    let language_count_after = bytes.peel_u64();
    let was_instrumental = bytes.peel_bool();
    let is_instrumental = bytes.peel_bool();
    let max_languages = bytes.peel_u64();
    assert_eq!(had_languages, *projected_exists);
    if (had_languages) {
        assert_eq!(previous_languages, *projected_languages);
    } else {
        assert!(previous_languages.is_empty());
    };
    assert_eq!(previous_languages.length(), language_count_before);
    assert_eq!(languages.length(), language_count_after);
    assert_eq!(was_instrumental, *projected_instrumental);
    if (had_languages) {
        assert_eq!(was_instrumental, previous_languages.is_empty());
    } else {
        assert!(!was_instrumental);
    };
    assert_eq!(is_instrumental, languages.is_empty());
    assert_eq!(max_languages, 10);
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_exists = true;
    *projected_languages = languages;
    *projected_instrumental = is_instrumental;
}

fun project_cleared_event(
    projected_exists: &mut bool,
    projected_languages: &mut vector<vector<u8>>,
    projected_instrumental: &mut bool,
    event: &rl::RecordingLanguagesClearedEvent<REC, COMP>,
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    let removed_languages = bytes.peel_vec_vec_u8();
    let language_count_before = bytes.peel_u64();
    let was_instrumental = bytes.peel_bool();
    assert!(*projected_exists);
    assert_eq!(removed_languages, *projected_languages);
    assert_eq!(removed_languages.length(), language_count_before);
    assert_eq!(was_instrumental, *projected_instrumental);
    assert_eq!(was_instrumental, removed_languages.is_empty());
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_exists = false;
    *projected_languages = vector[];
    *projected_instrumental = false;
}

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let recording_id = object::id(&rec).to_address();
    let composition_id = @0xC0;
    let admin_cap_id = object::id(&cap).to_address();
    let mut projected_exists = false;
    let mut projected_languages = vector[];
    let mut projected_instrumental = false;

    assert_projection_matches_view(
        &rec, projected_exists, &projected_languages, projected_instrumental,
    );

    // Sung languages are attached first.
    rl::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr")]);
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 1);
    project_set_event(
        &mut projected_exists,
        &mut projected_languages,
        &mut projected_instrumental,
        &set_events[0],
        recording_id,
        composition_id,
        admin_cap_id,
    );
    assert_projection_matches_view(
        &rec, projected_exists, &projected_languages, projected_instrumental,
    );

    // Equal replacement still emits and projects the same state.
    rl::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr")]);
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 2);
    project_set_event(
        &mut projected_exists,
        &mut projected_languages,
        &mut projected_instrumental,
        &set_events[1],
        recording_id,
        composition_id,
        admin_cap_id,
    );
    assert_projection_matches_view(
        &rec, projected_exists, &projected_languages, projected_instrumental,
    );

    // Reordering is a replacement and preserves caller order.
    rl::set_languages(&mut rec, &cap, vector[lang(b"fr"), lang(b"en")]);
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 3);
    project_set_event(
        &mut projected_exists,
        &mut projected_languages,
        &mut projected_instrumental,
        &set_events[2],
        recording_id,
        composition_id,
        admin_cap_id,
    );
    assert_projection_matches_view(
        &rec, projected_exists, &projected_languages, projected_instrumental,
    );

    // Instrumental is an attached empty value, not absence.
    rl::set_instrumental(&mut rec, &cap);
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 4);
    project_set_event(
        &mut projected_exists,
        &mut projected_languages,
        &mut projected_instrumental,
        &set_events[3],
        recording_id,
        composition_id,
        admin_cap_id,
    );
    assert_projection_matches_view(
        &rec, projected_exists, &projected_languages, projected_instrumental,
    );

    // Equal empty replacement also emits.
    rl::set_instrumental(&mut rec, &cap);
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 5);
    project_set_event(
        &mut projected_exists,
        &mut projected_languages,
        &mut projected_instrumental,
        &set_events[4],
        recording_id,
        composition_id,
        admin_cap_id,
    );
    assert_projection_matches_view(
        &rec, projected_exists, &projected_languages, projected_instrumental,
    );

    // Present-empty clear emits and projects absence.
    rl::unset_languages(&mut rec, &cap);
    let cleared_events =
        event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, COMP>>();
    assert_eq!(cleared_events.length(), 1);
    project_cleared_event(
        &mut projected_exists,
        &mut projected_languages,
        &mut projected_instrumental,
        &cleared_events[0],
        recording_id,
        composition_id,
        admin_cap_id,
    );
    assert_projection_matches_view(
        &rec, projected_exists, &projected_languages, projected_instrumental,
    );

    // Absent clear is silent and leaves the projection unchanged.
    rl::unset_languages(&mut rec, &cap);
    assert_eq!(
        event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, COMP>>().length(),
        1,
    );
    assert_projection_matches_view(
        &rec, projected_exists, &projected_languages, projected_instrumental,
    );

    // A later set starts a fresh attached state after the clear.
    rl::set_languages(&mut rec, &cap, vector[lang(b"ja")]);
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 6);
    project_set_event(
        &mut projected_exists,
        &mut projected_languages,
        &mut projected_instrumental,
        &set_events[5],
        recording_id,
        composition_id,
        admin_cap_id,
    );
    assert_projection_matches_view(
        &rec, projected_exists, &projected_languages, projected_instrumental,
    );

    destroy(rec);
    destroy(cap);
}

/// Order is the caller's and must survive the round trip — the first entry is
/// conventionally the predominant language.
#[test]
fun order_is_preserved() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    rl::set_languages(&mut rec, &cap, vector[lang(b"ja"), lang(b"en"), lang(b"ko")]);
    let got = rl::languages(&rec);
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
    assert!(!rl::has_languages(&rec));
    assert!(!rl::is_instrumental(&rec));
    assert_eq!(event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>().length(), 0);
    assert_eq!(event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, COMP>>().length(), 0);

    // Attached and empty: asserts instrumental.
    rl::set_instrumental(&mut rec, &cap);
    assert!(rl::has_languages(&rec));
    assert!(rl::is_instrumental(&rec));
    assert_eq!(rl::languages(&rec).length(), 0);
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 1);
    let (_, _, _, had_languages, previous_languages, languages, language_count_before,
        language_count_after, was_instrumental, is_instrumental, max_languages) =
        rl::set_event_fields(&set_events[0]);
    assert!(!had_languages);
    assert_eq!(previous_languages, vector[]);
    assert_eq!(languages, vector[]);
    assert_eq!(language_count_before, 0);
    assert_eq!(language_count_after, 0);
    assert!(!was_instrumental);
    assert!(is_instrumental);
    assert_eq!(max_languages, 10);
    assert_eq!(sui::bcs::to_bytes(&set_events[0]).length(), 125);
    // Views are silent.
    assert_eq!(event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>().length(), 1);

    // Attached with a language: not instrumental.
    rl::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    assert!(!rl::is_instrumental(&rec));
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 2);
    let (_, _, _, had_languages, previous_languages, languages, language_count_before,
        language_count_after, was_instrumental, is_instrumental, _) =
        rl::set_event_fields(&set_events[1]);
    assert!(had_languages);
    assert_eq!(previous_languages, vector[]);
    assert_eq!(languages, vector[b"en"]);
    assert_eq!(language_count_before, 0);
    assert_eq!(language_count_after, 1);
    assert!(was_instrumental);
    assert!(!is_instrumental);

    // Back to nothing attached: the instrumental claim is withdrawn, not kept.
    rl::unset_languages(&mut rec, &cap);
    assert!(!rl::is_instrumental(&rec));
    assert!(!rl::has_languages(&rec));
    let unset_events = event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, COMP>>();
    assert_eq!(unset_events.length(), 1);
    let (_, _, _, removed_languages, language_count_before, was_instrumental) =
        rl::unset_event_fields(&unset_events[0]);
    assert_eq!(removed_languages, vector[b"en"]);
    assert_eq!(language_count_before, 1);
    assert!(!was_instrumental);

    destroy(rec);
    destroy(cap);
}

#[test]
fun set_instrumental_matches_an_explicit_empty_vector() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (mut b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(object::id_from_address(@0xC0), ctx);

    rl::set_instrumental(&mut a, &a_cap);
    rl::set_languages(&mut b, &b_cap, vector[]);

    assert_eq!(rl::is_instrumental(&a), rl::is_instrumental(&b));
    assert_eq!(rl::languages(&a).length(), rl::languages(&b).length());

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// The bound is inclusive — exactly MAX_LANGUAGES must be accepted.
#[test]
fun exactly_max_languages_is_accepted() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    let codes = vector[b"en", b"fr", b"es", b"de", b"it", b"ja", b"ko", b"pt", b"ru", b"zh"];
    let mut langs = vector[];
    codes.do!(|c| langs.push_back(lang(c)));
    assert_eq!(langs.length(), 10);

    rl::set_languages(&mut rec, &cap, langs);
    assert_eq!(rl::languages(&rec).length(), 10);
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 1);
    let (_, _, _, had_languages, previous_languages, languages, language_count_before,
        language_count_after, was_instrumental, is_instrumental, max_languages) =
        rl::set_event_fields(&set_events[0]);
    assert!(!had_languages);
    assert_eq!(previous_languages, vector[]);
    assert_eq!(languages, vector[b"en", b"fr", b"es", b"de", b"it", b"ja", b"ko", b"pt", b"ru", b"zh"]);
    assert_eq!(language_count_before, 0);
    assert_eq!(language_count_after, 10);
    assert!(!was_instrumental);
    assert!(!is_instrumental);
    assert_eq!(max_languages, 10);
    assert_eq!(sui::bcs::to_bytes(&set_events[0]).length(), 155);

    let mut replacement = vector[];
    codes.do!(|c| replacement.push_back(lang(c)));
    rl::set_languages(&mut rec, &cap, replacement);
    let set_events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(set_events.length(), 2);
    let (_, _, _, had_languages, previous_languages, languages, language_count_before,
        language_count_after, was_instrumental, is_instrumental, _) =
        rl::set_event_fields(&set_events[1]);
    assert!(had_languages);
    assert_eq!(previous_languages, vector[b"en", b"fr", b"es", b"de", b"it", b"ja", b"ko", b"pt", b"ru", b"zh"]);
    assert_eq!(languages, vector[b"en", b"fr", b"es", b"de", b"it", b"ja", b"ko", b"pt", b"ru", b"zh"]);
    assert_eq!(language_count_before, 10);
    assert_eq!(language_count_after, 10);
    assert!(!was_instrumental);
    assert!(!is_instrumental);
    assert_eq!(sui::bcs::to_bytes(&set_events[1]).length(), 185);

    rl::unset_languages(&mut rec, &cap);
    let unset_events = event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, COMP>>();
    assert_eq!(unset_events.length(), 1);
    let (_, _, _, removed_languages, language_count_before, was_instrumental) =
        rl::unset_event_fields(&unset_events[0]);
    assert_eq!(removed_languages, vector[b"en", b"fr", b"es", b"de", b"it", b"ja", b"ko", b"pt", b"ru", b"zh"]);
    assert_eq!(language_count_before, 10);
    assert!(!was_instrumental);
    assert_eq!(sui::bcs::to_bytes(&unset_events[0]).length(), 136);

    destroy(rec);
    destroy(cap);
}

#[test]
fun set_emits_the_codes() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    rl::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr")]);

    let events = event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, event_comp_id, event_cap_id, had_languages, previous_languages,
        languages, language_count_before, language_count_after, was_instrumental,
        is_instrumental, max_languages) = rl::set_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id.to_address());
    assert_eq!(event_comp_id, @0xC0);
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert!(!had_languages);
    assert_eq!(previous_languages, vector[]);
    assert_eq!(languages, vector[b"en", b"fr"]);
    assert_eq!(language_count_before, 0);
    assert_eq!(language_count_after, 2);
    assert!(!was_instrumental);
    assert!(!is_instrumental);
    assert_eq!(max_languages, 10);
    assert_eq!(sui::bcs::to_bytes(&events[0]).length(), 131);

    destroy(rec);
    destroy(cap);
}

#[test]
fun unset_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    rl::unset_languages(&mut rec, &cap);
    assert_eq!(
        event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, COMP>>().length(),
        0,
    );

    rl::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    rl::unset_languages(&mut rec, &cap);

    let events = event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, COMP>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, event_comp_id, event_cap_id, removed_languages,
        language_count_before, was_instrumental) = rl::unset_event_fields(&events[0]);
    assert_eq!(event_rec_id, rec_id.to_address());
    assert_eq!(event_comp_id, @0xC0);
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert_eq!(removed_languages, vector[b"en"]);
    assert_eq!(language_count_before, 1);
    assert!(!was_instrumental);

    destroy(rec);
    destroy(cap);
}

#[test]
fun languages_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (mut b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(
        object::id_from_address(@0xC0),
        ctx,
    );
    let (mut c, c_cap) = recording::new_for_testing<REC, OTHER_COMP>(
        object::id_from_address(@0xC1),
        ctx,
    );

    rl::set_languages(&mut a, &a_cap, vector[lang(b"en")]);
    rl::set_languages(&mut b, &b_cap, vector[lang(b"fr")]);
    rl::set_languages(&mut c, &c_cap, vector[lang(b"de")]);

    assert!(rl::has_languages(&a));
    assert!(rl::has_languages(&b));
    assert!(rl::has_languages(&c));
    assert_eq!(event::events_by_type<rl::RecordingLanguagesSetEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rl::RecordingLanguagesSetEvent<OTHER_REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rl::RecordingLanguagesSetEvent<REC, OTHER_COMP>>().length(), 1);
    assert_eq!(
        event::events_by_type<rl::RecordingLanguagesSetEvent<OTHER_REC, OTHER_COMP>>().length(),
        0,
    );

    rl::unset_languages(&mut a, &a_cap);
    rl::unset_languages(&mut b, &b_cap);
    rl::unset_languages(&mut c, &c_cap);
    assert_eq!(event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rl::RecordingLanguagesClearedEvent<OTHER_REC, COMP>>().length(), 1);
    assert_eq!(event::events_by_type<rl::RecordingLanguagesClearedEvent<REC, OTHER_COMP>>().length(), 1);
    assert_eq!(
        event::events_by_type<rl::RecordingLanguagesClearedEvent<OTHER_REC, OTHER_COMP>>().length(),
        0,
    );

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap); destroy(c); destroy(c_cap);
}

#[test, expected_failure(abort_code = rl::ENoLanguages)]
fun languages_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rec, cap) = new_rec(ctx);
    let _ = rl::languages(&rec);
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rl::EDuplicateLanguage)]
fun duplicate_language_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    rl::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr"), lang(b"en")]);
    destroy(rec);
    destroy(cap);
}

#[test, expected_failure(abort_code = rl::ETooManyLanguages)]
fun more_than_max_languages_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    // Count validation is first: this is both over capacity and duplicated.
    let codes = vector[b"en", b"fr", b"es", b"de", b"it", b"ja", b"ko", b"pt", b"ru", b"zh", b"en"];
    let mut langs = vector[];
    codes.do!(|c| langs.push_back(lang(c)));
    assert_eq!(langs.length(), 11);

    rl::set_languages(&mut rec, &cap, langs);
    destroy(rec);
    destroy(cap);
}

/// A malformed code cannot reach this package at all — `LanguageCode` validates
/// on construction, which is why `validate` here checks only count and repeats.
#[test, expected_failure(abort_code = language_code::EInvalidLanguageCode)]
fun invalid_code_is_rejected_by_the_primitive() {
    let _ = lang(b"zzz");
}
