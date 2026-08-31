# Security review — `recording_engine_session`

**Date:** 2026-09-01

## Security claim

The extension stores exactly one canonical, directly derivable engine-session
reference under a Recording. Only the matching `RecordingAdminCap` can attach,
replace, or remove it. The root must be a standalone, unencrypted `WalrusData`
blob, so clients can discover the public delivery manifest without an indexer or
an access-control circular dependency.

Initial attachment and replacement are separate functions. This prevents a
generic uploader from silently overwriting purchaser-visible audio unless it
deliberately selects the replacement operation. Removal is idempotent.

## Adversarial coverage

Move tests cover first attachment, explicit replacement, idempotent removal,
missing and occupied slots, Recording isolation, public reads after sharing,
quilt-patch rejection, and encrypted-root rejection. The concrete cap type and
`Recording::uid_mut` enforce the Recording/cap pairing in the protocol package.

## Residual assumptions

- A Recording administrator can deliberately replace or remove the pointer.
- Walrus availability and retention remain operator obligations; replacement
  does not erase already published blobs.
- The plaintext document is public metadata. Stem confidentiality belongs to
  its Seal-wrapped AES key and authenticated ciphertext, not to this extension.
- Package upgrades can change reviewed behavior and require a new deployment
  review and client allowlist entry.
