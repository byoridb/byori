#!/usr/bin/env python3
"""ByoriDB memory MCP server (stdio, JSON-RPC 2.0, stdlib-only).

Bridges Claude Code (and any MCP client) to a local ByoriDB instance and exposes
a small "memory" surface on top of a dedicated `claude_memory` space:

  tools:
    - memory_remember(name, kind, body, relates_to?)  -> upsert a memory note (+ edges)
    - memory_recall(text?, kind?, limit?)             -> retrieve notes (recency-ordered)
    - memory_query(ngql)                              -> raw nGQL escape hatch (incl. `AS OF`)

Transport = mechanism (auth, schema, hashing). The *policy* (when/what to remember,
how to model the graph) lives in the Claude Code skill `byoridb-memory`.

Env:
  BYORIDB_HTTP           default http://127.0.0.1:19669
  BYORIDB_USER           default root
  BYORIDB_PASSWORD / BYORIDB_ROOT_PASSWORD   root password
"""
import hashlib
import json
import os
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


# ---- tools -----------------------------------------------------------------

def tool_remember(args):
    _ensure_ready()
    name = args["name"]
    kind = args.get("kind", "note")
    body = args.get("body", "")
    relates_to = args.get("relates_to") or []
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
    _ensure_ready()
    text = args.get("text")
    kind = args.get("kind")
    limit = int(args.get("limit", 20))
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
    _ensure_ready()
    return _raw_query(args["ngql"])


TOOLS = {
    "memory_remember": {
        "handler": tool_remember,
        "description": (
            "Store or update a memory note in ByoriDB (persists across Claude Code "
            "sessions). Re-remembering the same `name` records a new bitemporal "
            "version. Use for durable facts: decisions, module relationships, bugs, "
            "preferences, project context."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Stable entity key (e.g. 'byoridb-executor', 'decision:use-redb'). Same name = same node."},
                "kind": {"type": "string", "description": "Category: decision | module | bug | entity | preference | context ..."},
                "body": {"type": "string", "description": "The note content."},
                "relates_to": {"type": "array", "items": {"type": "string"}, "description": "Other memory names this relates to (creates edges)."},
            },
            "required": ["name", "body"],
        },
    },
    "memory_recall": {
        "handler": tool_recall,
        "description": "Retrieve memory notes from ByoriDB, most-recent first. Filter by free text (matches name/body) and/or kind.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Substring to match in name or body."},
                "kind": {"type": "string", "description": "Restrict to this kind."},
                "limit": {"type": "integer", "description": "Max results (default 20)."},
            },
        },
    },
    "memory_query": {
        "handler": tool_query,
        "description": (
            "Run a raw nGQL statement against the memory space (power/escape hatch). "
            "Supports temporal reads, e.g. `FETCH PROP ON note <vid> AS OF <epoch-ms>` "
            "for what a memory said at a past time, plus MATCH/GO/LOOKUP."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"ngql": {"type": "string", "description": "nGQL statement."}},
            "required": ["ngql"],
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


def handle(msg):
    method = msg.get("method")
    id_ = msg.get("id")
    if method == "initialize":
        _result(id_, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "byoridb-memory", "version": "0.1.1"},
        })
    elif method == "notifications/initialized":
        pass  # notification, no reply
    elif method == "ping":
        _result(id_, {})
    elif method == "tools/list":
        _result(id_, {"tools": [
            {"name": n, "description": t["description"], "inputSchema": t["inputSchema"]}
            for n, t in TOOLS.items()
        ]})
    elif method == "tools/call":
        params = msg.get("params", {})
        name = params.get("name")
        args = params.get("arguments") or {}
        tool = TOOLS.get(name)
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
    log(f"starting; ByoriDB at {HTTP}, space={SPACE}")
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
