"""Exercise persisted code snapshots through a small SQL-backed nGQL test peer.

The peer executes the generated predicates/projections rather than returning
prearranged query strings, so worktree/snapshot filters and pagination are tested.
The real engine contract is covered separately by the runtime smoke test.
"""
import hashlib
import importlib.util
import pathlib
import re
import sqlite3
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("code_graph_test", ROOT / "mcp/code_graph.py")
CG = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CG)


LITERAL = re.compile(r"'(?:\\.|[^'\\])*'")


def unquote(value):
    text = value[1:-1]
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "r": "\r", "t": "\t"}.get(m[1], m[1]), text)


class Engine:
    def __init__(self):
        self.db = sqlite3.connect(":memory:")
        self.db.row_factory = sqlite3.Row
        self.edges = set()
        self.queries = []
        self.fail_on = None
        for statement in CG.MIGRATION:
            match = re.match(r"CREATE TAG IF NOT EXISTS (\w+)\((.*)\)", statement)
            if match:
                self.db.execute("CREATE TABLE %s (vid INTEGER PRIMARY KEY, %s)" % (match[1], match[2]))

    def query(self, text, read_only=False):
        self.queries.append((text, read_only))
        if self.fail_on and self.fail_on in text:
            raise RuntimeError("injected engine write failure")
        if text.startswith("INSERT VERTEX"):
            assert not read_only
            match = re.fullmatch(r"INSERT VERTEX (\w+)\((.*?)\) VALUES (.*)", text)
            tag, fields, values = match.groups()
            # Each item consists of an integer VID and parenthesized nGQL
            # literals. Parentheses inside a string are consumed by the token.
            item = re.compile(r"(\d+):\(((?:'(?:\\.|[^'\\])*'|[^')])*)\)(?:, |$)")
            consumed = 0
            for row in item.finditer(values):
                self.assert_position(row.start(), consumed)
                tokens = re.findall(r"'(?:\\.|[^'\\])*'|-?\d+", row[2])
                decoded = [unquote(t) if t.startswith("'") else int(t) for t in tokens]
                self.db.execute("INSERT OR REPLACE INTO %s (vid,%s) VALUES (%s)" % (
                    tag, fields, ",".join("?" for _ in range(len(decoded) + 1))), [int(row[1])] + decoded)
                consumed = row.end()
            self.assert_position(consumed, len(values))
            return {"results": []}
        if text.startswith("INSERT EDGE"):
            assert not read_only
            kind = text.split()[2].split("(")[0]
            for source, target in re.findall(r"(\d+)->(\d+):", text):
                self.edges.add((kind, int(source), int(target)))
            return {"results": []}
        assert read_only, text
        match = re.fullmatch(r"MATCH \(n:(\w+)\) WHERE (.*?) RETURN (.*?) ORDER BY (.*?) LIMIT (\d+) OFFSET (\d+)", text)
        if not match:
            raise AssertionError("unsupported test query: " + text)
        tag, where, projection, order, limit, offset = match.groups()
        sql = "SELECT %s FROM %s WHERE %s ORDER BY %s LIMIT %s OFFSET %s" % (
            projection, tag, where, order, limit, offset)
        sql = re.sub(r"n\.\w+\.(\w+)", r"\1", sql)
        # Bind every literal so a parser/escaping mistake cannot accidentally
        # become valid SQL and make this fake peer more permissive than intended.
        params = []

        def bind(match):
            params.append(unquote(match[0]))
            return "?"

        sql = LITERAL.sub(bind, sql)
        sql = re.sub(r"(\w+) CONTAINS \?", r"instr(\1, ?) > 0", sql)
        return {"results": [dict(row) for row in self.db.execute(sql, params)]}

    @staticmethod
    def assert_position(actual, expected):
        if actual != expected:
            raise AssertionError("unparsed nGQL insert values")


def payload(root, snapshot="a", name="callee"):
    file = {"id": "file:src/main.py", "path": "src/main.py", "language": "python",
            "hash": hashlib.sha256(name.encode()).hexdigest()}
    return {"format_version": 1, "root": str(root), "checkout_id": CG.checkout_for_root(root),
            "snapshot_id": snapshot * 64, "revision": "abc123", "files": [file],
            "symbols": [{"id": "callee", "name": name, "qualified_name": name,
                         "kind": "function", "file": file["path"], "start_line": 1, "end_line": 2},
                        {"id": "caller", "name": "caller", "qualified_name": "caller",
                         "kind": "function", "file": file["path"], "start_line": 4, "end_line": 6}],
            "references": [{"source": "caller", "target": "callee", "kind": "calls", "name": name,
                            "file": file["path"], "line": 5, "resolution": "resolved"},
                           {"source": "caller", "target": None, "kind": "calls", "name": "receiver.run",
                            "file": file["path"], "line": 6, "resolution": "unresolved"}],
            "diagnostics": [], "stats": {"parsed_files": 1, "cached_files": 0}}


class CodeGraphTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve()
        self.engine = Engine()
        self.addCleanup(self.engine.db.close)
        self.graph = CG.CodeGraph(self.engine.query, lambda: None,
                                  lambda: CG.checkout_for_root(self.root))

    def test_store_search_and_static_evidence_round_trip(self):
        out = self.graph.store(payload(self.root))
        self.assertTrue(out["ok"])
        status = self.graph.status({})
        self.assertTrue(status["indexed"])
        self.assertEqual(status["index"]["unresolved_references"], 1)
        self.assertEqual(status["index"]["freshness"], "not_checked")
        result = self.graph.search({"query": "callee", "language": "python", "file": "src/main.py"})
        self.assertEqual([s["id"] for s in result["symbols"]], ["callee"])
        self.assertEqual(result["symbols"][0]["start_line"], 1)
        self.assertEqual(result["symbols"][0]["content_hash"], payload(self.root)["files"][0]["hash"])
        callers = self.graph.relations({"symbol_id": "callee", "direction": "incoming"})
        self.assertEqual(callers["relations"][0]["source"], "caller")
        outgoing = self.graph.relations({"symbol_id": "caller"})
        self.assertEqual(len(outgoing["relations"]), 2)
        self.assertEqual(sum(r["target"] is None for r in outgoing["relations"]), 1)
        self.assertEqual(len(self.engine.edges), 3)  # two defines, one resolved call
        self.assertTrue(all(read for text, read in self.engine.queries if text.startswith("MATCH")))

    def test_repeat_snapshot_ignores_cache_counters_and_does_not_write(self):
        first = payload(self.root)
        self.graph.store(first)
        first["stats"] = {"parsed_files": 0, "cached_files": 1}
        self.engine.queries.clear()
        self.assertTrue(self.graph.store(first)["unchanged"])
        self.assertTrue(all(read for _, read in self.engine.queries))

    def test_unchanged_code_can_be_bound_to_a_new_git_revision(self):
        first = payload(self.root)
        self.graph.store(first)
        first["revision"] = "def456"
        self.engine.queries.clear()
        self.assertTrue(self.graph.store(first)["unchanged"])
        self.assertEqual(self.graph.status({})["index"]["revision"], "def456")
        writes = [q for q, read in self.engine.queries if not read]
        self.assertEqual(len(writes), 1)
        self.assertTrue(writes[0].startswith("INSERT VERTEX code_index"))

    def test_invalid_input_is_rejected_before_any_query(self):
        bad = []
        for mutate in (
            lambda p: p.update(checkout_id="0" * 16),
            lambda p: p["files"][0].update(path="../secret"),
            lambda p: p["files"][0].update(language="unknown"),
            lambda p: p["symbols"][0].update(file="missing.py"),
            lambda p: p["symbols"][1].update(id="callee"),
            lambda p: p["references"][0].update(target="not-a-symbol"),
            lambda p: p["references"][1].update(target="callee"),
            lambda p: p["symbols"][0].update(start_line=True),
        ):
            value = payload(self.root)
            mutate(value)
            bad.append(value)
        for value in bad:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.graph.store(value)
        self.assertEqual(self.engine.queries, [])

    def test_failed_publish_keeps_previous_snapshot_and_can_resume(self):
        self.graph.store(payload(self.root))
        changed = payload(self.root, snapshot="b", name="new_name")
        self.engine.fail_on = "INSERT EDGE code_calls"
        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.graph.store(changed)
        self.assertEqual(self.graph.search({"query": "callee"})["symbols"][0]["name"], "callee")
        self.assertEqual(self.graph.search({"query": "new_name"})["symbols"], [])
        self.engine.fail_on = None
        self.graph.store(changed)
        self.assertEqual(self.graph.search({"query": "callee"})["symbols"], [])
        self.assertEqual(self.graph.search({"query": "new_name"})["symbols"][0]["name"], "new_name")

    def test_same_snapshot_cannot_be_overwritten_with_different_content(self):
        self.graph.store(payload(self.root))
        with self.assertRaisesRegex(ValueError, "reused"):
            self.graph.store(payload(self.root, name="wrong"))

    def test_staging_snapshot_digest_cannot_be_reused_after_failure(self):
        self.engine.fail_on = "INSERT VERTEX code_symbol"
        with self.assertRaises(RuntimeError):
            self.graph.store(payload(self.root))
        self.engine.fail_on = None
        with self.assertRaisesRegex(ValueError, "reused"):
            self.graph.store(payload(self.root, name="wrong"))
        self.assertFalse(self.graph.status({})["indexed"])

    def test_deleted_files_symbols_and_edges_disappear_with_new_snapshot(self):
        self.graph.store(payload(self.root))
        empty = payload(self.root, snapshot="b")
        empty.update(files=[], symbols=[], references=[])
        self.graph.store(empty)
        self.assertEqual(self.graph.search({})["symbols"], [])
        self.assertEqual(self.graph.relations({"symbol_id": "callee", "direction": "incoming"})["relations"], [])
        self.assertEqual(self.graph.status({})["index"]["files"], 0)

    def test_worktrees_share_space_but_never_share_code_snapshots(self):
        self.graph.store(payload(self.root))
        sibling = self.root / "worktree"
        sibling.mkdir()
        self.graph.store(payload(sibling, name="other_tree"))
        self.assertEqual(self.graph.search({"query": "other_tree"})["symbols"], [])
        other = self.graph.search({"query": "other_tree", "checkout_id": CG.checkout_for_root(sibling)})
        self.assertEqual(other["symbols"][0]["name"], "other_tree")

    def test_pagination_and_exact_symbol_lookup(self):
        self.graph.store(payload(self.root))
        first = self.graph.search({"limit": 1})
        self.assertTrue(first["truncated"])
        second = self.graph.search({"limit": 1, "offset": first["next_offset"]})
        self.assertFalse(second["truncated"])
        self.assertNotEqual(first["symbols"][0]["id"], second["symbols"][0]["id"])
        self.assertEqual(len(self.graph.search({"symbol_id": "caller"})["symbols"]), 1)

    def test_impact_cycles_are_bounded_and_dynamic_calls_excluded(self):
        value = payload(self.root)
        value["references"].append({"source": "callee", "target": "caller", "kind": "calls",
            "name": "caller", "file": "src/main.py", "line": 2, "resolution": "resolved"})
        self.graph.store(value)
        result = self.graph.impact({"symbol_id": "callee", "depth": 5})
        self.assertEqual(result["impacted"], [{"id": "caller", "distance": 1}])
        self.assertFalse(result["truncated"])
        self.assertTrue(all(r["resolution"] == "resolved" for r in result["relations"]))
        self.assertTrue(self.graph.impact({"symbol_id": "callee", "depth": 1})["truncated"])

    def test_hostile_names_remain_literals(self):
        name = "f'); DELETE VERTEX 1 -- \\n\n"
        self.graph.store(payload(self.root, name=name))
        result = self.graph.search({"query": name})
        self.assertEqual(result["symbols"][0]["name"], name)
        self.assertEqual(self.graph.status({})["index"]["symbols"], 2)

    def test_tools_reject_extra_fields_and_invalid_bounds_before_queries(self):
        for handler in (self.graph.status, self.graph.search, self.graph.relations, self.graph.impact):
            for args in ([], {"unexpected": True}):
                with self.subTest(handler=handler, args=args), self.assertRaises(ValueError):
                    handler(args)
        for method, args in ((self.graph.search, {"limit": 101}),
                             (self.graph.relations, {"symbol_id": "x", "direction": "both"}),
                             (self.graph.impact, {"symbol_id": "x", "depth": 6})):
            with self.assertRaises(ValueError):
                method(args)
        self.assertEqual(self.engine.queries, [])

    def test_vid_collision_is_detected_before_writing(self):
        with mock.patch.object(CG, "_vid", return_value=1), self.assertRaisesRegex(ValueError, "collision"):
            self.graph.store(payload(self.root))
        self.assertEqual(self.engine.queries, [])

    def test_large_ingest_uses_bounded_batches(self):
        value = payload(self.root)
        template = value["symbols"][0]
        value["symbols"] += [dict(template, id="extra-%s" % i, name="x" * 1000) for i in range(150)]
        self.graph.store(value)
        inserts = [q for q, _ in self.engine.queries if q.startswith("INSERT VERTEX code_symbol")]
        self.assertGreater(len(inserts), 1)
        self.assertTrue(all(len(q.encode()) <= CG.MAX_BATCH_BYTES for q in inserts))

    def test_frontier_queries_stay_bounded_with_long_symbol_ids(self):
        self.graph.store(payload(self.root))
        active = self.graph.status({})["index"]
        keys = ["x" * 8000 + str(i) for i in range(100)]
        self.engine.queries.clear()
        self.assertEqual(self.graph._references(active, keys, "incoming", None, 101), [])
        self.assertGreater(len(self.engine.queries), 1)
        self.assertTrue(all(len(q.encode()) <= CG.MAX_BATCH_BYTES for q, _ in self.engine.queries))

    def test_long_unicode_diagnostics_are_summarized_without_rejecting_snapshot(self):
        value = payload(self.root)
        value["diagnostics"] = [{"file": "소스" * 1000 + ".py", "message": "오류" * 4000}
                                for _ in range(21)]
        self.graph.store(value)
        status = self.graph.status({})["index"]
        self.assertEqual(status["diagnostics_count"], 21)
        self.assertTrue(status["diagnostics_truncated"])
        self.assertEqual(len(status["diagnostics"]), 20)
        writes = [q for q, read in self.engine.queries if not read]
        self.assertTrue(all(len(q.encode()) <= CG.MAX_BATCH_BYTES for q in writes))


if __name__ == "__main__":
    unittest.main()
