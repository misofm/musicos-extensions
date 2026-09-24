// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Fixtures shared by every test module in this package: release
/// construction in both production shapes (unshared `Initialized`, and
/// published-and-shared), vocabulary creation for the genre tests, and a
/// long-string builder for the byte-bound tests.
#[test_only]
module release_metadata::test_utils;

use genre::genre as g;
use genre::genre::GenreRegistry;
use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use std::string::String;
use sui::clock;
use sui::test_scenario::{Self as ts, Scenario};

/// A one-track, unshared `Initialized` release. Nothing in this package reads
/// the tracklist — every attribute here is a claim about the release as a
/// whole — but the core constructor still needs tracks.
public fun mk_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let rec_id = test_helpers::fake_id(ctx);
    let target_id = test_helpers::fake_id(ctx);
    let tracks = vector[track::new_for_testing(rec_id, target_id, 10000u16)];
    release::new_for_testing(tracks, ctx)
}

/// Builds a one-track release and publishes it in the same transaction —
/// create-and-publish is atomic in production (`musicos::release`'s module
/// doc): a fresh `Initialized` release cannot outlive its creating
/// transaction, so every release that exists on chain is already `Published`
/// and shared. Returns the admin cap and the release's id, since callers need
/// the id to `take_shared_by_id` it back later.
public fun publish_and_share_release(scenario: &mut Scenario): (ReleaseAdminCap, ID) {
    let ctx = scenario.ctx();
    let (rel, cap) = mk_release(ctx);
    let release_id = object::id(&rel);
    let the_clock = clock::create_for_testing(ctx);
    rel.publish(&cap, &the_clock); // verifies track assignment, shares
    the_clock.destroy_for_testing();
    (cap, release_id)
}

/// `n` bytes of ASCII `A`.
public fun long_string(n: u64): String {
    let mut bytes = vector[];
    n.do!(|_| bytes.push_back(0x41));
    bytes.to_string()
}

/// Creates a genre in the permissionless registry and returns its derived id.
public fun create_genre(scenario: &Scenario, name: vector<u8>): ID {
    let mut registry = scenario.take_shared<GenreRegistry>();
    let id = g::derive_address(&registry, name.to_string()).to_id();
    g::new(&mut registry, name.to_string());
    ts::return_shared(registry);
    id
}
