"""Adversarial compiler/publication tests; no engine, host, or model calls.

The source worker was still implementing handbook_sources when these tests were
written. That input boundary is replaced with a deterministic snapshot, and
protect_outputs is mocked because those storage fixtures have no Git metadata;
the actual handbook compiler, generation reader, locks, and filesystem writes
run against TemporaryDirectory fixtures. RealSourceAdversarialTests additionally
uses the actual adapter with isolated, unborn Git repositories; no commits,
worktrees, user configuration, or external services are created.
"""

import contextlib
import concurrent.futures
import copy
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class SourceBoundaryError(RuntimeError):
    pass


def unconfigured_collector(*args, **kwargs):
    raise AssertionError("test must configure its isolated source snapshot")


# Import the real compiler without importing an unfinished adapter or allowing
# an adapter import to make this suite depend on the user's actual checkout.
source_boundary = types.ModuleType("handbook_sources")
source_boundary.SourceError = SourceBoundaryError
source_boundary.collect_sources = unconfigured_collector
SPEC = importlib.util.spec_from_file_location(
    "byori_handbook_adversarial", ROOT / "cli" / "handbook.py"
)
HANDBOOK = importlib.util.module_from_spec(SPEC)
with mock.patch.dict(sys.modules, {"handbook_sources": source_boundary}):
    SPEC.loader.exec_module(HANDBOOK)


class HandbookAdversarialTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="byori-adversarial-")
        self.addCleanup(self.temporary.cleanup)
        self.base = pathlib.Path(self.temporary.name).resolve()
        self.root = self.base / "project"
        self.root.mkdir()
        self.source_text = "# Project\n\nKeep retries bounded to three attempts.\n"
        self.source_metadata = {}
        self.warnings = []
        self.exclusions = []
        self.collector = mock.patch.object(
            HANDBOOK, "collect_sources", side_effect=self.snapshot
        )
        self.collector.start()
        self.addCleanup(self.collector.stop)
        # Git ignore policy belongs to the real-source integration boundary;
        # these fixtures intentionally stub collection and have no .git.
        self.output_policy = mock.patch.object(HANDBOOK, "protect_outputs", return_value=None)
        self.output_policy.start()
        self.addCleanup(self.output_policy.stop)

    @property
    def storage(self):
        return self.root / ".byori"

    @property
    def active(self):
        return self.storage / "handbook.md"

    def snapshot(self, root, **limits):
        canonical = pathlib.Path(root).resolve()
        source = {
            "id": "source:" + digest("README.md")[:24],
            "kind": "document",
            "path": "README.md",
            "locator": "README.md",
            "content": self.source_text,
            "digest": digest(self.source_text),
            "metadata": copy.deepcopy(self.source_metadata),
        }
        return {
            "project_root": str(canonical),
            "checkout_id": digest(str(canonical)),
            "head": "1" * 40,
            "snapshot_digest": digest(self.source_text),
            "sources": [source],
            "warnings": list(self.warnings),
            "exclusions": list(self.exclusions),
        }

    def preview(self, **kwargs):
        return HANDBOOK.compile_handbook(self.root, **kwargs)

    def publish(self, **kwargs):
        build = self.preview(**kwargs)
        HANDBOOK.publish_handbook(
            build, accepted_records=kwargs.get("accepted_records")
        )
        return build

    def generation_path(self, build):
        return self.storage / "generations" / build["generation"]

    def assert_unreadable(self):
        status = HANDBOOK.handbook_status(self.root)
        self.assertNotEqual(status["state"], "current", status)
        result = HANDBOOK.read_handbook(self.root)
        self.assertIsNone(result.get("handbook"), result)

    def test_control_roundtrip_is_deterministic_and_idempotent(self):
        build = self.preview()
        self.assertFalse(self.storage.exists(), "preview must not write output")
        self.assertEqual(build, self.preview())
        first = HANDBOOK.publish_handbook(build)
        second = HANDBOOK.publish_handbook(build)
        self.assertTrue(first["changed"])
        self.assertFalse(second["changed"])
        self.assertEqual(HANDBOOK.read_handbook(self.root)["handbook"], build["handbook"])

    def test_cooperative_publishers_serialize_to_one_complete_generation(self):
        build = self.preview()
        ready = threading.Barrier(2, timeout=5)

        def publish_same_snapshot():
            ready.wait()
            return HANDBOOK.publish_handbook(copy.deepcopy(build))

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            jobs = [pool.submit(publish_same_snapshot) for _ in range(2)]
            results = [job.result(timeout=10) for job in jobs]
        self.assertEqual(sorted(result["changed"] for result in results), [False, True])
        self.assertEqual(HANDBOOK.read_handbook(self.root)["handbook"], build["handbook"])

    def test_cooperative_rebuilds_serialize_with_existing_lock(self):
        self.publish()
        self.source_text += "\nA source change before both callers start.\n"
        self.test_cooperative_publishers_serialize_to_one_complete_generation()

    def test_missing_active_returns_no_body_without_creating_storage(self):
        self.assertEqual(HANDBOOK.handbook_status(self.root)["state"], "missing")
        self.assertIsNone(HANDBOOK.read_handbook(self.root)["handbook"])
        self.assertFalse(self.storage.exists())

    def test_source_access_failure_withholds_body_and_preserves_last_generation(self):
        build = self.publish()
        original = self.active.read_bytes()
        with mock.patch.object(
            HANDBOOK, "collect_sources", side_effect=HANDBOOK.SourceError("source access failed")
        ):
            self.assertEqual(HANDBOOK.handbook_status(self.root)["state"], "unavailable")
            self.assertIsNone(HANDBOOK.read_handbook(self.root)["handbook"])
            with self.assertRaises(HANDBOOK.HandbookError):
                HANDBOOK.publish_handbook(build)
        self.assertEqual(self.active.read_bytes(), original)
        self.assertEqual(HANDBOOK.read_handbook(self.root)["handbook"], build["handbook"])

    def test_missing_accepted_snapshot_withholds_body_without_rewriting_output(self):
        records = [{"name": "decision:window", "body": "Keep the accepted maintenance window."}]
        build = self.publish(accepted_records=records)
        original = self.active.read_bytes()
        self.assertEqual(HANDBOOK.handbook_status(self.root)["state"], "unavailable")
        self.assertIsNone(HANDBOOK.read_handbook(self.root)["handbook"])
        self.assertEqual(self.active.read_bytes(), original)
        self.assertEqual(
            HANDBOOK.read_handbook(self.root, accepted_records=records)["handbook"],
            build["handbook"],
        )

    def test_active_disappearing_after_status_is_a_bounded_read_failure(self):
        self.publish()
        actual_status = HANDBOOK.handbook_status

        def remove_after_status(*args, **kwargs):
            result = actual_status(*args, **kwargs)
            self.assertEqual(result["state"], "current")
            self.active.unlink()
            return result

        with mock.patch.object(HANDBOOK, "handbook_status", side_effect=remove_after_status):
            try:
                result = HANDBOOK.read_handbook(self.root)
            except HANDBOOK.HandbookError:
                return
        self.assertIsNone(result.get("handbook"))
        self.assertNotEqual(result["state"], "current")

    def test_storage_disappearing_after_status_is_a_bounded_read_failure(self):
        build = self.publish()
        actual_status = HANDBOOK.handbook_status
        saved = self.root / "saved-output"

        def move_after_status(*args, **kwargs):
            result = actual_status(*args, **kwargs)
            self.assertEqual(result["state"], "current")
            self.storage.rename(saved)
            return result

        with mock.patch.object(HANDBOOK, "handbook_status", side_effect=move_after_status):
            try:
                result = HANDBOOK.read_handbook(self.root)
            except HANDBOOK.HandbookError:
                result = {"state": "unavailable", "handbook": None}
        self.assertIsNone(result.get("handbook"))
        self.assertNotEqual(result["state"], "current")
        self.assertEqual((saved / "handbook.md").read_text(encoding="utf-8"), build["handbook"])

    def test_cooperative_rebuild_between_status_and_read_requires_retry(self):
        self.publish()
        actual_status = HANDBOOK.handbook_status
        replacements = []

        def rebuild_after_status(*args, **kwargs):
            result = actual_status(*args, **kwargs)
            self.assertEqual(result["state"], "current")
            self.source_text += "\nNew source version from another cooperative caller.\n"
            replacements.append(self.publish())
            return result

        with mock.patch.object(HANDBOOK, "handbook_status", side_effect=rebuild_after_status):
            try:
                result = HANDBOOK.read_handbook(self.root)
            except HANDBOOK.HandbookError:
                result = {"handbook": None}
        self.assertIsNone(result.get("handbook"), "a mixed-generation read must ask for a retry")
        self.assertEqual(
            HANDBOOK.read_handbook(self.root)["handbook"], replacements[0]["handbook"]
        )

    def test_publish_rejects_tampered_in_memory_evidence(self):
        build = self.preview()
        build["evidence"]["claims"][0]["body"] = "Invented rule: disable validation."
        with self.assertRaises(HANDBOOK.HandbookError):
            HANDBOOK.publish_handbook(build)
        self.assertFalse(self.active.exists())

    def test_reader_rejects_tampered_published_evidence(self):
        build = self.publish()
        path = self.generation_path(build) / "evidence.json"
        evidence = json.loads(path.read_text(encoding="utf-8"))
        evidence["claims"][0]["body"] = "Invented rule: disable validation."
        path.write_text(json.dumps(evidence), encoding="utf-8")
        self.assert_unreadable()

    def test_reader_rejects_rewritten_handbooks_with_updated_local_digest(self):
        build = self.publish()
        generation = self.generation_path(build)
        forged = build["handbook"] + "\nUnreviewed policy: disable validation.\n"
        self.active.write_text(forged, encoding="utf-8")
        (generation / "handbook.md").write_text(forged, encoding="utf-8")
        path = generation / "evidence.json"
        evidence = json.loads(path.read_text(encoding="utf-8"))
        evidence["handbook_digest"] = digest(forged)
        path.write_text(json.dumps(evidence), encoding="utf-8")
        self.assert_unreadable()

    def test_read_pins_verified_artifact_not_only_generation_id(self):
        build = self.publish()
        actual_status = HANDBOOK.handbook_status
        forged = build["handbook"] + "\nUnreviewed post-verification instruction.\n"
        injected = []

        def edit_after_verification(*args, **kwargs):
            result = actual_status(*args, **kwargs)
            self.assertEqual(result["state"], "current")
            generation = self.generation_path(build)
            self.active.write_text(forged, encoding="utf-8")
            (generation / "handbook.md").write_text(forged, encoding="utf-8")
            path = generation / "evidence.json"
            evidence = json.loads(path.read_text(encoding="utf-8"))
            evidence["handbook_digest"] = digest(forged)
            path.write_text(json.dumps(evidence), encoding="utf-8")
            injected.append(True)
            return result

        with mock.patch.object(HANDBOOK, "handbook_status", side_effect=edit_after_verification):
            try:
                result = HANDBOOK.read_handbook(self.root)
            except HANDBOOK.HandbookError:
                result = {"handbook": None}
        self.assertTrue(injected)
        self.assertTrue(
            result.get("handbook") in (None, build["handbook"]),
            "read returned bytes that were never verified by status",
        )

    def test_staged_evidence_edit_cannot_replace_last_safe_active(self):
        old = self.publish()
        self.source_text += "\nNew source section.\n"
        build = self.preview()
        original_atomic = HANDBOOK._atomic
        injected = []

        def edit_staged_evidence(fd, name, text):
            result = original_atomic(fd, name, text)
            if name == "evidence.json" and not injected:
                path = self.generation_path(build) / "evidence.json"
                material = json.loads(path.read_text(encoding="utf-8"))
                material["claims"][0]["body"] = "Concurrent edit to staged evidence."
                path.write_text(json.dumps(material), encoding="utf-8")
                injected.append(True)
            return result

        with mock.patch.object(HANDBOOK, "_atomic", side_effect=edit_staged_evidence):
            try:
                HANDBOOK.publish_handbook(build)
            except HANDBOOK.HandbookError:
                pass
        self.assertTrue(injected)
        self.assertTrue(
            self.active.read_text(encoding="utf-8") == old["handbook"],
            "edited staged evidence replaced the last safe active generation",
        )
        with HANDBOOK._storage(self.root) as fd:
            self.assertEqual(HANDBOOK._active(fd)[0], old["handbook"])

    def test_manual_active_edit_is_not_overwritten(self):
        self.publish()
        manual = self.active.read_text(encoding="utf-8") + "\nUser correction.\n"
        self.active.write_text(manual, encoding="utf-8")
        self.source_text += "\nAnother source paragraph.\n"
        with self.assertRaises(HANDBOOK.HandbookError):
            HANDBOOK.publish_handbook(self.preview())
        self.assertEqual(self.active.read_text(encoding="utf-8"), manual)
        self.assert_unreadable()

    def test_manual_edit_during_generation_staging_is_preserved(self):
        self.publish()
        self.source_text += "\nAnother source paragraph.\n"
        build = self.preview()
        original_atomic = HANDBOOK._atomic
        manual = "# User-owned correction written during publication\n"
        injected = []

        def edit_during_staging(fd, name, text):
            if name == "evidence.json" and not injected:
                self.active.write_text(manual, encoding="utf-8")
                injected.append(True)
            return original_atomic(fd, name, text)

        with mock.patch.object(HANDBOOK, "_atomic", side_effect=edit_during_staging):
            try:
                HANDBOOK.publish_handbook(build)
            except HANDBOOK.HandbookError:
                pass
        self.assertTrue(injected, "fault-injection point was not exercised")
        self.assertEqual(self.active.read_text(encoding="utf-8"), manual)

    def test_first_publish_preserves_manual_file_created_during_staging(self):
        build = self.preview()
        original_atomic = HANDBOOK._atomic
        manual = "# Existing user instructions arrived while compiler worked\n"
        injected = []

        def create_during_staging(fd, name, text):
            if name == "evidence.json" and not injected:
                self.active.write_text(manual, encoding="utf-8")
                injected.append(True)
            return original_atomic(fd, name, text)

        with mock.patch.object(HANDBOOK, "_atomic", side_effect=create_during_staging):
            try:
                HANDBOOK.publish_handbook(build)
            except HANDBOOK.HandbookError:
                pass
        self.assertTrue(injected)
        self.assertEqual(self.active.read_text(encoding="utf-8"), manual)

    def test_interruption_before_activation_preserves_complete_old_generation(self):
        old = self.publish()
        old_bytes = self.active.read_bytes()
        self.source_text += "\nUpdated documentation.\n"
        build = self.preview()
        replace = HANDBOOK.os.replace
        storage_identity = (self.storage.stat().st_dev, self.storage.stat().st_ino)
        injected = []

        def interrupt_activation(src, dst, *args, **kwargs):
            fd = kwargs.get("dst_dir_fd")
            info = os.fstat(fd) if fd is not None else None
            if (dst == "handbook.md" and info is not None
                    and (info.st_dev, info.st_ino) == storage_identity):
                injected.append(True)
                raise OSError("injected activation interruption")
            return replace(src, dst, *args, **kwargs)

        with mock.patch.object(HANDBOOK.os, "replace", side_effect=interrupt_activation):
            with self.assertRaises(HANDBOOK.HandbookError):
                HANDBOOK.publish_handbook(build)
        self.assertTrue(injected)
        self.assertEqual(self.active.read_bytes(), old_bytes)
        with HANDBOOK._storage(self.root) as fd:
            text, evidence = HANDBOOK._active(fd)
        self.assertEqual(text, old["handbook"])
        self.assertEqual(evidence["generation"], old["generation"])
        HANDBOOK.publish_handbook(build)
        self.assertEqual(HANDBOOK.read_handbook(self.root)["handbook"], build["handbook"])

    def test_source_change_after_preview_blocks_activation(self):
        old = self.publish()
        self.source_text += "\nPreviewed update.\n"
        build = self.preview()
        self.source_text += "\nNewer concurrent edit.\n"
        with self.assertRaises(HANDBOOK.HandbookError):
            HANDBOOK.publish_handbook(build)
        self.assertEqual(self.active.read_text(encoding="utf-8"), old["handbook"])

    def test_source_change_during_generation_staging_blocks_activation(self):
        old = self.publish()
        self.source_text += "\nPreviewed update.\n"
        build = self.preview()
        original_atomic = HANDBOOK._atomic
        injected = []

        def change_during_staging(fd, name, text):
            result = original_atomic(fd, name, text)
            if name == "evidence.json" and not injected:
                self.source_text += "\nNewer edit after the initial snapshot check.\n"
                injected.append(True)
            return result

        with mock.patch.object(HANDBOOK, "_atomic", side_effect=change_during_staging):
            with self.assertRaises(HANDBOOK.HandbookError):
                HANDBOOK.publish_handbook(build)
        self.assertTrue(injected)
        self.assertEqual(self.active.read_text(encoding="utf-8"), old["handbook"])

    def test_omitted_records_do_not_silently_erase_checkpoint_only_knowledge(self):
        body = "Checkpoint-only fact: coordinate the maintenance window with Alice."
        old = self.publish(accepted_records=[{"name": "decision:window", "body": body}])
        self.source_text += "\nSource-only refresh.\n"
        try:
            HANDBOOK.publish_handbook(self.preview())
        except HANDBOOK.HandbookError:
            # Either explicit failure or preservation is safe. Silently treating
            # unavailable authoritative records as an empty snapshot is not.
            self.assertEqual(self.active.read_text(encoding="utf-8"), old["handbook"])
        self.assertIn(body, self.active.read_text(encoding="utf-8"))

    def test_explicit_empty_records_can_remove_previously_supplied_records(self):
        body = "Checkpoint-only fact: a retired maintenance window."
        self.publish(accepted_records=[{"name": "decision:window", "body": body}])
        new = self.preview(accepted_records=[])
        HANDBOOK.publish_handbook(new, accepted_records=[])
        result = HANDBOOK.read_handbook(self.root, accepted_records=[])
        self.assertEqual(result["state"], "current")
        self.assertNotIn(body, result["handbook"])

    def test_wrong_checkout_record_is_rejected(self):
        with self.assertRaises(HANDBOOK.HandbookError):
            self.preview(accepted_records=[{
                "name": "decision:foreign", "body": "Other checkout fact.",
                "checkout_id": "not-this-checkout",
            }])
        self.assertFalse(self.storage.exists())

    def test_generation_cannot_be_published_into_another_root(self):
        build = self.preview()
        other = self.base / "other-project"
        other.mkdir()
        build["project_root"] = str(other)
        with self.assertRaises(HANDBOOK.HandbookError):
            HANDBOOK.publish_handbook(build)
        self.assertFalse((other / ".byori" / "handbook.md").exists())

    def test_existing_generation_collision_is_not_overwritten(self):
        build = self.preview()
        generation = self.generation_path(build)
        generation.mkdir(parents=True)
        foreign = generation / "evidence.json"
        foreign.write_text("user-owned evidence", encoding="utf-8")
        with self.assertRaises(HANDBOOK.HandbookError):
            HANDBOOK.publish_handbook(build)
        self.assertEqual(foreign.read_text(encoding="utf-8"), "user-owned evidence")
        self.assertFalse(self.active.exists())

    def test_reader_rejects_invalid_generation_headers(self):
        self.storage.mkdir()
        for generation in ("../outside", "f" * 63, "g" * 64, "A" * 64, ""):
            with self.subTest(generation=generation):
                self.active.write_text(
                    "<!-- byori-handbook:v1 generation=%s -->\n# Forged\n" % generation,
                    encoding="utf-8",
                )
                self.assert_unreadable()

    def test_reader_rejects_missing_or_malformed_generation_evidence(self):
        build = self.publish()
        path = self.generation_path(build) / "evidence.json"
        for raw in (None, "{", "null", "[]", "{}"):
            with self.subTest(raw=raw):
                if raw is None:
                    path.unlink()
                else:
                    path.write_text(raw, encoding="utf-8")
                self.assert_unreadable()

    def test_reader_handles_invalid_policy_types_without_crashing(self):
        build = self.publish()
        path = self.generation_path(build) / "evidence.json"
        for policy in (None, [], "invalid", {"source_limits": [], "max_chars": 12000}):
            with self.subTest(policy=policy):
                evidence = copy.deepcopy(build["evidence"])
                evidence["policy"] = policy
                path.write_text(json.dumps(evidence), encoding="utf-8")
                self.assert_unreadable()

    def test_output_symlinks_never_modify_external_targets(self):
        for target in ("storage", "generations", "generation", "evidence", "copy", "active", "lock"):
            with self.subTest(target=target), tempfile.TemporaryDirectory(dir=self.base) as tmp:
                self.root = pathlib.Path(tmp) / "project"
                self.root.mkdir()
                build = self.preview()
                outside = pathlib.Path(tmp) / "outside"
                outside.mkdir()
                sentinel = outside / "sentinel"
                sentinel.write_text("external original", encoding="utf-8")
                if target == "storage":
                    self.storage.symlink_to(outside, target_is_directory=True)
                else:
                    self.storage.mkdir()
                    generations = self.storage / "generations"
                    if target == "generations":
                        generations.symlink_to(outside, target_is_directory=True)
                    elif target in {"generation", "evidence", "copy"}:
                        generations.mkdir()
                        generation = self.generation_path(build)
                        if target == "generation":
                            generation.symlink_to(outside, target_is_directory=True)
                        else:
                            generation.mkdir()
                            name = "evidence.json" if target == "evidence" else "handbook.md"
                            (generation / name).symlink_to(sentinel)
                    else:
                        name = "handbook.md" if target == "active" else "compiler.lock"
                        (self.storage / name).symlink_to(sentinel)
                with self.assertRaises(HANDBOOK.HandbookError):
                    HANDBOOK.publish_handbook(build)
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "external original")
                self.assertEqual(sorted(p.name for p in outside.iterdir()), ["sentinel"])

    def test_regular_file_at_storage_root_is_preserved(self):
        self.storage.write_text("user-owned file", encoding="utf-8")
        with self.assertRaises(HANDBOOK.HandbookError):
            HANDBOOK.publish_handbook(self.preview())
        self.assertEqual(self.storage.read_text(encoding="utf-8"), "user-owned file")

    def test_fifo_active_is_rejected_without_blocking(self):
        self.storage.mkdir()
        os.mkfifo(self.active)
        self.assert_unreadable()
        with self.assertRaises(HANDBOOK.HandbookError):
            HANDBOOK.publish_handbook(self.preview())

    def test_sensitive_body_is_absent_from_all_published_artifacts_and_diagnostics(self):
        secret = "ghp_" + "SyntheticSecretValue" * 3
        self.source_text = "# Configuration\n\napi_key=" + secret + "\n"
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            build = self.publish(accepted_records=[{
                "name": "note:secret", "body": "access_token=" + secret,
            }])
        self.assertTrue(secret not in json.dumps(build), "synthetic secret leaked in build")
        self.assertNotIn(secret, output.getvalue())
        for path in self.storage.rglob("*"):
            if path.is_file():
                self.assertNotIn(secret.encode(), path.read_bytes(), str(path))

    def test_sensitive_accepted_record_metadata_is_not_published(self):
        secret = "ghp_" + "SyntheticSecretValue" * 3
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            try:
                build = self.publish(accepted_records=[{
                    "name": "decision:window", "body": "Keep maintenance windows short.",
                    "annotation": "api_key=" + secret,
                }])
            except HANDBOOK.HandbookError as exc:
                self.assertNotIn(secret, str(exc))
            else:
                self.assertTrue(
                    secret not in json.dumps(build),
                    "synthetic secret leaked through accepted-record metadata",
                )
        self.assertNotIn(secret, output.getvalue())
        if self.storage.exists():
            for path in self.storage.rglob("*"):
                if path.is_file():
                    self.assertNotIn(secret.encode(), path.read_bytes(), str(path))

    def test_allowlisted_metadata_secret_assignment_is_not_hidden_by_json_quoting(self):
        secret = "synthetic-password-value-48291"
        try:
            build = self.publish(accepted_records=[{
                "name": "decision:window", "body": "Keep maintenance windows short.",
                "revision": "password=" + secret,
            }])
        except HANDBOOK.HandbookError as exc:
            self.assertNotIn(secret, str(exc))
        else:
            self.assertTrue(
                secret not in json.dumps(build),
                "allowlisted metadata bypassed the existing password-assignment detector",
            )
        if self.storage.exists():
            for path in self.storage.rglob("*"):
                if path.is_file():
                    self.assertNotIn(secret.encode(), path.read_bytes(), str(path))


class RealSourceAdversarialTests(unittest.TestCase):
    """Actual collector/compiler integration, without commits or live profiles."""

    def setUp(self):
        source_path = ROOT / "cli" / "handbook_sources.py"
        if not source_path.is_file():
            self.skipTest("source worker has not provided handbook_sources.py yet")
        spec = importlib.util.spec_from_file_location("adversarial_real_sources", source_path)
        self.sources = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.sources)
        self.temporary = tempfile.TemporaryDirectory(prefix="byori-source-adversarial-")
        self.addCleanup(self.temporary.cleanup)
        self.base = pathlib.Path(self.temporary.name).resolve()
        self.root = self.base / "project"
        self.root.mkdir()
        # Remove ambient Git routing before creating the fixture. Deliberate
        # routing variables are introduced only by the corresponding test.
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("GIT_")}
        self.environment = mock.patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.git(self.root, "init", "-b", "main")
        patches = (
            mock.patch.object(HANDBOOK, "collect_sources", self.sources.collect_sources),
            mock.patch.object(HANDBOOK, "SourceError", self.sources.SourceError),
        )
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    @staticmethod
    def git(root, *arguments):
        return subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
             "-C", str(root), *arguments],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ).stdout.strip()

    def stage(self, relative, content, root=None):
        root = root or self.root
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        self.git(root, "add", "--force", "--", relative)
        return path

    def test_real_collector_roundtrip_and_dirty_rebuild(self):
        path = self.stage("README.md", "# Project\n\nKeep retries bounded.\n")
        build = HANDBOOK.compile_handbook(self.root, max_commits=0)
        self.assertEqual(build, HANDBOOK.compile_handbook(self.root, max_commits=0))
        HANDBOOK.publish_handbook(build)
        self.assertEqual(HANDBOOK.read_handbook(self.root)["handbook"], build["handbook"])
        path.write_text("# Project\n\nRetry no more than twice.\n", encoding="utf-8")
        self.assertIsNone(HANDBOOK.read_handbook(self.root)["handbook"])
        new = HANDBOOK.compile_handbook(self.root, max_commits=0)
        HANDBOOK.publish_handbook(new)
        self.assertNotEqual(new["generation"], build["generation"])
        self.assertEqual(HANDBOOK.read_handbook(self.root)["handbook"], new["handbook"])

    def test_ambient_git_routing_cannot_redirect_requested_project(self):
        self.stage("README.md", "# Requested project\n\nAuthorized context.\n")
        other = self.base / "unrelated-project"
        other.mkdir()
        self.git(other, "init", "-b", "main")
        marker = "UNRELATED-PROJECT-PRIVATE-CONTEXT"
        self.stage("README.md", "# Other project\n\n" + marker + "\n", root=other)
        with mock.patch.dict(os.environ, {
            "GIT_DIR": str(other / ".git"), "GIT_WORK_TREE": str(other),
        }):
            try:
                build = HANDBOOK.compile_handbook(self.root, max_commits=0)
            except HANDBOOK.HandbookError:
                return
        self.assertEqual(pathlib.Path(build["project_root"]), self.root)
        self.assertNotIn(marker, json.dumps(build))

    def test_raw_transcript_directory_is_excluded_from_compiler_output(self):
        self.stage("README.md", "# Project\n\nSafe selected documentation.\n")
        marker = "PRIVATE-RAW-CONVERSATION-SENTINEL"
        self.stage(
            "docs/transcripts/session.md",
            "# Raw chat transcript\n\nUser: " + marker + "\nAssistant: private trace.\n",
        )
        build = HANDBOOK.compile_handbook(self.root, max_commits=0)
        self.assertTrue(marker not in json.dumps(build), "raw transcript content was compiled")

    def test_excluded_secret_filename_does_not_leak_through_evidence_diagnostics(self):
        self.stage("README.md", "# Project\n\nSafe selected documentation.\n")
        secret = "ghp_" + "SyntheticFilenameToken" * 2
        self.stage(".env." + secret, "excluded file body\n")
        build = HANDBOOK.compile_handbook(self.root, max_commits=0)
        self.assertTrue(
            secret not in json.dumps(build),
            "excluded secret-like filename leaked a recognized token through evidence",
        )


class JournalHistoryBoundaryTests(unittest.TestCase):
    """A successful import must never activate an unreadable history chain."""

    def assert_history_extension_refused(self, limit_name):
        spec = importlib.util.spec_from_file_location(
            "adversarial_record_journal", ROOT / "cli" / "handbook_records.py"
        )
        journal = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(journal)
        with tempfile.TemporaryDirectory(prefix="byori-journal-boundary-") as temporary:
            root = pathlib.Path(temporary).resolve()
            RealSourceAdversarialTests.git(root, "init", "-b", "main")

            def envelope(body):
                return {
                    "complete": True,
                    "source": {"kind": "explicit-test-snapshot", "revision": body},
                    "records": [{
                        "type": "decision", "name": "decision:window", "vid": "42",
                        "body": body, "scope": "project",
                        "provenance": {"locator": "memory:decision:window"},
                    }],
                }

            one = journal.import_records(root, envelope("one"))
            two = journal.import_records(root, envelope("two"), expected_revision=one["revision"])
            storage = root / ".byori" / "records"
            before = (storage / "active.json").read_bytes()
            bound = 2 if limit_name == "MAX_HISTORY_REVISIONS" else sum(
                path.stat().st_size for path in (storage / "snapshots").iterdir()
            )
            with mock.patch.object(journal, limit_name, bound):
                self.assertEqual(journal.load_records(root), two)
                with self.assertRaises(journal.RecordError):
                    journal.import_records(root, envelope("three"), expected_revision=two["revision"])
                self.assertEqual((storage / "active.json").read_bytes(), before)
                self.assertEqual(journal.load_records(root), two)

    def test_history_revision_limit_is_enforced_before_activation(self):
        self.assert_history_extension_refused("MAX_HISTORY_REVISIONS")

    def test_history_byte_limit_is_enforced_before_activation(self):
        self.assert_history_extension_refused("MAX_HISTORY_BYTES")


if __name__ == "__main__":
    unittest.main()
