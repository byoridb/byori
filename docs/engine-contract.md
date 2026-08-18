**English** | [한국어](ko/engine-contract.md)

# ByoriDB Engine Compatibility Contract

This document specifies the **entire** ByoriDB engine surface on which Byori depends.
Engine features not listed here may change without affecting Byori compatibility. Conversely,
if a surface documented here changes, Byori must be updated before the engine tag is advanced.

- Source of truth: `mcp/byoridb_mcp.py`, `tests/test_mcp_contract.py`,
  `tests/smoke_mcp.py`,
  `manager/macos/Sources/ByoriManagerCore/ByoriGraphClient.swift`, `install.sh`, and
  `templates/run-server.sh`
- Validated pairing: **byori v0.2.x ↔ engine `v0.4.0`**
  (`ENGINE_TAG_DEFAULT` in `install.sh`)
- What each install path takes: the macOS app's install button passes
  `--engine-tag latest`, so a user's engine tracks the newest engine release and no
  longer waits for a byori release. `ENGINE_TAG_DEFAULT` remains the validated
  pairing, what CI installs, and the fallback when the release lookup fails.
  **Consequence:** a breaking engine release reaches app users before the checklist
  below runs, so this client has to survive an engine newer than the one it was
  validated against — the surfaces here are the ones that must not be broken silently.
- Validation has two layers:
  - `python3 -m unittest tests/test_mcp_contract.py` checks profiles, closed and bounded
    tool schemas, the read-query gate, canonical identities, relation rules, lifecycle values,
    VID compatibility, and decimal-string VID normalization without an engine.
  - The CI smoke test (`.github/workflows/ci.yml` → `tests/smoke_mcp.py`) downloads and
    installs the pinned engine tag, then exercises legacy notes, graph projection, typed wiki
    bootstrap and structured upsert/read/link/export/delete, v0.2.0 VID reuse, explicit edge
    deletion, guarded and cascading vertex deletion, temporal reads, and profile filtering.

Product-model boundary: the Byori macOS app presents
**Project → Source Tree/Worktree → Task → Session**, and the user chooses one coding agent
and model per Session. That operational tree is app state, not an engine schema contract.
Settings is a supporting surface for installation, integration, and diagnostics. This
engine contract covers the project-scoped ByoriDB knowledge graph consumed by the Context
inspector; all Source Trees/Worktrees, Tasks, Sessions, and agent choices in one Project
share that graph space.

## Engine Upgrade Checklist

1. Update `ENGINE_TAG_DEFAULT` in `install.sh` (CI's pin and the offline fallback;
   app installs already take the new release)
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
| `POST /api/v1/query` | body `{"session_id","query"}` → the result JSON below. Errors are 4xx + `{"error","code"}`. Optional `"read_only": true` makes the engine refuse a statement that would write |
| `DELETE /api/v1/session` | session id in the `X-ByoriDB-Session-Id` header → signs that session out. Byori calls it on MCP exit instead of leaving the session to its TTL |

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

Engine 0.4.0 makes the three query failure classes distinct by status, so the status alone decides
what a client does:

| Status | Code | Meaning | Client action |
|---:|---|---|---|
| `401` | `SESSION_EXPIRED` | The session is gone | Exactly one **re-login → `USE <space>` re-pin → retry** |
| `403` | `PERMISSION_DENIED` | The session is valid and stays valid | Surface it. **Never re-login** |
| `400` | `QUERY_ERROR` | The statement itself is wrong | Do not retry |
| `413` | `QUERY_TOO_LARGE` | Over 1 MiB | Do not retry |

`403` must not be retried. Re-authenticating cannot grant a role the session does not have, and
each attempt is spent against the login throttle below. Before 0.4.0 an authorization denial
arrived as `400 "…Authentication failed: Permission denied…"`, and the client rule that retried any
400 containing `auth` existed for exactly that reason; it is gone.

The `session` marker on a `400` is still honoured, because an engine older than 0.4.0 reports a
restarted server's stale session that way and a user can be on one until they reinstall. **Keep the
word `session` in that error body.** `auth` is deliberately not a marker.

### Login Lockout

The engine throttles login verification after consecutive failures. A `401` from the **query**
endpoint triggers the single session-recovery sequence above, but a `401` from the fresh **login**
request must fail immediately without another login retry (see `byoridb_mcp.py._ensure_ready`).
A `403` never causes a login attempt at all.

## 2. nGQL Subset

These are all statements emitted by the MCP and the Byori macOS app's Context inspector.
Byori works as long as this syntax parses and executes.

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

The statements above include both the structured MCP write/read surface and the Byori macOS
app's read-only Context projection surface. Structured upserts first look up an existing typed
node by its canonical `name` property; they do not assume that the stored VID matches the
current hash recipe. `memory_link(action="delete")` emits `DELETE EDGE`, while `memory_delete` emits
`DELETE VERTEX` only after its link guard has passed. Engine v0.3.3 does **not** remove incident
edges with `DELETE VERTEX`. For `cascade=true`, the MCP first enumerates every incoming and
outgoing edge, emits one `DELETE EDGE` for each, and only then deletes the vertex.

For the app's Context projection, `id(n)`/`id(a)`/`id(b)` must return the vertex INT64 VID, and
`ORDER BY` must accept projection aliases (`vid`, `src`, `dst`). `LIMIT` and `OFFSET` are
non-negative integers: after sorting, the engine skips `offset` rows and then applies `limit`.
The app queries the `note` tag, each of the seven typed wiki tags, `rel`, and each of the eight
typed wiki edge kinds separately and in parallel, then merges the results in the client.
**Measurements show that the engine's `UNION`
returns only the first MATCH branch instead of combining multiple MATCH branches, so the app
does not depend on it.** Typed wiki edge queries use `(a)`/`(b)` without endpoint vertex tags,
because the same edge kind may connect several endpoint-tag combinations. The engine must support
matching vertex patterns without specified tags.

Every edge query first filters on the server against the VIDs selected by the current node
projection, chaining them as `id(a) == <vid> OR ...`. **Measurements show that the engine does not
support `WHERE <expr> IN [...]` and returns zero rows even for a single-element list**, so the
query must use an OR chain of `==` comparisons. Without this filter, the per-kind LIMIT 501 cutoff
can be consumed by edges whose endpoints would not be displayed. A displayable edge pushed past
row 501 would then be lost without `edgesTruncated` detecting the truncation. The app displays at
most 200 nodes and 500 edges, requesting one extra row for each to detect truncation. The initial
node projection excludes `body`/`summary`; only the selected node is lazy-loaded by the final
query.

\* `decided_in` (decision → task) exists in the memory ontology's target schema, but the
schema v2 migration in `byoridb_mcp.py` does not yet contain its `CREATE EDGE`. Engine v0.3.3
currently returns an empty
result for an undefined edge tag, but the app must not treat that behavior as a compatibility
contract because it would silently hide data. If `decided_in` becomes necessary—under the memory
ontology's promotion criterion of “having been forced into another type at least three times”—add
a separate schema migration before adding it to the app's edge kinds.

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

The MCP offers eight tools in the default `safe` profile. The opt-in `legacy` profile exposes nine:
`safe` hides and refuses dispatch of only `memory_query`. It still exposes all structured mutation
tools and the legacy `memory_remember` note writer, so **safe is not a read-only mode, an
authorization boundary, or a sandbox**.
The `readonly` profile advertises and dispatches only `memory_recall`, `memory_query_read`,
`memory_read`, and `memory_export`; every mutation tool and unrestricted `memory_query` call is
rejected as an unknown tool.

| Tool | `legacy` | `safe` | `readonly` | Contract |
|---|:---:|:---:|:---:|---|
| `memory_remember` | yes | yes | no | Upsert a legacy `note`; optionally create `relates_to` edges |
| `memory_recall` | yes | yes | yes | Read legacy notes by substring and/or kind, newest first |
| `memory_query` | yes | no | no | Unrestricted raw nGQL compatibility escape hatch |
| `memory_query_read` | yes | yes | yes | Run one statement admitted by the read-query gate below |
| `memory_wiki_upsert` | yes | yes | no | Validate and upsert one canonical typed-wiki node |
| `memory_link` | yes | yes | no | Upsert or delete one validated relationship between existing endpoints |
| `memory_read` | yes | yes | yes | Return normalized legacy or typed nodes, optionally with incident links |
| `memory_delete` | yes | yes | no | Delete one exact node; linked nodes require `cascade=true` |
| `memory_export` | yes | yes | yes | Return a bounded page of normalized nodes and optional outgoing links |

Profiles filter the MCP tool surface; they are not authorization boundaries or sandboxes. A
`readonly` process performs only login, `USE <space>`, and a schema-version read during startup;
it fails if a writer has not already bootstrapped the space at the current schema version. The
process still retains its configured engine credential, so use separate engine instances and
credentials across trust boundaries.

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
| `BYORIDB_MEMORY_SPACE` | MCP | Overrides the logical memory-space name; must match `^[A-Za-z_][A-Za-z0-9_]{0,63}$`. Unset = resolved from the project (docs/install.md, "Memory space") |
| `BYORIDB_MCP_PROFILE` | MCP | Case-sensitive `safe` (default, 8 tools; hides only `memory_query`), opt-in `legacy` (9 tools), or `readonly` (4 read tools) |

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

## 7. Minimum Engine Version and Build Identity

**Minimum: `v0.4.0`**, which is also `ENGINE_TAG_DEFAULT`. Everything below `v0.4.0` is
unsupported by this client, and the reason is not a preference:

| What 0.4.0 provides | Why this client needs it |
|---|---|
| `403 PERMISSION_DENIED`, distinct from `400 QUERY_ERROR` | Without it an authorization denial is indistinguishable from a bad statement, and the client's only way to tell was a substring match on `auth` that also retried permission denials (§1) |
| Non-blank `BYORIDB_ROOT_PASSWORD` gate | An engine that generates its own root password **writes it to `logs/server.log`**. `templates/run-server.sh` also refuses to start without the variable, so both sides enforce it |
| Login throttling | Bounds repeated failed logins |
| `--version` / `--help`, and unknown flags rejected | Lets the installed build identify itself (below) |
| `type(e)` MATCH edge accessor and batch destination projection | One untyped `MATCH` reads every relation type, instead of one query per type |
| `IN` / `NOT IN` | Set membership instead of an OR-chain over seed VIDs |
| Per-request `read_only` | The engine enforces the promise `memory_query_read` makes, rather than that gate standing alone |

An older engine does not fail at startup. It fails at the first read that depends on one of these,
which is why the minimum is stated here rather than discovered.

Do not advance `ENGINE_TAG_DEFAULT` to an unreleased commit: `install.sh` downloads a release
asset, so a build that exists only on `main` cannot be installed by a user.

There is no maximum. `--engine-tag latest` installs whatever the newest engine release is, and
nothing stops an engine release that changes a surface in this document; that is why the upgrade
checklist compares this document against the engine CHANGELOG rather than trusting the pin.

### Build identity

`install.sh` records what it installed in `$BYORIDB_HOME/engine.json` (`tag`, `target`, `source`,
`sha256`, `installed_at`), and the macOS app shows it on the ByoriDB page.

From 0.4.0 the binary can also identify itself, parsing arguments before it loads configuration or
touches disk:

```console
$ byoridb-server --version
byoridb-server 0.4.0 (commit fbeb4ac55417, release)
```

The app prefers that answer, drops the leading binary name, and keeps the file as the fallback.

**The recorded tag gates the probe.** Engines before 0.4.0 ignore every argument, so `--version`
starts a full server against the live data directory — which a status refresh must never do. Byori
therefore runs `--version` only when the recorded tag is `v0.4.0` or later, and reports the recorded
identity otherwise. An install performed before Byori recorded anything has no file, which is
reported as "not recorded" rather than as a verified build.
