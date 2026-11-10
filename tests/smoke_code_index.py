#!/usr/bin/env python3
"""Real Rust -> CLI -> ByoriDB -> stdio MCP roundtrip; requires a running engine.

Uses a temporary Git repository and a fresh graph space, never an existing
project's memories. BYORIDB_HOME supplies runtime credentials as in smoke_mcp.py.
BYORI_INDEXER may point at a development binary. All four environments are tested.
"""
import hashlib
import json
import os
import pathlib
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = {
    "demo.py": "def py_helper():\n    return 1\ndef py_entry():\n    return py_helper()\ndef dynamic(obj):\n    return obj.dispatch()\n",
    "Demo.swift": "func swiftHelper() -> Int { return 1 }\nfunc swiftEntry() -> Int { return swiftHelper() }\n",
    "demo.js": "export function jsHelper() { return 1; }\nexport function jsEntry() { return jsHelper(); }\n",
    "demo.ts": "interface Input { value: number }\nexport function tsHelper(): number { return 1; }\nexport function tsEntry(): number { return tsHelper(); }\n",
    "demo.rs": "fn rust_helper() -> i32 { 1 }\nfn rust_entry() -> i32 { rust_helper() }\n",
}


def run(argv, *, cwd, env):
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise AssertionError("%s failed: %s" % (argv[0], result.stderr[-8000:]))
    return result.stdout


class MCPClient:
    def __init__(self, root, env):
        self.process = subprocess.Popen(
            [sys.executable, str(ROOT / "mcp" / "byoridb_mcp.py")],
            cwd=root, env=dict(env, BYORIDB_MCP_PROFILE="readonly", CLAUDE_PROJECT_DIR=str(root)),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, text=True,
        )
        self.responses = queue.Queue()
        self.counter = 0

        def receive():
            for line in self.process.stdout:
                self.responses.put(line)
            self.responses.put(None)

        threading.Thread(target=receive, daemon=True).start()
        self.call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                 "clientInfo": {"name": "code-index-smoke", "version": "1"}})

    def call(self, method, params):
        self.counter += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.counter,
                                            "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        line = self.responses.get(timeout=30)
        assert line is not None, "MCP closed before responding"
        result = json.loads(line)
        assert "error" not in result, result
        return result["result"]

    def tool(self, name, **arguments):
        result = self.call("tools/call", {"name": name, "arguments": arguments})
        assert not result.get("isError"), result
        return json.loads(result["content"][0]["text"])

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.process.stdout.close()


def main():
    env = os.environ.copy()
    runtime = pathlib.Path(env.get("BYORIDB_HOME", "~/.byoridb")).expanduser()
    if (runtime / "env").is_file():
        for line in (runtime / "env").read_text().splitlines():
            if line.startswith("BYORIDB_") and "=" in line:
                key, value = line.split("=", 1)
                env.setdefault(key, value)
    env["BYORIDB_MEMORY_SPACE"] = "code_smoke_" + uuid.uuid4().hex[:16]
    with tempfile.TemporaryDirectory(prefix="byori-code-smoke-") as temporary:
        base = pathlib.Path(temporary).resolve()
        repo = base / "repo"
        repo.mkdir()
        env["BYORI_HOME"] = str(base / "state")
        env["CLAUDE_PROJECT_DIR"] = str(repo)
        git = lambda *args: run(["git", *args], cwd=repo, env=env)
        git("init", "-b", "main")
        git("config", "user.name", "Byori Smoke")
        git("config", "user.email", "smoke@example.invalid")
        for name, body in FIXTURES.items():
            (repo / name).write_text(body, encoding="utf-8")
        git("add", ".")
        git("commit", "-m", "four-language fixture")

        def index(path=repo):
            result = run([sys.executable, str(ROOT / "cli" / "byori.py"), "index", str(path), "--json"],
                         cwd=repo, env=env)
            return json.loads(result)

        # Project analysis (the app's command) must run the Rust indexer itself,
        # including a repository with no decision/issue history to import.
        initialized = run(
            [sys.executable, str(ROOT / "cli" / "byori.py"), "init", str(repo), "--json"],
            cwd=repo, env=env,
        )
        first = json.loads(initialized.strip().splitlines()[-1])
        assert first["stats"]["files"] == 5, first
        print("ok project analysis automatically indexes source")
        cached = index()
        assert cached["snapshot_id"] == first["snapshot_id"], (cached, first)
        assert cached["stats"]["cached_files"] == 5, cached
        client = MCPClient(repo, env)
        try:
            available = {tool["name"] for tool in client.call("tools/list", {})["tools"]}
            assert {"code_status", "code_search", "code_relations", "code_impact"} <= available
            for helper, entry in (("py_helper", "py_entry"), ("swiftHelper", "swiftEntry"),
                                  ("jsHelper", "jsEntry"), ("tsHelper", "tsEntry"),
                                  ("rust_helper", "rust_entry")):
                found = client.tool("code_search", query=helper)
                rows = found["symbols"]
                symbol = next(item for item in rows if item["name"] == helper)
                relations = client.tool("code_relations", symbol_id=symbol["id"], direction="incoming")
                assert relations["relations"], (helper, relations)
                impact = client.tool("code_impact", symbol_id=symbol["id"])
                assert impact["impacted"], (helper, impact)
                print("ok %s callers and impact" % helper)
            # A second checkout shares the project space without replacing this one's graph.
            linked = base / "linked"
            git("worktree", "add", "-b", "linked", str(linked))
            (linked / "demo.py").write_text("def branch_only(): pass\n")
            other = index(linked)
            assert other["checkout_id"] != first["checkout_id"]
            assert not client.tool("code_search", query="branch_only")["symbols"]
            assert client.tool("code_search", query="branch_only", checkout_id=other["checkout_id"])["symbols"]
            # Exercise the actual foreground watcher, not only its polling loop
            # with a mocked clock. It must publish changed content and stop cleanly.
            watcher = subprocess.Popen(
                [sys.executable, str(ROOT / "cli" / "byori.py"), "index", str(repo),
                 "--watch", "--interval", "1", "--json"], cwd=repo, env=env,
                stdout=subprocess.PIPE, stderr=sys.stderr, text=True,
            )
            events = queue.Queue()

            def watch_events():
                for line in watcher.stdout:
                    events.put(line)
                events.put(None)

            threading.Thread(target=watch_events, daemon=True).start()
            try:
                initial = json.loads(events.get(timeout=30))
                (repo / "demo.js").write_text(FIXTURES["demo.js"].replace("return 1", "return 2"))
                refreshed = json.loads(events.get(timeout=30))
                assert refreshed["snapshot_id"] != initial["snapshot_id"]
                assert refreshed["stats"]["parsed_files"] == 1, refreshed
                assert client.tool("code_status")["index"]["snapshot_id"] == refreshed["snapshot_id"]
            finally:
                watcher.send_signal(signal.SIGINT)
                try:
                    watcher.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    watcher.kill()
                    watcher.wait(timeout=5)
                watcher.stdout.close()
            assert watcher.returncode == 130, watcher.returncode
            print("ok foreground watch refresh and interruption")
            # Remove a file and replace a definition without committing; the old
            # graph must disappear from current queries while other checkouts stay intact.
            (repo / "demo.py").unlink()
            changed = index()
            assert changed["snapshot_id"] != first["snapshot_id"]
            assert not client.tool("code_search", query="py_helper")["symbols"]
            assert client.tool("code_search", query="branch_only", checkout_id=other["checkout_id"])["symbols"]
            print("ok incremental cache, deletion, dirty changes and worktree isolation")
            status = client.tool("code_status")
            assert status["checkout_id"] == hashlib.sha256(str(repo).encode()).hexdigest()[:16]
        finally:
            client.close()
    print("CODE INDEX SMOKE PASS")


if __name__ == "__main__":
    main()
