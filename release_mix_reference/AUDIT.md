# Security review — `release_mix_reference`

Reviewed 2026-09-02 for immutable publication. Verdict: no exploitable
findings in the reviewed source.

## Dependency provenance

`Move.toml` pins `miso` at
`6de5f9881ee62c81c57ce16832efc24dc33ae429`, `ori` at
`1ca4e5016848bd946072db19415086a309b9930f`, and `per_track` at
`547befbb33be14ac7400fabc01962a96bd54fb1e`. Both network lock graphs resolve
`bps` at `4ca1972a67d35c972ca567de7b08315e3778e52b` without duplicate aliases.

## Threat model and findings

The protected asset is the public pointer selected for each immutable Release
track. Both attach and replace first authenticate the ID-bound
`ReleaseAdminCap`; out-of-range indexes abort. The lazily created
`PerTrack<Option<WalrusData>>` has exactly the frozen track count. Attach only
fills an empty slot and replacement requires an occupied slot, preventing
accidental upsert semantics. The outer pointer must be a standalone plaintext
Walrus blob: quilt patches and references carrying an Ori sealed DEK abort.

The package authenticates who selected the descriptor and its outer reference
shape. It cannot prove availability, authenticity, decoding, encryption, or
authorization of assets named inside the off-chain descriptor. Consumers must
treat its contents as administrator-authored public metadata. The module moves
no funds and contains no Vault, Action, or Plugin logic.

## Evidence

With `sui 1.78.1-722ac4fcf484`, strict Testnet and Mainnet lint,
warnings-as-errors builds, and tests pass: 15/15 on each network. The production
module reports 100.00% coverage. Tests cover wrong-cap attempts, invalid outer
references, occupied/missing/empty slots, every out-of-range view and mutation,
absence/presence, exact event payloads, and a real published/shared Release
across attach, permissionless read, replacement, and later read transactions.
