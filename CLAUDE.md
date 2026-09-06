# Repository Guidance

This repository contains independent Sui Move packages for platform-aware Miso.fm
protocol extensions. Each top-level package extends a Miso `Composition`,
`Recording`, or `Release` through cap-gated dynamic fields.

## Project Structure

- `recording_master_reference/` — transitional master-audio references.
- `release_dsp_link/` — release and track links for supported DSPs.

Each package owns its manifest, lockfile, publication record, source, tests, and
audit. Run Move commands from the package directory.

## Project Rules

- Use Move 2024 syntax.
- Keep packages independently buildable and versioned.
- Pin Git dependencies to exact 40-character commit SHAs.
- Preserve `Published.toml` as deployment provenance.
- Keep platform-specific behavior here; neutral metadata extensions belong in
  `misofm/protocol-extensions`.

## Sui Development Skills

Install community-maintained skills for Sui development:

```sh
npx skills https://github.com/MystenLabs/skills
```

## Official Resources

When unsure about Move patterns or Sui APIs, consult these sources. Do not guess or
extrapolate from other blockchains. Use the Sui documentation MCP server at
`https://sui.mcp.kapa.ai` when it is available.

- Move Book: https://move-book.com (use https://move-book.com/llms.txt)
- Sui Docs: https://docs.sui.io (use https://docs.sui.io/llms.txt)
- Sui Move examples: https://github.com/MystenLabs/sui/tree/main/examples/move
