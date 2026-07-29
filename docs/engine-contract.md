**English** | [한국어](ko/engine-contract.md)

# ByoriDB Engine Compatibility Contract

This document specifies the **entire** ByoriDB engine surface on which Byori depends.
Engine features not listed here may change without affecting Byori compatibility. Conversely,
if a surface documented here changes, Byori must be updated before the engine tag is advanced.

- Source of truth: `mcp/byoridb_mcp.py`, `tests/test_mcp_contract.py`,
  `tests/smoke_mcp.py`,
  `manager/macos/Sources/ByoriManagerCore/ByoriGraphClient.swift`, `install.sh`, and
  `templates/run-server.sh`
- Validated pairing: **byori v0.2.x ↔ engine `v0.3.3`**
  (`ENGINE_TAG_DEFAULT` in `install.sh`)
- Validation has two layers:
  - `python3 -m unittest tests/test_mcp_contract.py` checks profiles, closed and bounded
    tool schemas, the read-query gate, canonical identities, relation rules, lifecycle values,
    VID compatibility, and decimal-string VID normalization without an engine.
  - The CI smoke test (`.github/workflows/ci.yml` → `tests/smoke_mcp.py`) downloads and
    installs the pinned engine tag, then exercises legacy notes, graph projection, typed wiki
    bootstrap and structured upsert/read/link/export/delete, v0.2.0 VID reuse, explicit edge
    deletion, guarded and cascading vertex deletion, temporal reads, and profile filtering.

## Engine Upgrade Checklist

1. Update `ENGINE_TAG_DEFAULT` in `install.sh`
2. Confirm that both the MCP contract test and CI smoke test pass; together they cover the
   complete surface below
3. Compare the surface in this document against the engine CHANGELOG diff, and update this
   document if anything changed
4. Tag a byori patch release

## 1. HTTP API

| Surface | Contract |
|---|---|
| `GET /health` | Returns 200 when the server is ready. The installer polls for up to 30 seconds |
| `POST /api/v1/session` | body `{"username","password"}` → `{"session_id": <decimal string or signed INT64>}` |
| `POST /api/v1/query` | body `{"session_id","query"}` → the result JSON below. Errors are 4xx + `{"error","code"}` |

- The current engine surface returns **`session_id` as a decimal string**. However, existing
  v0.3.3 release artifacts may return it as a signed INT64 JSON number and may require the same
  representation in queries. Clients must accept both without precision loss and send the value
  back in the same representation in which it was received. In particular, do not convert a JSON
  number to an IEEE-754 `Double`.
- A session is pinned to a space: a new session has no space until `USE <space>` is executed
  (`No space selected` error).

A successful query response from engine v0.3.3 has the following shape:

```json
{
  "results": [
    {
      "vid": 1197758748330275039,
      "name": "test2",
      "kind": "context",
      "ts": 1720000000000
    }
  ],
  "latency_ms": 1,
  "row_count": 1,
  "column_names": ["vid", "name", "kind", "ts"]
}
```

`results` is an array of row objects keyed by aliases, and `column_names` follows projection
order. `row_count` equals the length of `results`, and `latency_ms` is a non-negative integer.
An `id()` projection is a **signed INT64 represented as a JSON number**. Because a VID may exceed
2^53, clients must decode it directly as `Int64` without passing through an IEEE-754 `Double`.

### Session-Loss Semantics (Re-login Rules)

A client classifies the following as “session lost” and performs exactly one
**re-login → `USE <space>` re-pin → retry** sequence:

- HTTP `401` / `403`
- HTTP `400` **whose** lowercase error body contains `session` or `auth`
  (for example, after a server restart, a stale session appears as `400 "Invalid session"`)

Other 400 responses, including syntax errors, are not retried. If the engine changes these error
markers, client re-login will break. **Keep the words `session`/`auth` in the error body.**

### Login Lockout

The engine locks an account after consecutive failed login attempts. A 401/403 from the
**query** endpoint triggers the single session-recovery sequence above, but a 401/403 from the
fresh **login** request must fail immediately without another login retry (see
`byoridb_mcp.py._ensure_ready`).

## 2. nGQL Subset

These are all statements emitted by the MCP and the Manager graph view. Byori works as long as
this syntax parses and executes.

```ngql
CREATE SPACE IF NOT EXISTS <space>(vid_type=INT64)
USE <space>
CREATE TAG IF NOT EXISTS note(kind STRING, name STRING, body STRING, ts INT64)
CREATE EDGE IF NOT EXISTS rel(kind STRING)
CREATE TAG IF NOT EXISTS decision(name STRING, body STRING, state STRING, ts INT64)
                                               -- same pattern for all seven typed wiki tags (schema v2)
CREATE EDGE IF NOT EXISTS affects(ts INT64)    -- same pattern for all eight typed wiki edges (schema v2)
INSERT VERTEX note(kind, name, body, ts) VALUES <vid>:('<s>', '<s>', '<s>', <i64>)
INSERT VERTEX decision(name, body, state, ts) VALUES <vid>:('<s>', '<s>', '<s>', <i64>)
INSERT EDGE rel(kind) VALUES <vid>-><vid>:('<s>')
INSERT EDGE affects(ts) VALUES <vid>-><vid>:(<i64>)
MATCH (d:decision)-[:affects]->(m:module)
  RETURN d.decision.name AS decision, m.module.name AS module,
         d.decision.state AS state ORDER BY decision ASC LIMIT <n>
MATCH (n:note) WHERE (n.note.name CONTAINS '<s>' OR n.note.body CONTAINS '<s>')
  AND n.note.kind == '<s>'
  RETURN n.note.name AS name, ... ORDER BY ts DESC LIMIT <n>
MATCH (n:<tag>) WHERE n.<tag>.name == '<canonical-name>'
  RETURN id(n) AS vid, n.<tag>.name AS name, ... ORDER BY ts DESC LIMIT 2
                                                -- canonical lookup before structured writes
DELETE EDGE <edge> <source-vid>-><target-vid>
DELETE VERTEX <vid>                             -- only after explicit incident-edge deletion
FETCH PROP ON note <vid> AS OF <epoch-ms>      -- temporal read (vertices only)

MATCH (n:note)
  RETURN id(n) AS vid, n.note.name AS name, n.note.kind AS kind, n.note.ts AS ts
  ORDER BY vid ASC LIMIT 201 OFFSET 0
MATCH (n:<tag>)                                -- tag ∈ {module, decision, bug, incident, concept, entity, task}
  RETURN id(n) AS vid, n.<tag>.name AS name, n.<tag>.ts AS ts
  ORDER BY vid ASC LIMIT 201 OFFSET 0
MATCH (a:note)-[e:rel]->(b:note)
  WHERE (id(a) == <vid> OR id(a) == <vid> OR ...) AND (id(b) == <vid> OR id(b) == <vid> OR ...)
  RETURN id(a) AS src, id(b) AS dst, e.rel.kind AS kind
  ORDER BY src ASC, dst ASC LIMIT 501 OFFSET 0
MATCH (a)-[e:<edge>]->(b)                      -- edge ∈ eight typed wiki edges (excluding decided_in*)
  WHERE (id(a) == <vid> OR id(a) == <vid> OR ...) AND (id(b) == <vid> OR id(b) == <vid> OR ...)
  RETURN id(a) AS src, id(b) AS dst
  ORDER BY src ASC, dst ASC LIMIT 501 OFFSET 0
MATCH (a)-[e:<edge>]->(b)
  WHERE (id(a) == <vid> OR ...) OR (id(b) == <vid> OR ...)
  RETURN id(a) AS src, id(b) AS dst             -- MCP incident-link guard/cascade lookup
MATCH (n:note) WHERE id(n) == <vid> RETURN n.note.body AS body LIMIT 1
MATCH (n:<tag>) WHERE id(n) == <vid> RETURN n.<tag>.<body|summary> AS body LIMIT 1
                                                -- only module uses summary; all other tags use body
```

The statements above include both the structured MCP write/read surface and the Manager's
read-only graph projection surface. Structured upserts first look up an existing typed node by
its canonical `name` property; they do not assume that the stored VID matches the current hash
recipe. `memory_link(action="delete")` emits `DELETE EDGE`, while `memory_delete` emits
`DELETE VERTEX` only after its link guard has passed. Engine v0.3.3 does **not** remove incident
edges with `DELETE VERTEX`. For `cascade=true`, the MCP first enumerates every incoming and
outgoing edge, emits one `DELETE EDGE` for each, and only then deletes the vertex.

For the Manager projection, `id(n)`/`id(a)`/`id(b)` must return the vertex INT64 VID, and
`ORDER BY` must accept projection aliases (`vid`, `src`, `dst`). `LIMIT` and `OFFSET` are
non-negative integers: after sorting, the engine skips `offset` rows and then applies `limit`.
Manager queries the `note` tag, each of the seven typed wiki tags, `rel`, and each of the eight
typed wiki edge kinds separately and in parallel, then merges the results in the client.
**Measurements show that the engine's `UNION`
returns only the first MATCH branch instead of combining multiple MATCH branches, so Manager
does not depend on it.** Typed wiki edge queries use `(a)`/`(b)` without endpoint vertex tags,
because the same edge kind may connect several endpoint-tag combinations. The engine must support
matching vertex patterns without specified tags.

Every edge query first filters on the server against the VIDs selected by the current node
projection, chaining them as `id(a) == <vid> OR ...`. **Measurements show that the engine does not
support `WHERE <expr> IN [...]` and returns zero rows even for a single-element list**, so the
query must use an OR chain of `==` comparisons. Without this filter, the per-kind LIMIT 501 cutoff
can be consumed by edges whose endpoints would not be displayed. A displayable edge pushed past
row 501 would then be lost without `edgesTruncated` detecting the truncation. Manager displays at
most 200 nodes and 500 edges, requesting one extra row for each to detect truncation. The initial
node projection excludes `body`/`summary`; only the selected node is lazy-loaded by the final
query.

\* `decided_in` (decision → task) exists in the memory ontology's target schema, but the
schema v2 migration in `byoridb_mcp.py` does not yet contain its `CREATE EDGE`. Engine v0.3.3
currently returns an empty
result for an undefined edge tag, but Manager must not treat that behavior as a compatibility
contract because it would silently hide data. If `decided_in` becomes necessary—under the memory
ontology's promotion criterion of “having been forced into another type at least three times”—add
a separate schema migration before adding it to Manager's edge kinds.

The typed wiki statements are emitted by the MCP's schema v2 bootstrap
(`byoridb_mcp.py._migrate`) and by the smoke test's typed round trip. The schema version is stored
as a `note` vertex with the reserved name `byori:schema-version` (using the same note INSERT
surface shown above).

`memory_query` is a raw nGQL escape hatch, so users can issue `GO`/`LOOKUP` and other statements,
but **the contract enforced by the smoke gate guarantees only the subset above**.

### String-Literal Escaping

The MCP emits only three escape sequences inside single-quoted literals: `\\`, `\'`, and `\n`.
The engine parser must interpret all three.

### VID

- The space uses `vid_type=INT64`.
- **New Byori nodes use only non-negative VIDs (`0 ..= 2^63-1`)**: the current recipe reads the
  first eight SHA-1 bytes of `name` as unsigned and applies
  `& 0x7FFF_FFFF_FFFF_FFFF`. Engine v0.3.3's INSERT planner rejects negative VIDs. Even after
  the engine is fixed, Byori will retain this recipe so already-created VIDs remain stable.
- The v0.2.0 typed-wiki instructions used a different 60-bit recipe,
  `int(sha1(name).hexdigest()[:15], 16)`. Before a structured upsert, Byori searches by exact
  typed canonical `name` and reuses the actual stored VID. It therefore updates a v0.2.0 node in
  place instead of forking it at the current 63-bit VID. More than one match is treated as an
  ambiguous duplicate and rejected. Only a genuinely new canonical node receives the current
  63-bit VID.

## 3. MCP Tool and Profile Contract

The MCP offers nine tools in the default `legacy` profile. The `safe` profile exposes eight:
it hides and refuses dispatch of only `memory_query`. It still exposes all structured mutation
tools and the legacy `memory_remember` note writer, so **safe is not a read-only mode, an
authorization boundary, or a sandbox**.

| Tool | `legacy` | `safe` | Contract |
|---|:---:|:---:|---|
| `memory_remember` | yes | yes | Upsert a legacy `note`; optionally create `relates_to` edges |
| `memory_recall` | yes | yes | Read legacy notes by substring and/or kind, newest first |
| `memory_query` | yes | no | Unrestricted raw nGQL compatibility escape hatch |
| `memory_query_read` | yes | yes | Run one statement admitted by the read-query gate below |
| `memory_wiki_upsert` | yes | yes | Validate and upsert one canonical typed-wiki node |
| `memory_link` | yes | yes | Upsert or delete one validated relationship between existing endpoints |
| `memory_read` | yes | yes | Return normalized legacy or typed nodes, optionally with incident links |
| `memory_delete` | yes | yes | Delete one exact node; linked nodes require `cascade=true` |
| `memory_export` | yes | yes | Return a bounded page of normalized nodes and optional outgoing links |

All nine input schemas reject undeclared fields. Their shared hard limits are:

| Input | Contract |
|---|---|
| `name` | 1–256 characters; typed names must also match `^[a-z][a-z0-9_]*:[A-Za-z0-9][A-Za-z0-9._-]*$` and the prefix must equal `type` |
| `kind`, `state` | 1–64 characters; `kind` defaults to `note` for `memory_remember` |
| `body` | 1–65,536 characters |
| read `text` | 1–4,096 characters |
| `ngql` | 1–16,384 characters |
| `relates_to` | at most 64 names, each subject to the name limit |
| recall/read `limit` | 1–100; default 20 |
| export `limit` | 1–500; default 100 |
| export `offset` | 0–100,000; default 0 |

The normalized node-type set is `note`, `module`, `decision`, `bug`, `incident`, `concept`,
`entity`, and `task`. `memory_wiki_upsert` accepts only the seven non-`note` wiki types;
`memory_read`, `memory_delete`, and link endpoints also accept `note`. Boolean inputs must be
actual JSON booleans. `memory_read.include_links` and `memory_delete.cascade` default to `false`;
`memory_export.include_links` defaults to `true`. The reserved `byori:schema-version` note cannot
be deleted.

Typed node lifecycle values are closed enums: decision `state` is `active` or `superseded`;
bug `state` is `open`, `fixed`, or `known`; task `state` is `open`, `in_progress`, `blocked`,
or `done`; incident `resolved` is a boolean (stored in schema v2 as the string `true`/`false`
and normalized back to a boolean). New decision, bug, and task nodes default respectively to
`active`, `open`, and `open`; a new incident defaults to unresolved. An update that omits its
lifecycle field preserves the existing valid value. Module input `body` maps to the engine's
`summary` property.

`memory_link` defaults to `action="upsert"`; its endpoints must already exist. The validated
relations are `part_of` (module→module), `depends_on` (module→module), `affects`
((decision|bug)→module), `caused_by` ((incident|bug)→(bug|decision|module)), `fixed_by`
((bug|incident)→(decision|task)), `supersedes` (decision→decision), and `about`
((task|incident)→(module|entity|concept)). `relates_to` accepts any node types; a `note`
endpoint may participate only in `relates_to`.

These endpoint-existence and relation-matrix guarantees apply to `memory_link`. The compatibility
`memory_remember(relates_to=[...])` path preserves its legacy behavior and does not verify that
each target note already exists.

### Read-Query Gate

`memory_query_read` accepts a single statement beginning with `MATCH`, `FETCH`, `GO`, `LOOKUP`,
`SHOW`, or `WHY`. Outside quoted string literals it rejects comments (`--`, `//`, `/* ... */`,
or `#`), pipelines (`|`), semicolons, and any occurrence of `ALTER`, `CREATE`, `DELETE`, `DROP`,
`GRANT`, `INSERT`, `REVOKE`, `UPDATE`, `UPSERT`, or `USE`. The gate is a reduced raw-query
surface, not an authorization parser or security boundary.

### Result Normalization and Export

Structured tool results return `vid`, `src`, `dst`, `source_vid`, and `target_vid` as decimal
strings, recursively, so JSON consumers do not lose INT64 precision. `memory_query_read` applies
the same normalization to engine rows. The unrestricted legacy `memory_query` preserves the
engine's raw JSON representation, and `memory_remember` retains its legacy numeric `vid` result.

`memory_export` defaults to including links and reports `schema_version`, `space`, `offset`,
`next_offset`, and `has_more`. It is a bounded, best-effort inspection page, not a transactional
backup snapshot. Results are collected per type before global sorting, so deep offset pages can
shift or omit candidates even without concurrent writes; writes introduce additional movement.
The reserved schema-version note is excluded, and included links are outgoing from page nodes.

## 4. Temporal Semantics (Engine v0.3.3)

- `INSERT VERTEX` overwrites the current view and appends a history version. This is why
  re-remembering the same `name` creates bitemporal history.
- The only public temporal read is vertex `FETCH ... AS OF <epoch-ms>`. Edge AS OF, temporal
  MATCH/GO, and BETWEEN are not supported.
- The current/history dual write is **not atomic**, and writing the same entity twice within one
  millisecond risks a history-key collision. The practical risk is low with one MCP process, but
  the engine must be improved before parallel writers are introduced.

## 5. Environment Variable Contract

| Variable | Consumer | Meaning |
|---|---|---|
| `BYORIDB_ROOT_PASSWORD` | Server, MCP | Root password (single-`_` pattern), stored in `~/.byoridb/env` with mode 600 |
| `BYORIDB__STORAGE__DATA_PATHS` | Server | Data path (double-`__` configuration-tree pattern) |
| `BYORIDB__SERVER__HTTP_ADDR` / `BYORIDB__SERVER__GRAPH_ADDR` | Server | Bind addresses |
| `BYORIDB_HTTP` / `BYORIDB_USER` / `BYORIDB_PASSWORD` | MCP | Engine connection (`ROOT_PASSWORD` takes precedence over `PASSWORD`) |
| `BYORIDB_MEMORY_SPACE` | MCP | Logical memory-space name (default: `claude_memory`); must match `^[A-Za-z_][A-Za-z0-9_]{0,63}$` |
| `BYORIDB_MCP_PROFILE` | MCP | Case-sensitive `legacy` (default, 9 tools) or `safe` (8 tools; hides only `memory_query`) |

Note: the single-`_` secret convention and double-`__` configuration-tree convention coexist;
this is an engine convention.

`BYORIDB_MEMORY_SPACE` selects a logical namespace inside the same engine. It is not a tenant or
authorization boundary: MCP processes normally reuse the same root credential and can target
another valid space if their process configuration permits it. Run separate engine instances
and credentials across trust boundaries.

## 6. Release Artifact Contract

- Engine release asset name: `byoridb-<tag>-<target>.tar.gz`; its contents must include
  `byoridb-server` and may optionally include `byoridb-cli`.
- Targets: `aarch64-apple-darwin`, `x86_64-apple-darwin`, and
  `x86_64-unknown-linux-gnu`.
- Changing this convention breaks download URL construction in `install.sh`.
