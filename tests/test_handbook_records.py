#!/usr/bin/env python3
"""Contract tests for the authoritative original-record journal."""

import concurrent.futures
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "cli" / "handbook_records.py"
SPEC = importlib.util.spec_from_file_location("byori_handbook_records", MODULE_PATH)
RECORDS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECORDS)


def git(repository, *arguments):
    return subprocess.run(
        ("git", "-C", str(repository), *arguments),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ).stdout.strip()


class TemporaryRepository(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repository = pathlib.Path(self.temporary.name) / "project"
        self.repository.mkdir()
        git(self.repository, "init", "-b", "main", ".")

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def envelope(records, marker="graph-snapshot-1"):
        return {
            "complete": True,
            "source": {
                "kind": "caller-verified-graph-snapshot",
                "snapshot": marker,
            },
            "records": records,
        }

    @staticmethod
    def record(
        name="decision:retry-limit",
        body="Retry at most three times.",
        node_type="decision",
        vid="42",
        **changes
    ):
        value = {
            "type": node_type,
            "name": name,
            "vid": vid,
            "body": body,
            "scope": "project",
            "provenance": {
                "adapter": "explicit-test-import",
                "locator": "memory:" + name,
            },
        }
        value.update(changes)
        return value


class JournalContractTests(TemporaryRepository):
    def test_import_preserves_originals_and_loads_a_scoped_snapshot(self):
        original = self.record(
            body="Original body — preserve exactly.\nSecond line.",
            state="active",
            metadata={"vid": "42", "links": [{"relation": "caused_by", "target": "incident:x"}]},
        )
        checkout = self.record(
            name="bug:worktree-only",
            body="Observed only in this checkout.",
            node_type="bug",
            vid="43",
            scope="checkout",
            state="supported",
        )

        snapshot = RECORDS.import_records(self.repository, self.envelope([original, checkout]))
        loaded = RECORDS.load_records(self.repository / ".git" / "..")

        self.assertEqual(loaded, snapshot)
        self.assertRegex(snapshot["revision"], r"^[0-9a-f]{64}$")
        self.assertEqual(snapshot["sequence"], 1)
        by_name = {record["name"]: record for record in snapshot["records"]}
        preserved = by_name["decision:retry-limit"]
        self.assertEqual(
            (preserved["type"], preserved["name"], preserved["vid"]),
            ("decision", "decision:retry-limit", "42"),
        )
        self.assertEqual(preserved["body"], original["body"])
        self.assertEqual(preserved["provenance"], original["provenance"])
        self.assertEqual(preserved["metadata"], original["metadata"])
        self.assertEqual(preserved["state"], "unverified")
        self.assertEqual(preserved["original_state"], "active")
        self.assertEqual(by_name["bug:worktree-only"]["state"], "supported")
        self.assertIn("checkout_id", by_name["bug:worktree-only"]["scope"])
        exclude = pathlib.Path(git(self.repository, "rev-parse", "--git-path", "info/exclude"))
        if not exclude.is_absolute():
            exclude = self.repository / exclude
        self.assertIn("/.byori/", exclude.read_text(encoding="utf-8").splitlines())

    def test_legacy_note_prefixes_preserve_exact_type_name_and_vid(self):
        notes = [
            self.record(
                node_type="note",
                name="pref:korean-responses",
                vid="1001",
                body="Reply in Korean when requested.",
            ),
            self.record(
                node_type="note",
                name="context:deployment",
                vid="1002",
                body="Deployment context.",
            ),
        ]
        snapshot = RECORDS.import_records(self.repository, self.envelope(notes))
        identities = {
            (record["type"], record["name"], record["vid"])
            for record in snapshot["records"]
        }
        self.assertEqual(
            identities,
            {
                ("note", "pref:korean-responses", "1001"),
                ("note", "context:deployment", "1002"),
            },
        )

    def test_typed_prefix_mismatch_and_schema_marker_are_rejected(self):
        mismatch = self.record(node_type="decision", name="bug:not-a-decision")
        schema_marker = self.record(
            node_type="note",
            name="byori:schema-version",
            vid="1",
        )
        for record in (mismatch, schema_marker):
            with self.subTest(record=record), self.assertRaises(RECORDS.RecordError):
                RECORDS.import_records(self.repository, self.envelope([record]))

    def test_missing_journal_is_unavailable_not_an_empty_snapshot(self):
        self.assertIsNone(RECORDS.load_records(self.repository))

    def test_raw_or_incomplete_export_is_rejected_without_creating_storage(self):
        bounded_export = {
            "schema_version": 2,
            "space": "example",
            "items": [self.record()],
            "has_more": True,
            "next_offset": 100,
        }
        for value in (bounded_export, {"complete": False, "source": {}, "records": []}):
            with self.subTest(value=value), self.assertRaises(RECORDS.RecordError):
                RECORDS.import_records(self.repository, value)
        self.assertFalse((self.repository / ".byori").exists())

    def test_unknown_fields_and_bounds_fail_instead_of_truncating(self):
        unknown = self.record(extra_graph_field="would be lost")
        with self.assertRaisesRegex(RECORDS.RecordError, "silently discarded"):
            RECORDS.import_records(self.repository, self.envelope([unknown]))
        with mock.patch.object(RECORDS, "MAX_RECORDS", 1):
            with self.assertRaisesRegex(RECORDS.RecordError, "record-count"):
                RECORDS.import_records(
                    self.repository,
                    self.envelope([self.record(), self.record(name="decision:other")]),
                )
        self.assertFalse((self.repository / ".byori").exists())

    def test_revisions_append_and_stale_writers_cannot_replace_active(self):
        first = RECORDS.import_records(self.repository, self.envelope([self.record()]))
        changed = self.envelope([
            self.record(body="Retry twice after the provider change."),
        ], marker="graph-snapshot-2")
        second = RECORDS.import_records(
            self.repository,
            changed,
            expected_revision=first["revision"],
        )

        self.assertEqual(second["parent_revision"], first["revision"])
        self.assertEqual(second["sequence"], 2)
        snapshots = self.repository / ".byori" / "records" / "snapshots"
        self.assertTrue((snapshots / (first["revision"] + ".json")).is_file())
        self.assertTrue((snapshots / (second["revision"] + ".json")).is_file())
        with self.assertRaises(RECORDS.RecordConflict):
            RECORDS.import_records(
                self.repository,
                self.envelope([self.record(name="decision:stale")]),
                expected_revision=first["revision"],
            )
        self.assertEqual(RECORDS.load_records(self.repository), second)

    def test_import_refuses_to_activate_history_beyond_configured_bounds(self):
        first = RECORDS.import_records(self.repository, self.envelope([self.record()]))
        second = RECORDS.import_records(
            self.repository,
            self.envelope([self.record(body="second")], marker="second"),
            expected_revision=first["revision"],
        )
        storage = self.repository / ".byori" / "records"
        active_before = (storage / "active.json").read_bytes()
        existing_bytes = sum(
            path.stat().st_size for path in (storage / "snapshots").iterdir()
        )
        for limit_name, bound in (
            ("MAX_HISTORY_REVISIONS", 2),
            ("MAX_HISTORY_BYTES", existing_bytes),
        ):
            with self.subTest(limit=limit_name), mock.patch.object(RECORDS, limit_name, bound):
                with self.assertRaisesRegex(RECORDS.RecordError, "history exceeds"):
                    RECORDS.import_records(
                        self.repository,
                        self.envelope([self.record(body="third")], marker="third"),
                        expected_revision=second["revision"],
                    )
                self.assertEqual((storage / "active.json").read_bytes(), active_before)
                self.assertEqual(RECORDS.load_records(self.repository), second)

    def test_missing_parent_revision_is_detected_as_original_record_loss(self):
        first = RECORDS.import_records(self.repository, self.envelope([self.record()]))
        second = RECORDS.import_records(
            self.repository,
            self.envelope([self.record(body="second")], marker="second"),
            expected_revision=first["revision"],
        )
        first_path = (
            self.repository / ".byori" / "records" / "snapshots"
            / (first["revision"] + ".json")
        )
        first_path.unlink()
        with self.assertRaisesRegex(RECORDS.RecordError, "missing a parent"):
            RECORDS.load_records(self.repository)
        self.assertEqual(second["parent_revision"], first["revision"])

    def test_identical_guarded_import_is_a_noop(self):
        envelope = self.envelope([self.record()])
        first = RECORDS.import_records(self.repository, envelope)
        second = RECORDS.import_records(
            self.repository,
            envelope,
            expected_revision=first["revision"],
        )
        self.assertEqual(first, second)
        snapshots = list((self.repository / ".byori" / "records" / "snapshots").iterdir())
        self.assertEqual(len(snapshots), 1)

    def test_failed_activation_leaves_previous_snapshot_active(self):
        first = RECORDS.import_records(self.repository, self.envelope([self.record()]))
        changed = self.envelope([self.record(body="Replacement body")], marker="second")
        with mock.patch.object(RECORDS, "_atomic_write", side_effect=OSError("simulated crash")):
            with self.assertRaises(OSError):
                RECORDS.import_records(
                    self.repository,
                    changed,
                    expected_revision=first["revision"],
                )
        self.assertEqual(RECORDS.load_records(self.repository), first)

    def test_exact_retry_recovers_an_interrupted_first_activation(self):
        envelope = self.envelope([self.record()])
        with mock.patch.object(RECORDS, "_atomic_write", side_effect=OSError("simulated crash")):
            with self.assertRaises(OSError):
                RECORDS.import_records(self.repository, envelope)
        with self.assertRaisesRegex(RECORDS.RecordError, "no active pointer"):
            RECORDS.load_records(self.repository)

        recovered = RECORDS.import_records(self.repository, envelope)
        self.assertEqual(RECORDS.load_records(self.repository), recovered)
        snapshots = self.repository / ".byori" / "records" / "snapshots"
        self.assertEqual([path.name for path in snapshots.iterdir()], [recovered["revision"] + ".json"])

    def test_retry_does_not_recover_an_unexplained_or_different_orphan(self):
        first_envelope = self.envelope([self.record()])
        with mock.patch.object(RECORDS, "_atomic_write", side_effect=OSError("simulated crash")):
            with self.assertRaises(OSError):
                RECORDS.import_records(self.repository, first_envelope)
        different = self.envelope([self.record(body="different")], marker="different")
        with self.assertRaisesRegex(RECORDS.RecordError, "no active pointer"):
            RECORDS.import_records(self.repository, different)
        with self.assertRaisesRegex(RECORDS.RecordError, "no active pointer"):
            RECORDS.load_records(self.repository)

    def test_corrupt_or_symlinked_active_storage_never_loads_as_empty(self):
        RECORDS.import_records(self.repository, self.envelope([self.record()]))
        active = self.repository / ".byori" / "records" / "active.json"
        active.write_text("{broken", encoding="utf-8")
        with self.assertRaises(RECORDS.RecordError):
            RECORDS.load_records(self.repository)

        active.unlink()
        outside = pathlib.Path(self.temporary.name) / "outside.json"
        outside.write_text("{}", encoding="utf-8")
        active.symlink_to(outside)
        with self.assertRaises(RECORDS.RecordError):
            RECORDS.load_records(self.repository)

    def test_active_pointer_without_snapshots_directory_is_corruption(self):
        RECORDS.import_records(self.repository, self.envelope([self.record()]))
        snapshots = self.repository / ".byori" / "records" / "snapshots"
        shutil.rmtree(snapshots)
        with self.assertRaisesRegex(RECORDS.RecordError, "missing its snapshots"):
            RECORDS.load_records(self.repository)

    def test_preserved_snapshots_without_active_pointer_are_unavailable(self):
        RECORDS.import_records(self.repository, self.envelope([self.record()]))
        active = self.repository / ".byori" / "records" / "active.json"
        active.unlink()
        with self.assertRaisesRegex(RECORDS.RecordError, "no active pointer"):
            RECORDS.load_records(self.repository)

    def test_partial_first_snapshot_write_does_not_poison_retry(self):
        def partial_write(descriptor, data):
            os.write(descriptor, data[: max(1, len(data) // 2)])
            raise OSError("simulated interrupted write")

        with mock.patch.object(RECORDS, "_write_all", side_effect=partial_write):
            with self.assertRaises(RECORDS.RecordError):
                RECORDS.import_records(self.repository, self.envelope([self.record()]))
        snapshots = self.repository / ".byori" / "records" / "snapshots"
        self.assertEqual(list(snapshots.iterdir()), [])
        self.assertIsNone(RECORDS.load_records(self.repository))

        recovered = RECORDS.import_records(self.repository, self.envelope([self.record()]))
        self.assertEqual(RECORDS.load_records(self.repository), recovered)

    def test_tampered_snapshot_body_is_rejected(self):
        snapshot = RECORDS.import_records(self.repository, self.envelope([self.record()]))
        path = (
            self.repository / ".byori" / "records" / "snapshots"
            / (snapshot["revision"] + ".json")
        )
        stored = json.loads(path.read_text(encoding="utf-8"))
        stored["records"][0]["body"] = "tampered"
        path.write_text(json.dumps(stored), encoding="utf-8")
        with self.assertRaisesRegex(RECORDS.RecordError, "digest"):
            RECORDS.load_records(self.repository)

    def test_precreated_public_journal_directory_is_rejected(self):
        records = self.repository / ".byori" / "records"
        records.mkdir(parents=True, mode=0o755)
        records.chmod(0o755)
        with self.assertRaisesRegex(RECORDS.RecordError, "not private"):
            RECORDS.import_records(self.repository, self.envelope([self.record()]))

    def test_loaded_provenance_and_metadata_remain_objects(self):
        identity = RECORDS._identity(self.repository)
        source, normalized = RECORDS._normalize_envelope(
            self.envelope([self.record()]),
            identity,
        )
        for field, value in (("provenance", []), ("metadata", [])):
            with self.subTest(field=field):
                record = dict(normalized[0])
                record[field] = value
                with self.assertRaisesRegex(RECORDS.RecordError, field):
                    RECORDS._validate_loaded_record(record, identity)

    def test_ambient_git_routing_cannot_redirect_journal_scope(self):
        outside = pathlib.Path(self.temporary.name) / "outside"
        outside.mkdir()
        git(outside, "init", "-b", "main", ".")
        overrides = {
            "GIT_DIR": str(outside / ".git"),
            "GIT_WORK_TREE": str(outside),
            "GIT_COMMON_DIR": str(outside / ".git"),
            "GIT_INDEX_FILE": str(outside / ".git" / "index"),
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.worktree",
            "GIT_CONFIG_VALUE_0": str(outside),
        }
        with mock.patch.dict(os.environ, overrides, clear=False):
            snapshot = RECORDS.import_records(self.repository, self.envelope([self.record()]))
        self.assertEqual(snapshot["project_root"], str(self.repository.resolve()))
        self.assertTrue((self.repository / ".byori" / "records" / "active.json").is_file())
        self.assertFalse((outside / ".byori").exists())

    def test_copied_journal_cannot_cross_project_scope(self):
        RECORDS.import_records(self.repository, self.envelope([self.record()]))
        other = pathlib.Path(self.temporary.name) / "other"
        other.mkdir()
        git(other, "init", "-b", "main", ".")
        (other / ".byori").mkdir()
        shutil.copytree(
            self.repository / ".byori" / "records",
            other / ".byori" / "records",
        )
        with self.assertRaisesRegex(RECORDS.RecordError, "another project scope"):
            RECORDS.load_records(other)


class ConcurrencyTests(TemporaryRepository):
    def test_threads_with_the_same_expected_revision_have_one_winner(self):
        threading_barrier = threading.Barrier(2)

        def import_one(index):
            threading_barrier.wait()
            try:
                snapshot = RECORDS.import_records(
                    self.repository,
                    self.envelope([self.record(name="decision:item-%d" % index)]),
                )
                return "ok", snapshot["revision"]
            except RECORDS.RecordConflict:
                return "conflict", None

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(import_one, (1, 2)))
        self.assertEqual(sorted(result[0] for result in results), ["conflict", "ok"])
        self.assertIsNotNone(RECORDS.load_records(self.repository))

    def test_processes_with_the_same_expected_revision_have_one_winner(self):
        code = """
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('records_worker', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
envelope = {'complete': True, 'source': {'kind': 'process-test'}, 'records': [{
    'type': 'decision', 'name': 'decision:' + sys.argv[3], 'vid': sys.argv[3],
    'body': 'body', 'scope': 'project',
    'provenance': {'worker': sys.argv[3]}}]}
try:
    module.import_records(pathlib.Path(sys.argv[2]), envelope)
except module.RecordConflict:
    print('conflict')
else:
    print('ok')
"""
        processes = [
            subprocess.Popen(
                [sys.executable, "-c", code, str(MODULE_PATH), str(self.repository), str(index)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for index in (1, 2)
        ]
        outputs = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, stderr)
            outputs.append(stdout.strip())
        self.assertEqual(sorted(outputs), ["conflict", "ok"])
        self.assertIsNotNone(RECORDS.load_records(self.repository))


if __name__ == "__main__":
    unittest.main()
