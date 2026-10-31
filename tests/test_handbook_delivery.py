#!/usr/bin/env python3
"""Isolated tests for project-scoped handbook host delivery."""

import importlib.util
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
SPEC = importlib.util.spec_from_file_location(
    "handbook_delivery_contract", ROOT / "cli" / "handbook_delivery.py"
)
DELIVERY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DELIVERY)
SMOKE_SPEC = importlib.util.spec_from_file_location(
    "handbook_host_smoke_contract", ROOT / "tests" / "smoke_handbook_hosts.py"
)
SMOKE = importlib.util.module_from_spec(SMOKE_SPEC)
SMOKE_SPEC.loader.exec_module(SMOKE)


class HandbookDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name) / "project"
        self.root.mkdir()
        subprocess.run(
            ["git", "init", "-b", "main", str(self.root)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def publish_placeholder(self, body=b"generated handbook body\n"):
        storage = self.root / ".byori"
        storage.mkdir(exist_ok=True)
        (storage / "handbook.md").write_bytes(body)

    def test_preview_is_non_mutating_and_bounded_for_both_hosts(self):
        before = list(self.root.iterdir())
        for host, filename in (("claude", "CLAUDE.md"), ("codex", "AGENTS.md")):
            with self.subTest(host=host):
                result = DELIVERY.preview_connection(self.root, host)
                self.assertEqual(result["status"], "unconfigured")
                self.assertEqual(result["verification"], "unverified")
                self.assertEqual(result["startup_consumption"], "unverified")
                self.assertTrue(result["would_change"])
                self.assertEqual(pathlib.Path(result["instruction_file"]).name, filename)
                self.assertIn(".byori/handbook.md", result["managed_block"])
                self.assertIn("byori handbook sync .", result["managed_block"])
                self.assertIn("beginning of each project task", result["managed_block"])
                self.assertIn("before substantive work", result["managed_block"])
                self.assertIn("exactly once", result["managed_block"])
                self.assertIn("missing, stale, or unavailable", result["managed_block"])
                self.assertIn("do not read `.byori/handbook.md` directly", result["managed_block"])
                self.assertIn("Never enable refresh", result["managed_block"])
                self.assertIn("otherwise it only reads", result["managed_block"])
                self.assertNotIn("@.byori/handbook.md", result["managed_block"])
                self.assertLessEqual(
                    len(result["managed_block"].encode("utf-8")),
                    DELIVERY.MAX_MANAGED_BLOCK_BYTES,
                )
        self.assertEqual(list(self.root.iterdir()), before)

    def test_legacy_guard_stays_recoverable_and_needs_explicit_reconnect(self):
        target = self.root / "CLAUDE.md"
        original = b"# Existing instructions\r\nKeep me exactly.\r\n"
        target.write_bytes(original)
        legacy_config = {**DELIVERY.HOSTS["claude"], "body": DELIVERY.LEGACY_BODY}
        with mock.patch.dict(DELIVERY.HOSTS, {"claude": legacy_config}):
            DELIVERY.connect(self.root, "claude")
        legacy = target.read_bytes()
        status = DELIVERY.connection_status(self.root, "claude")
        self.assertEqual(status["status"], "configured")
        self.assertTrue(any("legacy read-only reference" in warning for warning in status["warnings"]))
        DELIVERY.connect(self.root, "claude")
        self.assertEqual(target.read_bytes(), legacy)
        DELIVERY.disconnect(self.root, "claude")
        self.assertEqual(target.read_bytes(), original)
        DELIVERY.connect(self.root, "claude")
        self.assertIn(b"handbook sync .", target.read_bytes())
        self.assertNotIn(b"handbook show .", target.read_bytes())
        DELIVERY.disconnect(self.root, "claude")
        self.assertEqual(target.read_bytes(), original)

    def test_connect_keeps_handbook_body_out_of_instruction_and_writes_private_record(self):
        secret_body = b"HANDBOOK-BODY-MUST-NOT-BE-COPIED\n"
        self.publish_placeholder(secret_body)
        original = b"# User instructions\nkeep=this-value\n"
        target = self.root / "CLAUDE.md"
        target.write_bytes(original)
        target.chmod(0o640)

        result = DELIVERY.connect(self.root, "claude")

        installed = target.read_bytes()
        self.assertEqual(result["status"], "configured")
        self.assertEqual(result["startup_consumption"], "unverified")
        self.assertTrue(result["changed"])
        self.assertTrue(result["handbook_present"])
        self.assertTrue(installed.endswith(original))
        self.assertNotIn(secret_body.rstrip(), installed)
        self.assertNotIn(b"@.byori/handbook.md", installed)
        self.assertIn(b"At the beginning of each project task", installed)
        self.assertIn(b"do not read `.byori/handbook.md` directly", installed)
        self.assertEqual(installed.count(DELIVERY.START_MARKER), 1)
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)

        record_path = self.root / ".byori" / "connections" / "claude.json"
        record = json.loads(record_path.read_text(encoding="utf-8"))
        backup = record_path.parent / record["backup_file"]
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(record_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual(record_path.parent.stat().st_mode & 0o777, 0o700)
        self.assertNotIn("keep=this-value", record_path.read_text(encoding="utf-8"))

    def test_connect_protects_outputs_in_git_local_exclude_only(self):
        exclude = self.root / ".git" / "info" / "exclude"
        original = exclude.read_bytes()

        DELIVERY.connect(self.root, "claude")
        after_first = exclude.read_bytes()
        DELIVERY.connect(self.root, "claude")

        self.assertTrue(after_first.startswith(original))
        self.assertEqual(after_first.count(b"/.byori/"), 1)
        self.assertEqual(exclude.read_bytes(), after_first)
        self.assertFalse((self.root / ".gitignore").exists())
        status = subprocess.run(
            ["git", "-C", str(self.root), "status", "--porcelain", "--", ".byori"],
            check=True,
            stdout=subprocess.PIPE,
        )
        self.assertEqual(status.stdout, b"")

    def test_connect_refuses_tracked_outputs_before_writing_connection_data(self):
        self.publish_placeholder()
        subprocess.run(
            ["git", "-C", str(self.root), "add", ".byori/handbook.md"], check=True
        )
        exclude = self.root / ".git" / "info" / "exclude"
        original_exclude = exclude.read_bytes()

        with self.assertRaisesRegex(DELIVERY.DeliveryError, "already tracked"):
            DELIVERY.connect(self.root, "codex")

        self.assertFalse((self.root / "AGENTS.md").exists())
        self.assertFalse((self.root / ".byori" / "connections").exists())
        self.assertEqual(exclude.read_bytes(), original_exclude)

    def test_existing_crlf_content_is_byte_exact_after_disconnect(self):
        original = b"# Existing\r\nLine two\r\n"
        target = self.root / "AGENTS.md"
        target.write_bytes(original)

        DELIVERY.connect(self.root, "codex")
        installed = target.read_bytes()
        block_end = installed.index(DELIVERY.END_MARKER) + len(DELIVERY.END_MARKER)
        self.assertIn(b"\r\n", installed[:block_end])
        self.assertTrue(installed.endswith(original))

        result = DELIVERY.disconnect(self.root, "codex")
        self.assertEqual(result["status"], "disconnected")
        self.assertTrue(result["changed"])
        self.assertFalse(result["removed_instruction_file"])
        self.assertEqual(target.read_bytes(), original)

    def test_repeated_connect_and_disconnect_are_idempotent(self):
        target = self.root / "CLAUDE.md"
        target.write_bytes(b"user-owned\n")

        first = DELIVERY.connect(self.root, "claude")
        once = target.read_bytes()
        second = DELIVERY.connect(self.root, "claude")
        self.assertTrue(first["changed"])
        self.assertFalse(second["changed"])
        self.assertEqual(target.read_bytes(), once)

        first_disconnect = DELIVERY.disconnect(self.root, "claude")
        second_disconnect = DELIVERY.disconnect(self.root, "claude")
        self.assertTrue(first_disconnect["changed"])
        self.assertFalse(second_disconnect["changed"])
        self.assertEqual(target.read_bytes(), b"user-owned\n")
        self.assertEqual(
            DELIVERY.connection_status(self.root, "claude")["status"], "disconnected"
        )

    def test_disconnect_preserves_user_changes_outside_owned_block(self):
        target = self.root / "AGENTS.md"
        original = b"original user content\n"
        target.write_bytes(original)
        DELIVERY.connect(self.root, "codex")
        target.write_bytes(target.read_bytes() + b"later user content\n")

        DELIVERY.disconnect(self.root, "codex")

        self.assertEqual(target.read_bytes(), original + b"later user content\n")

    def test_disconnect_rejects_edit_inside_owned_block(self):
        target = self.root / "CLAUDE.md"
        target.write_bytes(b"outside\n")
        DELIVERY.connect(self.root, "claude")
        edited = target.read_bytes().replace(
            b"At the beginning", b"At every beginning", 1
        )
        target.write_bytes(edited)

        with self.assertRaisesRegex(DELIVERY.DeliveryError, "edited"):
            DELIVERY.disconnect(self.root, "claude")
        self.assertEqual(target.read_bytes(), edited)

    def test_absent_original_is_removed_only_if_no_user_content_remains(self):
        target = self.root / "CLAUDE.md"
        DELIVERY.connect(self.root, "claude")
        self.assertTrue(target.exists())
        removed = DELIVERY.disconnect(self.root, "claude")
        self.assertTrue(removed["removed_instruction_file"])
        self.assertFalse(target.exists())

        DELIVERY.connect(self.root, "claude")
        target.write_bytes(target.read_bytes() + b"user added this\n")
        kept = DELIVERY.disconnect(self.root, "claude")
        self.assertFalse(kept["removed_instruction_file"])
        self.assertEqual(target.read_bytes(), b"user added this\n")

    def test_status_verifies_owned_block_and_backup_hashes(self):
        self.publish_placeholder()
        DELIVERY.connect(self.root, "codex")
        status = DELIVERY.connection_status(self.root, "codex")
        self.assertEqual(status["status"], "configured")
        self.assertEqual(status["startup_consumption"], "unverified")

        record_path = self.root / ".byori" / "connections" / "codex.json"
        record = json.loads(record_path.read_text(encoding="utf-8"))
        (record_path.parent / record["backup_file"]).write_bytes(b"changed")
        with self.assertRaisesRegex(DELIVERY.DeliveryError, "backup"):
            DELIVERY.connection_status(self.root, "codex")

    def test_invalid_host_is_rejected(self):
        for operation in (
            DELIVERY.preview_connection,
            DELIVERY.connect,
            DELIVERY.disconnect,
            DELIVERY.connection_status,
        ):
            with self.subTest(operation=operation.__name__):
                with self.assertRaisesRegex(DELIVERY.DeliveryError, "unsupported"):
                    operation(self.root, "other")

    def test_malformed_duplicate_and_unowned_markers_are_rejected(self):
        target = self.root / "CLAUDE.md"
        samples = (
            DELIVERY.START_MARKER + b"\nmissing end\n",
            DELIVERY.START_MARKER
            + b"\n"
            + DELIVERY.START_MARKER
            + b"\n"
            + DELIVERY.END_MARKER
            + b"\n",
            DELIVERY._managed_block("claude"),
        )
        for sample in samples:
            with self.subTest(sample=sample):
                target.write_bytes(sample)
                with self.assertRaises(DELIVERY.DeliveryError):
                    DELIVERY.preview_connection(self.root, "claude")
                self.assertFalse((self.root / ".byori").exists())

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks unavailable")
    def test_symlinked_instruction_storage_and_handbook_paths_are_rejected(self):
        outside = pathlib.Path(self.temporary.name) / "outside"
        outside.write_bytes(b"outside\n")
        (self.root / "CLAUDE.md").symlink_to(outside)
        with self.assertRaises(DELIVERY.DeliveryError):
            DELIVERY.preview_connection(self.root, "claude")
        self.assertEqual(outside.read_bytes(), b"outside\n")

        (self.root / "CLAUDE.md").unlink()
        byori = self.root / ".byori"
        byori.mkdir()
        (byori / "handbook.md").symlink_to(outside)
        with self.assertRaises(DELIVERY.DeliveryError):
            DELIVERY.connect(self.root, "claude")
        self.assertEqual(outside.read_bytes(), b"outside\n")

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks unavailable")
    def test_symlinked_connections_directory_is_rejected(self):
        byori = self.root / ".byori"
        byori.mkdir()
        external_directory = pathlib.Path(self.temporary.name) / "external-connections"
        external_directory.mkdir()
        (byori / "connections").symlink_to(external_directory, target_is_directory=True)

        with self.assertRaises(DELIVERY.DeliveryError):
            DELIVERY.preview_connection(self.root, "codex")
        self.assertEqual(list(external_directory.iterdir()), [])

    def test_concurrent_instruction_change_is_detected_without_overwrite(self):
        target = self.root / "CLAUDE.md"
        target.write_bytes(b"initial\n")
        real_atomic_write = DELIVERY._atomic_write
        raced = {"done": False}

        def atomic_write_with_race(parent_fd, name, data, **kwargs):
            result = real_atomic_write(parent_fd, name, data, **kwargs)
            if name.endswith(".backup") and not raced["done"]:
                raced["done"] = True
                target.write_bytes(b"concurrent user change\n")
            return result

        with mock.patch.object(DELIVERY, "_atomic_write", side_effect=atomic_write_with_race):
            with self.assertRaisesRegex(DELIVERY.DeliveryError, "concurrent change"):
                DELIVERY.connect(self.root, "claude")
        self.assertEqual(target.read_bytes(), b"concurrent user change\n")
        self.assertFalse((self.root / ".byori" / "connections" / "claude.json").exists())

    def test_existing_connection_lock_uses_exclusive_create_handoff(self):
        connections = self.root / ".byori" / "connections"
        connections.mkdir(parents=True)
        lock = connections / ".claude.lock"
        lock.write_bytes(b"")
        directory_fd = os.open(
            str(connections), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        )
        real_open = os.open
        calls = []

        def recording_open(path, flags, mode=0o777, *, dir_fd=None):
            calls.append(flags)
            return real_open(path, flags, mode, dir_fd=dir_fd)

        try:
            with mock.patch.object(DELIVERY.os, "open", side_effect=recording_open):
                with DELIVERY._locked(directory_fd, "claude"):
                    pass
        finally:
            os.close(directory_fd)

        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0] & os.O_EXCL)
        self.assertTrue(calls[0] & os.O_CREAT)
        self.assertFalse(calls[1] & os.O_EXCL)
        self.assertFalse(calls[1] & os.O_CREAT)
        self.assertTrue(calls[1] & os.O_NOFOLLOW)

    def test_smoke_guard_requires_an_actual_host_command_event(self):
        instruction_only = [
            {"type": "system", "instructions": "Run byori handbook sync ."}
        ]
        codex_execution = [
            {
                "type": "item.completed",
                "item": {
                    "type": "command_execution",
                    "command": "byori handbook sync .",
                },
            }
        ]
        claude_execution = [
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "Bash",
                            "input": {"command": "byori handbook sync ."},
                        }
                    ]
                },
            }
        ]

        self.assertFalse(SMOKE._guard_was_run("codex", instruction_only))
        self.assertFalse(SMOKE._guard_was_run("claude", instruction_only))
        self.assertTrue(SMOKE._guard_was_run("codex", codex_execution))
        self.assertTrue(SMOKE._guard_was_run("claude", claude_execution))

    def test_smoke_codex_command_keeps_sandbox_and_rules_enabled(self):
        command = SMOKE._host_argv(
            "codex", "codex", self.root, "test-model", "neutral prompt", 0.25
        )

        self.assertIn("--sandbox", command)
        self.assertEqual(command[command.index("--sandbox") + 1], "read-only")
        self.assertIn("--ask-for-approval", command)
        self.assertEqual(command[command.index("--ask-for-approval") + 1], "never")
        self.assertNotIn("--ignore-rules", command)

    def test_codex_override_prevents_false_connection_claim(self):
        (self.root / "AGENTS.override.md").write_bytes(b"override instructions\n")
        preview = DELIVERY.preview_connection(self.root, "codex")
        self.assertTrue(any("takes precedence" in item for item in preview["warnings"]))
        with self.assertRaisesRegex(DELIVERY.DeliveryError, "takes precedence"):
            DELIVERY.connect(self.root, "codex")
        self.assertFalse((self.root / "AGENTS.md").exists())


if __name__ == "__main__":
    unittest.main()
