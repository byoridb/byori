"""Reviewed memory CLI boundary; fake API only, no engine or filesystem access."""

import contextlib
import copy
import io
import json
import pathlib
import shlex
import sys
import types
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cli"))
import byori


class MemoryCaptureError(RuntimeError):
    pass


class HandbookMemoryCLITests(unittest.TestCase):
    def setUp(self):
        self.digest = "a" * 64
        self.payload = {
            "schema_version": 1, "state": "preview", "project_root": "/fake/checkout with spaces",
            "review_digest": self.digest, "base_revision": None, "record_count": 1,
            "new_records": 1, "changed_records": 0, "unchanged_records": 0,
            "retained_records": 2, "withheld_records": 1,
            "records": [{"type": "note", "name": "legacy name=exact", "vid": "42",
                         "body": "Keep retries bounded.", "scope": {"kind": "checkout"},
                         "state": "unverified"}],
        }
        self.api = types.ModuleType("handbook_memory")
        self.api.MemoryCaptureError = MemoryCaptureError
        self.api.capture_memory = mock.Mock(return_value=self.payload)
        self.enterContext(mock.patch.dict(sys.modules, {"handbook_memory": self.api}))
        # All environment/credential resolution belongs to the API, not the CLI.
        for name in ("MemoryWriter", "MemoryBridge", "ProjectRegistry", "read_runtime_env",
                     "repository_root", "default_byori_home", "default_byoridb_home"):
            self.enterContext(mock.patch.object(byori, name, side_effect=AssertionError("legacy boundary touched")))
        self.enterContext(mock.patch.object(byori.subprocess, "run", side_effect=AssertionError("no subprocess")))
        self.enterContext(mock.patch("builtins.open", side_effect=AssertionError("no file access")))
        self.enterContext(mock.patch.object(pathlib.Path, "open", side_effect=AssertionError("no file access")))

    def invoke(self, *options):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = byori.main(["handbook", "memory", *options])
        return code, output.getvalue(), errors.getvalue()

    def test_default_preview_delegates_without_resolving_configuration(self):
        before = copy.deepcopy(self.payload)
        code, output, errors = self.invoke("--json")
        self.assertEqual((code, errors), (0, ""))
        self.assertEqual(json.loads(output), before)
        self.assertEqual(self.payload, before)
        self.api.capture_memory.assert_called_once_with(
            pathlib.Path("."), selection=None, apply=False, expected_digest=None)

    def test_selection_preserves_exact_opaque_names_and_typed_names(self):
        code, output, errors = self.invoke(
            "/fake/subdir", "--record", "note= legacy name=exact ",
            "--record", "decision=decision:retry-policy", "--json")
        self.assertEqual((code, errors), (0, ""))
        self.assertEqual(json.loads(output), self.payload)
        self.api.capture_memory.assert_called_once_with(
            pathlib.Path("/fake/subdir"), selection=[
                {"type": "note", "name": " legacy name=exact "},
                {"type": "decision", "name": "decision:retry-policy"}],
            apply=False, expected_digest=None)

    def test_apply_passes_consent_and_returns_api_json_unchanged(self):
        self.payload.update(state="imported", revision="b" * 64, changed=True)
        code, output, errors = self.invoke(
            "/fake/subdir", "--record", "note=legacy name=exact", "--apply",
            "--expected-digest", self.digest, "--json")
        self.assertEqual((code, errors), (0, ""))
        self.assertEqual(json.loads(output), self.payload)
        self.api.capture_memory.assert_called_once_with(
            pathlib.Path("/fake/subdir"), selection=[{"type": "note", "name": "legacy name=exact"}],
            apply=True, expected_digest=self.digest)

    def test_consent_errors_are_rejected_before_api(self):
        cases = (("--apply",), ("--expected-digest", self.digest),
                 ("--apply", "--expected-digest", "short"),
                 ("--apply", "--expected-digest", "A" * 64),
                 ("--apply", "--expected-digest", self.digest + "\n"),
                 ("--apply", "--expected-digest", "../secret"))
        for options in cases:
            with self.subTest(options=options):
                code, output, errors = self.invoke(*options)
                self.assertEqual((code, output), (2, ""))
                self.assertIn("digest", errors)
        self.api.capture_memory.assert_not_called()

    def test_init_handbook_alias_does_not_capture(self):
        with mock.patch.object(byori, "command_handbook", return_value=0) as command:
            self.assertEqual(byori.main(["init", "--handbook", "--dry-run"]), 0)
        self.assertEqual(command.call_args.args[0].handbook_command, "preview")
        self.api.capture_memory.assert_not_called()

    def test_invalid_record_syntax_types_names_and_prefixes_are_safe(self):
        for value in ("note", "note=", "Note=legacy", "unknown=legacy", "note=" + "x" * 257,
                      "note=raw\nsecret", "note=raw\x1bsecret", "decision=opaque",
                      "decision=bug:wrong", "task=task:", "task=task:bad/name"):
            with self.subTest(value=value):
                with self.assertRaises(SystemExit) as raised:
                    self.invoke("--record", value)
                self.assertEqual(raised.exception.code, 2)
        self.api.capture_memory.assert_not_called()

    def test_selection_bound_and_duplicate_identity_are_rejected(self):
        for records in (["note=same", "note=same"], ["note=n%d" % n for n in range(201)]):
            with self.subTest(count=len(records)):
                options = [part for record in records for part in ("--record", record)]
                code, output, errors = self.invoke(*options)
                self.assertEqual((code, output), (2, ""))
                self.assertTrue(errors)
        self.api.capture_memory.assert_not_called()

    def test_maximum_selection_and_note_name_are_accepted(self):
        records = ["note=" + "x" * 256, *["note=n%d" % n for n in range(199)]]
        code, _, errors = self.invoke(*[part for record in records for part in ("--record", record)], "--json")
        self.assertEqual((code, errors), (0, ""))
        self.assertEqual(len(self.api.capture_memory.call_args.kwargs["selection"]), 200)

    def test_human_preview_has_records_counts_scope_and_exact_review_command(self):
        code, output, errors = self.invoke("/fake/subdir", "--record", "note=legacy name=exact")
        self.assertEqual((code, errors), (0, ""))
        for detail in ("preview: 1 records", "checkout", "Keep retries bounded.",
                       "retained: 2", "withheld: 1", "unverified", "Best-effort", "not a transactional backup"):
            self.assertIn(detail, output)
        review = shlex.split(output.splitlines()[-1])
        self.assertEqual(review, ["byori", "handbook", "memory", self.payload["project_root"],
                                 "--record", "note=legacy name=exact", "--apply",
                                 "--expected-digest", self.digest])

    def test_empty_preview_still_has_review_guidance(self):
        self.payload.update(record_count=0, new_records=0, records=[])
        code, output, errors = self.invoke()
        self.assertEqual((code, errors), (0, ""))
        self.assertIn("0 records", output)
        self.assertIn("--expected-digest " + self.digest, output)

    def test_human_apply_reports_revision_and_noop_without_a_second_apply_command(self):
        self.payload.update(state="imported", revision="b" * 64, changed=False)
        code, output, errors = self.invoke("--apply", "--expected-digest", self.digest)
        self.assertEqual((code, errors), (0, ""))
        self.assertIn("imported", output)
        self.assertIn(self.payload["revision"], output)
        self.assertIn("changed: False", output)
        self.assertNotIn("--apply", output)

    def test_api_errors_never_expose_transport_or_credentials(self):
        for exception in (MemoryCaptureError, OSError, ValueError):
            for json_output in (False, True):
                with self.subTest(exception=exception, json_output=json_output):
                    self.api.capture_memory.side_effect = exception("password=PRIVATE raw transport\x1b[31m")
                    code, output, errors = self.invoke(*(["--json"] if json_output else []))
                    self.assertEqual((code, output), (2, ""))
                    self.assertIn("fresh preview", errors)
                    for secret in ("PRIVATE", "password", "transport", "\x1b"):
                        self.assertNotIn(secret, errors)

    def test_other_handbook_commands_never_capture(self):
        handbook = types.ModuleType("handbook")
        handbook.HandbookError = type("HandbookError", (RuntimeError,), {})
        handbook.SourceError = type("SourceError", (RuntimeError,), {})
        handbook.handbook_status = mock.Mock(return_value={"state": "current"})
        handbook.read_handbook = mock.Mock(return_value={"state": "current"})
        handbook.read_evidence = mock.Mock(return_value={"state": "current"})
        refresh = types.ModuleType("handbook_refresh")
        refresh.refresh_handbook = mock.Mock(return_value={"state": "current"})
        refresh.read_config = mock.Mock(return_value={"enabled": False})
        refresh.compile_project_handbook = mock.Mock(return_value={
            "project_root": "/fake/checkout", "evidence": {
                "claims": [], "warnings": [], "exclusions": [],
                "sensitive_sources_withheld": 0, "omitted_sections": []}})
        delivery = types.ModuleType("handbook_delivery")
        delivery.DeliveryError = type("DeliveryError", (RuntimeError,), {})
        handbook.collect_sources = mock.Mock(return_value={"project_root": "/fake/checkout"})
        delivery.preview_connection = mock.Mock(return_value={"state": "preview"})
        delivery.disconnect = mock.Mock(return_value={"state": "disconnected"})
        with mock.patch.dict(sys.modules, {"handbook": handbook, "handbook_refresh": refresh,
                                           "handbook_delivery": delivery}):
            for action in ("preview", "build", "show", "status", "evidence", "sync", "refresh",
                           "refresh-config", "connect", "disconnect"):
                options = ["handbook", action, "--json"]
                if action == "evidence":
                    options.extend(["--generation", self.digest])
                if action in {"connect", "disconnect"}:
                    options.append("codex")
                with self.subTest(action=action), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(byori.main(options), 0)
        self.api.capture_memory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
