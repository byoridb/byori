"""Independent public-contract tests for the read-only dependency-context pilot."""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "cli" / "dependency_context.py"
SPEC = importlib.util.spec_from_file_location("dependency_context", MODULE_PATH)
CONTEXT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CONTEXT
SPEC.loader.exec_module(CONTEXT)


class DependencyContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "producer"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Dependency Context Tests")
        self.git("config", "user.email", "tests@example.invalid")
        self.content = "session_lost = 401\npermission_denied = 403\nid = '9223372036854775807'\n"
        self.source = self.repo / "src" / "api.py"
        self.source.parent.mkdir()
        self.source.write_text(self.content, encoding="utf-8")
        self.revision = self.commit()
        self.roots = {"producer": self.repo}
        self.manifest = {
            "schema_version": 1,
            "title": "HTTP session recovery",
            "task": "Recover session loss, but not permission failures or failed fresh login.",
            "repositories": {"producer": {"revision": self.revision}},
            "sources": [self.source_record("api", "src/api.py", self.content)],
            "claims": [{
                "id": "recover", "kind": "consumer_policy",
                "text": "CURATED_BODY: Preserve ID 9223372036854775807 as text.",
                "evidence": [{"source": "api", "start": 1, "end": 3}],
            }],
        }

    def git(self, *args):
        # Identity is configured only in this disposable repository.
        return subprocess.run(
            ["git", "-C", str(self.repo), *args], check=True,
            capture_output=True, text=True,
            env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull},
        ).stdout.strip()

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-m", "temporary fixture")
        return self.git("rev-parse", "HEAD")

    @staticmethod
    def source_record(identifier, path, content):
        data = content.encode("utf-8") if isinstance(content, str) else content
        return {"id": identifier, "repo": "producer", "path": path,
                "sha256": hashlib.sha256(data).hexdigest()}

    def inspect(self, manifest=None, roots=None):
        return CONTEXT.inspect_context(
            self.manifest if manifest is None else manifest,
            self.roots if roots is None else roots,
        )

    def assert_invalid(self, manifest):
        with self.assertRaises(CONTEXT.ContextError):
            CONTEXT.inspect_context(manifest, self.roots)

    def assert_review(self, report, code=None):
        self.assertEqual(report["status"], "needs_review")
        self.assertEqual(report["claims"], [])
        self.assertEqual(report["evidence"], [])
        rendered = CONTEXT.render_context(report)
        self.assertNotIn("CURATED_BODY", rendered)
        if code:
            self.assertIn(code, {item["code"] for item in report["diagnostics"]})

    def snapshot(self):
        # Includes Git metadata and timestamps, so an index refresh is a write too.
        return {
            str(path.relative_to(self.repo)): (
                path.lstat().st_mode, path.lstat().st_mtime_ns,
                os.readlink(path) if path.is_symlink() else
                hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None,
            )
            for path in self.repo.rglob("*")
        }

    def cli(self, manifest=None, *extra):
        path = self.base / "manifest.json"
        path.write_text(json.dumps(self.manifest if manifest is None else manifest), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(MODULE_PATH), "--manifest", str(path),
             "--repo", f"producer={self.repo}", *extra],
            capture_output=True, text=True, timeout=20,
        )

    def test_ready_report_and_rendering_are_deterministic_with_full_citations(self):
        first, second = self.inspect(), self.inspect()
        self.assertEqual(first, second)
        self.assertEqual(first["status"], "ready")
        self.assertEqual(first["schema_version"], 1)
        self.assertEqual(first["claims"], self.manifest["claims"])
        self.assertTrue(first["evidence"])
        self.assertTrue({"title", "task", "repositories", "diagnostics", "metrics", "limitations"} <= first.keys())
        rendered = CONTEXT.render_context(first)
        self.assertEqual(rendered, CONTEXT.render_context(second))
        for value in (self.revision, "producer", "src/api.py", "CURATED_BODY", self.manifest["task"]):
            self.assertIn(value, rendered)
        self.assertRegex(rendered, r"(?:L|lines?\s*|:)1\s*[-–:]\s*(?:L)?3")
        caveats = json.dumps(first["limitations"]).lower()
        for concept in (r"semantic|entailment|correctness", r"test", r"release", r"runtime|installed", r"token"):
            self.assertRegex(caveats, concept)
        metrics = first["metrics"]
        self.assertEqual(metrics["source_bytes_checked"], len(self.content.encode("utf-8")))
        self.assertEqual(metrics["selected_evidence_bytes"], len(self.content.encode("utf-8")))
        self.assertGreater(metrics["context_bytes"], 0)
        self.assertIsNone(metrics["model_tokens"])

    def test_64_bit_identifier_stays_exact_text_through_json_and_rendering(self):
        report = json.loads(json.dumps(self.inspect()))
        self.assertIsInstance(report["claims"][0]["text"], str)
        self.assertEqual(report["claims"][0]["text"], self.manifest["claims"][0]["text"])
        self.assertIn("9223372036854775807", CONTEXT.render_context(report))
        self.assertNotIn("9.223372", CONTEXT.render_context(report))

    def test_unrelated_commit_invalidates_revision_and_withholds_every_body(self):
        self.manifest["claims"].append({**copy.deepcopy(self.manifest["claims"][0]), "id": "other"})
        (self.repo / "notes.txt").write_text("unrelated committed change", encoding="utf-8")
        self.commit()
        self.assert_review(self.inspect(), "revision_mismatch")

    def test_selected_dirty_file_withholds_claims_even_when_head_matches(self):
        self.source.write_text("DO_NOT_LEAK_DIRTY_SOURCE\n", encoding="utf-8")
        report = self.inspect()
        self.assert_review(report, "working_tree_changed")
        self.assertNotIn("DO_NOT_LEAK_DIRTY_SOURCE", json.dumps(report))

    def test_selected_deleted_working_file_requires_review(self):
        self.source.unlink()
        self.assert_review(self.inspect())

    def test_selected_working_symlink_even_to_matching_content_requires_review(self):
        target = self.base / "matching.py"
        target.write_text(self.content, encoding="utf-8")
        self.source.unlink()
        self.source.symlink_to(target)
        self.assert_review(self.inspect())

    def test_committed_symlink_is_never_accepted_as_normal_blob(self):
        self.source.unlink()
        self.source.symlink_to("../../outside-secret")
        self.manifest["repositories"]["producer"]["revision"] = self.commit()
        self.manifest["sources"][0]["sha256"] = hashlib.sha256(b"../../outside-secret").hexdigest()
        try:
            report = self.inspect()
        except CONTEXT.ContextError:
            return  # A forbidden Git object may be rejected as malformed input.
        self.assert_review(report)

    def test_unrelated_untracked_and_tracked_uncommitted_changes_are_accepted(self):
        notes = self.repo / "notes.txt"
        notes.write_text("committed", encoding="utf-8")
        self.manifest["repositories"]["producer"]["revision"] = self.commit()
        notes.write_text("dirty unrelated", encoding="utf-8")
        (self.repo / "untracked.txt").write_text("untracked", encoding="utf-8")
        self.assertEqual(self.inspect()["status"], "ready")

    def test_entire_committed_blob_hash_mismatch_requires_review(self):
        self.manifest["sources"][0]["sha256"] = hashlib.sha256(b"different blob").hexdigest()
        self.assert_review(self.inspect(), "source_hash_mismatch")

    def test_missing_root_missing_directory_and_non_repository(self):
        for roots in ({}, {"producer": self.base / "absent"}, {"producer": self.base}):
            with self.subTest(roots=roots):
                self.assert_review(self.inspect(roots=roots), "repository_unavailable")

    def test_source_missing_from_commit_has_required_diagnostic(self):
        self.manifest["sources"][0]["path"] = "src/absent.py"
        self.assert_review(self.inspect(), "source_missing")

    def test_malformed_top_level_and_schema_versions_raise_value_error_subclass(self):
        self.assertTrue(issubclass(CONTEXT.ContextError, ValueError))
        for value in (None, [], "manifest", 1):
            with self.subTest(value=value):
                self.assert_invalid(value)
        for version in (True, "1", 0, 2):
            manifest = copy.deepcopy(self.manifest)
            manifest["schema_version"] = version
            with self.subTest(version=version):
                self.assert_invalid(manifest)
        for key in self.manifest:
            manifest = copy.deepcopy(self.manifest)
            del manifest[key]
            with self.subTest(missing=key):
                self.assert_invalid(manifest)

    def test_schema_is_closed_at_every_object_level(self):
        for level in ("manifest", "repository", "source", "claim", "evidence"):
            manifest = copy.deepcopy(self.manifest)
            targets = {"manifest": manifest, "repository": manifest["repositories"]["producer"],
                       "source": manifest["sources"][0], "claim": manifest["claims"][0],
                       "evidence": manifest["claims"][0]["evidence"][0]}
            targets[level]["unexpected"] = "not permitted"
            with self.subTest(level=level):
                self.assert_invalid(manifest)

    def test_malformed_nested_containers_and_missing_fields(self):
        for field, value in (("repositories", []), ("sources", {}), ("claims", {}),
                             ("sources", [None]), ("claims", [None])):
            manifest = copy.deepcopy(self.manifest)
            manifest[field] = value
            with self.subTest(field=field, value=value):
                self.assert_invalid(manifest)
        for level in ("repository", "source", "claim", "evidence"):
            template = {"repository": self.manifest["repositories"]["producer"],
                        "source": self.manifest["sources"][0],
                        "claim": self.manifest["claims"][0],
                        "evidence": self.manifest["claims"][0]["evidence"][0]}[level]
            for key in template:
                manifest = copy.deepcopy(self.manifest)
                target = {"repository": manifest["repositories"]["producer"],
                          "source": manifest["sources"][0], "claim": manifest["claims"][0],
                          "evidence": manifest["claims"][0]["evidence"][0]}[level]
                del target[key]
                with self.subTest(level=level, missing=key):
                    self.assert_invalid(manifest)

    def test_gitlink_is_never_accepted_as_normal_blob(self):
        self.source.unlink()
        self.git("update-index", "--add", "--cacheinfo", f"160000,{self.revision},src/api.py")
        self.git("commit", "-m", "temporary gitlink without any remote")
        self.manifest["repositories"]["producer"]["revision"] = self.git("rev-parse", "HEAD")
        try:
            report = self.inspect()
        except CONTEXT.ContextError:
            return
        self.assert_review(report)

    def test_identifiers_and_duplicate_source_or_claim_ids_are_rejected(self):
        for identifier in ("A", "../escape", "a" * 65, "", "a b", 12):
            for collection in ("sources", "claims"):
                manifest = copy.deepcopy(self.manifest)
                manifest[collection][0]["id"] = identifier
                with self.subTest(identifier=identifier, collection=collection):
                    self.assert_invalid(manifest)
        for collection in ("sources", "claims"):
            manifest = copy.deepcopy(self.manifest)
            manifest[collection].append(copy.deepcopy(manifest[collection][0]))
            with self.subTest(duplicate=collection):
                self.assert_invalid(manifest)

    def test_repository_source_and_claim_count_limits(self):
        for collection, limit in (("repositories", 4), ("sources", 12), ("claims", 20)):
            manifest = copy.deepcopy(self.manifest)
            if collection == "repositories":
                manifest[collection] = {f"repo{i}": {"revision": self.revision} for i in range(limit + 1)}
                manifest["sources"][0]["repo"] = "repo0"
            else:
                template = manifest[collection][0]
                manifest[collection] = [{**copy.deepcopy(template), "id": f"item{i}"} for i in range(limit + 1)]
                if collection == "sources":
                    manifest["claims"][0]["evidence"][0]["source"] = "item0"
            with self.subTest(collection=collection):
                self.assert_invalid(manifest)

    def test_full_lowercase_revision_hashes_only_and_sha256_revision_is_valid_schema(self):
        for revision in ("HEAD", "a" * 39, "a" * 41, "A" * 40, "g" * 40, 123):
            manifest = copy.deepcopy(self.manifest)
            manifest["repositories"]["producer"]["revision"] = revision
            with self.subTest(revision=revision):
                self.assert_invalid(manifest)
        self.manifest["repositories"]["producer"]["revision"] = "a" * 64
        self.assert_review(self.inspect(), "revision_mismatch")

    def test_sha256_hash_schema_rejects_invalid_values(self):
        for digest in ("f" * 63, "f" * 65, "G" * 64, "F" * 64, None, 1):
            manifest = copy.deepcopy(self.manifest)
            manifest["sources"][0]["sha256"] = digest
            with self.subTest(digest=digest):
                self.assert_invalid(manifest)

    def test_claim_kinds_required_evidence_and_cross_references(self):
        for kind in ("contract", "consumer_policy", "limitation"):
            self.manifest["claims"][0]["kind"] = kind
            self.assertEqual(self.inspect()["status"], "ready")
        for field, value in (("kind", "fact"), ("text", 9223372036854775807), ("evidence", []), ("evidence", None)):
            manifest = copy.deepcopy(self.manifest)
            manifest["claims"][0][field] = value
            with self.subTest(field=field, value=value):
                self.assert_invalid(manifest)
        for field, value in (("repo", "unknown"), ("evidence_source", "unknown")):
            manifest = copy.deepcopy(self.manifest)
            if field == "repo":
                manifest["sources"][0]["repo"] = value
            else:
                manifest["claims"][0]["evidence"][0]["source"] = value
            with self.subTest(reference=field):
                self.assert_invalid(manifest)

    def test_evidence_ranges_require_one_based_integer_ordered_bounds(self):
        for start, end in ((0, 1), (-1, 1), (3, 2), (True, 2), (1, True), ("1", 2), (1, 2.0), (1, 101)):
            manifest = copy.deepcopy(self.manifest)
            manifest["claims"][0]["evidence"][0].update(start=start, end=end)
            with self.subTest(start=start, end=end):
                self.assert_invalid(manifest)
        self.source.write_text("line\n" * 100, encoding="utf-8")
        self.manifest["repositories"]["producer"]["revision"] = self.commit()
        self.manifest["sources"][0]["sha256"] = hashlib.sha256(self.source.read_bytes()).hexdigest()
        self.manifest["claims"][0]["evidence"][0].update(start=1, end=100)
        self.assertEqual(self.inspect()["status"], "ready")

    def test_evidence_cannot_extend_past_committed_file_lines(self):
        self.manifest["claims"][0]["evidence"][0].update(start=3, end=4)
        self.assert_invalid(self.manifest)

    def test_invalid_unicode_is_a_context_error_not_an_encoding_crash(self):
        self.manifest["claims"][0]["text"] = "invalid surrogate \ud800"
        self.assert_invalid(self.manifest)

    def test_committed_source_byte_limit(self):
        self.source.write_bytes(b"x" * (1024 * 1024 + 1))
        self.manifest["repositories"]["producer"]["revision"] = self.commit()
        self.manifest["sources"][0]["sha256"] = hashlib.sha256(self.source.read_bytes()).hexdigest()
        try:
            report = self.inspect()
        except CONTEXT.ContextError:
            return
        self.assert_review(report)

    def test_total_committed_source_byte_limit(self):
        data = b"line\n" + b"x" * (900 * 1024)
        self.manifest["sources"] = []
        for index in range(5):
            relative = f"src/file{index}.py"
            (self.repo / relative).write_bytes(data)
            self.manifest["sources"].append(self.source_record(f"file{index}", relative, data))
        self.manifest["claims"][0]["evidence"] = [{"source": "file0", "start": 1, "end": 1}]
        self.manifest["repositories"]["producer"]["revision"] = self.commit()
        try:
            report = self.inspect()
        except CONTEXT.ContextError:
            return
        self.assert_review(report)

    def test_traversal_absolute_and_sensitive_paths_are_rejected(self):
        for path in ("../outside", "src/../../outside", "/etc/passwd", ".env", "src/.env",
                     ".env.local", "src/id_rsa", "src/id_ed25519", "src/private.key", "src/secret.pem"):
            manifest = copy.deepcopy(self.manifest)
            manifest["sources"][0]["path"] = path
            with self.subTest(path=path):
                self.assert_invalid(manifest)

    def test_diagnostics_never_leak_absolute_paths_source_or_git_stderr(self):
        report = self.inspect(roots={"producer": self.base / "ABSOLUTE_SECRET_PATH"})
        self.assert_review(report, "repository_unavailable")
        serialized = json.dumps(report)
        for forbidden in (str(self.base), "ABSOLUTE_SECRET_PATH", "fatal:", self.content):
            self.assertNotIn(forbidden, serialized)
        for diagnostic in report["diagnostics"]:
            self.assertIsInstance(diagnostic["code"], str)

    def test_api_is_read_only_does_not_mutate_inputs_or_use_runtime_network(self):
        before, manifest, roots = self.snapshot(), copy.deepcopy(self.manifest), self.roots.copy()
        real_run = subprocess.run

        def local_git_only(command, *args, **kwargs):
            self.assertIsInstance(command, (list, tuple))
            self.assertEqual(Path(command[0]).name, "git")
            for forbidden in ("fetch", "push", "pull", "clone", "checkout", "reset", "config", "login"):
                self.assertNotIn(forbidden, command)
            return real_run(command, *args, **kwargs)

        with mock.patch.object(subprocess, "run", side_effect=local_git_only), \
             mock.patch.object(socket, "create_connection", side_effect=AssertionError("network forbidden")), \
             mock.patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")):
            report = self.inspect()
            CONTEXT.render_context(report)
            self.assertEqual(before, self.snapshot())
            self.source.write_text("dirty", encoding="utf-8")
            dirty_before = self.snapshot()
            self.assert_review(self.inspect())
            self.assertEqual(dirty_before, self.snapshot())
        self.assertEqual(manifest, self.manifest)
        self.assertEqual(roots, self.roots)
        # Exclude the explicit test-owned edit, not Git metadata or other files.
        after = self.snapshot()
        before.pop("src/api.py")
        after.pop("src/api.py")
        self.assertEqual(before, after)

    def test_cli_ready_json_repeatable_roots_default_markdown_and_no_source_writes(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["repositories"]["consumer"] = {"revision": self.revision}
        before = self.snapshot()
        result = self.cli(manifest, "--repo", f"consumer={self.repo}", "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "ready")
        self.assertIn("9223372036854775807", result.stdout)
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.revision, result.stdout)
        self.assertIn("CURATED_BODY", result.stdout)
        self.assertEqual(before, self.snapshot())

    def test_cli_review_exit_one_and_all_bodies_withheld_in_both_formats(self):
        self.source.write_text("dirty", encoding="utf-8")
        before = self.snapshot()
        for extra in ((), ("--format", "json")):
            with self.subTest(extra=extra):
                result = self.cli(None, *extra)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("CURATED_BODY", result.stdout)
                if extra:
                    self.assert_review(json.loads(result.stdout), "working_tree_changed")
        self.assertEqual(before, self.snapshot())

    def test_cli_malformed_manifest_json_or_repo_argument_exits_two(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["unexpected"] = True
        before = self.snapshot()
        self.assertEqual(self.cli(manifest, "--format", "json").returncode, 2)
        path = self.base / "invalid.json"
        path.write_text("{not json", encoding="utf-8")
        for args in (("--manifest", str(path)), ("--manifest", str(path), "--repo", "malformed"),
                     ("--manifest", str(self.base / "missing.json"))):
            with self.subTest(args=args):
                result = subprocess.run([sys.executable, str(MODULE_PATH), *args],
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(before, self.snapshot())


if __name__ == "__main__":
    unittest.main()
