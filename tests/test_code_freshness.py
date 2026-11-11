"""Verify real Git working-tree bytes, never equating HEAD with source freshness."""
import contextlib
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

if __package__:
    from .test_code_graph import CG, Engine
    from .test_code_browse import CLI, MCP
else:
    from test_code_graph import CG, Engine
    from test_code_browse import CLI, MCP


class CodeFreshnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve() / "repo"
        self.root.mkdir()
        self.git("init", "-b", "main")
        self.engine = Engine()
        self.addCleanup(self.engine.db.close)
        self.graph = CG.CodeGraph(self.engine.query, lambda: None,
            checkout=lambda: CG.checkout_for_root(self.root), root=lambda: self.root)

    def git(self, *args):
        return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
            "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-C", str(self.root), *args],
            check=True, capture_output=True).stdout.decode().strip()

    def write(self, path, content="def run():\n    pass\n"):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        return target

    def store(self, *paths, revision=""):
        payload = {"format_version": 1, "root": str(self.root),
            "checkout_id": CG.checkout_for_root(self.root), "snapshot_id": "a" * 64,
            "revision": revision, "files": [{"id": "file:" + path, "path": path,
                "language": "python", "hash": hashlib.sha256((self.root / path).read_bytes()).hexdigest()}
                for path in paths], "symbols": [], "references": [], "diagnostics": []}
        self.graph.store(payload)
        self.engine.queries.clear()

    def verify(self):
        result = self.graph.verify({})
        self.assertTrue(all(read_only for _, read_only in self.engine.queries), "verification must never write")
        return result["verification"]

    def test_unchanged_uncommitted_sources_are_current(self):
        self.write("a.py")
        self.store("a.py")
        result = self.verify()
        self.assertEqual(result["state"], "current")
        self.assertTrue(result["complete"])
        self.assertEqual(result["checked_files"], 1)
        self.assertIsNone(result["current_revision"])

    def test_modification_addition_deletion_detected_without_head_change(self):
        self.write("edit.py")
        self.write("delete.py")
        self.git("add", ".")
        self.git("commit", "-m", "initial")
        revision = self.git("rev-parse", "HEAD")
        self.store("edit.py", "delete.py", revision=revision)
        self.write("edit.py", "def changed(): pass\n")
        self.write("add.py")
        (self.root / "delete.py").unlink()
        result = self.verify()
        self.assertEqual(result["state"], "changed")
        self.assertEqual((result["added"], result["modified"], result["deleted"]), (1, 1, 1))
        self.assertFalse(result["revision_changed"])
        self.assertEqual(result["current_revision"], revision)

    def test_new_revision_without_source_change_is_current_not_semantically_validated(self):
        self.write("a.py")
        self.git("add", ".")
        self.git("commit", "-m", "initial")
        self.store("a.py", revision=self.git("rev-parse", "HEAD"))
        self.git("commit", "--allow-empty", "-m", "metadata only")
        result = self.verify()
        self.assertEqual(result["state"], "current")
        self.assertTrue(result["revision_changed"])
        self.assertIn("not semantic validity", result["coverage"])

    def test_ignored_vendor_unsupported_and_nonutf8_sources_follow_indexer_eligibility(self):
        self.write("a.py")
        self.store("a.py")
        self.write(".gitignore", "ignored.py\n")
        for path in ("ignored.py", "node_modules/new.py", "vendor/new.py", "target/new.py", "notes.md"):
            self.write(path)
        (self.root / "binary.py").write_bytes(b"\xff\xfe")
        result = self.verify()
        self.assertEqual(result["state"], "current")
        self.assertEqual(result["checked_files"], 1)
        self.assertEqual(result["skipped_files"], 1)

    def test_symlink_directory_cannot_escape_checkout(self):
        self.write("src/a.py")
        self.git("add", ".")
        self.store("src/a.py")
        outside = self.root.parent / "outside"
        outside.mkdir()
        secret = outside / "a.py"
        secret.write_text("must never read this")
        outside_inode = secret.stat().st_ino
        shutil.rmtree(self.root / "src")
        (self.root / "src").symlink_to(outside, target_is_directory=True)
        original_read = os.read

        def read(fd, count):
            self.assertNotEqual(os.fstat(fd).st_ino, outside_inode)
            return original_read(fd, count)

        with mock.patch.object(CG.os, "read", side_effect=read):
            result = self.verify()
        self.assertEqual(result["state"], "changed")
        self.assertEqual(result["deleted"], 1)

    def test_new_symlink_is_skipped_without_following_target(self):
        self.write("a.py")
        self.store("a.py")
        (self.root / "link.py").symlink_to(self.root.parent / "missing-secret")
        result = self.verify()
        self.assertEqual(result["state"], "current")
        self.assertEqual(result["skipped_files"], 1)

    def test_checkout_mismatch_never_reads_another_roots_sources(self):
        self.write("a.py")
        self.store("a.py")
        other = self.root.parent / "other"
        other.mkdir()
        subprocess.run(["git", "init", str(other)], check=True, capture_output=True)
        self.graph.root = lambda: other
        with mock.patch.object(CG, "_verify_sources", side_effect=AssertionError("unexpected source read")):
            result = self.verify()
        self.assertEqual(result["state"], "not_checked")
        self.assertEqual(result["reason"], "checkout_mismatch")

    def test_remote_root_argument_is_rejected_before_query(self):
        with mock.patch.object(self.graph, "_context") as context, self.assertRaises(ValueError):
            self.graph.verify({"root": "/some/other/repository"})
        context.assert_not_called()

    def test_scan_limits_never_claim_current(self):
        self.write("a.py")
        self.store("a.py")
        for field, value, reason in (("MAX_VERIFY_FILES", 0, "file_limit"),
                                    ("MAX_VERIFY_BYTES", 1, "byte_limit"),
                                    ("MAX_VERIFY_SECONDS", 0, "time_limit"),
                                    ("MAX_VERIFY_PATH_BYTES", 1, "file_limit")):
            with self.subTest(field=field), mock.patch.object(CG, field, value):
                result = self.verify()
                self.assertEqual(result["state"], "not_checked")
                self.assertFalse(result["complete"])
                self.assertEqual(result["reason"], reason)

    def test_new_files_are_bounded_even_with_empty_saved_snapshot(self):
        self.store()
        self.write("a.py")
        with mock.patch.object(CG, "MAX_VERIFY_FILES", 0):
            result = self.verify()
        self.assertEqual(result["state"], "not_checked")
        self.assertEqual(result["reason"], "file_limit")

    def test_file_changes_during_scan_make_observation_incomplete(self):
        self.write("a.py")
        self.store("a.py")
        original = CG._verify_paths
        calls = 0

        def paths(root, deadline):
            nonlocal calls
            calls += 1
            if calls == 2:
                self.write("added-during-scan.py")
            return original(root, deadline)

        with mock.patch.object(CG, "_verify_paths", side_effect=paths):
            result = self.verify()
        self.assertEqual(result["state"], "not_checked")
        self.assertEqual(result["reason"], "working_tree_changed")

    def test_snapshot_publication_race_never_verifies_new_snapshot_with_old_hashes(self):
        self.write("a.py")
        self.store("a.py")
        active = self.graph._active(CG.checkout_for_root(self.root))
        newer = dict(active, snapshot_id="b" * 64)
        with mock.patch.object(self.graph, "_active", side_effect=[active, newer]):
            response = self.graph.verify({})
        self.assertEqual(response["index"]["snapshot_id"], "b" * 64)
        self.assertEqual(response["verification"]["snapshot_id"], "b" * 64)
        self.assertEqual(response["verification"]["state"], "not_checked")
        self.assertEqual(response["verification"]["reason"], "snapshot_changed")

    def test_empty_index_is_not_an_implicitly_verified_checkout(self):
        result = self.verify()
        self.assertEqual(result["state"], "not_checked")
        self.assertEqual(result["reason"], "no_index")

    def test_cli_verify_binds_actual_canonical_root_without_indexing(self):
        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            client = stack.enter_context(mock.patch.object(CLI, "MemoryWriter"))
            indexer = stack.enter_context(mock.patch.object(CLI, "run_code_indexer"))
            stack.enter_context(mock.patch.dict(os.environ, {"BYORI_HOME": str(self.root.parent / "home")}))
            stack.enter_context(contextlib.redirect_stdout(output))
            client.return_value.module.read_code_index.return_value = {"verification": {"state": "not_checked"}}
            code = CLI.main(["code", "verify", str(self.root), "--space", "test_space", "--json"])
        self.assertEqual(code, 0)
        client.return_value.module.read_code_index.assert_called_once_with("verify", {
            "checkout_id": CG.checkout_for_root(self.root)}, project_root=str(self.root))
        client.return_value.module._logout.assert_called_once_with()
        indexer.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())["verification"]["state"], "not_checked")

    def test_mcp_verify_tool_uses_readonly_bridge(self):
        with mock.patch.object(MCP, "read_code_index", return_value={"ok": True}) as read:
            result = MCP.TOOLS["code_verify"]["handler"]({})
        read.assert_called_once_with("verify", {})
        self.assertEqual(result, {"ok": True})


if __name__ == "__main__":
    unittest.main()
