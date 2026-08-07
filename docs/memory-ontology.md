**English** | [한국어](ko/memory-ontology.md)

# ByoriDB Project Knowledge Graph — Memory Ontology and Dogfood

> Status: **design and dogfood PoC validation complete**. This document defines the durable
> knowledge layer beneath the Byori multi-agent workspace: selected project facts accumulate at
> explicit checkpoints and can be read as a connected wiki. Since v0.2.0, the typed wiki schema
> in §4 is automatically bootstrapped or migrated as schema v2 when the MCP starts. Automatic
> repository or transcript ingestion is not implemented. Origin:
> conversation on 2026-07-11 (file memory vs. graph memory → typed knowledge-graph vision).

---

## 1. Vision

As users move between projects, source trees, tasks, and coding-agent sessions in Byori, promote
durable decisions, incidents, resolutions, benchmarks, and non-obvious project structure into a
**typed knowledge graph**. Capture happens at explicit checkpoints rather than on every terminal
turn. When read by following edges between nodes, the graph should tell a wiki-like story of why
the system became what it is.

- Limitation of file memory (`MEMORY.md`): always-on token cost, flat lists, and no relationships
  or temporal context.
- Goal: make recall a **traversal**:
  `this module → why it became this way → which decision/bug caused it → what superseded it`.

## 2. Why ByoriDB Is the Right Substrate

Capabilities already present in ByoriDB that ordinary vector/file memory does not provide:

| Capability | Wiki problem it solves |
|---|---|
| Ontology forward-chaining inference (O-4~O-9) | Exposes facts that were not stored explicitly (“A depends_on B, and B is affected_by a bug → A is in the impact radius”) |
| sameAs canonical merge (O-8) | Engine-level entity identity. This remains experimental/future work for the MCP structured surface |
| Bitemporal data (T-1~T-4) | Handles staleness. `AS OF` retrieves “the structure known when that decision was made” |
| Deletion retraction (O-9) | Retracts obsolete facts from the graph |

## 3. Failure Modes That Must Be Avoided

The naive approach—“let the LLM freely extract entities and relationships every turn”—will
inevitably become a junk drawer. Build the defenses into the schema:

1. **Extraction consistency collapses** → **fix a small set** of types and edges; do not allow
   open-ended additions.
2. **Entities fragment** → require **canonical naming rules** now; keep possible aliases as
   merge candidates until a structured `sameAs` relation is shipped.
3. **Noise vs. gaps** → instead of extracting everything, extract **only at boundaries
   (checkpoints)**.
4. **Staleness** → use bitemporal versions instead of overwrites, and mark retirement with
   `supersedes` edges.

## 4. Ontology Schema (Core Principle: Keep It Narrow)

§4 below describes the shipped schema v2 plus the explicitly marked target-only `decided_in`
edge. The PoC in §7 created only the subset required to validate feasibility. Since v0.2.0, the
MCP automatically bootstraps schema v2, using a lightweight representation in which the
`part_of` through `relates_to` edges contain only `ts` and `incident.resolved` is a STRING.

### 4.1 Node Types (Tags)

| tag | Meaning | Core properties |
|---|---|---|
| `module` | Code module/crate/subsystem | name, summary, ts |
| `decision` | Decision and rationale | name, body (including why), state (active/superseded), ts |
| `bug` | Bug/gotcha and resolution state | name, body, state (open/fixed/known), ts |
| `incident` | Operational incident | name, body, resolved (`"true"`/`"false"` STRING), ts |
| `concept` | Domain/design concept | name, body, ts |
| `entity` | Data entity (dogfood subject) | name, body, ts |
| `task` | Work/tracking item | name, body, state (open/in_progress/blocked/done), ts |

> Start with the minimum set. Promote a new type only after it has been awkwardly forced into
> an existing type at least three times. Do not add types arbitrarily.

### 4.2 Target Edge Types

Only meaningful relationships are included. Every edge has a direction.

| edge | from → to | Meaning |
|---|---|---|
| `part_of` | module → module | Submodule containment |
| `depends_on` | module → module | Dependency |
| `affects` | decision/bug → module | Impact |
| `caused_by` | incident/bug → bug/decision/module | Cause |
| `fixed_by` | bug/incident → decision/task | Means of resolution |
| `supersedes` | decision → decision | Replacement/retirement |
| `decided_in`* | decision → task | Work item in which the decision was made |
| `about` | task/incident → module/entity/concept | Subject |
| `relates_to` | any → any | Weak relationship (escape hatch; use sparingly) |

\* `decided_in` exists only in the target schema and is not yet part of the schema v2 migration
in `byoridb_mcp.py` (eight typed edge kinds are actually created). Until it has been needed at
least three times, encode it temporarily with `relates_to`; see
[engine-contract.md](engine-contract.md).

`sameAs` is also an engine capability and an experimental target, not a relation accepted by the
shipped structured `memory_link` tool. Do not invent a `sameAs` edge through the structured API;
keep aliases as merge candidates until that contract is designed and shipped.

> The compatibility note layer continues to use one `rel` edge with a `kind` property. The
> shipped typed-wiki layer promotes the eight supported relationships to separate edge tags, so
> queries such as `GO ... OVER affects` work directly.

### 4.3 Canonical Naming Rules

`<type>:<stable-slug>`—not a sentence. A canonical name must match
`^[a-z][a-z0-9_]*:[A-Za-z0-9][A-Za-z0-9._-]*$`, must begin with the exact node type passed to the
tool, and must be no longer than 256 characters. In particular, the slug starts with an ASCII
letter or digit; subsequent characters may also contain `.`, `_`, or `-`. Examples:
`module:byoridb-executor`, `decision:use-redb`, `bug:redb-repair-crashloop`,
`incident:aks-startup-probe`, and `concept:llm-wiki-memory-graph`.
Always use the same slug for the same subject, so rewriting becomes an update and bitemporal
versions accumulate.

### 4.4 Supported Structured MCP Surface

Use the structured tools for typed wiki work. They keep client code out of raw nGQL construction
and enforce the schema contract at the server boundary.

| Tool | Supported behavior |
|---|---|
| `memory_wiki_upsert` | Creates or updates one typed node; validates the type, canonical name, body, and lifecycle fields |
| `memory_link` | Creates/updates or deletes one relation; both endpoints must exist, and the server validates the source→target matrix (`relates_to` is the deliberate escape hatch) |
| `memory_read` | Reads normalized nodes by exact name or text and can include connected relationships |
| `memory_query_read` | Runs one guarded read-only `MATCH`, `FETCH`, `GO`, `LOOKUP`, `SHOW`, or `WHY` statement |
| `memory_delete` | Deletes one exact node; linked nodes require an explicit `cascade=true` |
| `memory_export` | Returns a bounded, best-effort inspection page; it is not a transactional backup or stable snapshot |

The older `memory_remember`, `memory_recall`, and raw `memory_query` tools remain for legacy
compatibility. New typed workflows should not calculate VIDs or construct write queries on the
client.

Canonical-name compatibility is property based. If a v0.2.0 typed node already exists under its
older 60-bit VID, the server discovers it by exact type/name and preserves that VID on update or
linking. A node with no existing canonical match receives the current non-negative 63-bit VID.
Duplicate canonical nodes are rejected instead of being updated ambiguously.

The API normalizes storage details: `module.summary` is returned as `body`, the stored
`incident.resolved` STRING is returned as a boolean, and VIDs are returned as decimal strings.
Lifecycle values are restricted to `decision: active|superseded`, `bug: open|fixed|known`, and
`task: open|in_progress|blocked|done`; incidents use boolean `resolved` instead of `state`. New
decisions, bugs, and tasks default to `active`, `open`, and `open`, respectively, while new
incidents default to `resolved=false`.

## 5. Extraction Rules (When / What / How)

**When (only at checkpoints):**

- When a task/tracking item ends
- When a PR is created
- When an incident ends
- When the user explicitly says “remember this”

**What:**

- Decisions and rationale (why), recurring bugs/gotchas and their resolution, incidents and their
  causes, and non-obvious structural facts.
- Do not store transient conversation or one-off logs (hygiene).

**How (prevent fragmentation):**

1. Generate a candidate canonical name, then call `memory_read` with its exact `type` and `name`
   before attempting a typed create. If the exact name is absent, use a focused text read to look
   for an existing entity under another canonical name.
2. Call `memory_wiki_upsert` with the same canonical name to update an existing node or create a
   new one. Never calculate the VID in the client.
3. Include `state` or `resolved` explicitly when recording a lifecycle transition. Omitting it on
   an existing node preserves the current value, but an explicit transition makes intent auditable.
4. Create relationships with `memory_link`; let the server verify that both endpoints exist and
   that their types fit the relation matrix. Use `relates_to` only when a stronger shipped relation
   does not apply.
5. If a similar entity with another name is found, record it as a `sameAs` merge candidate outside
   the structured relation set; `sameAs` is not shipped there yet.

## 6. PoC (Executed Alongside This Document)

This historical PoC added a subset of the §4 types to the `claude_memory` space and graphed
**the design conversation itself** to confirm that traversal reads like a wiki. It preserved the
existing note/rel schema. Results are recorded in §7; managed schema-v2 spaces should now be
changed only through MCP migrations and structured tools.

## 7. PoC Results (Executed 2026-07-11)

The §4 schema was added additively to the `claude_memory` space, and this conversation was
represented as a graph.

**Schema added** (preserving the existing note/rel schema):

- Tags: `module, decision, bug, incident, concept, task`
- Edges: `depends_on, affects, caused_by, fixed_by, supersedes, about, relates_to`
- Gotchas: `status` is reserved, so the property is named `state`. VIDs must be INT64, so explicit
  integer VIDs were used.

**Loaded:** 9 nodes + 10 edges representing knowledge from this conversation. VID mapping:
`1001 module:byoridb-memory-skill · 1003 module:byoridb-executor · 2001 decision:memory-schema-minimal ·
2002 decision:memory-wiki-typed-ontology · 3001 concept:llm-wiki-memory-graph · 3002 concept:ontology-inference ·
3003 concept:bitemporal-asof · 4001 bug:junk-drawer-antipattern · 5001 task:memory-wiki-poc`

**Does traversal read like a wiki? Yes.** Validated queries:

```
# “Why is the memory skill flat?” (module ← affects, reverse direction)
GO FROM 1001 OVER affects REVERSELY YIELD $$.decision.body
→ “Deliberate restraint to prevent unconstrained LLM extraction from fragmenting the graph” (state: superseded)

# “What replaced that decision?” (supersedes, reverse direction)
GO FROM 2001 OVER supersedes REVERSELY YIELD $$.decision.name
→ decision:memory-wiki-typed-ontology (state: active)

# A causal narrative in one query (multi-hop MATCH)
MATCH (b:bug)-[:fixed_by]->(d:decision)-[:about]->(c:concept) RETURN ...
→ junk-drawer-antipattern → memory-wiki-typed-ontology → llm-wiki-memory-graph

# What the vision depends on
GO FROM 3001 OVER depends_on YIELD $$.concept.name
→ ontology-inference, bitemporal-asof
```

**Evaluation:** directional traversal through “node → why → cause → replacement → vision →
dependency,” which is impossible with a file index, actually reads like a wiki document. This
validates the feasibility of Phase 1/2 in §8.

**Current cleanup rule:** the original PoC was additive, but its tags and edges are now managed
schema-v2 objects. Do not manually `DROP` them in a managed space: the schema-version marker would
no longer match the physical schema. Remove exact PoC seed nodes with `memory_delete` when needed.

## 8. Roadmap + Progress

- **Phase 1 (lightweight):** encode types in `rel.kind`/`note.kind` with no schema changes—concept
  validated.
- **Phase 2 (type-promotion PoC)** ✅: create separate tags/edges, directly supporting
  `LOOKUP ON module` and `GO ... OVER caused_by`. Validated in the §7 dogfood space and included
  in clean-install bootstrap (schema v2) since v0.2.0.
- **Phase 2b (guarded structured MCP)** ✅: typed upsert, relation management, normalized reads,
  guarded read-only queries, deletion, and bounded export are implemented. The server enforces
  canonical identities, lifecycle enums, endpoint matrices, and v0.2.0 60-bit VID compatibility.
- **Phase 3 (checkpoint assistance)** 🟡: an optional Claude Code hook can inject recall/capture
  reminders, while the agent following the skill performs the actual extraction and recording.
  Automatic ingestion is not implemented.
- **Phase 4 (inference-link PoC)** ✅: demonstrated core forward-chaining behavior that exposes
  unstored relationships in the dogfood space.

### Phase 3 Results — Optional Claude Code Checkpoint Hooks

The English reference snippet is committed at `adapters/claude/hooks.snippet.json`. The installer
merges it into user-level `~/.claude/settings.json` only when `--with-hooks` is requested, so the
reminders can work across projects without modifying project repositories.

- **SessionStart hook:** at session start, injects context stating that a memory graph exists and
  that non-obvious work should begin with recall and be captured at checkpoints.
- **PreToolUse(Bash) hook:** only when a command contains `git commit`, injects a reminder that
  “commit = checkpoint; verify graph capture.” It produces no output for other commands and is
  **non-blocking** (a reminder only).
- Validation covers valid JSON and the matching/non-matching shell behavior.
- Note: the installer's hook merge appends to the same event arrays, skips duplicates, and creates
  a `settings.json.bak.<timestamp>` backup before making changes.
- Limitation: hooks cannot call the MCP directly; they only inject reminders. The agent still
  performs the actual recording.

### Phase 4 Results — Ontology Inference (Measured in `claude_memory`)

ByoriDB's nGQL inference surface is
`CREATE EDGE <e>() TRANSITIVE|SYMMETRIC|INVERSE OF|SUBPROPERTY OF|CHAIN|DOMAIN/RANGE`.
Forward chaining occurs **automatically** on `INSERT EDGE`, and
`WHY <s> -> <d> OVER <e>` explains its basis. It operates per space with no configuration, but
semantics must be declared before INSERT.

Demonstration (memory-system evolution: minimal→typed→automated):

```
CREATE EDGE evolves_to() TRANSITIVE
INSERT EDGE evolves_to() VALUES 2001->2002:(), 2002->915327909379232758:()   -- store only two links in the chain

GO FROM 2001 OVER evolves_to   → both typed (asserted) + automated (inferred, not directly asserted)
WHY 2001 -> 915327909379232758 OVER evolves_to
  → status=inferred, rule=transitive, premises=[2001->2002, 2002->automated]
```

In other words, when asked “what did minimal evolve into?”, the engine materializes and stores
even the automated edge that was not directly asserted, and it can explain the basis for that
inference. This can be extended to transitive `depends_on`, and the engine's experimental
`sameAs` capability (O-8) can inform a future structured merge contract.

**The greatest risk is extraction discipline, not code.** If discipline fails, the system becomes
the junk drawer described in §3. Phases 1–4 have been shown to be technically viable; the remaining
work is operational practice that sustains the discipline, initiated through hooks and the skill.
