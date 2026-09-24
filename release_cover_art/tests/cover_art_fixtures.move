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

/// A still plus an animated blob, both plaintext.
public fun animated(still_blob_id: u256, animated_blob_id: u256): CoverArt {
    cover_art::new(
        data::new_blob(still_blob_id, confidentiality::new_unencrypted()),
        option::some(data::new_blob(animated_blob_id, confidentiality::new_unencrypted())),
    )
}

/// An encrypted still whose sealed DEK is `sealed_dek_length` bytes long.
public fun encrypted(blob_id: u256, sealed_dek_length: u64): CoverArt {
    let sealed_dek = vector::tabulate!(sealed_dek_length, |i| (i % 256) as u8);
    cover_art::new(
        data::new_blob(blob_id, confidentiality::new_encrypted(sealed_dek)),
        option::none(),
    )
}
