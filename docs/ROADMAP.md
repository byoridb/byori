**English** | [한국어](ko/ROADMAP.md)

# Byori Roadmap

**2026-09-12 update:** the owner reopened strategy. The active next step is the
[dependency-context reuse pilot](dependency-context-pilot.md), not completion of
the app-first roadmap below. Earlier work is retained and paused, not discarded.

Active direction accepted **2026-09-11**: Byori automatically builds and updates a source-backed
project handbook for coding AI. ByoriDB is the internal knowledge build engine. Product
consolidation is allowed; existing user data must survive the transition.

See [Product](../PRODUCT.md), [Design](../DESIGN.md), and the
[development plan](knowledge-compiler-plan.md) for scope, dependencies, and acceptance tests.
These are planned outcomes, not newly shipped features.

## Now — Establish first value

| ID | Outcome | Status |
|---|---|---|
| KC-00 | Accepted strategy and consistent product/design/plan documents | Documented |
| KC-01 | Deterministic, source-linked handbook for one project | Prototype under implementation and independent verification |
| KC-02 | Real Claude Code/Codex new-session delivery and explicit refresh | Adapter groundwork; real-delivery gate still pending |

Internal-demo gate: one project → useful handbook → new agent session uses it → source change
and explicit rebuild → next session receives the replacement. No model editor or DB rewrite
is needed for this gate.

## Next — Make it dependable and easy to install

| ID | Outcome | Status |
|---|---|---|
| KC-03 | Incremental compilation, scope isolation, safe publication and offline output | Consent-gated refresh and authenticated cross-invocation projection reuse implemented; host/offline and product-value gates pending |
| KC-04 | Small manager, one runtime owner, reversible installation and migration | Native UI prototype; full gate requires KC-02/KC-03 and recovery tests |
| KC-06 | Five-user pilot, fair baseline comparison, release decision | Not started; requires KC-04 |

The public pilot does not require KC-05. Safety and compatibility tests accompany each change.
The maintainer owns cross-repository dependencies; assess actual blockers before engine changes.
One active milestone at a time, with integration/defect capacity reserved. No calendar date is
promised before the first slice is measured.

## Later — Earn complexity

- **KC-05 (optional):** bounded, opt-in model-assisted editing from original evidence. Requires
  KC-03 and a demonstrated quality gain. If included in a release, it must pass before KC-06.
- Additional source connectors or team features only after repeated-use value is demonstrated.
- Legacy code retirement only after tested preservation and recovery; not an initial rewrite.

Deprioritized: new terminal/worktree/session orchestration, graph-dashboard polish, generic DB
feature expansion, and independent product launches for each internal component. New work must
displace lower-priority work rather than inflate this single-maintainer plan.

## Historical roadmap — 2026-08-07 snapshot, superseded

The P3–P8 material below is retained as design history. Its completion labels and “remaining”
lists describe that old snapshot, **not current implementation status or active commitments**.
The KC milestones above replace its priorities. Revalidate an old issue before treating it as a
current dependency. Originally established at the 2026-07-13 repository split.

### P3 — Engine Compatibility Contract 🟡 (Contract and CI Complete)

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

### P4 — Byori macOS App + Shared Management Core 🟡 (Workspace and Signed Release Shipped, CLI Convergence Pending)

The SwiftUI **Byori macOS app** is implemented and distributed as a signed, notarized, stapled
universal DMG on each release; the app installs its own updates after verifying that signature and
notarization. Its primary surface is a Project → Source Tree/Worktree → Task → Session workspace
with a real interactive Claude Code or Codex PTY selected by the user for each session. The shared
management core handles installation, diagnostics, connections, and updates from Settings. The current cross-platform `byori` CLI implements the
foreground compatibility slice (`provider / project / run / runs`); its broader management
surface still needs to converge with the app core:
`setup / doctor / connect claude / connect codex / project add . / status /
backup / upgrade --plan / rollback / uninstall`.

- ✅ The app persists project registrations, discovers source trees and linked worktrees, creates
  Byori-managed worktrees for an existing or new local branch, stores tasks and session metadata,
  and retains live PTYs. With tmux 3.2 or later a session survives a full app quit and reattaches
  on the next launch
- ✅ Each session records one user-selected launch provider and model. The app does not
  automatically fan out prompts, select a winner, merge, or delete agent work
- The app can detect Claude Code, Codex, Gemini CLI, Cursor CLI, and OpenCode and, with the
  user's explicit consent, run each vendor's **official installation command**. Authentication
  remains the responsibility of the vendor CLI;
  Byori neither reads nor stores vendor tokens
- `connect`/`disconnect` are idempotent and back up the original configuration before changes
  (the shell installer's `--with-hooks` option also uses append-and-back-up behavior)
- ByoriDB remains an independent launchd user service; installation, agent connections,
  maintenance, backups, and diagnostics remain supporting Settings surfaces
- Its state model follows the `byoridb-tray` prototype without reusing its hard-coded paths
  or synchronous process execution
- Remaining: convergence of the cross-platform `byori` CLI management surface with the app core

### P5 — Memory Schema Versioning + Migration 🟡 (Additive v2 + Structured MCP Complete)

- ✅ Store a `byori:schema-version` note in the `claude_memory` space; at MCP startup,
  read the version and apply only missing additive migrations
- ✅ Automatically bootstrap the typed wiki ontology
  (`module`/`decision`/`bug`/`incident`/`concept`/`entity`/`task` + causal edges) as
  schema v2 on fresh installs, and automatically migrate existing installations; see
  [`docs/memory-ontology.md`](memory-ontology.md)
- ✅ Provide the structured MCP surface for validated upsert, read, traversal, linking,
  export, and deletion, plus `safe` (no unrestricted raw query) and `readonly` (four read tools,
  fail-fast schema check) profiles. Exact canonical-name lookup preserves and reuses existing
  v0.2.0 typed VIDs instead of creating duplicate nodes
- Remaining: explicit staged execution of non-additive (destructive) migrations
  (`byori migrate`), converging on the shared management core/CLI from P4

### P6 — `byori` Project Registry + Foreground CLI Prototype 🟡 (Local MVP Complete)

This is an explicit compatibility/prototype path, not the native workspace interaction model.
The user selects one or more providers for a run; multi-provider execution is never an automatic
response to creating a task or session in the app.

- ✅ `byori provider list`: detect the Claude Code and Codex executables without reading vendor
  credentials; provider adapters normalize launch configuration and provider-native session IDs
- ✅ `byori project add . [--space SPACE]` and `project list`: register a canonical Git root and
  stable graph namespace. Registration is the explicit trust boundary for noninteractive workers
- ✅ `byori run`: launch selected providers concurrently. The default mode rejects a dirty
  repository and creates one `byori/<run-id>/<worker>` branch and managed worktree per worker;
  single-worker `--in-place` is an explicit escape hatch
- ✅ Keep operational JSON, raw prompts, provider logs, and worktrees under `~/.byori`; inject only
  bounded recall context and promote coordinator-owned project/task checkpoints to ByoriDB
- ✅ Give workers the four-tool `readonly` MCP profile. A project-space advisory lock serializes
  coordinator graph preparation and checkpoint writes, and workers fail fast on a stale schema
- ✅ `byori runs list/show`: inspect durable local run records. Branches and worktrees are never
  merged or deleted automatically
- Remaining: background/attach/resume control, additional provider adapters, patch comparison,
  explicit merge/cleanup workflows, and convergence with the app's management commands

### P7 — Automatic Ingestion + Ranked Recall

- Perform structured capture only at boundaries where knowledge becomes established
  (task completion, commit, PR, or incident resolution)
- Index repository modules, symbols, dependencies, documents, and Git changes with project
  awareness; use canonical names and merge candidates to prevent fragmentation
- Add traversal-, temporal-, and semantic-ranking recall, with a readable wiki surface

### P8 — Time to First Value

Byori's value is currently deferred: the graph is empty at install time and only becomes useful
after weeks of checkpoint capture. A new project therefore pays the cost before seeing any
benefit. This phase targets the first session rather than the hundredth.

- Seed a new registration from evidence that already exists — Git history, merge commits, issue
  and PR references, existing design documents — so `project add` produces a non-empty graph
  instead of an empty space
- Provide a runnable demonstration on a real repository that shows recall answering a question
  the code cannot answer, without requiring weeks of prior use
- Report what capture actually happened after a session, so the user can see the graph growing
  instead of trusting that it did
- Measure and publish repeatable before/after numbers rather than the current single dogfood
  run; the README benchmark is directional evidence, not a claim
