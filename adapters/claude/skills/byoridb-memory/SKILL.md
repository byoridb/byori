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
  is in its relationships. Complements (does not replace) the file-based project notes.
---

# ByoriDB Memory

A local, always-on ByoriDB instance is your long-term memory. You reach it through
the **`byoridb` MCP server**, which exposes three tools over a dedicated
`claude_memory` space. The basic notes schema is bootstrapped automatically;
the typed wiki schema is currently a dogfood prototype and is not created on a
fresh install:

- **`memory_remember(name, kind, body, relates_to?)`** — store/update a **note** vertex.
- **`memory_recall(text?, kind?, limit?)`** — retrieve **notes**, most-recent first.
- **`memory_query(ngql)`** — raw nGQL. The ONLY way to read/write the typed wiki layer,
  and the tool for traversals, aggregations, and temporal (`AS OF`) reads.

## Two layers — pick by whether relationships matter

| | Layer 1 — Notes | Layer 2 — Typed Wiki |
|---|---|---|
| For | standalone facts, prefs, one-off gotchas | structural knowledge whose value is its **relationships** |
| Node | single `note` tag | typed tags: `module / decision / bug / incident / concept / entity / task` |
| Edge | generic `rel` | typed: `depends_on / affects / caused_by / fixed_by / supersedes / about / relates_to` |
| Write | `memory_remember` (vid auto-hashed) | `memory_query` + `INSERT VERTEX/EDGE` (vid you supply) |
| Read | `memory_recall` | `memory_query` (`LOOKUP / FETCH / GO / MATCH`) |
| Availability | schema on every fresh install; known negative-VID write blocker below | only in a space where the typed schema was prepared manually |

Rule of thumb: if the thing **connects to other things** (a decision that affects
modules and supersedes an older decision; a bug caused by X and fixed by Y), use the
wiki layer **only when its schema is already available** so recall becomes a *traversal*.
On a clean install, fall back to Layer 1 rather than creating ad-hoc typed schema. If
it's an isolated fact (a preference, a lone gotcha), a note is enough. Do NOT record
the same thing in both layers.

---

## Layer 1 — Notes (quick facts)

- A `note` vertex keyed by a **stable `name`** — reusing the same `name` UPDATES it
  (bitemporal version kept). Names are stable identifiers, not sentences:
  `pref:korean-responses`, `context:test-serial-execution`.
- `kind`: `decision | module | bug | entity | preference | context`.
- `relates_to` (list of note names) creates generic `rel` edges.

```
memory_remember(name="pref:korean-responses", kind="preference",
  body="항상 한국어로 응답. 기술 용어/식별자는 원문 유지.")
memory_recall(text="korean")
```

---

## Layer 2 — Typed Wiki (structural knowledge)

The graph you build here reads like a wiki: from any node, follow typed edges to
learn *why it is the way it is*.

> **Current availability:** a fresh installer run creates only `note` and `rel`.
> Do not issue the typed `INSERT` examples below until the target space already
> contains the typed schema from the Memory-Wiki PoC/manual setup. Until automatic
> bootstrap ships, use Layer 1 on a clean install instead of inventing schema ad hoc.

### Node tags & properties
- `module(name, summary, ts)` — code module/crate/subsystem
- `decision(name, body, state, ts)` — `state`: `active | superseded`; `body` includes the *why*
- `bug(name, body, state, ts)` — `state`: `open | fixed | known`
- `incident(name, body, resolved, ts)` — `resolved`: `"true" | "false"`
- `concept(name, body, ts)` — domain/design concept
- `entity(name, body, ts)` — data entity (dogfooding subjects)
- `task(name, body, state, ts)` — work/track item

### Edge types (directional)
- `part_of` · `depends_on` : module → module
- `affects` : decision/bug → module
- `caused_by` : incident/bug → bug/decision/module
- `fixed_by` : bug/incident → decision/task
- `supersedes` : decision → decision (mark the old one `state="superseded"`)
- `about` : task/incident → module/entity/concept
- `relates_to` : any → any (weak link; don't overuse)

### Canonical name → stable vid

`INSERT VERTEX` needs an **INT64 vid** (string vids are unsupported here). Derive a
**stable** vid from the canonical name so that re-inserting the same name UPDATES the
same node (and stacks a bitemporal version). Run this once per node via Bash:

```bash
python3 -c "import hashlib,sys; print(int(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:15],16))" "decision:use-redb"
# → 739708277206059021 (60-bit, fits i64, collision-negligible; same name ⇒ same vid ⇒ update)
```

Canonical names: `<type>:<stable-slug>`, never a sentence —
`module:byoridb-executor`, `decision:use-redb`, `bug:redb-repair-crashloop`,
`incident:aks-startup-probe`, `concept:llm-wiki-memory-graph`, `task:g2-distributed`.

### Write (memory_query)

```
# vid_dec = hash("decision:use-redb"); vid_kv = hash("module:byoridb-kvstore")
INSERT VERTEX decision(name, body, state, ts)
  VALUES <vid_dec>:("decision:use-redb", "순수 Rust redb 채택. RocksDB C++ 툴체인 제거.", "active", <epoch_ms>)
INSERT VERTEX module(name, summary, ts)
  VALUES <vid_kv>:("module:byoridb-kvstore", "임베디드 redb KV. 현재뷰+이력 테이블.", <epoch_ms>)
INSERT EDGE affects(ts) VALUES <vid_dec>-><vid_kv>:(<epoch_ms>)
```

### Read — recall becomes traversal

```
# 모든 결정 나열 (LOOKUP은 prop을 JSON 블롭으로 반환)
LOOKUP ON decision YIELD decision.name

# 깔끔한 컬럼이 필요하면 FETCH/GO 사용
FETCH PROP ON decision <vid> YIELD decision.body, decision.state

# "이 모듈이 왜 이렇게 됐나" — module ← affects 역방향
GO FROM <module_vid> OVER affects REVERSELY YIELD $$.decision.body

# "그 결정을 무엇이 대체했나"
GO FROM <old_decision_vid> OVER supersedes REVERSELY YIELD $$.decision.name

# 인과 서사 한 방에
MATCH (b:bug)-[:fixed_by]->(d:decision)-[:about]->(c:concept)
  RETURN b.bug.name, d.decision.name, c.concept.name
```

### Capture recipe — record the causal chain, not just the fact

When recording an **incident** or a resolved **bug**, the value later is the *why*, so
capture the chain, not a lone symptom:

1. Ask "why" down to a **root cause** (don't stop at the surface symptom), and link the
   incident/bug `caused_by` → that root (a `bug` / `decision` / `module` node).
2. Link `fixed_by` → the `decision` or `task` that actually resolved it (separate the
   *immediate* patch from the *permanent* fix if they differ).
3. Link `about` / `affects` → what it touched.

Then "왜 이게 터졌나?" is one traversal — `GO FROM <incident_vid> OVER caused_by` — and
"무엇이 재발을 막았나?" is `GO ... OVER fixed_by`. A fact with no causal edges is a dead end.

### Gotchas (실측)
- **Known blocker in `memory_remember`** — its signed SHA-1 name hash can produce a
  negative VID, while the current INSERT planner accepts only an integer literal and
  rejects unary-negative expressions. Some names therefore fail to write until the
  hash is constrained to a nonnegative i64 or the planner folds negative literals.
  Do not rename the same fact just to retry; that fragments canonical identity.
- **`status`는 예약어** → 상태 property명은 `state`(또는 `resolved`)를 쓴다.
- **문자열 vid 미지원** → 위 hash 레시피로 INT64 vid를 만들어 명시적으로 넣는다.
- **`memory_recall`은 `note` tag만 읽는다** → 타입드 노드는 `memory_query`로만 조회된다.
- **`LOOKUP ... YIELD`는 prop을 JSON 블롭으로 반환** → 개별 컬럼은 `FETCH`/`GO`로.

---

## When to REMEMBER

Record durable knowledge the moment it's established — never make the user say it
twice. Before using Layer 2, check its availability with `memory_query("SHOW TAGS")`
and `memory_query("SHOW EDGES")`. If the typed tags/edges are absent, route the same
knowledge to one canonical Layer 1 note; do not invent partial schema during the task.
When Layer 2 is available, route by type:

- Decision + *why* → wiki `decision`, `affects` the modules, `supersedes` any prior.
- Recurring bug/gotcha + resolution → wiki `bug`, `caused_by` / `fixed_by`.
- Operational incident + root cause → wiki `incident`, `caused_by` / `about`.
- Non-obvious structural fact → wiki `module`/`concept` + edges.
- A lone preference or isolated fact → note (Layer 1) regardless of Layer 2 availability.

**Write at checkpoints, not every turn** — end of a task/track, a milestone, PR creation,
incident resolution, or when the user says "기억해". Per-turn extraction turns the graph
into a searchable junk drawer (the exact failure mode this schema exists to prevent). A
checkpoint is also the moment to do a quick pass: "what did we learn here worth keeping?"

**Classify scope before writing.** For each learning, decide how broadly it applies:
- **Reusable pattern** (recurs, would help on other work) → record generalized wording in
  a `concept`/`decision`, linked broadly. Strip project-specific specifics so it transfers.
- **Project-specific fact** → a scoped node named with the project prefix
  (`module:<proj>-x`, `bug:<proj>-y`); don't inflate it into a universal claim.
- **Neither** (transient, one-off) → don't record it at all.

Never write secrets, credentials, or one-off chatter into memory — generalize a learning
to its transferable shape, or drop it.

## When to RECALL

- **At the start of a non-trivial task or work phase** — `memory_recall` for notes. When
  the typed schema exists, also use `memory_query` (`LOOKUP`/`GO`/`MATCH`) to traverse
  the wiki around the relevant module/topic. Pull prior decisions, known bugs, and past
  incidents for that area *first*, so you don't re-derive a settled decision or repeat
  a resolved mistake.
- When the user references the past ("저번에 정한", "그때 왜", "기억하지?").
- Before re-deriving something that feels like it was decided before.
- Temporal: "그 결정 당시엔 뭘 알았지?" → `FETCH PROP ON <tag> <vid> AS OF <epoch_ms>`.

## Anti-patterns
- **"이번엔 그냥 넘기자"** — skipping capture at a checkpoint → the next session repeats the
  same mistake. If you'd have to re-learn it, record it now.
- **Capturing everything** — over-capture is the junk-drawer failure. One clear fact per node.
- **Symptom without root cause** — a bug/incident with no `caused_by`/`fixed_by` is a dead
  end later. Record the chain (see the causal-capture recipe).
- **Silently overwriting a decision** — when a decision changes, mark the old one
  `state="superseded"` and add the new one with a `supersedes` edge. Preserve the trail;
  bitemporal history + `AS OF` depends on it.
- **Inflating a one-off into a universal rule** (or burying a reusable pattern in a
  project-scoped node) — classify scope honestly before writing.

## Hygiene rules
- Canonical `<type>:<slug>` names, never sentences. Same name = update, not a dup.
- One clear fact per node. No transient chatter.
- Before creating a node, recall/LOOKUP for an existing one — merge, don't fork.
- Choose the narrowest true edge type; `relates_to` is the last resort.
- Don't double-record across both layers.
