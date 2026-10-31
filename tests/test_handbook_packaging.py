"""Exercise deployed sibling imports from outside the source checkout."""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class HandbookPackagingTests(unittest.TestCase):
    def test_copied_runtime_builds_without_checkout_imports(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            installed = base / "runtime with spaces" / "bin"
            installed.mkdir(parents=True)
            for name in ("byori", "doctor", "handbook", "handbook_sources", "handbook_delivery", "handbook_records", "handbook_refresh", "handbook_projection", "handbook_knowledge", "handbook_projection_cache", "handbook_memory"):
                shutil.copy2(ROOT / "cli" / (name + ".py"), installed / (name + ".py"))
            project = base / "project with spaces"
            project.mkdir()
            subprocess.run(["git", "init", "-b", "main", str(project)], check=True,
                           capture_output=True)
            (project / "README.md").write_text("# Fixture\n\nKeep retries bounded.\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(project), "add", "README.md"], check=True,
                           capture_output=True)
            environment = dict(os.environ)
            environment.pop("PYTHONPATH", None)
            environment.update(BYORI_HOME=str(base / "isolated-byori"),
                               BYORIDB_HOME=str(base / "no-engine"))
            cli = [sys.executable, "-B", str(installed / "byori.py"), "handbook"]
            for action in ("preview", "build", "status", "show", "refresh", "sync", "refresh-config"):
                with self.subTest(action=action):
                    result = subprocess.run([*cli, action, str(project), "--json"], cwd=base,
                                            env=environment, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    payload = json.loads(result.stdout)
                    if action in {"status", "show", "refresh", "sync"}:
                        self.assertEqual(payload["state"], "current")
                    elif action == "refresh-config":
                        self.assertFalse(payload["enabled"])
                    else:
                        self.assertGreater(payload["claim_count"], 0)
            diagnosis = subprocess.run(
                [sys.executable, "-B", str(installed / "byori.py"), "doctor", str(project),
                 "--handbook-only", "--json"], cwd=base, env=environment,
                capture_output=True, text=True, timeout=30)
            self.assertEqual(diagnosis.returncode, 0, diagnosis.stderr)
            checks = json.loads(diagnosis.stdout)
            self.assertEqual(checks["mode"], "handbook-only")
            self.assertIn("handbook-snapshot", {check["name"] for check in checks["checks"]})
            self.assertNotIn("Keep retries bounded.", diagnosis.stdout)
            self.assertFalse((base / "no-engine").exists())


if __name__ == "__main__":
    unittest.main()
