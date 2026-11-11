"""Lifecycle filtering is reversible and cannot turn old facts into current facts."""
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("memory_lifecycle_mcp", ROOT / "mcp/byoridb_mcp.py")
MCP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCP)


def node(vid, kind="decision", state="active", ts=None):
    value = {"vid": str(vid), "type": kind, "name": f"{kind}:item-{vid}", "body": "fact", "ts": ts if ts is not None else 100_000 - vid}
    if kind in MCP.WIKI_STATES:
        value["state"] = state
    return value


class MemoryLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.nodes, self.policies, self.superseded = [], {}, set()
        self.pages = []
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve()
        self.checkout = MCP._code_module.checkout_for_root(self.root)
        self.patches = [
            mock.patch.object(MCP, "_ensure_ready"),
            mock.patch.object(MCP, "_memory_page", side_effect=self.page),
            mock.patch.object(MCP, "_policy_records", side_effect=lambda nodes: {n["vid"]: self.policies[n["vid"]] for n in nodes if n["vid"] in self.policies}),
            mock.patch.object(MCP, "_incoming_superseded", side_effect=lambda nodes: self.superseded & {n["vid"] for n in nodes}),
            mock.patch.object(MCP, "_checkout_context", return_value=(self.root, self.checkout)),
            mock.patch.object(MCP, "_read_edges", return_value=[]),
        ]
        for patch in self.patches:
            patch.start(); self.addCleanup(patch.stop)

    def page(self, kind, args, offset, limit):
        self.pages.append((kind, offset, limit))
        found = [n for n in self.nodes if n["type"] == kind
                 and (not args.get("name") or n["name"] == args["name"])]
        return sorted(found, key=MCP._node_sort_key)[offset:offset + limit]

    def policy(self, vid, **fields):
        self.policies[str(vid)] = dict(MCP._default_policy(), **fields)

    def read(self, **args):
        return MCP.tool_read(dict(type="decision", **args))

    def test_current_skips_superseded_state_and_relation_but_keeps_fixed_bugs(self):
        self.nodes = [node(1, state="superseded"), node(2), node(3), node(4, kind="bug", state="fixed")]
        self.superseded.add("2")
        found = MCP.tool_read({})["items"]
        self.assertEqual({n["vid"] for n in found}, {"3", "4"})
        archived = self.read(view="archived")["items"]
        self.assertEqual({n["vid"] for n in archived}, {"1", "2"})
        self.assertTrue(all("superseded" in n["review_reasons"] for n in archived))

    def test_archive_unarchive_and_pin_are_independent_of_review(self):
        self.nodes = [node(1), node(2), node(3, state="superseded")]
        self.policy(1, archived=True, pinned=True)
        self.policy(2, pinned=True, review_after=1)
        self.policy(3, pinned=True)
        self.assertEqual(self.read()["items"], [])
        self.assertEqual([n["vid"] for n in self.read(view="review")["items"]], ["2"])
        self.policy(1, archived=False, pinned=True)
        self.assertEqual([n["vid"] for n in self.read()["items"]], ["1"])

    def test_old_only_first_pages_do_not_hide_current_records(self):
        self.nodes = [node(i, state="superseded" if i <= 250 else "active") for i in range(1, 256)]
        first = self.read(limit=2)
        self.assertEqual([n["vid"] for n in first["items"]], ["251", "252"])
        self.assertEqual(first["next_offset"], 2)
        second = self.read(limit=2, offset=first["next_offset"])
        self.assertEqual([n["vid"] for n in second["items"]], ["253", "254"])
        last = self.read(limit=2, offset=4)
        self.assertEqual([n["vid"] for n in last["items"]], ["255"])
        self.assertFalse(last["truncated"])
        self.assertTrue(any(offset == 200 for _, offset, _ in self.pages))

    def test_scan_limit_admits_incompleteness_instead_of_claiming_empty(self):
        self.nodes = [node(i, state="superseded") for i in range(1, 102)]
        with mock.patch.object(MCP, "MAX_MEMORY_SCAN", 100):
            result = self.read()
        self.assertEqual(result["items"], [])
        self.assertTrue(result["truncated"])
        self.assertTrue(result["scan_incomplete"])
        self.assertIsNone(result["next_offset"])
        self.assertIn("does not establish absence", result["note"])

    def test_source_hash_mismatch_requires_review_even_when_pinned(self):
        path = self.root / "source.py"
        path.write_text("original")
        digest, _ = MCP._source_hash(self.root, "source.py")
        self.nodes = [node(1)]
        self.policy(1, pinned=True, source={"path": "source.py", "content_hash": digest, "checkout_id": self.checkout, "verified_at": 1})
        self.assertEqual(len(self.read()["items"]), 1)
        path.write_text("changed")
        self.assertEqual(self.read()["items"], [])
        self.assertEqual(self.read(view="review")["items"][0]["review_reasons"], ["source_changed"])

    def test_missing_source_or_another_checkout_is_not_verified(self):
        self.nodes = [node(1)]
        self.policy(1, source={"path": "missing.py", "content_hash": "0" * 64, "checkout_id": self.checkout, "verified_at": 1})
        self.assertEqual(self.read(view="review")["items"][0]["review_reasons"], ["source_unavailable"])
        self.policies["1"]["source"]["checkout_id"] = "f" * 16
        self.assertEqual(self.read(view="review")["items"][0]["review_reasons"], ["source_other_checkout"])

    def test_failed_reads_still_consume_the_source_verification_budget(self):
        self.nodes = [node(i) for i in range(1, 11)]
        for item in self.nodes:
            self.policy(item["vid"], source={"path": "file-" + item["vid"], "content_hash": "0" * 64,
                "checkout_id": self.checkout, "verified_at": 1})
        with mock.patch.object(MCP, "_source_hash", side_effect=ValueError("changed during read")) as hashed:
            result = self.read(view="review")
        self.assertEqual(hashed.call_count, MCP.MAX_SOURCE_BATCH_BYTES // MCP.MAX_SOURCE_BYTES)
        self.assertEqual(sum("source_verification_limit" in n["review_reasons"] for n in result["items"]), 2)

    def test_source_path_cannot_escape_through_symlinks_or_special_files(self):
        (self.root / "good.py").write_text("content")
        (self.root / "link.py").symlink_to(self.root / "good.py")
        (self.root / "dir").mkdir()
        (self.root / "linkdir").symlink_to(self.root / "dir", target_is_directory=True)
        for path in ("../outside", "/etc/passwd", "link.py", "linkdir/file.py", "dir"):
            with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                MCP._source_hash(self.root, path)
        (self.root / "large.py").write_bytes(b"x" * (MCP.MAX_SOURCE_BYTES + 1))
        with self.assertRaises(ValueError):
            MCP._source_hash(self.root, "large.py")

    def test_timestamp_alone_and_fixed_state_do_not_expire_a_memory(self):
        self.nodes = [node(1, ts=0)]
        self.assertEqual(self.read()["items"][0]["lifecycle"], "current")

    def test_note_recall_uses_current_view_and_keeps_results_envelope(self):
        self.nodes = [node(1, kind="note"), node(2, kind="note")]
        self.policy(1, archived=True)
        result = MCP.tool_recall({})
        self.assertEqual([n["vid"] for n in result["results"]], ["2"])
        self.assertNotIn("items", result)

    def test_invalid_view_or_limits_are_rejected(self):
        for args in ({"view": "valid"}, {"offset": -1}, {"limit": 101}):
            with self.subTest(args=args), self.assertRaises(ValueError):
                self.read(**args)
        self.assertEqual(self.pages, [])


class MemoryPolicyWriteTests(unittest.TestCase):
    def test_explicit_delete_cleans_policy_and_missing_node_retry_can_finish_cleanup(self):
        existing = node(987)
        policy_vid = MCP._code_module._vid("memory-policy:decision:987")
        for original in (existing, None):
            statements = []
            def query(text, **kwargs):
                statements.append(text)
                return {"results": [{"policy_vid": policy_vid, "node_vid": "987"}]} if "MATCH (n:memory_policy)" in text else {}
            with self.subTest(original=original), mock.patch.object(MCP, "_ensure_ready"), mock.patch.object(MCP, "_find_existing_node", return_value=original), mock.patch.object(MCP, "_read_edge_records", return_value=[]), mock.patch.object(MCP, "_raw_query", side_effect=query):
                MCP.tool_delete({"type": "decision", "name": existing["name"]})
            self.assertIn("DELETE VERTEX " + str(policy_vid), statements)
            if original:
                self.assertIn("DELETE VERTEX 987", statements)

    def test_archive_uses_existing_identity_without_rewriting_body(self):
        existing = node(987, state="superseded")
        with mock.patch.object(MCP, "_ensure_ready"), mock.patch.object(MCP, "_require_existing_node", return_value=existing), mock.patch.object(MCP, "_policy_records", return_value={}), mock.patch.object(MCP, "_raw_query") as query:
            result = MCP.tool_policy({"type": "decision", "name": existing["name"], "archived": True, "pinned": True})
        self.assertTrue(result["policy"]["archived"])
        self.assertEqual(result["node"]["vid"], "987")
        self.assertIn("INSERT VERTEX memory_policy", query.call_args.args[0])
        self.assertNotIn("INSERT VERTEX decision", query.call_args.args[0])
        self.assertNotIn("VALUES 987:", query.call_args.args[0])
        self.assertIn("'987', 'decision'", query.call_args.args[0])

    def test_readonly_and_invalid_updates_never_write(self):
        with mock.patch.object(MCP, "PROFILE", "readonly"), mock.patch.object(MCP, "_raw_query") as query, self.assertRaises(ValueError):
            MCP.tool_policy({"type": "decision", "name": "decision:a", "archived": True})
        query.assert_not_called()
        for update in ({}, {"pinned": "yes"}, {"review_after": True}, {"source": {"path": "../secret"}}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                MCP.tool_policy(dict(type="decision", name="decision:a", **update))

    def test_version_three_policies_are_defaults_without_tag_queries(self):
        with mock.patch.dict(MCP._session, {"schema_version": 3}), mock.patch.object(MCP, "_raw_query") as query:
            self.assertEqual(MCP._policy_records([node(1)]), {})
        query.assert_not_called()

    def test_readonly_v3_remains_readable_without_migration(self):
        with mock.patch.object(MCP, "PROFILE", "readonly"), mock.patch.object(MCP, "_login"), mock.patch.object(MCP, "_raw_query"), mock.patch.object(MCP, "_schema_version", return_value=3), mock.patch.object(MCP, "_migrate") as migrate, mock.patch.dict(MCP._session, {"ready": False}, clear=True):
            MCP._ensure_ready()
            self.assertEqual(MCP._session["schema_version"], 3)
        migrate.assert_not_called()


class ScopedProjectMemoryReadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = pathlib.Path(self.temp.name).resolve()
        self.ambient, self.target = base / "ambient", base / "target"
        for root in (self.ambient, self.target):
            root.mkdir()
            subprocess.run(["git", "init", "-b", "main", str(root)], check=True, capture_output=True)
        patch = mock.patch.dict(os.environ, {"CLAUDE_PROJECT_DIR": str(self.ambient)})
        patch.start(); self.addCleanup(patch.stop)

    def test_bound_read_overrides_inherited_root_without_environment_mutation(self):
        before = dict(os.environ)
        with mock.patch.object(MCP, "tool_read", side_effect=lambda args: MCP._checkout_context()):
            root, checkout = MCP.memory_read_project({"view": "current"}, self.target)
        self.assertEqual(root, self.target)
        self.assertEqual(checkout, MCP._code_module.checkout_for_root(self.target))
        self.assertEqual(dict(os.environ), before)
        self.assertEqual(MCP._checkout_context()[0], self.ambient)

    def test_failure_resets_scope_and_invalid_root_never_reads_graph(self):
        with mock.patch.object(MCP, "tool_read", side_effect=RuntimeError("read failed")), self.assertRaises(RuntimeError):
            MCP.memory_read_project({}, self.target)
        self.assertEqual(MCP._checkout_context()[0], self.ambient)
        with mock.patch.object(MCP, "tool_read") as read, self.assertRaises(ValueError):
            MCP.memory_read_project({}, self.target.parent)
        read.assert_not_called()
        self.assertEqual(MCP._checkout_context()[0], self.ambient)

    def test_nested_reads_restore_the_outer_project_scope(self):
        observed = []
        def read(args):
            observed.append(MCP._checkout_context()[0])
            if args.get("outer"):
                MCP.memory_read_project({}, self.ambient)
                observed.append(MCP._checkout_context()[0])
            return {}
        with mock.patch.object(MCP, "tool_read", side_effect=read):
            MCP.memory_read_project({"outer": True}, self.target)
        self.assertEqual(observed, [self.target, self.ambient, self.target])
        self.assertEqual(MCP._checkout_context()[0], self.ambient)


if __name__ == "__main__":
    unittest.main()
