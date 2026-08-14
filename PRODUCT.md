# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Byori's primary user is a developer working in local Git repositories with several coding
agents available, such as Claude Code and Codex. For each source tree and task, the developer
chooses which agent and model should own an interactive session. They need important project
knowledge to survive when they move between those agents, sessions, and tools.

The same developer also operates the local ByoriDB service and its MCP and Skill connections.
Service administration is a supporting responsibility, not a separate primary persona.

## Product Purpose

Byori is a project-first native multi-agent coding workspace. The project is its largest
organizing unit. Within a project, a developer works in source trees or worktrees, creates tasks,
and opens interactive sessions with a chosen coding CLI. Byori records one launch agent and model
choice per session; using another agent through Byori means opening another session rather than
automatically fanning out the same task. Provider-side changes made inside the interactive CLI
remain provider-controlled.

ByoriDB is the integrated knowledge layer beneath that workspace. It preserves decisions and
their rationale, module relationships, recurring bugs, incidents, resolutions, and task
checkpoints so agents do not have to relearn the project from scratch in every session.

Success means a developer can move between source trees, tasks, agents, and sessions without
losing the project's important "what" and "why," while keeping each session's code changes and
execution under explicit human control.

## Positioning

Byori combines two mechanisms that neighboring tools cannot truthfully claim from either one
alone:

- a provider-neutral local workspace where the developer can open separate, interactive coding
  sessions with different CLIs in selected source trees and worktrees; and
- a typed, temporal, provenance-aware knowledge graph shared across those agents and sessions.

The graph is not a flat document wiki, a transcript archive, or the process supervisor. The
foreground CLI prototype keeps its raw prompts, provider events, logs, and operational run state
in its local run store; the native app does not store terminal prompts or transcripts. Only
bounded context and compact, durable checkpoints belong in ByoriDB.

## Operating Context

The current workflow is local and Git-centered:

1. The developer signs in through each vendor CLI and explicitly registers a trusted Git
   project with Byori.
2. They use the source-tree or task `+` action, accept or edit a generated session name,
   and choose one installed agent and model for the new session.
3. Byori opens an interactive terminal for that session and loads a bounded slice of project
   knowledge in the Context inspector. The agent accesses project memory through its separately
   configured MCP and Memory Skill. Byori preserves the launch selection; any provider-side model
   change made inside the interactive CLI is outside Byori's observation.
4. The developer may open other sessions manually, including sessions with other agents or in
   other worktrees. Byori does not automatically broadcast a prompt, select a winner, merge, or
   delete agent work.
5. At durable boundaries, the configured agent can record compact project and task checkpoints in
   the project's ByoriDB graph space for later recall.

Removing an item from the native workspace is deliberately non-destructive. Removing a project
archives its exact registry record outside the active project list; adding the same canonical
repository root again restores the prior project ID, graph space, and task/session linkage. Removing
a linked checkout only hides that canonical path from the project's outline until it is restored.
Neither action deletes repository files, Git worktrees or branches, task/session metadata, or
ByoriDB data.

The primary product surface is a workspace layout: a project, source-tree/worktree, task, and
session hierarchy in the left navigation; the selected session's real interactive terminal in
the main area; Files, Git, and contextual ByoriDB knowledge in a right inspector; and a compact
bottom status bar for verified local health, checkout, session, and Context state. Provider quota
percentages are excluded until a supported provider API can supply them truthfully.
Installation, agent connections, database maintenance, and system diagnostics belong in
Settings rather than the primary navigation. ByoriDB installation does not implicitly connect
or alter a provider; MCP and Memory Skill changes remain explicit per-agent actions. Settings
may inventory user-scoped MCP registrations and Skills, but it never presents secret-bearing
command arguments, headers, environment values, or tokens.

Claude Code may optionally be launched through Upstage's official Solar integration or a
user-configured Anthropic-compatible gateway. Byori stores the API credential in macOS Keychain,
stores only non-secret routing metadata in its preferences, and injects that configuration only
into newly launched Claude sessions. It does not rewrite Claude's settings files. Disabling the
option restores the user's ordinary Claude login and inherited configuration for subsequent
sessions. The Upstage preset follows Upstage's published Claude Code environment for
`https://api.upstage.ai` and Solar Pro 4; other providers must expose a Claude-compatible API.

The current Byori macOS app is built with SwiftUI for macOS 13 or later. The CLI and local runtime
support macOS and Linux. Web, iOS, Android, remote collaboration, and a cross-platform desktop UI
are not current product commitments.

## Capabilities and Constraints

Existing repository capabilities that the workspace can build on:

- detect and invoke Claude Code and Codex through provider-neutral adapters;
- create new local Git projects, or explicitly initialize and register trusted existing folders,
  with stable ByoriDB graph spaces;
- archive and restore project registrations, and hide or restore linked checkouts, without deleting
  their underlying Git or workspace data;
- create isolated branches and managed worktrees for explicit foreground CLI workers;
- preserve foreground CLI prompts, capped stdout/stderr logs, provider session identifiers, Git
  revisions, and prototype run state under `~/.byori`;
- recall and checkpoint durable knowledge through a guarded MCP surface backed by ByoriDB;
- install, update, start, stop, diagnose, and connect the local runtime through the Byori macOS
  app and installer;
- optionally route newly launched Claude Code sessions through an Anthropic-compatible gateway,
  with Keychain-backed credentials and a reversible default-Claude state; and
- inspect a bounded, read-only view of the knowledge graph.

Current implementation constraints:

- the existing CLI orchestration path is a foreground fan-out prototype and is not the new
  workspace interaction model;
- the Byori macOS app exposes the project/source-tree/task/session hierarchy and app-retained
  interactive PTY sessions, but does not yet create worktrees or reattach a PTY after the full
  app process exits;
- remote UI, automatic patch comparison, winner selection, merge, and worktree cleanup are not
  implemented;
- native project removal and checkout hiding are visibility/registration operations, not Git
  cleanup or knowledge deletion;
- the default managed-worktree mode requires a clean registered repository;
- vendor authentication and model data handling remain owned by each coding CLI unless the user
  explicitly enables Byori's Claude gateway override for new sessions;
- memory is historical reference and must be checked against the current repository;
- ByoriDB stores durable knowledge, not raw reasoning traces or complete provider logs;
- automatic repository ingestion and semantic-ranked recall are not implemented; and
- important data must not rely on the current experimental local installation as its only copy.

Open product decisions:

- whether the native workspace will remain macOS-first or gain another desktop surface;
- whether session survival should extend beyond the local app process, and when patch
  comparison and integration workflows enter the supported product; and
- whether future team collaboration remains local-first or introduces a remote control plane.

## Brand Commitments

The product name is **Byori**, the graph engine beneath it is **ByoriDB**, and the CLI executable
is **`byori`**. Product language must keep their roles unambiguous: Byori is the coding workspace;
ByoriDB is its durable knowledge graph; `byori` is a supporting command-line surface.

The voice is technically precise, candid about experimental limitations, and explicit about
trust and privacy boundaries. English documentation is canonical, with maintained Korean
translations. Interaction references such as Orca and Paseo inform workspace patterns but do
not authorize copying their source code, identity, or factual claims.

## Evidence on Hand

- The repository contains a working provider registry, trusted-project registry, parallel
  Claude/Codex coordinator, isolated-worktree lifecycle, and durable local run records in
  `cli/byori.py`.
- `docs/orchestration.md` documents the current run boundary, local record layout, graph
  promotion policy, and limitations.
- `mcp/byoridb_mcp.py` and `docs/memory-ontology.md` implement and document the note plus typed
  knowledge-graph memory surface.
- The SwiftUI app under `manager/macos/` implements the project-first workspace, real
  app-retained SwiftTerm PTYs, bounded Files/Git inspection, project-scoped ByoriDB context, and
  separate administration Settings.
- A preliminary single-repository synthetic dogfood run reported roughly 40 seconds, 5 turns,
  and $0.43 with Byori versus 125 seconds, 15 turns, and $1.15 without it, with 20/20 versus
  0/20 recovery of knowledge absent from the code. This is directional evidence only, not a
  statistically rigorous benchmark or marketing guarantee.
- There are no confirmed customer testimonials, production deployments, pricing claims, or
  independent benchmarks; future work must not fabricate them.

## Product Principles

1. **Workspace first, knowledge throughout.** Multi-agent coding means the user can choose the
   right agent for each session; it does not mean automatic fan-out. ByoriDB should surface useful
   context inside that work instead of becoming a separate admin destination.
2. **Durable knowledge over exhaustive capture.** Promote decisions, causes, resolutions, and
   checkpoints—not every turn, transcript, or reasoning trace.
3. **Recall, then verify.** Historical memory accelerates work but never replaces reading and
   testing the current code.
4. **One owner per session, with explicit human control.** A session has one recorded launch agent
   and model; provider-side changes inside the terminal remain provider-controlled. The developer
   chooses source trees, creates additional sessions, and controls trust, comparison, integration,
   and cleanup.
5. **Local-first, with visible boundaries.** Keep graph data and run evidence local by default,
   clearly disclose what vendor models may receive, and never hide consequential automation.

## Accessibility & Inclusion

The native workspace should preserve standard macOS keyboard navigation, semantic controls,
system text rendering, reduced-motion behavior, and light/dark appearance. A formal conformance
target and product-specific assistive-technology requirements remain undecided.
