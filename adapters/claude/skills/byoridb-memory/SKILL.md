---
name: byoridb-memory
description: >-
  Persistent, cross-session memory backed by a local ByoriDB graph database (via
  the `byoridb` MCP server). Use to REMEMBER durable facts — decisions and their
  rationale, module/entity relationships, recurring bugs, user preferences,
  project context — and to RECALL them at the start of a task or when the user
  refers to something from a past session ("우리 저번에", "지난번", "기억나?",
  "what did we decide about", "왜 이렇게 했더라"). Prefer this over re-deriving or
  re-asking. Backed by a graph + bitemporal history, so it also answers "what did
  we know/decide about X as of <past time>". Two layers: quick notes for standalone
  facts, and a typed knowledge-graph ("wiki") for structural knowledge whose value
  is in its relationships. This is the record for durable project knowledge: when the
  host also has its own file-based memory, keep the knowledge here and let that store
  hold pointers at most.
---

# ByoriDB Memory

A local, always-on ByoriDB instance is your long-term memory. You reach it through
the **`byoridb` MCP server** over this project's memory space, which the server
resolves from the project itself.

## Where knowledge lives when the host has its own memory

**This graph is the record.** Many hosts ship a file-based memory whose index is loaded
into context automatically; that convenience is exactly why knowledge ends up there by
default and this space stays connected but empty. Measured on a real project: twenty notes
in the host's file store, nothing here.

So: durable knowledge is written **here**. A host's file store may keep a one-line pointer
("this project's memory is in ByoriDB"), and nothing else worth keeping. Do not maintain the
same fact in both — two copies drift, and a stale memory is read with the same confidence as
a true one.

**If both already hold content**, that is a migration, not a steady state:
1. Read the file store, and write each durable fact here with the right type and edges.
2. Correct it as you go. Facts that sat in a file for weeks are usually stale in places —
   fix them rather than importing them verbatim.
3. Replace the file entries with a pointer, or delete them.
4. Do not sync the two afterwards.

**If recall here comes back empty** for a project that plainly has history, assume the
knowledge is in another store and go look, rather than starting a parallel copy. The MCP
server's startup line reports how many memories this space holds, precisely so an empty one
is visible. Both layers below are bootstrapped automatically: on startup the
MCP server migrates the space to the current memory schema (v2 = notes + typed wiki),
recording the version in the reserved note `byori:schema-version`.

Prefer the validated structured surface:

- **`memory_remember(name, kind?, body, relates_to?)`** — store/update a **note** vertex.
- **`memory_recall(text?, kind?, limit?)`** — retrieve **notes**, most-recent first.
- **`memory_wiki_upsert(type, name, body, state?, resolved?)`** — create/update a typed node;
  the server validates its canonical name and derives its stable VID.
- **`memory_link(action?, relation, source, target)`** — create/update or delete a validated edge.
- **`memory_read(type?, name?, text?, limit?, include_links?)`** — read normalized notes/wiki nodes.
- **`memory_query_read(ngql)`** — one validated read-only traversal or temporal query.
- **`memory_delete(...)` / `memory_export(...)`** — explicit maintenance operations.

`memory_query` is a legacy unrestricted raw-nGQL escape hatch. Do not use it when a structured
tool or `memory_query_read` is sufficient; it is unavailable when the MCP runs in `safe` profile.

## Two layers — pick by whether relationships matter

| | Layer 1 — Notes | Layer 2 — Typed Wiki |
|---|---|---|
| For | standalone facts, prefs, one-off gotchas | structural knowledge whose value is its **relationships** |
| Node | single `note` tag | typed tags: `module / decision / bug / incident / concept / entity / task` |
| Edge | generic `rel` | typed: `part_of / depends_on / affects / caused_by / fixed_by / supersedes / about / relates_to` |
| Write | `memory_remember` | `memory_wiki_upsert` + `memory_link` |
| Read | `memory_recall` | `memory_read`; `memory_query_read` for traversal/`AS OF` |
| Availability | schema on every fresh install | bootstrapped automatically since schema v2 (MCP startup migration) |

Rule of thumb: if the thing **connects to other things** (a decision that affects
modules and supersedes an older decision; a bug caused by X and fixed by Y), use the
wiki layer so recall becomes a *traversal*. If it's an isolated fact (a preference,
a lone gotcha), a note is enough. Do NOT record the same thing in both layers.

---

## Layer 1 — Notes (quick facts)

- A `note` vertex keyed by a **stable `name`** — reusing the same `name` UPDATES it
  (bitemporal version kept). Names are stable identifiers, not sentences:
  `pref:korean-responses`, `context:test-serial-execution`.
- `kind`: `decision | module | bug | entity | preference | context`.
- `relates_to` (list of note names) creates generic `rel` edges.

```
memory_remember(name="pref:korean-responses", kind="preference",
  body="Always respond in Korean. Preserve technical terms and identifiers as written.")
memory_recall(text="korean")
```

---

## Layer 2 — Typed Wiki (structural knowledge)

The graph you build here reads like a wiki: from any node, follow typed edges to
learn *why it is the way it is*.

> **Availability:** the MCP server bootstraps this schema automatically (schema v2)
> on fresh installs and migrates older spaces on startup. If you suspect a stale
> pre-v2 MCP, `memory_query_read(ngql="SHOW TAGS")` confirms; never invent ad-hoc typed schema.

### Node tags & properties
- `module(name, summary, ts)` — code module/crate/subsystem
- `decision(name, body, state, ts)` — `state`: `active | superseded`; `body` includes the *why*
- `bug(name, body, state, ts)` — `state`: `open | fixed | known`
- `incident(name, body, resolved, ts)` — API `resolved`: boolean; engine storage: `"true" | "false"`
- `concept(name, body, ts)` — domain/design concept
- `entity(name, body, ts)` — data entity (dogfooding subjects)
- `task(name, body, state, ts)` — `state`: `open | in_progress | blocked | done`

### Edge types (directional)
- `part_of` · `depends_on` : module → module
- `affects` : decision/bug → module
- `caused_by` : incident/bug → bug/decision/module
- `fixed_by` : bug/incident → decision/task
- `supersedes` : decision → decision (mark the old one `state="superseded"`)
- `about` : task/incident → module/entity/concept
- `relates_to` : any → any (weak link; don't overuse)

### Canonical names and server-derived VIDs

Canonical names are `<type>:<stable-slug>`, never a sentence —
`module:byoridb-executor`, `decision:use-redb`, `bug:redb-repair-crashloop`,
`incident:aks-startup-probe`, `concept:llm-wiki-memory-graph`, `task:g2-distributed`.
The stable slug starts with a letter or digit and may otherwise contain letters, digits, `.`,
`_`, and `-`. `memory_wiki_upsert` checks that the name prefix matches the type. New nodes use
a server-derived non-negative 63-bit VID returned as a decimal string. Existing canonical typed
nodes created with Byori v0.2.0's 60-bit recipe are found by name and keep their original VID;
reusing the canonical name updates that node and preserves its bitemporal history.

### Write with structured tools

```
memory_wiki_upsert(type="decision", name="decision:use-redb",
  body="Adopt pure-Rust redb; remove the RocksDB C++ toolchain.", state="active")
memory_wiki_upsert(type="module", name="module:byoridb-kvstore",
  body="Embedded redb KV with current-view and history tables.")
memory_link(relation="affects",
  source={"type":"decision","name":"decision:use-redb"},
  target={"type":"module","name":"module:byoridb-kvstore"})
```

### Read — recall becomes traversal

```
# Find normalized decisions, optionally with nearby edges
memory_read(type="decision", text="redb", include_links=true)

# Read-only graph traversal when normalized lookup is not enough
memory_query_read(ngql="MATCH (d:decision)-[:affects]->(m:module) RETURN d.decision.name, m.module.name")

# Temporal read, using the decimal VID returned by memory_read/upsert
memory_query_read(ngql="FETCH PROP ON decision <vid> AS OF <epoch_ms>")
```

`memory_query_read` accepts one statement beginning with `MATCH`, `FETCH`, `GO`, `LOOKUP`,
`SHOW`, or `WHY`. Outside quoted literals, it rejects mutations, `USE`, comments, pipelines,
semicolons, and multiple statements. Prefer `memory_read` whenever it can express the lookup.

### Capture recipe — record the causal chain, not just the fact

When recording an **incident** or a resolved **bug**, the value later is the *why*, so
capture the chain, not a lone symptom:

1. Ask "why" down to a **root cause** (don't stop at the surface symptom), and link the
   incident/bug `caused_by` → that root (a `bug` / `decision` / `module` node).
2. Link `fixed_by` → the `decision` or `task` that actually resolved it (separate the
   *immediate* patch from the *permanent* fix if they differ).
3. Link `about` / `affects` → what it touched.

Then "why did this happen?" is one read with links or traversal over `caused_by`, and "what
prevented it from recurring?" follows `fixed_by`. A fact with no causal edges is a dead end.

### Gotchas (measured behavior)
- **`memory_remember` VIDs are non-negative 63-bit values** — the SHA-1 hash is read
  as unsigned and masked to 63 bits, so every name is valid (this resolves the old
  negative-hash rejection issue).
- **`status` is reserved** — use `state` (or `resolved`) for state properties.
- **`memory_recall` reads only the `note` tag** — query typed nodes with `memory_read`.
- **Structured VIDs are decimal strings** — raw engine projections and legacy note responses
  may still expose JSON INT64 numbers; never round-trip either through an IEEE-754 `Double`.
- **Lifecycle fields are explicit** — use `bug.state="fixed"`, `task.state="done"`, or
  `incident.resolved=true` when recording a confirmed fix or closure.
- **`memory_export` is bounded diagnostics, not a backup snapshot** — pagination is not
  transactional, and deep pages can shift because results are assembled per node type before
  global sorting, even when no concurrent write occurs.
- **Deletion is destructive** — use `memory_delete` only after the user explicitly confirms the
  exact type/name. If links exist, get separate confirmation before `cascade=true`; cascade can
  remove every incoming and outgoing relationship connected to that node.

---

## When to REMEMBER

Record durable knowledge the moment it's established — never make the user say it
twice. Route by type:

- Decision + *why* → wiki `decision`, `affects` the modules, `supersedes` any prior.
- Recurring bug/gotcha + resolution → wiki `bug`, `caused_by` / `fixed_by`.
- Operational incident + root cause → wiki `incident`, `caused_by` / `about`.
- Non-obvious structural fact → wiki `module`/`concept` + edges.
- A lone preference or isolated fact → note (Layer 1) regardless of Layer 2 availability.

**Write at checkpoints, not every turn** — end of a task/track, a milestone, PR creation or merge,
a release, incident resolution, or when the user says "remember this". Per-turn extraction turns the
graph into a searchable junk drawer (the exact failure mode this schema exists to prevent). A
checkpoint is two passes, not one: "what did we learn here worth keeping?" **and "which recorded
facts did this change make wrong?"** A merged PR, a shipped release, or a fixed bug usually falsifies
something already in the graph — update those nodes in the same pass, by name, so they stay the
answer rather than becoming a trap.

**Classify scope before writing.** For each learning, decide how broadly it applies:
- **Reusable pattern** (recurs, would help on other work) → record generalized wording in
  a `concept`/`decision`, linked broadly. Strip project-specific specifics so it transfers.
- **Project-specific fact** → a scoped node named with the project prefix
  (`module:<proj>-x`, `bug:<proj>-y`); don't inflate it into a universal claim.
- **Neither** (transient, one-off) → don't record it at all.

Never write secrets, credentials, or one-off chatter into memory — generalize a learning
to its transferable shape, or drop it.

## When to RECALL

- **At the start of a non-trivial task or work phase** — `memory_recall` for notes,
  and `memory_read(include_links=true)` or `memory_query_read` to traverse the wiki around the relevant
  module/topic. Pull prior decisions, known bugs, and past
  incidents for that area *first*, so you don't re-derive a settled decision or repeat
  a resolved mistake.
- When the user references the past ("what did we decide last time?", "why did we do that?", "remember?").
- Before re-deriving something that feels like it was decided before.
- Temporal: "what did we know when we made that decision?" → `memory_query_read` with
  `FETCH PROP ON <tag> <vid> AS OF <epoch_ms>`.

## Anti-patterns
- **"Let's skip it this time"** — skipping capture at a checkpoint → the next session repeats the
  same mistake. If you'd have to re-learn it, record it now.
- **Capturing everything** — over-capture is the junk-drawer failure. One clear fact per node.
- **Symptom without root cause** — a bug/incident with no `caused_by`/`fixed_by` is a dead
  end later. Record the chain (see the causal-capture recipe).
- **Silently overwriting a decision** — when a decision changes, mark the old one
  `state="superseded"` and add the new one with a `supersedes` edge. Preserve the trail;
  bitemporal history + `AS OF` depends on it.
- **Inflating a one-off into a universal rule** (or burying a reusable pattern in a
  project-scoped node) — classify scope honestly before writing.
- **Volatile state in a body** — "the fix is on an unreleased branch", "the app is still on 0.8.9",
  "not yet filed as an issue" all expire. Prefer the durable shape (what the hazard is, why it
  happens, what it costs); when current state genuinely matters, date it in the sentence and correct
  it at the next checkpoint. A stale node is worse than a missing one: it is read with the same
  confidence as a true one, and the next session acts on it.

## Hygiene rules
- Canonical `<type>:<slug>` names, never sentences. Same name = update, not a dup.
- One clear fact per node. No transient chatter.
- Before creating a node, use `memory_read` to find an existing canonical one — merge, don't fork.
- Choose the narrowest true edge type; `relates_to` is the last resort.
- Don't double-record across both layers.
