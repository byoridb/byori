#!/usr/bin/env python3
"""Engine-contract smoke: drive an installed byori MCP over stdio JSON-RPC.

Covers the MCP/engine surface used by Byori:
  remember (INSERT VERTEX/EDGE, non-negative VID) -> recall (MATCH/CONTAINS)
  -> graph projections (id/ORDER BY/LIMIT/OFFSET) -> typed wiki bootstrap
  (schema v2 + structured upsert/read/link roundtrip) -> Manager typed graph
  projection (tag-only node MATCH, untyped-endpoint edge MATCH with a
  visible-ID WHERE filter, module summary lazy-load) -> read-only query
  (FETCH ... AS OF temporal read + mutation denial) -> safe and readonly profile filtering.

Prereq: `install.sh` has run and the server is healthy (CI does this first).
Usage:  BYORIDB_HOME=<home> python3 tests/smoke_mcp.py
        BYORIDB_MCP=<checkout>/mcp/byoridb_mcp.py python3 tests/smoke_mcp.py
"""
import hashlib
import json
import os
import subprocess
import sys
import time

HOME = os.environ.get("BYORIDB_HOME", os.path.expanduser("~/.byoridb"))
MCP = os.environ.get("BYORIDB_MCP", os.path.join(HOME, "bin", "run-mcp.sh"))
MCP_COMMAND = [sys.executable, MCP] if MCP.endswith(".py") else [MCP]
MASK = 0x7FFF_FFFF_FFFF_FFFF

# Fixed names with known hash signs under the OLD signed scheme:
#   'a'     -> sha1 i64 = -8721251224300181508  (negative: 63-bit mask regression)
#   'test2' -> sha1 i64 =  1197758748330275039  (positive: VID must stay identical)
NEG_NAME, POS_NAME = "a", "test2"
POS_VID_LEGACY = 1197758748330275039


def expected_vid(name):
    return int.from_bytes(hashlib.sha1(name.encode()).digest()[:8], "big") & MASK


def legacy_wiki_vid(name):
    return int(hashlib.sha1(name.encode()).hexdigest()[:15], 16)


def start_mcp(profile):
    env = os.environ.copy()
    env["BYORIDB_MCP_PROFILE"] = profile
    return subprocess.Popen(
        MCP_COMMAND,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        text=True,
        env=env,
    )


proc = start_mcp("legacy")
_id = 0


def exchange(method, params=None):
    global _id
    _id += 1
    proc.stdin.write(
        json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params or {}}) + "\n"
    )
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("FAIL: MCP closed stdout")
        msg = json.loads(line)
        if msg.get("id") == _id:
            return msg


def call(method, params=None):
    msg = exchange(method, params)
    assert "error" not in msg, f"FAIL: {method} -> {msg['error']}"
    return msg["result"]


def tool(name, args):
    res = call("tools/call", {"name": name, "arguments": args})
    text = res["content"][0]["text"]
    assert not res.get("isError"), f"FAIL: {name}({args}) -> {text}"
    return text


def query_rows(statement, expected_columns, tool_name="memory_query"):
    payload = json.loads(tool(tool_name, {"ngql": statement}))
    required = {"results", "latency_ms", "row_count", "column_names"}
    assert required <= payload.keys(), f"FAIL: query response shape={payload}"
    rows = payload["results"]
    assert isinstance(rows, list), f"FAIL: results is not a list: {payload}"
    assert payload["column_names"] == expected_columns, f"FAIL: columns={payload}"
    assert payload["row_count"] == len(rows), f"FAIL: row_count={payload}"
    assert type(payload["latency_ms"]) is int and payload["latency_ms"] >= 0, (
        f"FAIL: latency_ms={payload}"
    )
    return rows


def main():
    global proc, _id
    call("initialize", {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "smoke", "version": "0"},
    })
    tools = {t["name"] for t in call("tools/list")["tools"]}
    legacy_tools = {"memory_remember", "memory_recall", "memory_query"}
    structured_tools = {
        "memory_query_read", "memory_wiki_upsert", "memory_link",
        "memory_read", "memory_delete", "memory_export",
    }
    assert legacy_tools | structured_tools <= tools, f"FAIL: legacy tools={tools}"
    print("ok tools/list (legacy compatibility + structured tools)")

    marker = f"smoke-{int(time.time())}"

    # remember: old-scheme-negative name must now insert (mask regression),
    # and it creates an edge to the positive-name node via relates_to.
    out = json.loads(tool("memory_remember", {
        "name": NEG_NAME, "kind": "context", "body": f"{marker} neg-hash body",
        "relates_to": [POS_NAME],
    }))
    assert out["ok"] and out["vid"] == expected_vid(NEG_NAME) >= 0, f"FAIL: {out}"
    print(f"ok remember neg-hash name (vid={out['vid']})")

    # remember: positive name keeps its legacy VID (backward compat with data
    # stored before the 63-bit mask).
    out = json.loads(tool("memory_remember", {
        "name": POS_NAME, "kind": "context", "body": f"{marker} pos-hash body",
    }))
    assert out["vid"] == POS_VID_LEGACY == expected_vid(POS_NAME), f"FAIL: {out}"
    print(f"ok remember pos-hash name (vid unchanged: {out['vid']})")

    # Manager graph node projection: IDs remain exact Int64 JSON numbers, rows
    # are alias-keyed and ordered, and bodies are intentionally excluded.
    node_rows = query_rows(
        "MATCH (n:note) "
        "RETURN id(n) AS vid, n.note.name AS name, n.note.kind AS kind, n.note.ts AS ts "
        "ORDER BY vid ASC LIMIT 201 OFFSET 0",
        ["vid", "name", "kind", "ts"],
    )
    node_ids = [row["vid"] for row in node_rows]
    assert node_ids == sorted(node_ids), f"FAIL: unordered node projection: {node_rows}"
    nodes_by_name = {row.get("name"): row for row in node_rows}
    for name, vid in ((NEG_NAME, expected_vid(NEG_NAME)), (POS_NAME, POS_VID_LEGACY)):
        row = nodes_by_name.get(name)
        assert row and row["vid"] == vid, f"FAIL: projected node {name}: {node_rows}"
        assert row["kind"] == "context" and isinstance(row["ts"], int), (
            f"FAIL: projected node metadata {name}: {row}"
        )
        assert "body" not in row, f"FAIL: eager body in node projection: {row}"
    print("ok graph node projection")

    # Manager graph edge projection: the remembered relates_to edge is directed
    # from the masked negative-hash VID to the legacy positive VID.
    edge_rows = query_rows(
        "MATCH (a:note)-[e:rel]->(b:note) "
        "RETURN id(a) AS src, id(b) AS dst, e.rel.kind AS kind "
        "ORDER BY src ASC, dst ASC LIMIT 501 OFFSET 0",
        ["src", "dst", "kind"],
    )
    edge_keys = [(row["src"], row["dst"]) for row in edge_rows]
    assert edge_keys == sorted(edge_keys), f"FAIL: unordered edge projection: {edge_rows}"
    expected_edge = {
        "src": expected_vid(NEG_NAME),
        "dst": POS_VID_LEGACY,
        "kind": "relates_to",
    }
    assert expected_edge in edge_rows, f"FAIL: projected edge missing: {edge_rows}"
    print("ok graph edge projection")

    # typed wiki bootstrap: _ensure_ready migrated the fresh space to schema
    # v2 and stamped the version note.
    ver_rows = query_rows(
        f"MATCH (n:note) WHERE id(n) == {expected_vid('byori:schema-version')} "
        "RETURN n.note.body AS body LIMIT 1",
        ["body"],
    )
    assert ver_rows and ver_rows[0]["body"] == "2", f"FAIL: schema version: {ver_rows}"
    print("ok schema version note (v2)")

    # Byori v0.2.0 taught clients to raw-insert typed nodes at a 60-bit VID.
    # The structured API must discover that node by canonical name and keep its
    # original VID so upgrades do not fork the entity or strand its edges/history.
    legacy_name = "decision:smoke-v020-legacy-vid"
    legacy_vid = legacy_wiki_vid(legacy_name)
    current_vid = expected_vid(legacy_name)
    assert legacy_vid != current_vid, "FAIL: legacy compatibility fixture VIDs are equal"
    tool("memory_query", {
        "ngql": (
            "INSERT VERTEX decision(name, body, state, ts) VALUES "
            f"{legacy_vid}:('{legacy_name}', 'v0.2 raw node', 'active', {int(time.time() * 1000)})"
        )
    })
    legacy_read = json.loads(tool("memory_read", {
        "type": "decision", "name": legacy_name,
    }))
    assert [item["vid"] for item in legacy_read["items"]] == [str(legacy_vid)], (
        f"FAIL: legacy typed read: {legacy_read}"
    )
    legacy_updated = json.loads(tool("memory_wiki_upsert", {
        "type": "decision", "name": legacy_name,
        "body": "updated through structured API", "state": "active",
    }))
    assert legacy_updated["vid"] == str(legacy_vid), f"FAIL: legacy upsert: {legacy_updated}"
    legacy_rows = query_rows(
        f"MATCH (n:decision) WHERE n.decision.name == '{legacy_name}' "
        "RETURN id(n) AS vid, n.decision.body AS body ORDER BY vid ASC LIMIT 2",
        ["vid", "body"],
    )
    assert legacy_rows == [{"vid": legacy_vid, "body": "updated through structured API"}], (
        f"FAIL: legacy typed node forked or stale: {legacy_rows}"
    )
    print("ok v0.2 typed VID compatibility (canonical-name reuse)")

    # Structured typed roundtrip: server-side VID derivation, normalized reads,
    # and a validated decision --affects--> module link.
    d_vid, m_vid = expected_vid("decision:smoke-typed"), expected_vid("module:smoke-typed")
    decision = json.loads(tool("memory_wiki_upsert", {
        "type": "decision",
        "name": "decision:smoke-typed",
        "body": "smoke rationale",
        "state": "active",
    }))
    module = json.loads(tool("memory_wiki_upsert", {
        "type": "module",
        "name": "module:smoke-typed",
        "body": "smoke module",
    }))
    assert decision["vid"] == str(d_vid) and module["vid"] == str(m_vid), (
        f"FAIL: structured VIDs decision={decision}, module={module}"
    )
    assert isinstance(decision["vid"], str) and isinstance(module["vid"], str), (
        "FAIL: structured VIDs must be decimal strings"
    )
    linked = json.loads(tool("memory_link", {
        "relation": "affects",
        "source": {"type": "decision", "name": "decision:smoke-typed"},
        "target": {"type": "module", "name": "module:smoke-typed"},
    }))
    assert linked["ok"] and linked["source"]["vid"] == str(d_vid), f"FAIL: {linked}"

    unlinked = json.loads(tool("memory_link", {
        "action": "delete",
        "relation": "affects",
        "source": {"type": "decision", "name": "decision:smoke-typed"},
        "target": {"type": "module", "name": "module:smoke-typed"},
    }))
    assert unlinked["ok"] and unlinked["action"] == "delete", f"FAIL: {unlinked}"
    removed_rows = query_rows(
        "MATCH (a)-[e:affects]->(b) "
        f"WHERE id(a) == {d_vid} AND id(b) == {m_vid} "
        "RETURN id(a) AS src, id(b) AS dst LIMIT 1",
        ["src", "dst"],
    )
    assert not removed_rows, f"FAIL: structured edge delete: {removed_rows}"
    tool("memory_link", {
        "relation": "affects",
        "source": {"type": "decision", "name": "decision:smoke-typed"},
        "target": {"type": "module", "name": "module:smoke-typed"},
    })

    structured = json.loads(tool("memory_read", {
        "type": "decision",
        "name": "decision:smoke-typed",
        "include_links": True,
    }))
    assert any(
        row["name"] == "decision:smoke-typed" and row["vid"] == str(d_vid)
        for row in structured["items"]
    ), f"FAIL: structured read: {structured}"
    assert {
        "relation": "affects", "source_vid": str(d_vid), "target_vid": str(m_vid)
    } in structured["links"], f"FAIL: structured links: {structured}"
    print("ok structured typed upsert/read/link")

    exported = json.loads(tool("memory_export", {"limit": 100, "include_links": True}))
    exported_names = {row["name"] for row in exported["items"]}
    assert {"decision:smoke-typed", "module:smoke-typed"} <= exported_names, (
        f"FAIL: structured export items: {exported}"
    )
    assert all(isinstance(row["vid"], str) for row in exported["items"]), (
        f"FAIL: export VIDs are not decimal strings: {exported}"
    )
    assert {
        "relation": "affects", "source_vid": str(d_vid), "target_vid": str(m_vid)
    } in exported["links"], f"FAIL: structured export links: {exported}"
    print("ok structured export")

    disposable = json.loads(tool("memory_wiki_upsert", {
        "type": "task", "name": "task:smoke-delete", "body": "delete smoke",
    }))
    deleted = json.loads(tool("memory_delete", {
        "type": "task", "name": "task:smoke-delete", "cascade": False,
    }))
    assert deleted["deleted"] and deleted["vid"] == disposable["vid"], (
        f"FAIL: structured delete: {deleted}"
    )
    missing = json.loads(tool("memory_read", {
        "type": "task", "name": "task:smoke-delete",
    }))
    assert not missing["items"], f"FAIL: deleted task still readable: {missing}"

    cascade_task = json.loads(tool("memory_wiki_upsert", {
        "type": "task", "name": "task:smoke-cascade", "body": "cascade smoke",
    }))
    tool("memory_link", {
        "relation": "about",
        "source": {"type": "task", "name": "task:smoke-cascade"},
        "target": {"type": "module", "name": "module:smoke-typed"},
    })
    blocked = call("tools/call", {
        "name": "memory_delete",
        "arguments": {
            "type": "task", "name": "task:smoke-cascade", "cascade": False,
        },
    })
    assert blocked.get("isError") and "cascade=true" in blocked["content"][0]["text"], (
        f"FAIL: linked delete was not blocked: {blocked}"
    )
    cascaded = json.loads(tool("memory_delete", {
        "type": "task", "name": "task:smoke-cascade", "cascade": True,
    }))
    assert cascaded["deleted"] and cascaded["vid"] == cascade_task["vid"], (
        f"FAIL: cascade delete: {cascaded}"
    )
    cascade_rows = query_rows(
        "MATCH (a)-[e:about]->(b) "
        f"WHERE id(a) == {int(cascade_task['vid'])} "
        "RETURN id(a) AS src, id(b) AS dst LIMIT 1",
        ["src", "dst"],
    )
    assert not cascade_rows, f"FAIL: cascade left incident edge: {cascade_rows}"
    print("ok structured edge delete + guarded/cascade vertex delete")

    # Legacy raw query remains available in the legacy profile for compatibility.
    typed_rows = query_rows(
        "MATCH (d:decision)-[:affects]->(m:module) "
        "RETURN d.decision.name AS decision, m.module.name AS module, "
        "d.decision.state AS state ORDER BY decision ASC LIMIT 10",
        ["decision", "module", "state"],
    )
    expected_typed = {
        "decision": "decision:smoke-typed",
        "module": "module:smoke-typed",
        "state": "active",
    }
    assert expected_typed in typed_rows, f"FAIL: typed traversal: {typed_rows}"
    print("ok legacy query compatibility (decision -[affects]-> module)")

    # Manager typed node projection: tag-only MATCH (no note-style `kind`
    # column), id(n) stays an exact Int64 for typed tags too.
    typed_node_rows = query_rows(
        "MATCH (n:decision) "
        "RETURN id(n) AS vid, n.decision.name AS name, n.decision.ts AS ts "
        "ORDER BY vid ASC LIMIT 201 OFFSET 0",
        ["vid", "name", "ts"],
    )
    assert any(
        row["vid"] == d_vid and row["name"] == "decision:smoke-typed" for row in typed_node_rows
    ), f"FAIL: typed node projection missing decision: {typed_node_rows}"
    print("ok typed node projection (tag-only MATCH)")

    # Manager typed edge projection: untyped `(a)-[e:<edge>]->(b)` endpoints,
    # filtered server-side to a visible-ID allowlist via OR-chained `==`
    # (the engine does not support `WHERE <expr> IN [...]` at all -- measured:
    # it returns zero rows even for a single-element list, silently, with no
    # error). This is the exact shape of the fix/manager-graph-typed-wiki
    # review's blocker fix: without this filter, a per-kind LIMIT cutoff can
    # silently drop displayable edges without edgesTruncated ever detecting it.
    visible_filter = f"(id(a) == {d_vid} OR id(a) == {m_vid})" \
        f" AND (id(b) == {d_vid} OR id(b) == {m_vid})"
    typed_edge_rows = query_rows(
        "MATCH (a)-[e:affects]->(b) "
        f"WHERE {visible_filter} "
        "RETURN id(a) AS src, id(b) AS dst "
        "ORDER BY src ASC, dst ASC LIMIT 501 OFFSET 0",
        ["src", "dst"],
    )
    assert {"src": d_vid, "dst": m_vid} in typed_edge_rows, (
        f"FAIL: typed edge projection missing affects edge: {typed_edge_rows}"
    )
    print("ok typed edge projection (untyped endpoints + visible-ID OR filter)")

    # Manager lazy body/summary load: module reads `summary`, not `body`.
    module_body_rows = query_rows(
        f"MATCH (n:module) WHERE id(n) == {m_vid} RETURN n.module.summary AS body LIMIT 1",
        ["body"],
    )
    assert module_body_rows and module_body_rows[0]["body"] == "smoke module", (
        f"FAIL: module summary lazy-load: {module_body_rows}"
    )
    print("ok typed body/summary lazy-load (module -> summary)")

    # recall: MATCH + CONTAINS finds both freshly written notes.
    text = tool("memory_recall", {"text": marker, "limit": 10})
    assert text.count(marker) >= 2, f"FAIL: recall missed notes: {text}"
    print("ok recall")

    # Safe raw query: temporal read is allowed, while mutation is denied.
    as_of = int(time.time() * 1000) + 1000
    text = tool(
        "memory_query_read",
        {"ngql": f"FETCH PROP ON note {POS_VID_LEGACY} AS OF {as_of}"},
    )
    assert marker in text, f"FAIL: AS OF read missed note: {text}"
    denied = call("tools/call", {
        "name": "memory_query_read",
        "arguments": {
            "ngql": "INSERT VERTEX note(kind, name, body, ts) VALUES 99:('x','x','x',1)"
        },
    })
    assert denied.get("isError") and "read-only" in denied["content"][0]["text"], (
        f"FAIL: read-only mutation was not denied: {denied}"
    )
    print("ok read-only query FETCH AS OF + mutation denial")

    proc.kill()
    proc.wait(timeout=5)

    # The safe profile keeps compatibility note tools and structured tools but
    # neither advertises nor dispatches the unrestricted memory_query escape hatch.
    proc = start_mcp("safe")
    _id = 0
    call("initialize", {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "smoke-safe", "version": "0"},
    })
    safe_tools = {t["name"] for t in call("tools/list")["tools"]}
    assert "memory_query" not in safe_tools, f"FAIL: safe tools={safe_tools}"
    assert {"memory_remember", "memory_recall"} | structured_tools <= safe_tools, (
        f"FAIL: safe tools={safe_tools}"
    )
    direct = exchange("tools/call", {"name": "memory_query", "arguments": {"ngql": "SHOW TAGS"}})
    assert direct.get("error", {}).get("code") == -32602, f"FAIL: safe dispatch={direct}"
    proc.kill()
    proc.wait(timeout=5)
    print("ok safe profile filtering")

    # The readonly profile advertises and dispatches only the four read tools.
    proc = start_mcp("readonly")
    _id = 0
    call("initialize", {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "smoke-readonly", "version": "0"},
    })
    readonly_tools = {
        "memory_recall", "memory_query_read", "memory_read", "memory_export",
        # Answering "why" reads and traverses; a worker needs it for the recall it
        # is supposed to do before working.
        "memory_why",
    }
    discovered = {t["name"] for t in call("tools/list")["tools"]}
    assert discovered == readonly_tools, f"FAIL: readonly tools={discovered}"
    for name in sorted(tools - readonly_tools):
        direct = exchange("tools/call", {"name": name, "arguments": {}})
        assert direct.get("error", {}).get("code") == -32602, (
            f"FAIL: readonly dispatch {name}={direct}"
        )
    text = tool("memory_recall", {"text": marker, "limit": 10})
    assert marker in text, f"FAIL: readonly recall dispatch={text}"
    # A why answer against the real engine: the shape has to survive a round trip,
    # not only a unit test with a stubbed graph.
    why = json.loads(tool("memory_why", {"question": marker, "limit": 3}))
    assert why["answers"], f"FAIL: why found nothing for {marker}: {why}"
    first = why["answers"][0]
    for field in ("type", "name", "body", "confidence", "evidence"):
        assert field in first, f"FAIL: why answer missing {field}: {first}"
    assert first["confidence"] in ("evidence-backed", "unsourced"), first["confidence"]
    print("ok why answer over the real engine")
    proc.kill()
    proc.wait(timeout=5)
    print("ok readonly profile filtering")
    print("SMOKE PASS")


if __name__ == "__main__":
    main()
