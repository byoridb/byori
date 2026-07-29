**English** | [한국어](ko/ROADMAP.md)

# Byori Roadmap

Plan as of the split from the byoridb repository on 2026-07-13. Principle: **dependencies
flow in one direction, from Byori to ByoriDB**. Byori installs and manages a validated
engine release; the engine knows nothing about Byori.

## P3 — Engine Compatibility Contract 🟡 (Contract and CI Complete)

- ✅ Created [`docs/engine-contract.md`](engine-contract.md), documenting only the engine surface that the MCP actually uses:
  - `/health`, session login, re-login semantics for `400 Invalid session`, and re-pinning with `USE`
  - The gated nGQL subset: `CREATE SPACE/TAG/EDGE`, `USE`, `INSERT`, `MATCH` with
    canonical-name `WHERE` lookups plus `RETURN`/`ORDER BY`/`LIMIT`/`OFFSET`,
    `FETCH` (+ `AS OF`), `DELETE EDGE`, and `DELETE VERTEX`
  - Environment contract: `BYORIDB_ROOT_PASSWORD`, `BYORIDB__*`
- ✅ CI downloads the release pinned by `ENGINE_TAG`, runs
  `install.sh --assets . --no-claude --no-codex`, and exercises the contract with unit tests and a
  pinned-engine smoke test. Coverage includes structured upsert/read/link/export/delete,
  safe-profile denial of raw queries, reuse of v0.2.0 typed VIDs, edge deletion, and
  cascading vertex deletion
- 🟡 The 63-bit hash mask and documented VID range are in place. The canonical upstream
  planner fix for negative VIDs remains pending in the engine

## P4 — Byori Manager + Shared Management Core 🟡 (Manager Implemented, Signed DMG Pending)

The SwiftUI **Byori Manager** is implemented and available to build from source. A signed
and notarized `.dmg` release is still pending. Its shared management core handles
installation, diagnostics, connections, and updates, and will later be reused by a thin
`byori` CLI:
`setup / doctor / connect claude / connect codex / project add . / status /
backup / upgrade --plan / rollback / uninstall`.

- Manager can detect Claude/Codex and, with the user's explicit consent, run each vendor's
  **official installer**. Authentication remains the responsibility of the vendor CLI;
  Manager neither reads nor stores vendor tokens
- `connect`/`disconnect` are idempotent and back up the original configuration before changes
  (the shell installer's `--with-hooks` option also uses append-and-back-up behavior)
- The macOS app is implemented in SwiftUI, while ByoriDB remains an independent launchd
  user service
- Its state model follows the `byoridb-tray` prototype without reusing its hard-coded paths
  or synchronous process execution

## P5 — Memory Schema Versioning + Migration 🟡 (Additive v2 + Structured MCP Complete)

- ✅ Store a `byori:schema-version` note in the `claude_memory` space; at MCP startup,
  read the version and apply only missing additive migrations
- ✅ Automatically bootstrap the typed wiki ontology
  (`module`/`decision`/`bug`/`incident`/`concept`/`entity`/`task` + causal edges) as
  schema v2 on fresh installs, and automatically migrate existing installations; see
  [`docs/memory-ontology.md`](memory-ontology.md)
- ✅ Provide the structured MCP surface for validated upsert, read, traversal, linking,
  export, and deletion, plus the `safe` profile that omits the unrestricted raw-query tool.
  Exact canonical-name lookup preserves and reuses existing v0.2.0 typed VIDs instead of
  creating duplicate nodes
- Remaining: explicit staged execution of non-additive (destructive) migrations
  (`byori migrate`), converging on the shared management core/CLI from P4

## P6 — Project Registry + Automatic Ingestion

- `byori project add .`: register a per-project namespace (a space or name prefix)
- Perform structured capture only at boundaries where knowledge becomes established
  (task completion, commit, PR, or incident resolution)
- Index repository modules, symbols, dependencies, documents, and Git changes with project
  awareness; use canonical names and merge candidates to prevent fragmentation
- Later: traversal-, temporal-, and semantic-ranking recall, with a readable wiki surface
