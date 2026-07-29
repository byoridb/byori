#!/usr/bin/env python3
"""ByoriDB memory MCP server (stdio, JSON-RPC 2.0, stdlib-only).

Bridges Claude Code (and any MCP client) to a local ByoriDB instance and exposes
a small "memory" surface on top of a dedicated `claude_memory` space:

  compatibility tools:
    - memory_remember(name, kind?, body, relates_to?) -> upsert a memory note (+ edges)
    - memory_recall(text?, kind?, limit?)             -> retrieve notes (recency-ordered)
    - memory_query(ngql)                              -> unrestricted legacy nGQL escape hatch

  structured tools:
    - memory_wiki_upsert / memory_link / memory_read / memory_delete / memory_export
    - memory_query_read                               -> read-only nGQL

Transport = mechanism (auth, schema, hashing). The *policy* (when/what to remember,
how to model the graph) lives in each agent adapter's `byoridb-memory` skill.

Env:
  BYORIDB_HTTP           default http://127.0.0.1:19669
  BYORIDB_USER           default root
  BYORIDB_PASSWORD / BYORIDB_ROOT_PASSWORD   root password
  BYORIDB_MEMORY_SPACE   default claude_memory; validated nGQL identifier
  BYORIDB_MCP_PROFILE    legacy (default) | safe (hides unrestricted memory_query)
"""
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

HTTP = os.environ.get("BYORIDB_HTTP", "http://127.0.0.1:19669").rstrip("/")
USER = os.environ.get("BYORIDB_USER", "root")
# The installer sets BYORIDB_ROOT_PASSWORD as the canonical secret; prefer it so a
# stray inherited BYORIDB_PASSWORD cannot shadow it with a stale/wrong value.
PASSWORD = os.environ.get("BYORIDB_ROOT_PASSWORD") or os.environ.get("BYORIDB_PASSWORD", "")
SPACE = os.environ.get("BYORIDB_MEMORY_SPACE", "claude_memory")
PROFILE = os.environ.get("BYORIDB_MCP_PROFILE", "legacy")

SPACE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
CANONICAL_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*:[A-Za-z0-9][A-Za-z0-9._-]*$")
MAX_NAME_LENGTH = 256
MAX_BODY_LENGTH = 65_536
MAX_KIND_LENGTH = 64
MAX_RELATES_TO = 64
MAX_QUERY_LENGTH = 16_384
MAX_READ_TEXT_LENGTH = 4_096
MAX_READ_LIMIT = 100
MAX_EXPORT_LIMIT = 500
MAX_EXPORT_OFFSET = 100_000

WIKI_TYPES = ("module", "decision", "bug", "incident", "concept", "entity", "task")
NODE_TYPES = ("note",) + WIKI_TYPES
WIKI_STATES = {
    "decision": {"active", "superseded"},
    "bug": {"open", "fixed", "known"},
    "task": {"open", "in_progress", "blocked", "done"},
}
DEFAULT_WIKI_STATES = {"decision": "active", "bug": "open", "task": "open"}
TYPED_RELATIONS = (
    "part_of",
    "depends_on",
    "affects",
    "caused_by",
    "fixed_by",
    "supersedes",
    "about",
    "relates_to",
)
RELATION_RULES = {
    "part_of": ({"module"}, {"module"}),
    "depends_on": ({"module"}, {"module"}),
    "affects": ({"decision", "bug"}, {"module"}),
    "caused_by": ({"incident", "bug"}, {"bug", "decision", "module"}),
    "fixed_by": ({"bug", "incident"}, {"decision", "task"}),
    "supersedes": ({"decision"}, {"decision"}),
    "about": ({"task", "incident"}, {"module", "entity", "concept"}),
}
READ_ONLY_STATEMENTS = {"MATCH", "FETCH", "GO", "LOOKUP", "SHOW", "WHY"}
MUTATING_STATEMENTS = {
    "ALTER",
    "CREATE",
    "DELETE",
    "DROP",
    "GRANT",
    "INSERT",
    "REVOKE",
    "UPDATE",
    "UPSERT",
    "USE",
}

# Memory schema version of the space, recorded in a reserved `note` vertex.
# v1 = base note/rel only (pre-versioning installs carry no version note).
# v2 = + typed wiki ontology (docs/memory-ontology.md §4, adapters SKILL.md).
SCHEMA_VERSION = 2
SCHEMA_VERSION_NAME = "byori:schema-version"

# Additive-only statements (IF NOT EXISTS): re-running against a space that
# already carries the dogfood PoC schema is safe, existing tags keep their
# shape. `status` is an nGQL reserved word — properties use state/resolved.
MIGRATIONS = {
    2: (
        "CREATE TAG IF NOT EXISTS module(name STRING, summary STRING, ts INT64)",
        "CREATE TAG IF NOT EXISTS decision(name STRING, body STRING, state STRING, ts INT64)",
        "CREATE TAG IF NOT EXISTS bug(name STRING, body STRING, state STRING, ts INT64)",
        "CREATE TAG IF NOT EXISTS incident(name STRING, body STRING, resolved STRING, ts INT64)",
        "CREATE TAG IF NOT EXISTS concept(name STRING, body STRING, ts INT64)",
        "CREATE TAG IF NOT EXISTS entity(name STRING, body STRING, ts INT64)",
        "CREATE TAG IF NOT EXISTS task(name STRING, body STRING, state STRING, ts INT64)",
        "CREATE EDGE IF NOT EXISTS part_of(ts INT64)",
        "CREATE EDGE IF NOT EXISTS depends_on(ts INT64)",
        "CREATE EDGE IF NOT EXISTS affects(ts INT64)",
        "CREATE EDGE IF NOT EXISTS caused_by(ts INT64)",
        "CREATE EDGE IF NOT EXISTS fixed_by(ts INT64)",
        "CREATE EDGE IF NOT EXISTS supersedes(ts INT64)",
        "CREATE EDGE IF NOT EXISTS about(ts INT64)",
        "CREATE EDGE IF NOT EXISTS relates_to(ts INT64)",
    ),
}

PROTOCOL_VERSION = "2024-11-05"
_session = {"id": None, "ready": False}


def log(msg):
    print(f"[byoridb-mcp] {msg}", file=sys.stderr, flush=True)


def _validate_space_name(space):
    if not isinstance(space, str) or not SPACE_RE.fullmatch(space):
        raise ValueError(
            "BYORIDB_MEMORY_SPACE must match "
            "^[A-Za-z_][A-Za-z0-9_]{0,63}$"
        )
    return space


def _validate_profile(profile):
    if profile not in {"legacy", "safe"}:
        raise ValueError("BYORIDB_MCP_PROFILE must be 'legacy' or 'safe'")
    return profile


def _post(path, payload, timeout=30):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        HTTP + path, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, json.loads(resp.read().decode() or "{}")


def _login():
    status, body = _post("/api/v1/session", {"username": USER, "password": PASSWORD})
    sid = body.get("session_id")
    if not sid:
        raise RuntimeError(f"login failed (status={status}): {body}")
    _session["id"] = sid
    log(f"authenticated, session={sid}")


def _raw_query(ngql):
    """Run one nGQL statement in the current session; re-login on session loss."""
    if _session["id"] is None:
        _login()
    payload = {"session_id": _session["id"], "query": ngql}
    try:
        status, body = _post("/api/v1/query", payload)
        return body
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace") if hasattr(e, "read") else str(e)
        # An expired/invalid session surfaces as 401/403 OR as 400 with a session/auth
        # error body (e.g. after the server restarts). Re-login once, re-pin the memory
        # space on the fresh session, then retry. Genuine query errors (syntax, etc.)
        # also return 400 but without a session marker, so they are NOT retried.
        low = detail.lower()
        session_lost = e.code in (401, 403) or (
            e.code == 400 and ("session" in low or "auth" in low)
        )
        if session_lost:
            _login()
            _post("/api/v1/query", {"session_id": _session["id"], "query": f"USE {SPACE}"})
            payload["session_id"] = _session["id"]
            _, body = _post("/api/v1/query", payload)
            return body
        raise RuntimeError(f"query failed ({e.code}): {detail}")


def _ensure_ready():
    """Bootstrap the memory space + schema (idempotent). Waits for the server."""
    _validate_space_name(SPACE)
    if _session["ready"]:
        return
    last = None
    for attempt in range(30):
        try:
            _login()
            for stmt in (
                f"CREATE SPACE IF NOT EXISTS {SPACE}(vid_type=INT64)",
                f"USE {SPACE}",
                "CREATE TAG IF NOT EXISTS note(kind STRING, name STRING, body STRING, ts INT64)",
                "CREATE EDGE IF NOT EXISTS rel(kind STRING)",
            ):
                _raw_query(stmt)
            # pin session to the memory space for subsequent queries
            _raw_query(f"USE {SPACE}")
            _migrate()
            _session["ready"] = True
            log(f"memory space '{SPACE}' ready (schema v{SCHEMA_VERSION})")
            return
        except urllib.error.HTTPError as e:
            # Fail fast on auth errors: retrying a wrong password would trip the
            # server's failed-login lockout. Only transient/startup errors retry.
            if e.code in (401, 403):
                raise RuntimeError(
                    f"authentication failed (HTTP {e.code}); check BYORIDB_ROOT_PASSWORD. "
                    "Aborting without retry to avoid locking the root account."
                )
            last = e
            _session["id"] = None
            time.sleep(2)
        except Exception as e:  # noqa: BLE001 - server may still be starting (conn refused, etc.)
            last = e
            _session["id"] = None
            time.sleep(2)
    raise RuntimeError(f"could not bootstrap ByoriDB after retries: {last}")


def _schema_version():
    """Schema version recorded in the space. No version note = v1 (note/rel
    only): both a fresh space (base DDL just ran) and a pre-versioning install
    start there and take every later migration."""
    body = _raw_query(
        f"MATCH (n:note) WHERE id(n) == {_vid(SCHEMA_VERSION_NAME)} "
        "RETURN n.note.body AS body LIMIT 1"
    )
    rows = body.get("results") or []
    if not rows:
        return 1
    try:
        return int(rows[0].get("body"))
    except (TypeError, ValueError):
        return 1


def _migrate():
    """Apply additive migrations up to SCHEMA_VERSION, stamping the version
    note after each step so an interrupted run resumes where it stopped."""
    for version in range(_schema_version() + 1, SCHEMA_VERSION + 1):
        for stmt in MIGRATIONS[version]:
            _raw_query(stmt)
        _raw_query(
            f"INSERT VERTEX note(kind, name, body, ts) VALUES "
            f"{_vid(SCHEMA_VERSION_NAME)}:('schema', '{SCHEMA_VERSION_NAME}', "
            f"'{version}', {int(time.time() * 1000)})"
        )
        log(f"memory schema migrated to v{version}")


def _vid(name):
    """Deterministic non-negative i64 VID from an entity name.

    Unsigned read + 63-bit mask keeps every VID in 0..=i64::MAX: engine v0.3.3's
    INSERT planner rejects negative VIDs, and any name whose previous signed hash
    was positive keeps the exact same VID (sign bit was 0, so the mask is a no-op)
    — existing stored notes stay addressable. See docs/engine-contract.md.
    """
    h = hashlib.sha1(name.encode("utf-8")).digest()[:8]
    return int.from_bytes(h, "big") & 0x7FFF_FFFF_FFFF_FFFF


def _esc(s):
    """Escape a string for an nGQL single-quoted literal."""
    return str(s).replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n")


def _require_string(value, field, max_length, allow_empty=False):
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string")
    if not allow_empty and not value:
        raise ValueError(f"{field} must not be empty")
    if len(value) > max_length:
        raise ValueError(f"{field} exceeds maximum length {max_length}")
    return value


def _bounded_int(value, field, minimum, maximum):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{field} must be an integer")
    if value < minimum or value > maximum:
        raise ValueError(f"{field} must be between {minimum} and {maximum}")
    return value


def _reject_extra_fields(args, allowed, tool_name):
    if not isinstance(args, dict):
        raise ValueError(f"{tool_name} arguments must be an object")
    extra = set(args) - set(allowed)
    if extra:
        raise ValueError(
            f"{tool_name} contains unsupported fields: {', '.join(sorted(extra))}"
        )


def _validate_wiki_identity(node_type, name):
    if node_type not in WIKI_TYPES:
        raise ValueError(f"unsupported wiki type: {node_type}")
    _require_string(name, "name", MAX_NAME_LENGTH)
    if not CANONICAL_NAME_RE.fullmatch(name) or not name.startswith(f"{node_type}:"):
        raise ValueError(
            f"wiki name must use canonical form '{node_type}:<stable-slug>'"
        )
    return node_type, name


def _validate_node_identity(node_type, name):
    if node_type == "note":
        return node_type, _require_string(name, "name", MAX_NAME_LENGTH)
    return _validate_wiki_identity(node_type, name)


def _strip_quoted_literals(statement):
    """Replace quoted nGQL literals so keyword checks cannot be hidden in them."""
    out = []
    quote = None
    escaped = False
    for char in statement:
        if quote is not None:
            out.append(" ")
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in {"'", '"'}:
            quote = char
            out.append(" ")
        else:
            out.append(char)
    if quote is not None:
        raise ValueError("read-only query contains an unterminated string literal")
    return "".join(out)


def _validate_read_only_query(ngql):
    query = _require_string(ngql, "ngql", MAX_QUERY_LENGTH).strip()
    scrubbed = _strip_quoted_literals(query)
    if any(marker in scrubbed for marker in ("--", "//", "/*", "*/", "#")):
        raise ValueError("read-only query does not allow comments")
    if "|" in scrubbed:
        raise ValueError("read-only query does not allow pipelines")
    if ";" in scrubbed:
        raise ValueError("read-only query must contain exactly one statement")

    match = re.match(r"^([A-Za-z]+)\b", scrubbed.lstrip())
    if not match or match.group(1).upper() not in READ_ONLY_STATEMENTS:
        allowed = ", ".join(sorted(READ_ONLY_STATEMENTS))
        raise ValueError(f"read-only query must start with one of: {allowed}")

    keywords = {word.upper() for word in re.findall(r"\b[A-Za-z]+\b", scrubbed)}
    denied = sorted(keywords & MUTATING_STATEMENTS)
    if denied:
        raise ValueError(f"read-only query contains mutating keyword: {denied[0]}")
    return query


def _result_rows(payload):
    rows = payload.get("results") if isinstance(payload, dict) else None
    return rows if isinstance(rows, list) else []


def _body_property(node_type):
    return "summary" if node_type == "module" else "body"


def _node_projection(node_type):
    prefix = f"n.{node_type}"
    fields = [
        "id(n) AS vid",
        f"{prefix}.name AS name",
        f"{prefix}.{_body_property(node_type)} AS body",
        f"{prefix}.ts AS ts",
    ]
    if node_type == "note":
        fields.insert(2, f"{prefix}.kind AS kind")
    elif node_type in WIKI_STATES:
        fields.insert(3, f"{prefix}.state AS state")
    elif node_type == "incident":
        fields.insert(3, f"{prefix}.resolved AS resolved")
    return ", ".join(fields)


def _normalize_node(node_type, row):
    node = {
        "vid": str(row.get("vid")),
        "type": node_type,
        "name": row.get("name", ""),
        "body": row.get("body", ""),
        "ts": row.get("ts", 0),
    }
    if node_type == "note":
        node["kind"] = row.get("kind", "note")
    elif node_type in WIKI_STATES:
        node["state"] = row.get("state", "")
    elif node_type == "incident":
        value = row.get("resolved", "false")
        node["resolved"] = value is True or str(value).lower() == "true"
    return node


def _query_node_by_vid(node_type, vid):
    query = (
        f"MATCH (n:{node_type}) WHERE id(n) == {vid} "
        f"RETURN {_node_projection(node_type)} LIMIT 1"
    )
    rows = _result_rows(_raw_query(query))
    return _normalize_node(node_type, rows[0]) if rows else None


def _nodes_at_vid(vid):
    nodes = []
    for node_type in NODE_TYPES:
        node = _query_node_by_vid(node_type, vid)
        if node is not None:
            nodes.append(node)
    return nodes


def _find_existing_node(node_type, name):
    matches = _query_nodes(node_type, name=name, limit=2)
    if len(matches) > 1:
        vids = ", ".join(node["vid"] for node in matches)
        raise ValueError(
            f"duplicate canonical {node_type} node {name!r} exists at VIDs {vids}"
        )
    return matches[0] if matches else None


def _require_existing_node(node_type, name):
    _validate_node_identity(node_type, name)
    node = _find_existing_node(node_type, name)
    if node is None:
        raise ValueError(f"endpoint does not exist: {node_type} node {name!r}")
    return node


def _query_nodes(node_type, name=None, text=None, limit=20):
    conditions = []
    if name is not None:
        conditions.append(f"n.{node_type}.name == '{_esc(name)}'")
    if text is not None:
        escaped = _esc(text)
        body_property = _body_property(node_type)
        conditions.append(
            f"(n.{node_type}.name CONTAINS '{escaped}' OR "
            f"n.{node_type}.{body_property} CONTAINS '{escaped}')"
        )
    where = f" WHERE {' AND '.join(conditions)}" if conditions else ""
    query = (
        f"MATCH (n:{node_type}){where} "
        f"RETURN {_node_projection(node_type)} "
        f"ORDER BY ts DESC LIMIT {limit}"
    )
    nodes = [_normalize_node(node_type, row) for row in _result_rows(_raw_query(query))]
    return [
        node
        for node in nodes
        if not (node_type == "note" and node["name"] == SCHEMA_VERSION_NAME)
    ]


def _node_sort_key(node):
    try:
        timestamp = int(node.get("ts", 0))
    except (TypeError, ValueError):
        timestamp = 0
    return (-timestamp, node.get("type", ""), node.get("name", ""), node["vid"])


def _validate_relation(relation, source_type, target_type):
    if relation not in TYPED_RELATIONS:
        raise ValueError(f"unsupported relation: {relation}")
    if relation == "relates_to":
        return
    if source_type == "note" or target_type == "note":
        raise ValueError("note nodes only support relates_to")
    allowed_sources, allowed_targets = RELATION_RULES[relation]
    if source_type not in allowed_sources or target_type not in allowed_targets:
        raise ValueError(
            f"invalid endpoints for {relation}: {source_type} -> {target_type}"
        )


def _edge_filter(vids, source_only):
    source = " OR ".join(f"id(a) == {vid}" for vid in vids)
    if source_only:
        return f"({source})"
    target = " OR ".join(f"id(b) == {vid}" for vid in vids)
    return f"({source}) OR ({target})"


def _read_edge_records(vids, source_only=False):
    if not vids:
        return []
    numeric_vids = [int(vid) for vid in vids]
    where = _edge_filter(numeric_vids, source_only)
    edges = []

    legacy_query = (
        "MATCH (a:note)-[e:rel]->(b:note) "
        f"WHERE {where} "
        "RETURN id(a) AS src, id(b) AS dst, e.rel.kind AS relation"
    )
    for row in _result_rows(_raw_query(legacy_query)):
        edges.append(
            {
                "edge_type": "rel",
                "relation": row.get("relation", "relates_to"),
                "source_vid": str(row.get("src")),
                "target_vid": str(row.get("dst")),
            }
        )

    for relation in TYPED_RELATIONS:
        query = (
            f"MATCH (a)-[e:{relation}]->(b) WHERE {where} "
            "RETURN id(a) AS src, id(b) AS dst"
        )
        for row in _result_rows(_raw_query(query)):
            edges.append(
                {
                    "edge_type": relation,
                    "relation": relation,
                    "source_vid": str(row.get("src")),
                    "target_vid": str(row.get("dst")),
                }
            )

    unique = {
        (
            edge["edge_type"],
            edge["relation"],
            edge["source_vid"],
            edge["target_vid"],
        ): edge
        for edge in edges
    }
    return [unique[key] for key in sorted(unique)]


def _read_edges(vids, source_only=False):
    public_edges = []
    for record in _read_edge_records(vids, source_only=source_only):
        public_edges.append(
            {
                "relation": record["relation"],
                "source_vid": record["source_vid"],
                "target_vid": record["target_vid"],
            }
        )
    unique = {
        (edge["relation"], edge["source_vid"], edge["target_vid"]): edge
        for edge in public_edges
    }
    return [unique[key] for key in sorted(unique)]


# ---- tools -----------------------------------------------------------------

def tool_remember(args):
    _reject_extra_fields(args, {"name", "kind", "body", "relates_to"}, "memory_remember")
    _ensure_ready()
    name = _require_string(args.get("name"), "name", MAX_NAME_LENGTH)
    kind = _require_string(args.get("kind", "note"), "kind", MAX_KIND_LENGTH)
    body = _require_string(args.get("body"), "body", MAX_BODY_LENGTH)
    relates_to = args.get("relates_to", [])
    if not isinstance(relates_to, list):
        raise ValueError("relates_to must be an array")
    if len(relates_to) > MAX_RELATES_TO:
        raise ValueError(f"relates_to exceeds maximum items {MAX_RELATES_TO}")
    relates_to = [
        _require_string(target, "relates_to item", MAX_NAME_LENGTH)
        for target in relates_to
    ]
    ts = int(time.time() * 1000)
    vid = _vid(name)
    # INSERT VERTEX overwrites the current view AND appends a bitemporal history
    # version (T-트랙) — so re-remembering the same entity records its evolution.
    q = (
        f"INSERT VERTEX note(kind, name, body, ts) VALUES "
        f"{vid}:('{_esc(kind)}', '{_esc(name)}', '{_esc(body)}', {ts})"
    )
    _raw_query(q)
    edges = []
    for target in relates_to:
        tvid = _vid(target)
        _raw_query(
            f"INSERT EDGE rel(kind) VALUES {vid}->{tvid}:('relates_to')"
        )
        edges.append({"to": target, "vid": tvid})
    return {"ok": True, "vid": vid, "name": name, "kind": kind, "edges": edges}


def tool_recall(args):
    _reject_extra_fields(args, {"text", "kind", "limit"}, "memory_recall")
    _ensure_ready()
    text = args.get("text")
    kind = args.get("kind")
    if text is not None:
        text = _require_string(text, "text", MAX_READ_TEXT_LENGTH)
    if kind is not None:
        kind = _require_string(kind, "kind", MAX_KIND_LENGTH)
    limit = _bounded_int(args.get("limit", 20), "limit", 1, MAX_READ_LIMIT)
    conds = []
    if text:
        t = _esc(text)
        conds.append(f"(n.note.name CONTAINS '{t}' OR n.note.body CONTAINS '{t}')")
    if kind:
        conds.append(f"n.note.kind == '{_esc(kind)}'")
    where = (" WHERE " + " AND ".join(conds)) if conds else ""
    q = (
        f"MATCH (n:note){where} "
        f"RETURN n.note.name AS name, n.note.kind AS kind, n.note.body AS body, n.note.ts AS ts "
        f"ORDER BY ts DESC LIMIT {limit}"
    )
    return _raw_query(q)


def tool_query(args):
    _reject_extra_fields(args, {"ngql"}, "memory_query")
    _ensure_ready()
    query = _require_string(args.get("ngql"), "ngql", MAX_QUERY_LENGTH)
    return _raw_query(query)


def _stringify_vid_fields(value):
    if isinstance(value, list):
        return [_stringify_vid_fields(item) for item in value]
    if not isinstance(value, dict):
        return value
    result = {}
    for key, item in value.items():
        if key in {"vid", "src", "dst", "source_vid", "target_vid"} and isinstance(
            item, int
        ):
            result[key] = str(item)
        else:
            result[key] = _stringify_vid_fields(item)
    return result


def tool_query_read(args):
    _reject_extra_fields(args, {"ngql"}, "memory_query_read")
    _ensure_ready()
    query = _validate_read_only_query(args.get("ngql"))
    return _stringify_vid_fields(_raw_query(query))


def tool_wiki_upsert(args):
    _reject_extra_fields(
        args,
        {"type", "name", "body", "state", "resolved"},
        "memory_wiki_upsert",
    )
    _ensure_ready()
    node_type, name = _validate_wiki_identity(args.get("type"), args.get("name"))
    body = _require_string(args.get("body"), "body", MAX_BODY_LENGTH)
    existing_node = _find_existing_node(node_type, name)
    vid = int(existing_node["vid"]) if existing_node else _vid(name)

    for node_at_vid in _nodes_at_vid(vid):
        if node_at_vid["name"] != name or node_at_vid["type"] != node_type:
            raise ValueError(
                f"VID collision: {name!r} maps to an existing "
                f"{node_at_vid['type']} node named {node_at_vid['name']!r}"
            )

    timestamp = int(time.time() * 1000)
    result = {
        "ok": True,
        "vid": str(vid),
        "type": node_type,
        "name": name,
        "body": body,
        "ts": timestamp,
    }

    if node_type == "module":
        query = (
            "INSERT VERTEX module(name, summary, ts) VALUES "
            f"{vid}:('{_esc(name)}', '{_esc(body)}', {timestamp})"
        )
    elif node_type in WIKI_STATES:
        if "resolved" in args:
            raise ValueError(f"resolved is not valid for wiki type {node_type}")
        default_state = DEFAULT_WIKI_STATES[node_type]
        if existing_node and existing_node.get("state") in WIKI_STATES[node_type]:
            default_state = existing_node["state"]
        state = args.get("state", default_state)
        _require_string(state, "state", 64)
        if state not in WIKI_STATES[node_type]:
            allowed = ", ".join(sorted(WIKI_STATES[node_type]))
            raise ValueError(f"state for {node_type} must be one of: {allowed}")
        query = (
            f"INSERT VERTEX {node_type}(name, body, state, ts) VALUES "
            f"{vid}:('{_esc(name)}', '{_esc(body)}', '{_esc(state)}', {timestamp})"
        )
        result["state"] = state
    elif node_type == "incident":
        if "state" in args:
            raise ValueError("state is not valid for wiki type incident")
        default_resolved = (
            existing_node.get("resolved", False) if existing_node else False
        )
        resolved = args.get("resolved", default_resolved)
        if not isinstance(resolved, bool):
            raise ValueError("resolved must be a boolean")
        stored_resolved = "true" if resolved else "false"
        query = (
            "INSERT VERTEX incident(name, body, resolved, ts) VALUES "
            f"{vid}:('{_esc(name)}', '{_esc(body)}', '{stored_resolved}', {timestamp})"
        )
        result["resolved"] = resolved
    else:
        if "state" in args or "resolved" in args:
            raise ValueError(f"state/resolved is not valid for wiki type {node_type}")
        query = (
            f"INSERT VERTEX {node_type}(name, body, ts) VALUES "
            f"{vid}:('{_esc(name)}', '{_esc(body)}', {timestamp})"
        )

    _raw_query(query)
    return result


def _parse_endpoint(args, field):
    endpoint = args.get(field)
    if not isinstance(endpoint, dict):
        raise ValueError(f"{field} must be an object")
    extra = set(endpoint) - {"type", "name"}
    if extra:
        raise ValueError(
            f"{field} contains unsupported fields: {', '.join(sorted(extra))}"
        )
    return _require_existing_node(endpoint.get("type"), endpoint.get("name"))


def tool_link(args):
    _reject_extra_fields(
        args, {"action", "relation", "source", "target"}, "memory_link"
    )
    _ensure_ready()
    action = args.get("action", "upsert")
    if action not in {"upsert", "delete"}:
        raise ValueError("action must be 'upsert' or 'delete'")
    relation = args.get("relation")
    source = _parse_endpoint(args, "source")
    target = _parse_endpoint(args, "target")
    _validate_relation(relation, source["type"], target["type"])

    source_vid = int(source["vid"])
    target_vid = int(target["vid"])
    use_legacy_rel = (
        relation == "relates_to"
        and source["type"] == "note"
        and target["type"] == "note"
    )
    edge_type = "rel" if use_legacy_rel else relation

    if action == "delete":
        query = f"DELETE EDGE {edge_type} {source_vid}->{target_vid}"
    elif use_legacy_rel:
        query = (
            "INSERT EDGE rel(kind) VALUES "
            f"{source_vid}->{target_vid}:('relates_to')"
        )
    else:
        timestamp = int(time.time() * 1000)
        query = (
            f"INSERT EDGE {edge_type}(ts) VALUES "
            f"{source_vid}->{target_vid}:({timestamp})"
        )

    _raw_query(query)
    return {
        "ok": True,
        "action": action,
        "relation": relation,
        "source": {
            "type": source["type"],
            "name": source["name"],
            "vid": source["vid"],
        },
        "target": {
            "type": target["type"],
            "name": target["name"],
            "vid": target["vid"],
        },
    }


def tool_read(args):
    _reject_extra_fields(
        args, {"type", "name", "text", "limit", "include_links"}, "memory_read"
    )
    _ensure_ready()
    node_type = args.get("type")
    if node_type is not None and node_type not in NODE_TYPES:
        raise ValueError(f"unsupported node type: {node_type}")

    name = args.get("name")
    if name is not None:
        if node_type is not None:
            _validate_node_identity(node_type, name)
        else:
            _require_string(name, "name", MAX_NAME_LENGTH)

    text = args.get("text")
    if text is not None:
        _require_string(text, "text", MAX_READ_TEXT_LENGTH)

    limit = _bounded_int(args.get("limit", 20), "limit", 1, MAX_READ_LIMIT)
    include_links = args.get("include_links", False)
    if not isinstance(include_links, bool):
        raise ValueError("include_links must be a boolean")

    node_types = (node_type,) if node_type else NODE_TYPES
    items = []
    for current_type in node_types:
        items.extend(_query_nodes(current_type, name=name, text=text, limit=limit))
    if name is not None:
        exact = [item for item in items if item["name"] == name]
        if len(exact) > 1:
            vids = ", ".join(item["vid"] for item in exact)
            raise ValueError(f"duplicate canonical node {name!r} exists at VIDs {vids}")
    items.sort(key=_node_sort_key)
    items = items[:limit]
    links = _read_edges([item["vid"] for item in items]) if include_links else []
    return {"items": items, "links": links}


def tool_delete(args):
    _reject_extra_fields(args, {"type", "name", "cascade"}, "memory_delete")
    _ensure_ready()
    node_type, name = _validate_node_identity(args.get("type"), args.get("name"))
    cascade = args.get("cascade", False)
    if not isinstance(cascade, bool):
        raise ValueError("cascade must be a boolean")
    if node_type == "note" and name == SCHEMA_VERSION_NAME:
        raise ValueError("the schema version note cannot be deleted")

    node = _find_existing_node(node_type, name)
    if node is None:
        vid = _vid(name)
        return {
            "ok": True,
            "deleted": False,
            "vid": str(vid),
            "type": node_type,
            "name": name,
            "cascaded_links": 0,
        }
    vid = int(node["vid"])

    edge_records = _read_edge_records([str(vid)])
    if edge_records and not cascade:
        raise ValueError(
            f"node has {len(edge_records)} incident link(s); "
            "set cascade=true to delete it"
        )

    for edge in edge_records:
        _raw_query(
            f"DELETE EDGE {edge['edge_type']} "
            f"{edge['source_vid']}->{edge['target_vid']}"
        )
    _raw_query(f"DELETE VERTEX {vid}")
    return {
        "ok": True,
        "deleted": True,
        "vid": str(vid),
        "type": node_type,
        "name": name,
        "cascaded_links": len(edge_records),
    }


def tool_export(args):
    _reject_extra_fields(
        args, {"limit", "offset", "include_links"}, "memory_export"
    )
    _ensure_ready()
    limit = _bounded_int(args.get("limit", 100), "limit", 1, MAX_EXPORT_LIMIT)
    offset = _bounded_int(
        args.get("offset", 0), "offset", 0, MAX_EXPORT_OFFSET
    )
    include_links = args.get("include_links", True)
    if not isinstance(include_links, bool):
        raise ValueError("include_links must be a boolean")

    fetch_limit = offset + limit + 1
    items = []
    for node_type in NODE_TYPES:
        items.extend(_query_nodes(node_type, limit=fetch_limit))
    items.sort(key=lambda item: (item["type"], item["name"], int(item["vid"])))
    page = items[offset : offset + limit]
    has_more = len(items) > offset + limit
    links = (
        _read_edges([item["vid"] for item in page], source_only=True)
        if include_links
        else []
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "space": SPACE,
        "items": page,
        "links": links,
        "offset": offset,
        "next_offset": offset + len(page) if has_more else None,
        "has_more": has_more,
    }


ENDPOINT_SCHEMA = {
    "type": "object",
    "properties": {
        "type": {"type": "string", "enum": list(NODE_TYPES)},
        "name": {"type": "string", "minLength": 1, "maxLength": MAX_NAME_LENGTH},
    },
    "required": ["type", "name"],
    "additionalProperties": False,
}


TOOLS = {
    "memory_remember": {
        "handler": tool_remember,
        "description": (
            "Store or update a memory note in ByoriDB (persists across agent "
            "sessions). Re-remembering the same `name` records a new bitemporal "
            "version. Use for durable facts: decisions, module relationships, bugs, "
            "preferences, project context."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "minLength": 1, "maxLength": MAX_NAME_LENGTH, "description": "Stable entity key (e.g. 'byoridb-executor', 'decision:use-redb'). Same name = same node."},
                "kind": {"type": "string", "minLength": 1, "maxLength": MAX_KIND_LENGTH, "description": "Category: decision | module | bug | entity | preference | context ..."},
                "body": {"type": "string", "minLength": 1, "maxLength": MAX_BODY_LENGTH, "description": "The note content."},
                "relates_to": {"type": "array", "maxItems": MAX_RELATES_TO, "items": {"type": "string", "minLength": 1, "maxLength": MAX_NAME_LENGTH}, "description": "Other memory names this relates to (creates edges)."},
            },
            "required": ["name", "body"],
            "additionalProperties": False,
        },
    },
    "memory_recall": {
        "handler": tool_recall,
        "description": "Retrieve memory notes from ByoriDB, most-recent first. Filter by free text (matches name/body) and/or kind.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "minLength": 1, "maxLength": MAX_READ_TEXT_LENGTH, "description": "Substring to match in name or body."},
                "kind": {"type": "string", "minLength": 1, "maxLength": MAX_KIND_LENGTH, "description": "Restrict to this kind."},
                "limit": {"type": "integer", "minimum": 1, "maximum": MAX_READ_LIMIT, "description": "Max results (default 20)."},
            },
            "additionalProperties": False,
        },
    },
    "memory_query": {
        "handler": tool_query,
        "description": (
            "Legacy unrestricted raw nGQL escape hatch. This tool is hidden when "
            "BYORIDB_MCP_PROFILE=safe. "
            "Supports temporal reads, e.g. `FETCH PROP ON note <vid> AS OF <epoch-ms>` "
            "for what a memory said at a past time, plus MATCH/GO/LOOKUP."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "ngql": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": MAX_QUERY_LENGTH,
                    "description": "nGQL statement.",
                }
            },
            "required": ["ngql"],
            "additionalProperties": False,
        },
    },
    "memory_query_read": {
        "handler": tool_query_read,
        "description": (
            "Run one read-only nGQL statement. Allows MATCH, FETCH, GO, LOOKUP, "
            "SHOW, and WHY; outside quoted literals, rejects mutations, USE, "
            "comments, pipelines, and multiple statements."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "ngql": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": MAX_QUERY_LENGTH,
                }
            },
            "required": ["ngql"],
            "additionalProperties": False,
        },
    },
    "memory_wiki_upsert": {
        "handler": tool_wiki_upsert,
        "description": (
            "Create or update one typed wiki node. The server validates the "
            "canonical type:name, reuses an existing canonical node's VID, or "
            "derives a stable non-negative 63-bit VID for a new node."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "type": {"type": "string", "enum": list(WIKI_TYPES)},
                "name": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": MAX_NAME_LENGTH,
                },
                "body": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": MAX_BODY_LENGTH,
                },
                "state": {"type": "string", "minLength": 1, "maxLength": 64},
                "resolved": {"type": "boolean"},
            },
            "required": ["type", "name", "body"],
            "additionalProperties": False,
        },
    },
    "memory_link": {
        "handler": tool_link,
        "description": (
            "Create/update or delete one validated note/wiki relationship. "
            "Both endpoints must already exist."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["upsert", "delete"]},
                "relation": {"type": "string", "enum": list(TYPED_RELATIONS)},
                "source": ENDPOINT_SCHEMA,
                "target": ENDPOINT_SCHEMA,
            },
            "required": ["relation", "source", "target"],
            "additionalProperties": False,
        },
    },
    "memory_read": {
        "handler": tool_read,
        "description": (
            "Read normalized note or typed-wiki nodes, optionally including "
            "incident relationships. VIDs are returned as decimal strings."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "type": {"type": "string", "enum": list(NODE_TYPES)},
                "name": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": MAX_NAME_LENGTH,
                },
                "text": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": MAX_READ_TEXT_LENGTH,
                },
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_READ_LIMIT,
                },
                "include_links": {"type": "boolean"},
            },
            "additionalProperties": False,
        },
    },
    "memory_delete": {
        "handler": tool_delete,
        "description": (
            "Delete one exact note/wiki node. Linked nodes require cascade=true; "
            "the reserved schema-version note can never be deleted."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "type": {"type": "string", "enum": list(NODE_TYPES)},
                "name": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": MAX_NAME_LENGTH,
                },
                "cascade": {"type": "boolean"},
            },
            "required": ["type", "name"],
            "additionalProperties": False,
        },
    },
    "memory_export": {
        "handler": tool_export,
        "description": (
            "Export a bounded best-effort inspection page of normalized note/wiki "
            "nodes and outgoing relationships. This is not a transactional backup."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_EXPORT_LIMIT,
                },
                "offset": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": MAX_EXPORT_OFFSET,
                },
                "include_links": {"type": "boolean"},
            },
            "additionalProperties": False,
        },
    },
}


# ---- JSON-RPC / MCP plumbing ----------------------------------------------

def _send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _result(id_, result):
    _send({"jsonrpc": "2.0", "id": id_, "result": result})


def _error(id_, code, message):
    _send({"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}})


def _active_tools():
    profile = _validate_profile(PROFILE)
    if profile == "safe":
        return {name: tool for name, tool in TOOLS.items() if name != "memory_query"}
    return TOOLS


def handle(msg):
    method = msg.get("method")
    id_ = msg.get("id")
    if method == "initialize":
        _result(id_, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "byoridb-memory", "version": "0.2.0"},
        })
    elif method == "notifications/initialized":
        pass  # notification, no reply
    elif method == "ping":
        _result(id_, {})
    elif method == "tools/list":
        active_tools = _active_tools()
        _result(id_, {"tools": [
            {"name": n, "description": t["description"], "inputSchema": t["inputSchema"]}
            for n, t in active_tools.items()
        ]})
    elif method == "tools/call":
        params = msg.get("params", {})
        name = params.get("name")
        raw_args = params.get("arguments")
        args = {} if raw_args is None else raw_args
        tool = _active_tools().get(name)
        if not tool:
            _error(id_, -32602, f"unknown tool: {name}")
            return
        try:
            out = tool["handler"](args)
            text = json.dumps(out, ensure_ascii=False, indent=2)
            _result(id_, {"content": [{"type": "text", "text": text}]})
        except Exception as e:  # noqa: BLE001 - surface tool errors to the model
            log(f"tool {name} error: {e}")
            _result(id_, {"content": [{"type": "text", "text": f"ERROR: {e}"}], "isError": True})
    elif id_ is not None:
        _error(id_, -32601, f"method not found: {method}")


def main():
    _validate_space_name(SPACE)
    _validate_profile(PROFILE)
    log(f"starting; ByoriDB at {HTTP}, space={SPACE}, profile={PROFILE}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            handle(msg)
        except Exception as e:  # noqa: BLE001 - never crash the loop
            log(f"handler error: {e}")


if __name__ == "__main__":
    main()
