// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary, lifecycle and event-payload tests for the title attribute,
/// deliberately kept in single-transaction `tx_context::dummy()` style: every
/// case here holds its `Release`/`ReleaseAdminCap` pair locally, with no
/// shared object and no ownership handoff between transactions — the property
/// under test is the assertion or authorization check itself (byte bounds,
/// verbatim storage, event payloads, the cap-mismatch abort), not
/// transaction-boundary mechanics. The production shape — a published, shared
/// `Release` operated on by distinct senders via `take_shared`, including the
/// wrong-cap path against the shared object — is covered in
/// `title_e2e_tests`.
#[test_only]
module release_metadata::title_tests;

use musicos::release::Release;
use release_metadata::release_metadata as rm;
use release_metadata::test_utils::{mk_release, long_string};
use std::option::{Self, Option};
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::event;

// Mirrors `release::EUnauthorized`. A `Release` binds its cap at runtime —
// `uid_mut` calls `authorize`, which asserts `object::id(self) ==
// cap.release_id` — so a foreign cap is testable here.
const EUnauthorized: u64 = 0;

// === Event-only projection ===

/// The state an indexer can maintain from the event stream alone: absence is
/// `none`, while an attached title is its raw UTF-8 byte vector. The
/// projector never reads the dynamic field.
fun apply_set_event(e: &rm::ReleaseTitleSetEvent): Option<vector<u8>> {
    let (_, title) = rm::title_set_event_fields(e);
    option::some(*title.as_bytes())
}

/// A clear always removes the projector's currently attached value, because
/// absent clears emit nothing.
fun apply_cleared_event(projection: Option<vector<u8>>): Option<vector<u8>> {
    assert!(projection.is_some());
    option::none()
}

fun assert_projection_matches_storage(projection: &Option<vector<u8>>, rel: &Release) {
    assert_eq!(projection.is_some(), rm::has_title(rel));
    if (projection.is_some()) {
        assert_eq!(*projection.borrow(), *rm::title(rel).as_bytes());
    };
}

/// Decodes the raw BCS bytes in declaration order and asserts nothing
/// trails: the payload is exactly the release id and the title bytes.
fun assert_set_bcs(e: &rm::ReleaseTitleSetEvent, release_id: address, title: vector<u8>) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), release_id);
    assert_eq!(bytes.peel_vec_u8(), title);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_cleared_bcs(e: &rm::ReleaseTitleClearedEvent, release_id: address) {
    let mut bytes = bcs::new(bcs::to_bytes(e));
    assert_eq!(bytes.peel_address(), release_id);
    assert!(bytes.into_remainder_bytes().is_empty());
}

// === Lifecycle ===

#[test]
fun set_read_replace_clear_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    assert!(!rm::has_title(&rel));

    rm::set_title(&mut rel, &cap, b"Long Player".to_string());
    assert!(rm::has_title(&rel));
    assert_eq!(*rm::title(&rel), b"Long Player".to_string());
    let sets = event::events_by_type<rm::ReleaseTitleSetEvent>();
    assert_eq!(sets.length(), 1);
    assert_set_bcs(&sets[0], release_id, b"Long Player");
    let mut projection = apply_set_event(&sets[0]);
    assert_projection_matches_storage(&projection, &rel);

    // A release may correct its title.
    rm::set_title(&mut rel, &cap, b"Long Player (Remastered)".to_string());
    assert_eq!(*rm::title(&rel), b"Long Player (Remastered)".to_string());
    let sets = event::events_by_type<rm::ReleaseTitleSetEvent>();
    assert_eq!(sets.length(), 2);
    assert_set_bcs(&sets[1], release_id, b"Long Player (Remastered)");
    projection = apply_set_event(&sets[1]);
    assert_projection_matches_storage(&projection, &rel);

    // Equal replacement is a no-op: no write, no event; the projected state
    // is unchanged.
    rm::set_title(&mut rel, &cap, b"Long Player (Remastered)".to_string());
    let sets = event::events_by_type<rm::ReleaseTitleSetEvent>();
    assert_eq!(sets.length(), 2);
    assert_projection_matches_storage(&projection, &rel);

    rm::clear_title(&mut rel, &cap);
    assert!(!rm::has_title(&rel));
    let clears = event::events_by_type<rm::ReleaseTitleClearedEvent>();
    assert_eq!(clears.length(), 1);
    assert_cleared_bcs(&clears[0], release_id);
    projection = apply_cleared_event(projection);
    assert_projection_matches_storage(&projection, &rel);

    // Clear is idempotent and silent when absent.
    rm::clear_title(&mut rel, &cap);
    assert!(!rm::has_title(&rel));
    assert_eq!(event::events_by_type<rm::ReleaseTitleClearedEvent>().length(), 1);
    assert_projection_matches_storage(&projection, &rel);

    // Removing the field permits a fresh set.
    rm::set_title(&mut rel, &cap, b"Re-titled".to_string());
    let sets = event::events_by_type<rm::ReleaseTitleSetEvent>();
    assert_eq!(sets.length(), 3);
    assert_set_bcs(&sets[2], release_id, b"Re-titled");
    projection = apply_set_event(&sets[2]);
    assert_projection_matches_storage(&projection, &rel);

    destroy(rel);
    destroy(cap);
}

/// Stored exactly as given: case, spacing, line breaks and multi-byte UTF-8
/// survive the round trip, and the event carries the same bytes.
#[test]
fun title_is_preserved_verbatim() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    let text = b"  MiXeD\n\n spacing  ".to_string();
    rm::set_title(&mut rel, &cap, text);
    assert_eq!(*rm::title(&rel), text);
    let (_, event_title) = rm::title_set_event_fields(&event::events_by_type<rm::ReleaseTitleSetEvent>()[0]);
    assert_eq!(event_title, text);

    // "été ✿" — 5 characters, 9 bytes. Accepted, and read back intact.
    let multibyte = b"\xc3\xa9t\xc3\xa9 \xe2\x9c\xbf".to_string();
    assert_eq!(multibyte.as_bytes().length(), 9);
    rm::set_title(&mut rel, &cap, multibyte);
    assert_eq!(*rm::title(&rel), multibyte);

    // Whitespace and NUL inside the string are ordinary bytes to this module.
    let whitespace_nul = std::string::utf8(vector[69, 80, 32, 9, 0, 32, 101, 112]);
    rm::set_title(&mut rel, &cap, whitespace_nul);
    assert_eq!(rm::title(&rel).as_bytes().length(), 8);

    destroy(rel);
    destroy(cap);
}

#[test]
fun titles_are_per_release() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rm::set_title(&mut a, &a_cap, b"The first one.".to_string());

    assert!(rm::has_title(&a));
    assert!(!rm::has_title(&b));

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

// === Bounds ===

/// 300 bytes exactly — the inclusive bound — is accepted, stored, and
/// emitted in full. The maximum set event is 32 (release id) + 2 (ULEB128
/// length of 300) + 300 = 334 bytes; a cleared event is always 32.
#[test]
fun exactly_max_length_is_accepted_with_exact_bcs_sizes() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    let max = long_string(300);
    let max_bytes = *max.as_bytes();
    rm::set_title(&mut rel, &cap, max);
    assert_eq!(rm::title(&rel).as_bytes().length(), 300);

    // A different 300-byte value exercises replacement at the bound.
    let mut different = b"B".to_string();
    different.append(long_string(299));
    assert_eq!(different.as_bytes().length(), 300);
    rm::set_title(&mut rel, &cap, different);
    assert_eq!(*rm::title(&rel), different);

    rm::clear_title(&mut rel, &cap);

    let sets = event::events_by_type<rm::ReleaseTitleSetEvent>();
    assert_eq!(sets.length(), 2);
    assert_set_bcs(&sets[0], release_id, max_bytes);
    assert_set_bcs(&sets[1], release_id, *different.as_bytes());
    assert_eq!(bcs::to_bytes(&sets[0]).length(), 334);
    assert_eq!(bcs::to_bytes(&sets[1]).length(), 334);
    let clears = event::events_by_type<rm::ReleaseTitleClearedEvent>();
    assert_eq!(clears.length(), 1);
    assert_cleared_bcs(&clears[0], release_id);
    assert_eq!(bcs::to_bytes(&clears[0]).length(), 32);

    destroy(rel);
    destroy(cap);
}

// === Events ===

/// Setting the title already attached is a no-op: nothing is written and
/// nothing is emitted. The record stays attached with its value intact.
#[test]
fun equal_set_is_a_silent_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    rm::set_title(&mut rel, &cap, b"Long Player".to_string());
    assert_eq!(event::num_events(), 1);

    rm::set_title(&mut rel, &cap, b"Long Player".to_string());
    assert_eq!(event::num_events(), 1);
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(*rm::title(&rel), b"Long Player".to_string());

    // Cleared and set again to the same value: absent, so not a no-op.
    rm::clear_title(&mut rel, &cap);
    assert!(!rm::has_metadata_for_testing(&rel));
    rm::set_title(&mut rel, &cap, b"Long Player".to_string());
    assert!(rm::has_metadata_for_testing(&rel));
    assert_eq!(event::events_by_type<rm::ReleaseTitleSetEvent>().length(), 2);

    destroy(rel);
    destroy(cap);
}

#[test]
fun set_emits_the_title() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    rm::set_title(&mut rel, &cap, b"Long Player".to_string());

    let events = event::events_by_type<rm::ReleaseTitleSetEvent>();
    assert_eq!(events.length(), 1);
    let (event_release_id, event_title) = rm::title_set_event_fields(&events[0]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_title, b"Long Player".to_string());
    assert_set_bcs(&events[0], release_id, b"Long Player");

    destroy(rel);
    destroy(cap);
}

#[test]
fun clear_emits_only_when_something_was_removed() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel).to_address();

    rm::clear_title(&mut rel, &cap);
    assert_eq!(event::events_by_type<rm::ReleaseTitleClearedEvent>().length(), 0);

    rm::set_title(&mut rel, &cap, b"Out of print.".to_string());
    rm::clear_title(&mut rel, &cap);

    let events = event::events_by_type<rm::ReleaseTitleClearedEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(rm::title_cleared_event_fields(&events[0]), release_id);
    assert_cleared_bcs(&events[0], release_id);

    destroy(rel);
    destroy(cap);
}

/// Views do not publish events, and an authorized clear of an absent field is
/// a silent no-op. A later clear emits exactly once, after the actual remove.
#[test]
fun views_and_absent_clear_are_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);

    let events_before = event::num_events();
    assert!(!rm::has_title(&rel));
    assert_eq!(event::num_events(), events_before);
    rm::clear_title(&mut rel, &cap);
    assert_eq!(event::num_events(), events_before);

    rm::set_title(&mut rel, &cap, b"No event from reading.".to_string());
    let events_after_set = event::num_events();
    assert!(rm::has_title(&rel));
    assert_eq!(*rm::title(&rel), b"No event from reading.".to_string());
    assert_eq!(event::num_events(), events_after_set);

    rm::clear_title(&mut rel, &cap);
    let events_after_clear = event::num_events();
    rm::clear_title(&mut rel, &cap);
    assert_eq!(event::num_events(), events_after_clear);
    assert_eq!(events_after_clear, events_after_set + 1);

    destroy(rel);
    destroy(cap);
}

/// Every event carries the identity of its release, so an indexer can replay
/// two independent release streams without object reads.
#[test]
fun two_releases_have_independent_event_identity() {
    let ctx = &mut tx_context::dummy();
    let (mut first, first_cap) = mk_release(ctx);
    let (mut second, second_cap) = mk_release(ctx);
    let first_id = object::id(&first).to_address();
    let second_id = object::id(&second).to_address();

    rm::set_title(&mut first, &first_cap, b"First release.".to_string());
    rm::set_title(&mut second, &second_cap, b"Second release.".to_string());

    let sets = event::events_by_type<rm::ReleaseTitleSetEvent>();
    assert_eq!(sets.length(), 2);
    let (id, title) = rm::title_set_event_fields(&sets[0]);
    assert_eq!(id, first_id);
    assert_eq!(title, b"First release.".to_string());
    let (id, title) = rm::title_set_event_fields(&sets[1]);
    assert_eq!(id, second_id);
    assert_eq!(title, b"Second release.".to_string());

    destroy(first); destroy(first_cap); destroy(second); destroy(second_cap);
}

// === Aborts ===

#[test, expected_failure(abort_code = rm::ENoTitle)]
fun title_aborts_when_unset() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = mk_release(ctx);
    let _ = rm::title(&rel);
    destroy(rel);
    destroy(cap);
}

/// Naming nothing is done by not attaching, not by attaching emptiness.
#[test, expected_failure(abort_code = rm::EEmptyTitle)]
fun empty_title_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    rm::set_title(&mut rel, &cap, b"".to_string());
    destroy(rel);
    destroy(cap);
}

#[test, expected_failure(abort_code = rm::ETitleTooLong)]
fun over_max_length_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, cap) = mk_release(ctx);
    // 301 bytes — one past the bound.
    rm::set_title(&mut rel, &cap, long_string(301));
    destroy(rel);
    destroy(cap);
}

/// Both validation guards precede the release's cap authorization. A foreign
/// cap therefore cannot change which validation error a caller observes.
#[test, expected_failure(abort_code = rm::EEmptyTitle)]
fun empty_title_precedes_foreign_cap_authorization() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rm::set_title(&mut rel, &other_cap, b"".to_string());
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(abort_code = rm::ETitleTooLong)]
fun over_max_title_precedes_foreign_cap_authorization() {
    let ctx = &mut tx_context::dummy();
    let (mut rel, rel_cap) = mk_release(ctx);
    let (other, other_cap) = mk_release(ctx);
    rm::set_title(&mut rel, &other_cap, long_string(301));
    destroy(rel);
    destroy(rel_cap);
    destroy(other);
    destroy(other_cap);
}

/// A `Release` binds its cap at runtime, so this gate is testable — and must
/// hold.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun another_releases_cap_is_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rm::set_title(&mut a, &b_cap, b"Not yours.".to_string());

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}

/// The cap is checked before the stored value is compared, so a foreign cap
/// is rejected even when the value it supplies is the one already attached.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun another_releases_cap_is_rejected_on_equal_set() {
    let ctx = &mut tx_context::dummy();
    let (mut a, a_cap) = mk_release(ctx);
    let (b, b_cap) = mk_release(ctx);

    rm::set_title(&mut a, &a_cap, b"Long Player".to_string());
    rm::set_title(&mut a, &b_cap, b"Long Player".to_string());

    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap);
}
