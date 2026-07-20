#!/usr/bin/env python3
"""Engine-contract smoke: drive an installed byori MCP over stdio JSON-RPC.

Covers the surface promised in docs/engine-contract.md:
  remember (INSERT VERTEX/EDGE, non-negative VID) -> recall (MATCH/CONTAINS)
  -> graph projections (id/ORDER BY/LIMIT/OFFSET) -> typed wiki bootstrap
  (schema v2 note + typed INSERT/MATCH roundtrip) -> query
  (FETCH ... AS OF temporal read).

Prereq: `install.sh` has run and the server is healthy (CI does this first).
Usage:  BYORIDB_HOME=<home> python3 tests/smoke_mcp.py
"""
import hashlib
import json
import os
import subprocess
import sys
import time

HOME = os.environ.get("BYORIDB_HOME", os.path.expanduser("~/.byoridb"))
MCP = os.path.join(HOME, "bin", "run-mcp.sh")
MASK = 0x7FFF_FFFF_FFFF_FFFF

# Fixed names with known hash signs under the OLD signed scheme:
#   'a'     -> sha1 i64 = -8721251224300181508  (negative: 63-bit mask regression)
#   'test2' -> sha1 i64 =  1197758748330275039  (positive: VID must stay identical)
NEG_NAME, POS_NAME = "a", "test2"
POS_VID_LEGACY = 1197758748330275039


def expected_vid(name):
    return int.from_bytes(hashlib.sha1(name.encode()).digest()[:8], "big") & MASK


proc = subprocess.Popen(
    [MCP], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, text=True
)
_id = 0


def call(method, params=None):
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
            return msg["result"]


def tool(name, args):
    res = call("tools/call", {"name": name, "arguments": args})
    text = res["content"][0]["text"]
    assert not res.get("isError"), f"FAIL: {name}({args}) -> {text}"
    return text


def query_rows(statement, expected_columns):
    payload = json.loads(tool("memory_query", {"ngql": statement}))
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
    call("initialize", {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "smoke", "version": "0"},
    })
    tools = {t["name"] for t in call("tools/list")["tools"]}
    assert tools == {"memory_remember", "memory_recall", "memory_query"}, f"FAIL: tools={tools}"
    print("ok tools/list")

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

    # typed roundtrip on the bootstrapped schema, in SKILL.md's shape:
    # decision --affects--> module, read back as a MATCH traversal.
    d_vid, m_vid = expected_vid("decision:smoke-typed"), expected_vid("module:smoke-typed")
    now = int(time.time() * 1000)
    tool("memory_query", {"ngql": (
        f"INSERT VERTEX decision(name, body, state, ts) VALUES "
        f"{d_vid}:('decision:smoke-typed', 'smoke rationale', 'active', {now})"
    )})
    tool("memory_query", {"ngql": (
        f"INSERT VERTEX module(name, summary, ts) VALUES "
        f"{m_vid}:('module:smoke-typed', 'smoke module', {now})"
    )})
    tool("memory_query", {"ngql": f"INSERT EDGE affects(ts) VALUES {d_vid}->{m_vid}:({now})"})
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
    print("ok typed wiki roundtrip (decision -[affects]-> module)")

    # recall: MATCH + CONTAINS finds both freshly written notes.
    text = tool("memory_recall", {"text": marker, "limit": 10})
    assert text.count(marker) >= 2, f"FAIL: recall missed notes: {text}"
    print("ok recall")

    # query: temporal read of the current version via AS OF just-after-now.
    as_of = int(time.time() * 1000) + 1000
    text = tool("memory_query", {"ngql": f"FETCH PROP ON note {POS_VID_LEGACY} AS OF {as_of}"})
    assert marker in text, f"FAIL: AS OF read missed note: {text}"
    print("ok query FETCH AS OF")

    proc.kill()
    print("SMOKE PASS")


if __name__ == "__main__":
    main()
