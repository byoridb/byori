"""Persistent viewer reads never index sources or mutate the graph."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CLI = load("code_browse_cli", "cli/byori.py")
MCP = load("code_browse_mcp", "mcp/byoridb_mcp.py")


class CodeBrowseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve() / "project"
        self.root.mkdir()
        subprocess.run(["git", "init", "-b", "main", str(self.root)], check=True, capture_output=True)
        patch = mock.patch.dict(os.environ, {"BYORI_HOME": str(self.root.parent / "state"),
            "BYORIDB_HOME": str(self.root.parent / "runtime"), "BYORIDB_MEMORY_SPACE": ""})
        patch.start()
        self.addCleanup(patch.stop)

    def invoke(self, action, *args):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = CLI.main(["code", action, str(self.root), "--json", *args])
        return code, output.getvalue(), errors.getvalue()

    def test_reader_uses_explicit_checkout_readonly_profile_and_closes_session(self):
        with mock.patch.object(CLI, "MemoryWriter") as client, mock.patch.object(CLI, "run_code_indexer") as indexer:
            client.return_value.module.read_code_index.return_value = {"index": None}
            code, output, errors = self.invoke("files", "--query=--option", "--space", "project_space", "--offset", "50")
        self.assertEqual((code, errors), (0, ""))
        self.assertEqual(json.loads(output), {"index": None})
        client.assert_called_once_with("project_space", self.root.parent / "runtime", profile="readonly")
        client.return_value.module.read_code_index.assert_called_once_with("files", {
            "checkout_id": hashlib.sha256(str(self.root).encode()).hexdigest()[:16],
            "query": "--option", "offset": 50, "limit": 50,
        })
        client.return_value.module._logout.assert_called_once_with()
        indexer.assert_not_called()

    def test_failed_query_closes_session_and_does_not_emit_json(self):
        with mock.patch.object(CLI, "MemoryWriter") as client:
            client.return_value.module.read_code_index.side_effect = RuntimeError("unavailable")
            code, output, errors = self.invoke("status")
        self.assertEqual(code, 2)
        self.assertEqual(output, "")
        self.assertIn("could not read code index", errors)
        client.return_value.module._logout.assert_called_once_with()

    def test_oversized_page_is_valid_json_with_next_offset(self):
        result = {"symbols": [{"id": str(i), "name": "한" * 8192} for i in range(50)]}
        encoded = CLI.bounded_code_response(result, "symbols", 100)
        parsed = json.loads(encoded)
        self.assertLessEqual(len(encoded.encode()), 192 * 1024)
        self.assertTrue(parsed["truncated"])
        self.assertGreater(len(parsed["symbols"]), 0)
        self.assertEqual(parsed["next_offset"], 100 + len(parsed["symbols"]))


class CodeReadBridgeTests(unittest.TestCase):
    def setUp(self):
        self.args = {"checkout_id": "a" * 16}
        patch = mock.patch.dict(MCP._session, {"id": "1", "ready": False, "space": None})
        patch.start()
        self.addCleanup(patch.stop)

    def test_missing_space_is_empty_without_creating_anything(self):
        with mock.patch.object(MCP, "_raw_query", return_value={"results": []}) as query:
            result = MCP.read_code_index("status", self.args)
        self.assertFalse(result["indexed"])
        query.assert_called_once_with("SHOW SPACES", read_only=True)

    def test_older_schema_is_empty_without_migrating(self):
        with mock.patch.object(MCP, "_raw_query", side_effect=[
            {"results": [{"Name": MCP.SPACE}]}, {}, {"results": [{"Name": "note"}]},
        ]) as query:
            result = MCP.read_code_index("files", self.args)
        self.assertIsNone(result["index"])
        self.assertEqual(result["files"], [])
        self.assertEqual([c.args[0] for c in query.call_args_list], ["SHOW SPACES", "USE " + MCP.SPACE, "SHOW TAGS"])

    def test_queries_are_read_only_and_scoped_after_connection(self):
        with mock.patch.object(MCP, "_raw_query", side_effect=[
            {"results": [{"Name": MCP.SPACE}]}, {}, {"results": [{"Name": "code_index"}]}, {"results": []},
        ]) as query:
            result = MCP.read_code_index("symbols", self.args)
        self.assertEqual(result["symbols"], [])
        self.assertIn("n.code_index.checkout == '" + "a" * 16 + "'", query.call_args.args[0])
        self.assertTrue(query.call_args.kwargs["read_only"])

    def test_bad_arguments_do_not_authenticate(self):
        with mock.patch.object(MCP, "_raw_query") as query, self.assertRaises(ValueError):
            MCP.read_code_index("files", dict(self.args, limit=101))
        query.assert_not_called()

    def test_authentication_failure_is_not_misrepresented_as_empty(self):
        with mock.patch.object(MCP, "_raw_query", side_effect=RuntimeError("auth failed")), self.assertRaisesRegex(RuntimeError, "auth"):
            MCP.read_code_index("status", self.args)


if __name__ == "__main__":
    unittest.main()
