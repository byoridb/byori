"""Generation-aware MCP reads use the packaged CLI, never a graph login."""

import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("handbook_mcp_test", ROOT / "mcp" / "byoridb_mcp.py")
MCP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCP)


class HandbookMCPTests(unittest.TestCase):
    def test_refresh_cannot_change_consent_scope_or_bypass_readonly(self):
        for args in ({"root": "/elsewhere"}, {"enabled": True}, {"automatic": False}):
            with self.subTest(args=args), mock.patch.object(MCP.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    MCP.tool_handbook_refresh(args)
                run.assert_not_called()
        with mock.patch.object(MCP, "PROFILE", "readonly"), mock.patch.object(MCP.subprocess, "run") as run:
            self.assertNotIn("memory_handbook_refresh", MCP._active_tools())
            with self.assertRaises(ValueError):
                MCP.tool_handbook_refresh({})
            run.assert_not_called()

    def test_rejects_unbound_paths_and_invalid_generation_before_running(self):
        for args in ({"path": "/elsewhere"}, {"expected_generation": 42},
                     {"expected_generation": "../old"}, {"query": "topic"}):
            with self.subTest(args=args), mock.patch.object(MCP.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    MCP.tool_handbook(args)
                run.assert_not_called()

    def test_runtime_failure_withholds_body_and_does_not_echo_output(self):
        for result in (
            subprocess.CompletedProcess([], 1, "not JSON secret", "secret"),
            subprocess.CompletedProcess([], 0, json.dumps({"state": "current", "generation": 3, "handbook": "bad"}), ""),
            subprocess.CompletedProcess([], 1, json.dumps({"state": "stale", "handbook": "do not expose"}), ""),
        ):
            with self.subTest(result=result), mock.patch.object(MCP.subprocess, "run", return_value=result):
                output = MCP.tool_handbook({})
                self.assertIsNone(output["handbook"])
                self.assertNotIn("secret", json.dumps(output))

    def test_oversized_evidence_is_reported_without_partial_source_content(self):
        result = subprocess.CompletedProcess([], 0, "x" * 512001, "")
        with mock.patch.object(MCP.subprocess, "run", return_value=result):
            output = MCP.tool_handbook({"expected_generation": "a" * 64, "source_id": "source:" + "b" * 24})
        self.assertIsNone(output["handbook"])
        self.assertIn("MCP context limit", output["reason"])

    def test_installed_runtime_is_scoped_pinned_and_engine_independent(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            runtime = base / "runtime with spaces"
            bin_dir = runtime / "bin"
            bin_dir.mkdir(parents=True)
            shutil.copy2(ROOT / "mcp" / "byoridb_mcp.py", runtime / "byoridb_mcp.py")
            for name in ("byori", "handbook", "handbook_sources", "handbook_delivery", "handbook_records", "handbook_refresh", "handbook_projection", "handbook_knowledge", "handbook_projection_cache", "handbook_memory"):
                shutil.copy2(ROOT / "cli" / (name + ".py"), bin_dir / (name + ".py"))
            project = base / "scope with spaces"
            project.mkdir()
            subprocess.run(["git", "init", "-b", "main", str(project)], check=True, capture_output=True)
            readme = project / "README.md"
            readme.write_text("# Fixture\n\nKeep retries bounded to three.\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(project), "add", "README.md"], check=True, capture_output=True)
            cli = [sys.executable, "-B", str(bin_dir / "byori.py"), "handbook", "build", str(project), "--json"]
            built = subprocess.run(cli, check=True, capture_output=True, text=True, timeout=30)
            generation = json.loads(built.stdout)["generation"]
            with mock.patch.object(MCP, "__file__", str(runtime / "byoridb_mcp.py")), \
                 mock.patch.dict(os.environ, {"BYORI_PROJECT_DIR": str(project), "CLAUDE_PROJECT_DIR": "/wrong", "GIT_DIR": "/wrong/.git"}), \
                 mock.patch.object(MCP, "_ensure_ready") as login:
                output = MCP.tool_handbook({"expected_generation": generation})
                self.assertEqual(output["state"], "current")
                self.assertIn("three", output["handbook"])
                source_id = re.search(r"source:[a-f0-9]{24}", output["handbook"]).group(0)
                evidence = MCP.tool_handbook({"expected_generation": generation, "source_id": source_id})
                self.assertEqual(evidence["state"], "current")
                self.assertIn("three", evidence["evidence"]["source"]["content"])
                with self.assertRaises(ValueError):
                    MCP.tool_handbook({"source_id": source_id})
                self.assertIsNone(MCP.tool_handbook({"expected_generation": "0" * 64})["handbook"])
                readme.write_text("# Fixture\n\nOnly two retries now.\n", encoding="utf-8")
                self.assertIsNone(MCP.tool_handbook({})["handbook"])
                self.assertEqual(MCP.tool_handbook({})["state"], "stale")
                disabled = MCP.tool_handbook_refresh({})
                self.assertEqual(disabled["refresh"], "disabled")
                self.assertIsNone(disabled["handbook"])
                subprocess.run([sys.executable, "-B", str(bin_dir / "byori.py"), "handbook",
                                "refresh-config", str(project), "--enable", "--debounce-ms", "0", "--json"],
                               check=True, capture_output=True, text=True, timeout=30)
                refreshed = MCP.tool_handbook_refresh({})
                self.assertEqual((refreshed["state"], refreshed["refresh"]), ("current", "rebuilt"))
                self.assertIn("Only two retries", refreshed["handbook"])
                self.assertNotEqual(refreshed["generation"], generation)
                login.assert_not_called()


if __name__ == "__main__":
    unittest.main()
