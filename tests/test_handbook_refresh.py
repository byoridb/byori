"""Real-Git consent and reconciliation tests; no live runtime or agent calls."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cli"))
import handbook
import handbook_refresh as refresh


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name) / "project with spaces"
        self.root.mkdir()
        self.git("init", "-b", "main")
        self.readme = self.root / "README.md"
        self.readme.write_text("# Fixture\n\nKeep retries bounded to three.\n")
        (self.root / "docs").mkdir()
        self.private = self.root / "docs" / "retired.md"
        self.private.write_text("# Legacy\n\nOld retry window was five.\n")
        self.git("add", ".")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def enable(self, **kwargs):
        return refresh.configure_refresh(self.root, True, debounce_ms=0, **kwargs)

    def cli(self, *args):
        result = subprocess.run([sys.executable, "-B", str(ROOT / "cli" / "byori.py"),
                                 "handbook", *args, str(self.root), "--json"],
                                capture_output=True, text=True, timeout=30)
        return result, json.loads(result.stdout) if result.stdout else None

    def test_disabled_defaults_and_sync_are_read_only(self):
        config = refresh.read_config(self.root)
        self.assertFalse(config["enabled"])
        self.assertIsNone(config["revision"])
        output = refresh.refresh_handbook(self.root)
        self.assertEqual((output["state"], output["refresh"]), ("missing", "disabled"))
        self.assertFalse((self.root / ".byori").exists())

    def test_enabled_refresh_and_true_publication_noop(self):
        self.enable()
        first = refresh.refresh_handbook(self.root)
        self.assertEqual((first["state"], first["refresh"]), ("current", "rebuilt"))
        active = self.root / ".byori" / "handbook.md"
        before = (active.stat().st_mtime_ns, active.read_bytes())
        with mock.patch.object(handbook, "publish_handbook", side_effect=AssertionError("no-op must not publish")):
            second = refresh.refresh_handbook(self.root)
        self.assertEqual(second["refresh"], "unchanged")
        self.assertEqual((active.stat().st_mtime_ns, active.read_bytes()), before)

    def test_source_change_rebuilds_next_request(self):
        self.enable()
        first = refresh.refresh_handbook(self.root)
        self.readme.write_text("# Fixture\n\nOnly two retries are allowed now.\n")
        second = refresh.refresh_handbook(self.root)
        self.assertEqual(second["refresh"], "rebuilt")
        self.assertNotEqual(first["generation"], second["generation"])
        self.assertIn("Only two retries", second["handbook"])
        self.assertNotIn("bounded to three", second["handbook"])

    def test_explicit_refresh_does_not_enable_future_runs(self):
        output = refresh.refresh_handbook(self.root, automatic=False)
        self.assertEqual(output["state"], "current")
        self.assertFalse(refresh.read_config(self.root)["enabled"])
        self.readme.write_text("# New\n\nChanged after explicit refresh.\n")
        self.assertEqual(refresh.refresh_handbook(self.root)["refresh"], "disabled")
        self.assertIsNone(refresh.refresh_handbook(self.root)["handbook"])

    def test_disabled_policy_still_withholds_newly_excluded_material(self):
        config = self.enable()
        first = refresh.refresh_handbook(self.root)
        self.assertIn("Old retry window", first["handbook"])
        config = refresh.configure_refresh(self.root, False, expected_revision=config["revision"],
            source_limits={**config["source_limits"], "exclude_paths": ["docs/"]})
        self.assertIsNone(handbook.read_handbook(self.root)["handbook"])
        self.assertEqual(handbook.handbook_status(self.root)["state"], "stale")
        self.assertIsNone(handbook.read_evidence(self.root, first["generation"])["evidence"])
        self.assertIsNone(refresh.refresh_handbook(self.root)["handbook"])
        current = refresh.refresh_handbook(self.root, automatic=False)
        self.assertEqual(current["state"], "current")
        self.assertNotIn("Old retry window", current["handbook"])

    def test_cancelled_refresh_never_activates(self):
        self.enable()
        output = refresh.refresh_handbook(self.root, cancelled=lambda: True)
        self.assertEqual(output["refresh"], "cancelled")
        self.assertFalse((self.root / ".byori" / "handbook.md").exists())

    def test_settings_changed_during_build_cancel_activation(self):
        config = self.enable()
        original = handbook.compile_handbook
        changed = False
        def compile_then_disable(*args, **kwargs):
            nonlocal changed
            build = original(*args, **kwargs)
            if not changed:
                changed = True
                refresh.configure_refresh(self.root, False, expected_revision=config["revision"])
            return build
        with mock.patch.object(handbook, "compile_handbook", side_effect=compile_then_disable):
            output = refresh.refresh_handbook(self.root)
        self.assertEqual(output["refresh"], "cancelled")
        self.assertFalse((self.root / ".byori" / "handbook.md").exists())

    def test_invalid_configuration_never_implicitly_repairs_or_enables(self):
        self.enable()
        path = self.root / ".byori" / "refresh.json"
        original = path.read_bytes()
        path.write_text("not a managed setting")
        output = refresh.refresh_handbook(self.root)
        self.assertEqual(output["refresh"], "failed")
        self.assertEqual(path.read_text(), "not a managed setting")
        with self.assertRaises(refresh.RefreshError):
            refresh.configure_refresh(self.root, True)
        self.assertNotEqual(path.read_bytes(), original)

    def test_config_compare_and_swap_preserves_latest_choice(self):
        config = self.enable()
        second = refresh.configure_refresh(self.root, False, expected_revision=config["revision"])
        with self.assertRaises(refresh.RefreshConflict):
            refresh.configure_refresh(self.root, True, expected_revision=config["revision"])
        self.assertEqual(refresh.read_config(self.root), second)

    def test_cli_uses_the_same_consent_gate(self):
        result, config = self.cli("refresh-config")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(config["enabled"])
        result, output = self.cli("sync")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(output["refresh"], "disabled")
        result, config = self.cli("refresh-config", "--enable", "--debounce-ms", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        result, output = self.cli("sync")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["refresh"], "rebuilt")

    def test_largest_exclusion_list_remains_readable_and_disableable(self):
        paths = [str(index).zfill(2) + '"' * 1022 for index in range(64)]
        config = self.enable(source_limits={"exclude_paths": paths})
        self.assertEqual(refresh.read_config(self.root), config)
        self.assertFalse(refresh.configure_refresh(self.root, False,
                         expected_revision=config["revision"])["enabled"])

    def test_serialized_policy_limit_is_checked_before_any_mutation(self):
        with mock.patch.object(refresh, "MAX_CONFIG_BYTES", 100):
            with self.assertRaisesRegex(refresh.RefreshError, "serialized size limit"):
                self.enable()
        self.assertFalse((self.root / ".byori").exists())

    def test_cli_reviewed_unconfigured_state_cannot_overwrite_new_settings(self):
        configured = self.enable(source_limits={"exclude_paths": ["docs/"]})
        result, _ = self.cli("refresh-config", "--enable", "--expect-unconfigured")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(refresh.read_config(self.root), configured)

    def test_cli_bounds_and_exclusions_change_only_by_explicit_setting(self):
        result, _ = self.cli("refresh-config", "--max-commits", "2")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / ".byori").exists())
        result, config = self.cli("refresh-config", "--disable", "--max-commits", "2", "--exclude", "docs/")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config["source_limits"]["max_commits"], 2)
        self.assertEqual(config["source_limits"]["exclude_paths"], ["docs/"])
        result, config = self.cli("refresh-config", "--disable", "--clear-exclusions")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config["source_limits"]["exclude_paths"], [])


if __name__ == "__main__":
    unittest.main()
