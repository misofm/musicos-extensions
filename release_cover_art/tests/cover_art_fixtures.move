// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_cover_art::cover_art_fixtures;

use cover_art::cover_art::{Self, CoverArt};
use ori::{confidentiality, data};

/// Explicit blob IDs keep album, override, and replacement covers distinguishable.
public fun plain(blob_id: u256): CoverArt {
    cover_art::new(
        data::new_blob(blob_id, confidentiality::new_unencrypted()),
        option::none(),
    )
}
