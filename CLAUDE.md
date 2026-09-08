# Repository Guidance

This repository contains independent Sui Move packages that extend a `musicos`
`Composition`, `Recording`, or `Release` through cap-gated dynamic fields. It
consolidates two families: neutral, first-party protocol extensions with no
platform-specific assumptions, and extensions shaped by Miso.fm product,
storage, delivery, and distribution conventions.

## Project Structure

14 packages, each an independently versioned and published top-level
directory; see the package tables in `README.md` for the full list, each
package's target object, and its purpose.

Each package owns its manifest, lockfile, publication record, source, tests, and
audit. Run Move commands from the package directory.

## Project Rules

- Use Move 2024 syntax.
- Keep packages independently buildable and versioned.
- Pin Git dependencies to exact 40-character commit SHAs.
- Preserve `Published.toml` as deployment provenance.
- Neutral, platform-agnostic metadata extensions and Miso.fm platform-specific
  extensions both live in this repository; keep each package's own
  target-object contract free of the other family's assumptions.

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
