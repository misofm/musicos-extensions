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
/// A recording's `RecordingShare` type uniquely identifies it, so
/// `RecordingAdminCap<RecordingShare>` is bound to its recording by type and
/// `recording::uid_mut` performs no runtime check. A wrong-cap test is therefore
/// not expressible — the call would fail to compile, not abort.
#[test_only]
module recording_language::recording_language_tests;

use language_code::language_code;
use miso::recording;
use recording_language::recording_language as rl;
use std::unit_test::{assert_eq, destroy};
use sui::event;

public struct REC {}
public struct COMP {}
public struct OTHER_REC {}

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

#[test]
fun set_read_replace_unset_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);

    assert!(!rl::has_languages(&rec));

    rl::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    assert!(rl::has_languages(&rec));
    assert_eq!(rl::languages(&rec).length(), 1);

    // Replacing swaps the whole record rather than merging.
    rl::set_languages(&mut rec, &cap, vector[lang(b"fr"), lang(b"es")]);
    assert_eq!(rl::languages(&rec).length(), 2);
    assert_eq!(rl::languages(&rec)[0].code(), b"fr".to_string());

    rl::unset_languages(&mut rec, &cap);
    assert!(!rl::has_languages(&rec));

    // Unset is idempotent.
    rl::unset_languages(&mut rec, &cap);
    assert!(!rl::has_languages(&rec));

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

    // Attached and empty: asserts instrumental.
    rl::set_instrumental(&mut rec, &cap);
    assert!(rl::has_languages(&rec));
    assert!(rl::is_instrumental(&rec));
    assert_eq!(rl::languages(&rec).length(), 0);

    // Attached with a language: not instrumental.
    rl::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    assert!(!rl::is_instrumental(&rec));

    // Back to nothing attached: the instrumental claim is withdrawn, not kept.
    rl::unset_languages(&mut rec, &cap);
    assert!(!rl::is_instrumental(&rec));
    assert!(!rl::has_languages(&rec));

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

    destroy(rec);
    destroy(cap);
}

#[test]
fun set_emits_the_codes() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    rl::set_languages(&mut rec, &cap, vector[lang(b"en"), lang(b"fr")]);

    let events = event::events_by_type<rl::LanguagesSetEvent>();
    assert_eq!(events.length(), 1);
    let (id, langs) = rl::set_event_fields(&events[0]);
    assert_eq!(id, rec_id);
    assert_eq!(langs.length(), 2);
    assert_eq!(langs[0].code(), b"en".to_string());

    destroy(rec);
    destroy(cap);
}

#[test]
fun unset_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rec, cap) = new_rec(ctx);
    let rec_id = object::id(&rec);

    rl::unset_languages(&mut rec, &cap);
    assert_eq!(event::events_by_type<rl::LanguagesUnsetEvent>().length(), 0);

    rl::set_languages(&mut rec, &cap, vector[lang(b"en")]);
    rl::unset_languages(&mut rec, &cap);

    let events = event::events_by_type<rl::LanguagesUnsetEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(rl::unset_event_recording_id(&events[0]), rec_id);

    destroy(rec);
    destroy(cap);
}

#[test]
fun languages_are_per_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = new_rec(ctx);
    let (b, b_cap) = recording::new_for_testing<OTHER_REC, COMP>(object::id_from_address(@0xC0), ctx);

    rl::set_languages(&mut a, &a_cap, vector[lang(b"en")]);

    assert!(rl::has_languages(&a));
    assert!(!rl::has_languages(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
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

    let codes = vector[b"en", b"fr", b"es", b"de", b"it", b"ja", b"ko", b"pt", b"ru", b"zh", b"ar"];
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
