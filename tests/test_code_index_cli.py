"""CLI contracts for analysis, project scoping, and publishing code snapshots."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("byori_index_cli", ROOT / "cli" / "byori.py")
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


class IndexCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name).resolve()
        self.root = self.base / "project"
        self.root.mkdir()
        self.home = self.base / "state"
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Byori Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.root / "main.py").write_text("def hello(): pass\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-m", "fixture")
        self.binary = self.base / "fake-indexer"
        self.binary.write_text(
            "#!%s\n" % sys.executable + """import hashlib, json, os, pathlib, sys
assert not os.environ.get('BYORIDB_ROOT_PASSWORD'), 'credential reached analyzer'
assert not os.environ.get('BYORIDB_PASSWORD'), 'credential reached analyzer'
root = str(pathlib.Path(sys.argv[sys.argv.index('--root') + 1]).resolve())
print(json.dumps({
    'format_version': 1, 'root': root,
    'checkout_id': hashlib.sha256(root.encode()).hexdigest()[:16],
    'revision': '', 'snapshot_id': 'a' * 64,
    'files': [], 'symbols': [], 'references': [], 'diagnostics': [],
    'stats': {'files': 0, 'symbols': 0, 'parsed_files': 0, 'cached_files': 0},
}))
""", encoding="utf-8")
        self.binary.chmod(0o755)
        patch = mock.patch.dict(os.environ, {
            "BYORI_HOME": str(self.home), "BYORIDB_HOME": str(self.base / "runtime"),
            "BYORIDB_MEMORY_SPACE": "", "BYORI_INDEXER": str(self.binary),
            "BYORIDB_ROOT_PASSWORD": "test-secret", "BYORIDB_PASSWORD": "test-old-secret",
        })
        patch.start()
        self.addCleanup(patch.stop)

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.root), *arguments], check=True,
                              capture_output=True, text=True).stdout.strip()

    def invoke(self, *arguments):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = CLI.main(["index", str(self.root), *arguments])
        return code, output.getvalue(), errors.getvalue()

    def invoke_init(self, *arguments, root=None):
        output, errors = io.StringIO(), io.StringIO()
        with (contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors),
              mock.patch.object(sys, "path", [str(ROOT / "cli")] + sys.path)):
            code = CLI.main(["init", str(root or self.root), *arguments])
        return code, output.getvalue(), errors.getvalue()

    def commit_history_evidence(self):
        (self.root / "main.py").write_text("def hello(): return 1\n", encoding="utf-8")
        self.git("add", "main.py")
        self.git("commit", "-m", "fix: correct greeting\n\nFixes #1")

    def test_dry_run_is_json_and_never_loads_or_writes_database(self):
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            code, output, errors = self.invoke("--dry-run", "--json")
        self.assertEqual(code, 0, errors)
        writer.assert_not_called()
        report = json.loads(output)
        self.assertTrue(report["dry_run"])
        self.assertIsNone(report["stored"])
        self.assertEqual(report["root"], str(self.root))
        self.assertEqual(report["space"], CLI.memory_space_for_root(self.root))
        cache = self.home / "indexes" / report["checkout_id"]
        self.assertEqual(cache.stat().st_mode & 0o777, 0o700)

    def test_publish_uses_runtime_and_closes_its_session(self):
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            runtime = writer.return_value.module
            runtime.store_code_index.return_value = {"ok": True}
            code, output, errors = self.invoke("--json", "--space", "code_fixture")
        self.assertEqual(code, 0, errors)
        self.assertEqual(json.loads(output)["stored"], {"ok": True})
        writer.assert_called_once_with("code_fixture", self.base / "runtime")
        payload = runtime.store_code_index.call_args.args[0]
        self.assertEqual(payload["root"], str(self.root))
        runtime._logout.assert_called_once_with()

    def test_success_diagnostics_are_reported_once_from_the_snapshot(self):
        script = self.binary.read_text().replace(
            "'diagnostics': []", "'diagnostics': [{'file': 'main.py', 'message': 'Syntax recovery'}]",
        )
        self.binary.write_text(script + "\nprint('main.py: Syntax recovery', file=sys.stderr)\n")
        code, _, errors = self.invoke("--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(errors.count("Syntax recovery"), 1)
        code, output, errors = self.invoke("--dry-run", "--json")
        self.assertEqual(code, 0)
        self.assertEqual(errors, "")
        self.assertEqual(len(json.loads(output)["diagnostics"]), 1)

    def test_publish_failure_returns_failure_and_closes_session(self):
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.module.store_code_index.side_effect = RuntimeError("database unavailable")
            code, output, errors = self.invoke("--json")
        self.assertEqual(code, 2)
        self.assertEqual(output, "")
        self.assertIn("could not publish code index", errors)
        writer.return_value.module._logout.assert_called_once_with()

    def test_worktree_uses_project_space_but_separate_checkout_identity(self):
        linked = self.base / "linked"
        self.git("worktree", "add", "-b", "feature", str(linked))
        CLI.ProjectRegistry(self.home).add(self.root, "shared_project")
        self.assertEqual(CLI.code_index_space(linked, None, self.home), "shared_project")
        payload = CLI.run_code_indexer(self.binary, linked, self.home / "cache", False)
        self.assertEqual(payload["checkout_id"], hashlib.sha256(str(linked).encode()).hexdigest()[:16])
        self.assertNotEqual(payload["checkout_id"], hashlib.sha256(str(self.root).encode()).hexdigest()[:16])

    def test_worktree_without_registration_derives_main_project_space(self):
        linked = self.base / "linked"
        self.git("worktree", "add", "-b", "feature", str(linked))
        self.assertEqual(CLI.code_index_space(linked, None, self.home),
                         CLI.memory_space_for_root(self.root))

    def test_archived_project_keeps_space_and_explicit_override_wins(self):
        registry = CLI.ProjectRegistry(self.home)
        project, _ = registry.add(self.root, "old_registered_space")
        registry.remove(project["id"])
        self.assertEqual(CLI.code_index_space(self.root, None, self.home), "old_registered_space")
        self.assertEqual(CLI.code_index_space(self.root, "custom", self.home), "custom")

    def test_watch_publishes_only_changed_snapshots(self):
        first = CLI.run_code_indexer(self.binary, self.root, self.home / "cache", False)
        changed = dict(first, snapshot_id="b" * 64)
        with (mock.patch.object(CLI, "run_code_indexer", side_effect=[first, first, changed]),
              mock.patch.object(CLI.time, "sleep", side_effect=[None, None, KeyboardInterrupt]),
              mock.patch.object(CLI, "MemoryWriter") as writer):
            writer.return_value.module.store_code_index.return_value = {"ok": True}
            code, output, errors = self.invoke("--watch", "--json")
        self.assertEqual(code, 130, errors)
        self.assertEqual(len(output.splitlines()), 2)
        self.assertEqual(writer.return_value.module.store_code_index.call_count, 2)
        writer.return_value.module._logout.assert_called_once_with()

    def test_foreign_checkout_output_is_rejected_before_publishing(self):
        self.binary.write_text("#!%s\nprint('{\"format_version\": 1}')\n" % sys.executable)
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            code, _, errors = self.invoke()
        self.assertEqual(code, 2)
        self.assertIn("different checkout", errors)
        writer.assert_not_called()

    def test_interval_and_explicit_binary_are_validated(self):
        for value in ("0", "nan", "inf", "4000"):
            with self.subTest(value=value):
                code, _, errors = self.invoke("--interval", value)
                self.assertEqual(code, 2)
                self.assertIn("--interval", errors)
        code, _, errors = self.invoke("--indexer", str(self.base / "missing"))
        self.assertEqual(code, 2)
        self.assertIn("not executable", errors)

    def test_source_cli_loads_matching_source_mcp_even_when_old_runtime_is_installed(self):
        installed = self.base / "runtime"
        installed.mkdir()
        (installed / "byoridb_mcp.py").write_text("raise AssertionError('obsolete runtime')\n")
        writer = CLI.MemoryWriter("source_test", installed)
        self.assertEqual(pathlib.Path(writer.module.__file__).resolve(), ROOT / "mcp" / "byoridb_mcp.py")

    def test_bundled_cli_prefers_its_matching_indexer_to_an_installed_one(self):
        bundle = self.base / "bundle" / "runtime"
        (bundle / "cli").mkdir(parents=True)
        bundled_binary = bundle / "bin" / "byori-indexer"
        installed_binary = self.base / "runtime" / "bin" / "byori-indexer"
        for executable in (bundled_binary, installed_binary):
            executable.parent.mkdir(parents=True)
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o755)
        with (mock.patch.object(CLI, "__file__", str(bundle / "cli" / "byori.py")),
              mock.patch.dict(os.environ, {"BYORI_INDEXER": ""})):
            self.assertEqual(CLI.code_indexer_binary(), bundled_binary)

    def test_init_publishes_history_and_code_by_default_and_closes_both_sessions(self):
        self.commit_history_evidence()
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.write.return_value = {"nodes": 1, "edges": 0, "failed": 0}
            writer.return_value.module.store_code_index.return_value = {"ok": True}
            code, output, errors = self.invoke_init()
        self.assertEqual(code, 0, errors)
        writer.return_value.write.assert_called_once()
        writer.return_value.module.store_code_index.assert_called_once()
        self.assertEqual(writer.return_value.module._logout.call_count, 2)
        self.assertIn("analyzing source code", output)
        self.assertIn("indexed", output)

    def test_init_indexes_code_even_without_history_memories(self):
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.module.store_code_index.return_value = {"ok": True}
            code, output, errors = self.invoke_init()
        self.assertEqual(code, 0, errors)
        writer.return_value.write.assert_not_called()
        writer.return_value.module.store_code_index.assert_called_once()
        writer.return_value.module._logout.assert_called_once()
        self.assertIn("no history memories to write", output)
        self.assertIn("indexed", output)

    def test_init_indexes_an_unborn_repository_without_masking_history_failure(self):
        unborn = self.base / "unborn"
        unborn.mkdir()
        subprocess.run(["git", "-C", str(unborn), "init", "-b", "main"], check=True,
                       capture_output=True, text=True)
        (unborn / "app.py").write_text("def app(): pass\n", encoding="utf-8")
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.module.store_code_index.return_value = {"ok": True}
            code, output, errors = self.invoke_init(root=unborn)
        self.assertEqual(code, 0, errors)
        self.assertIn("no commits yet", output)
        writer.return_value.write.assert_not_called()
        writer.return_value.module.store_code_index.assert_called_once()

    def test_init_does_not_report_failed_established_history_as_empty(self):
        with mock.patch.object(sys, "path", [str(ROOT / "cli")] + sys.path):
            import archaeology
        with (mock.patch.object(archaeology, "excavate", side_effect=archaeology.ArchaeologyError("walk failed")),
              mock.patch.object(CLI, "run_code_indexer") as analyzer):
            code, output, errors = self.invoke_init()
        self.assertEqual(code, 2)
        self.assertIn("walk failed", errors)
        self.assertNotIn("no commits yet", output)
        analyzer.assert_not_called()

    def test_init_dry_run_analyzes_code_without_loading_database(self):
        self.commit_history_evidence()
        with (mock.patch.object(CLI, "MemoryWriter") as writer,
              mock.patch.object(CLI, "run_code_indexer", wraps=CLI.run_code_indexer) as analyzer):
            code, output, errors = self.invoke_init("--dry-run", "--no-cache", "--indexer", str(self.binary))
        self.assertEqual(code, 0, errors)
        writer.assert_not_called()
        analyzer.assert_called_once()
        self.assertTrue(analyzer.call_args.args[3])
        self.assertIn("analyzing source code", output)
        self.assertIn("dry run: nothing was written", output)

    def test_init_skip_code_retains_history_only_operation(self):
        self.commit_history_evidence()
        with (mock.patch.object(CLI, "MemoryWriter") as writer,
              mock.patch.object(CLI, "run_code_indexer") as analyzer):
            writer.return_value.write.return_value = {"nodes": 1, "edges": 0, "failed": 0}
            code, output, errors = self.invoke_init("--skip-code")
        self.assertEqual(code, 0, errors)
        writer.return_value.write.assert_called_once()
        writer.return_value.module._logout.assert_called_once()
        writer.return_value.module.store_code_index.assert_not_called()
        analyzer.assert_not_called()
        self.assertNotIn("analyzing source code", output)

    def test_init_propagates_index_failure(self):
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.module.store_code_index.side_effect = RuntimeError("index unavailable")
            code, _, errors = self.invoke_init()
        self.assertEqual(code, 2)
        self.assertIn("could not publish code index", errors)
        writer.return_value.module._logout.assert_called_once()

    def test_init_reports_partial_history_failure_even_when_code_index_succeeds(self):
        self.commit_history_evidence()
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.write.return_value = {"nodes": 0, "edges": 0, "failed": 1}
            writer.return_value.module.store_code_index.return_value = {"ok": True}
            code, output, errors = self.invoke_init()
        self.assertEqual(code, 2)
        self.assertIn("history import is incomplete", errors)
        self.assertIn("1 failed", output)
        self.assertNotIn("ask an agent why", output)
        writer.return_value.module.store_code_index.assert_called_once()
        self.assertEqual(writer.return_value.module._logout.call_count, 2)

    def test_init_closes_history_session_on_unexpected_write_failure(self):
        self.commit_history_evidence()
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.write.side_effect = RuntimeError("history unavailable")
            code, _, errors = self.invoke_init()
        self.assertEqual(code, 2)
        self.assertIn("could not publish project history", errors)
        writer.return_value.module._logout.assert_called_once()
        writer.return_value.module.store_code_index.assert_not_called()

    def test_init_uses_same_main_project_space_for_worktree_history_and_code(self):
        self.commit_history_evidence()
        linked = self.base / "linked"
        self.git("worktree", "add", "-b", "feature", str(linked))
        CLI.ProjectRegistry(self.home).add(self.root, "shared_init")
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.write.return_value = {"nodes": 1, "edges": 0, "failed": 0}
            writer.return_value.module.store_code_index.return_value = {"ok": True}
            code, _, errors = self.invoke_init(root=linked)
        self.assertEqual(code, 0, errors)
        self.assertEqual(writer.call_args_list, [mock.call("shared_init", self.base / "runtime")] * 2)
        indexed = writer.return_value.module.store_code_index.call_args.args[0]
        self.assertEqual(indexed["root"], str(linked))


if __name__ == "__main__":
    unittest.main()
