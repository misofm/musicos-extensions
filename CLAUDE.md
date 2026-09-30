# Repository Guidance

This repository contains independent Sui Move packages that extend a `musicos`
`Composition`, `Recording`, or `Release`: neutral metadata extensions stored as
cap-gated dynamic fields, and the `recording_license` scheme, which derives its
policy and license objects from a composition and a recording.

## Project Structure

15 packages, each an independently versioned and published top-level
directory; see the package tables in `README.md` for the full list, each
package's target object, and its purpose.

Each package owns its manifest, lockfile, publication record, source, tests, and
audit. Run Move commands from the package directory.

## Project Rules

- Use Move 2024 syntax.
- Import modules, functions, and types with `use`; never write fully
  qualified `address::module::member` paths inline.
- In tests, reference the real error constant through the imported module:
  `expected_failure(abort_code = release::EUnauthorized)`. Move infers the
  location; do not add `location =` or mirror error constants in test files.
  Use `location = <imported module>` only for aborts with no named constant.
- One package per concern: each package defines a single `ExtensionKey()` and
  stores one value under it, so a schema change to one attribute never forces
  a data migration of another. `recording_license` is one concern with two
  sides: its single `ExtensionKey()` derives both the composition's policy and
  the recording's license.
- Keep packages independently buildable and versioned.
- Pin Git dependencies to exact 40-character commit SHAs.
- Preserve `Published.toml` as deployment provenance.

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
