"""Checkpoints preserve explicit progress, not hidden reasoning or execution."""
import importlib.util
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("checkpoint_mcp", ROOT / "mcp/byoridb_mcp.py")
MCP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCP)


class CheckpointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve()
        self.git("init", "-b", "main")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "fixture")
        self.checkout = MCP._code_module.checkout_for_root(self.root)
        for patch in [mock.patch.object(MCP, "_ensure_ready"), mock.patch.dict(os.environ, {"CLAUDE_PROJECT_DIR": str(self.root), "BYORI_TASK_ID": "task-a"}), mock.patch.dict(MCP._session, {"schema_version": 4})]:
            patch.start(); self.addCleanup(patch.stop)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True, text=True).stdout.strip()

    def test_saved_explicit_fields_resume_without_executing_embedded_text(self):
        fields = {"goal": "Implement viewer", "decisions": "Keep project scope",
                  "attempts": "Tried query batch", "verification": "12 tests passed",
                  "next_steps": "Review tests\n$(touch /tmp/should-never-run)"}
        with mock.patch.object(MCP, "_raw_query") as query:
            saved = MCP.tool_checkpoint(fields)["checkpoint"]
        self.assertEqual(saved["task_id"], "task-a")
        self.assertEqual(saved["checkout_id"], self.checkout)
        self.assertEqual(saved["revision"], self.git("rev-parse", "HEAD"))
        self.assertIn("INSERT VERTEX task_checkpoint", query.call_args.args[0])
        row = {key: value for key, value in saved.items() if key not in ("checkout_id", "task_id")}
        with mock.patch.object(MCP, "_raw_query", return_value={"results": [row]}) as query:
            result = MCP.tool_resume({})
        self.assertEqual(result["checkpoint"], saved)
        self.assertEqual(result["revision_state"], "match")
        self.assertFalse(result["working_tree_verified"])
        self.assertIn("not restored hidden reasoning", result["note"])
        self.assertEqual(result["checkpoint"]["next_steps"], fields["next_steps"])
        self.assertTrue(query.call_args.kwargs["read_only"])

    def test_task_and_checkout_have_distinct_identities(self):
        queries = []
        with mock.patch.object(MCP, "_raw_query", side_effect=lambda q: queries.append(q) or {}):
            MCP.tool_checkpoint({"goal": "one", "task_id": "one"})
            MCP.tool_checkpoint({"goal": "two", "task_id": "two"})
            with mock.patch.object(MCP, "_checkout_context", return_value=(self.root, "f" * 16)):
                MCP.tool_checkpoint({"goal": "branch", "task_id": "one"})
        self.assertEqual(len({q.split(" VALUES ")[1].split(":")[0] for q in queries}), 3)

    def test_resume_query_is_scoped_to_checkout_and_explicit_task(self):
        with mock.patch.object(MCP, "_raw_query", return_value={"results": []}) as query:
            result = MCP.tool_resume({"task_id": "another-task"})
        self.assertFalse(result["found"])
        self.assertIn("checkout == '" + self.checkout + "'", query.call_args.args[0])
        self.assertIn("task_key == 'another-task'", query.call_args.args[0])

    def test_revision_change_is_reported_and_unborn_head_is_unverified(self):
        row = {"goal": "g", "revision": "0" * 40, "created_at": 1}
        with mock.patch.object(MCP, "_raw_query", return_value={"results": [row]}):
            self.assertEqual(MCP.tool_resume({})["revision_state"], "changed")
            with mock.patch.object(MCP, "_checkout_revision", return_value=""):
                self.assertEqual(MCP.tool_resume({})["revision_state"], "unverified")

    def test_project_default_is_used_without_task_environment(self):
        with mock.patch.dict(os.environ, {"BYORI_TASK_ID": ""}), mock.patch.object(MCP, "_raw_query"):
            self.assertEqual(MCP.tool_checkpoint({"goal": "project work"})["checkpoint"]["task_id"], "project")

    def test_no_checkpoint_tag_on_v3_returns_not_found_without_query(self):
        with mock.patch.dict(MCP._session, {"schema_version": 3}), mock.patch.object(MCP, "_raw_query") as query:
            self.assertFalse(MCP.tool_resume({})["found"])
        query.assert_not_called()

    def test_bad_input_or_readonly_profile_never_writes(self):
        for fields in ({}, {"goal": "x" * 8001}, {"goal": "x", "terminal_log": "raw"}, {"goal": "x", "task_id": "bad\nkey"}, {"goal": "\x00"}):
            with self.subTest(fields=fields), mock.patch.object(MCP, "_raw_query") as query, self.assertRaises(ValueError):
                MCP.tool_checkpoint(fields)
            query.assert_not_called()
        with mock.patch.object(MCP, "PROFILE", "readonly"), mock.patch.object(MCP, "_raw_query") as query, self.assertRaises(ValueError):
            MCP.tool_checkpoint({"goal": "x"})
        query.assert_not_called()

    def test_encoded_size_is_bounded_before_database_write(self):
        fields = {field: "한" * 8000 for field in ("goal", "decisions", "attempts", "verification", "next_steps")}
        with mock.patch.object(MCP, "_raw_query") as query, self.assertRaisesRegex(ValueError, "encoded limit"):
            MCP.tool_checkpoint(fields)
        query.assert_not_called()


if __name__ == "__main__":
    unittest.main()
