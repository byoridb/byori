#!/usr/bin/env python3
"""Engine-contract smoke: drive an installed byori MCP over stdio JSON-RPC.

Covers the surface promised in docs/engine-contract.md:
  remember (INSERT VERTEX/EDGE, non-negative VID) -> recall (MATCH/CONTAINS)
  -> query (FETCH ... AS OF temporal read).

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
