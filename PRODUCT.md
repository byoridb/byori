# Product

<!-- impeccable:product-schema 1 -->

## Decision and Status

**2026-09-12 — strategy reopened; dependency-context pilot authorized.** The owner
has explicitly removed the previous product documents as design constraints.
The active next step is the bounded [dependency-context reuse experiment](docs/dependency-context-pilot.md):
test whether version-bound, source-backed knowledge reduces repeated cross-repository
exploration without harming correctness. App-first delivery, a mandatory graph DB,
local/cloud storage and public plugins are not settled requirements for the next product.
The earlier direction below is retained as history; its unfinished implementation is
preserved and paused. A successful plumbing test alone will not establish token savings.

Strategy accepted by the product owner on **2026-09-11**. This document replaces the
workspace-first product direction. It specifies the target product, not a claim that the
handbook compiler or automatic delivery has shipped. Implementation is tracked in the
[development plan](docs/knowledge-compiler-plan.md) and [roadmap](docs/ROADMAP.md).

## Platform

adaptive

The first product surface is the existing native macOS app, supported by the CLI and MCP.
Keep existing macOS/Linux CLI compatibility; additional desktop platforms are not a launch gate.

## Users

Start with developers maintaining a Git project across repeated AI coding sessions, especially
those moving between Claude Code and Codex. Their problem is repeated project explanation and
outdated context, not a shortage of terminals or graph visualizers. There is currently one
confirmed user: the product owner. Broader demand and willingness to pay remain unvalidated.

## Product Purpose

**Byori automatically builds and updates a short, source-backed project handbook for coding AI.**

User promise: **“Stop explaining your project over and over.”**

Korean: **“프로젝트 설명, 매번 다시 하지 마세요.”**

Connect a project, see what Byori learned and where it came from, then let an explicitly
connected coding agent read the handbook in its next session. When selected sources change,
Byori rebuilds the affected knowledge and makes its freshness visible.

The handbook covers the project's purpose, important modules, established decisions and their
reasons, relevant constraints, and known pitfalls. Missing reasons stay missing. It is neither
an exhaustive transcript nor an instruction to trust historical claims over current code.

## Positioning and Brand

**Byori** is the single user-facing product. **ByoriDB** is its internal knowledge build engine.
**`byori`** remains the CLI. A customer should not need to select a database, create a graph
space, configure a port, or understand MCP to get the first useful result.

The graph is an implementation choice for provenance, dependencies, conflicts, and incremental
updates—not the headline or a claim of exclusive technology. ByoriDB can evolve toward this
workload; general-purpose database expansion is not a prerequisite. Existing repositories and
runtime interfaces need not be merged or rewritten to unify the product experience.

The product must earn adoption by reducing context-maintenance work without reducing answer
quality. Neither graph structure nor shorter prompts alone proves that outcome.

## Target Experience

1. **Connect:** choose a trusted project and review the source scope. Use selected repository
   documents, bounded Git history, existing durable memories, and structured checkpoints.
2. **Preview:** build a handbook without a model first. Show useful content, source links,
   exclusions, and unresolved questions. Do not make the user wait for a complete history scan.
3. **Connect an agent:** explicitly approve the proposed Claude Code/Codex configuration changes.
   Load a bounded handbook on session start; fetch detailed evidence through MCP when needed.
4. **Stay current:** detect source changes and incrementally rebuild. Display current, outdated,
   building, failed, or disconnected status independently. A configured MCP server is not proof
   that an agent actually received the handbook.

The app's primary surface becomes a small project manager: handbook preview, evidence, freshness,
and agent connections. A graph canvas, terminal, session tree, and worktree controls are not
required to complete this flow. Existing users' work remains recoverable during the transition.

## Knowledge Ownership

- Original selected sources and accepted durable checkpoints are the authoritative records.
  Preserve checkpoint-only knowledge that cannot be reconstructed from Git.
- The normalized graph and generated handbook are derived views. Every published claim carries
  source lineage, scope, and a build version. They must be rebuildable from retained originals.
- Generated files are read-only products of the compiler, not a second independently maintained
  memory store. Corrections go to the source or an explicit accepted correction record.
- A source locator resolving successfully does not prove that the source supports the claim.
  Inferences, conflicts, and unverified legacy knowledge must not silently become current policy.
- Project-wide accepted facts and checkout-specific observations have distinct scopes. One
  worktree's experimental change must not overwrite another checkout's handbook.
- Rebuild from originals and accepted records, not recursively from the last summary. Retain
  conditions, rejected alternatives when documented, supersession, and unresolved contradictions.

## Capabilities and Constraints

Reuse the existing project registry, deterministic `byori init` archaeology, structured memory
MCP, local engine, native manager, installer, and doctor. Their existence does not mean that the
target compiler is already implemented. Current archaeology extracts signals; current evidence
labels and retrieval results are not a validated claim-entailment system.

The first end-to-end slice is one project, a deterministic handbook, real new-session delivery,
and an explicit rebuild after a source change. Add optional model-assisted editing only after
this loop works. Add automatic refresh and distribution hardening before a public pilot.

Must have: source-backed preview, safe incremental publication, Claude Code/Codex delivery,
visible freshness, source exclusions, reversible setup, and preservation of existing data.

Not in the first release: new workspace/orchestration features, full transcript ingestion,
all-company search, Slack/Jira connectors, team sync, billing, RBAC, a general-purpose graph query
product, or a database rewrite. Remove legacy code only after its replacement and recovery path
are verified; consolidation permission is not permission to erase user data.

## Privacy and Reliability

Local storage and deterministic compilation are the default. Model-assisted editing is an
explicit opt-in with a disclosed provider, outbound source scope, and hard usage budget. An
installed vendor CLI or subscription is not authorization to reuse its credentials or model.

Do not ingest secrets, `.env` files, arbitrary home directories, raw reasoning traces, or entire
chat histories. Treat repository text as untrusted input, never as commands to execute. Preserve
user-owned instruction files; show and back up configuration edits before applying them.

A previously published handbook should remain readable when the engine is unavailable, with
its snapshot and freshness limitations visible. Wrong-checkout, retracted, or newly excluded
sensitive material must be withheld rather than served as an unconditional fallback.

Use one runtime lifecycle owner and a validated app/CLI/MCP/engine compatibility bundle. Test
backup restoration and rollback; a bounded graph export or runtime-only snapshot is not a full
knowledge backup. Important data must not rely on this experimental installation as its only copy.

## Evidence and Success

The Redis 8/8 versus 0/8 result is historical evidence-token retrieval against an empty-graph
baseline. It does not establish superiority over an agent reading Git or a maintained Markdown
handbook. No independent performance, customer, or revenue claim is established.

Evaluate repeated tasks against the same sources with (a) agent plus repository/Git, (b) a
manually maintained handbook, and (c) Byori. Measure factual correctness, citation support,
currentness after changes, user maintenance time, first-use latency, and total model cost.
Use a graph ablation to decide which graph operations actually earn their complexity.
Release gates and provisional targets belong in the development plan, not in marketing as results.

## Product Principles

1. **Useful before sophisticated.** The first preview matters more than node counts.
2. **Maintain knowledge, not summaries of summaries.** Preserve evidence and compile incrementally.
3. **Delivery is part of the product.** Verify consumption in a new agent session, not registration alone.
4. **Honest context.** Unknown, conflicting, outdated, and inferred are visible states.
5. **One product, reversible operations.** Hide infrastructure complexity, not failures or data boundaries.

## Accessibility and Documentation

Preserve native macOS keyboard navigation, semantic controls, readable system typography,
light/dark appearance, and reduced-motion behavior. Freshness and failures must not rely on color
alone. English product/development documents are canonical; maintain Korean development-plan,
roadmap, and README counterparts. Existing terminal design rules apply only to retained legacy UI.
