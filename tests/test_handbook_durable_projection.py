"""Independent cross-process projection contract tests, using real temporary Git.

Only this file is owned by the durable integration verifier. Every compiler/CLI
run starts a fresh interpreter; spies call the real collector and projector.
No fixture engine, host, installer, service, network, or live project is used.
Missing durable integration is a failure, never a skip or a counter-only pass.
"""

import contextlib
import copy
import fcntl
import hashlib
import io
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE_NAME = ".byori-projection-cache-v1"
MARKER = "RETRACTABLE_ORIGINAL_649"


def records():
    def row(name, body, **declarations):
        return {"name": name, "type": name.split(":")[0], "state": "accepted",
                "body": body, "metadata": {"handbook": declarations}}
    return [row("module:transport", "Transport owns the wire format."),
            row("module:payments", "Payments owns dispatch.", depends_on=["module:transport"]),
            row("decision:retry", "Retry at most twice.", affects=["module:payments"],
                conditions=["Only before capture; never after settlement."]),
            row("module:reports", "Reports are independent.")]


def tree_snapshot(root):
    """No symlink traversal/FIFO reads; include metadata that reveals rewrites."""
    if not root.exists() and not root.is_symlink():
        return None
    result = {}
    for path in [root, *sorted(root.rglob("*"))] if root.is_dir() else [root]:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            body = ("symlink", os.readlink(path))
        elif stat.S_ISREG(info.st_mode):
            body = ("regular", path.read_bytes())
        else:
            body = ("special-or-directory",)
        result[str(path.relative_to(root))] = (
            stat.S_IMODE(info.st_mode), info.st_ino, info.st_nlink,
            info.st_mtime_ns, info.st_ctime_ns, body)
    return result


def worker(request):
    """Instrumentation is in this verifier, not a production diagnostic seam."""
    runtime = pathlib.Path(request.get("runtime", ROOT / "cli"))
    sys.path.insert(0, str(runtime))
    import handbook
    import handbook_refresh

    root = pathlib.Path(request["root"])
    calls, passes, collections_seen = [], [], []
    original_project = handbook._project_source
    original_compile = handbook.compile_handbook
    original_collect = handbook.collect_sources
    original_atomic = handbook._atomic
    original_replace = os.replace
    staged = []
    cancelled = []

    def project(value):
        calls.append({"id": value["source"]["id"], "locator": value["source"]["locator"]})
        return original_project(value)

    def collect(*args, **kwargs):
        result = original_collect(*args, **kwargs)
        collections_seen.append(result["snapshot_digest"])
        return result

    def compile_spy(*args, **kwargs):
        diagnostics = kwargs.setdefault("projection_stats", {})
        offset = len(calls)
        result = original_compile(*args, **kwargs)
        passes.append({"stats": copy.deepcopy(diagnostics), "calls": calls[offset:],
                       "clean": kwargs.get("clean_projection", False)})
        return result

    def atomic(fd, name, text):
        result = original_atomic(fd, name, text)
        if name == "evidence.json" and not staged:
            staged.append(True)
            fault = request.get("fault")
            if fault == "staged-failure":
                raise OSError("synthetic staged I/O failure")
            if fault == "staged-cancel":
                cancelled.append(True)
            if fault == "staged-source-race":
                (root / "README.md").write_text("# Changed\n\nRACE_WINNER_991.\n", encoding="utf-8")
            if fault == "staged-exit":
                os._exit(73)
        return result

    def replace(src, dst, *args, **kwargs):
        if request.get("fault") == "cache-write-failure" and pathlib.Path(dst).name == "entry.json":
            raise OSError("synthetic cache-only replace failure")
        return original_replace(src, dst, *args, **kwargs)

    started = time.monotonic()
    response = {"implementation": handbook._PROJECTION_IMPLEMENTATION}
    if request.get("rewrite_loaded_runtime"):
        # Only a temporary copy is eligible for the update-after-import experiment.
        if not runtime.is_relative_to(root.parent) or runtime == ROOT / "cli":
            raise AssertionError("loaded-code update must stay inside the fixture")
        path = runtime / "handbook.py"
        code = path.read_text()
        old = '"kind": "attributed_excerpt"'
        if old not in code:
            raise AssertionError("real projection replacement target missing")
        path.write_text(code.replace(old, '"kind": "attributed_excerpt_v2"'))
    with mock.patch.object(handbook, "_project_source", side_effect=project), \
            mock.patch.object(handbook, "collect_sources", side_effect=collect), \
            mock.patch.object(handbook, "compile_handbook", side_effect=compile_spy), \
            mock.patch.object(handbook, "_atomic", side_effect=atomic), \
            mock.patch.object(os, "replace", side_effect=replace):
        try:
            action = request.get("action", "compile")
            if action == "cli":
                import byori
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    code = byori.main(request["argv"])
                response.update(code=code, stdout=out.getvalue(), stderr=err.getvalue())
                if code == 0:
                    response["result"] = json.loads(out.getvalue())
            elif action == "journal":
                import handbook_records
                previous = handbook_records.load_records(root)
                response["result"] = handbook_records.import_records(root, {
                    "complete": True, "source": {"kind": "synthetic-durable-verifier"},
                    "records": request["records"],
                }, expected_revision=None if previous is None else previous["revision"])
            elif action == "config":
                response["result"] = handbook_refresh.configure_refresh(
                    root, enabled=False, source_limits={"exclude_paths": request["exclude_paths"]})
            elif action == "read":
                response["result"] = handbook.read_handbook(root)
            else:
                options = {"max_commits": 0, "max_chars": 16000,
                           "clean_projection": request.get("clean", False)}
                options.update(request.get("options", {}))
                if "records" in request:
                    options["accepted_records"] = request["records"]
                result = handbook.compile_handbook(root, **options)
                if action == "build":
                    publish_options = {"cancelled": lambda: bool(cancelled)}
                    if "records" in request:
                        publish_options["accepted_records"] = request["records"]
                    if request.get("clean"):
                        publish_options["clean_projection"] = True
                    result = handbook.publish_handbook(result, **publish_options)
                response["result"] = result
        except Exception as exc:
            response["error"] = {"type": type(exc).__name__, "message": str(exc)}
    response.update(pid=os.getpid(), calls=calls, passes=passes,
                    collections=collections_seen, staged=bool(staged),
                    elapsed_ms=round((time.monotonic() - started) * 1000, 3))
    return response


class DurableProjectionIntegrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="byori-durable-verifier-")
        self.addCleanup(temporary.cleanup)
        self.base = pathlib.Path(temporary.name).resolve()
        self.root = self.base / "checkout"
        self.root.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GIT_", "BYORI", "CLAUDE_", "PYTHON"))}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
                        GIT_CONFIG_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0",
                        PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1",
                        BYORI_HOME=str(self.base / "byori-home"),
                        BYORIDB_HOME=str(self.base / "unused-engine-home"))
        self.git("init", "-b", "main")
        self.write("README.md", "# Fixture\n\nCheckout-local deterministic source.\n")
        self.write("docs/operations.md", "# Operations\n\n" + MARKER + ".\n")
        self.write("docs/independent.md", "# Independent\n\nUnrelated documentation.\n")
        self.commit("Create isolated originals")
        self.cache = pathlib.Path(self.git("rev-parse", "--absolute-git-dir")) / CACHE_NAME

    def git(self, *args, root=None):
        return subprocess.run(["git", "--no-pager", "-c", "core.hooksPath=/dev/null",
                               "-c", "core.fsmonitor=false", "-C", str(root or self.root), *args],
                              env=self.env, capture_output=True, text=True, check=True,
                              timeout=15).stdout.strip()

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return target

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=Durable verifier", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-m", message)

    def run_worker(self, action="compile", *, root=None, expected_exit=0, environment=None, **kwargs):
        request = {"root": str(root or self.root), "action": action, **kwargs}
        result = subprocess.run([sys.executable, "-B", str(pathlib.Path(__file__).resolve()), "--worker"],
                                input=json.dumps(request), text=True, capture_output=True,
                                env={**self.env, **(environment or {})}, cwd=root or self.root, timeout=25)
        self.assertEqual(result.returncode, expected_exit,
                         "fixture worker failed: " + result.stderr[-2000:])
        if expected_exit:
            return None
        return json.loads(result.stdout)

    def ok(self, action="compile", **kwargs):
        response = self.run_worker(action, **kwargs)
        self.assertNotIn("error", response, response.get("error"))
        return response

    def cli(self, action, *args, root=None, success=True, **kwargs):
        target = root or self.root
        response = self.run_worker("cli", root=target,
                                   argv=["handbook", action, str(target), "--json", *args], **kwargs)
        if success:
            self.assertNotIn("error", response, response.get("error"))
            self.assertEqual(response["code"], 0, response.get("stderr"))
        return response

    def seed(self, **kwargs):
        response = self.ok("build", **kwargs)
        self.assertTrue(response["result"]["published"])
        self.assertTrue((self.cache / "entry.json").is_file(), "successful normal publication must seed durable cache")
        self.assertTrue((self.cache / "key").is_file())
        return response

    def artifacts_equal(self, first, second):
        for field in ("schema_version", "generation", "project_root", "handbook", "evidence"):
            self.assertEqual(first["result"][field], second["result"][field], field)
        # Also compare encoded full evidence, without stripping generation/bookkeeping fields.
        encode = lambda value: json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        self.assertEqual(encode(first["result"]["evidence"]), encode(second["result"]["evidence"]))

    def actual_first_calls(self, response):
        self.assertTrue(response["passes"], "instrumented compile must actually execute")
        return {item["locator"] for item in response["passes"][0]["calls"]}

    def assert_cold(self, response):
        evidence = response["result"]["evidence"]
        expected = {source["locator"] for source in evidence["sources"]}
        self.assertEqual(self.actual_first_calls(response), expected)
        self.assertEqual(response["passes"][0]["stats"]["reused_sources"], 0)

    def test_fresh_build_reuses_real_projector_and_preserves_all_artifacts(self):
        first = self.seed()
        self.assert_cold(first)
        second = self.ok("build")
        self.assertNotEqual(first["pid"], second["pid"])
        self.assertEqual(second["calls"], [], "fresh process must reuse actual projections, not relabel a full compile")
        self.assertGreaterEqual(len(second["collections"]), 2)
        self.assertFalse(second["result"]["changed"])
        self.artifacts_equal(first, second)
        clean = self.ok(clean=True)
        self.assert_cold(clean)
        self.artifacts_equal(second, clean)
        self.assertEqual(second["passes"][0]["stats"]["reused_sources"], len(clean["calls"]))
        self.assertNotEqual(second["passes"][0]["stats"]["mode"], "process-local")

    def test_cli_build_cold_then_fresh_warm_then_clean_exact_generation(self):
        first = self.cli("build")
        self.assertGreater(len(first["calls"]), 0)
        self.assertTrue((self.cache / "entry.json").exists())
        second = self.cli("build")
        self.assertEqual(second["calls"], [])
        self.assertGreaterEqual(len(second["collections"]), 2)
        generation = second["result"]["generation"]
        evidence_path = self.root / ".byori/generations" / generation / "evidence.json"
        evidence_before = evidence_path.read_bytes()
        cache_before = tree_snapshot(self.cache)
        clean = self.cli("build", "--clean")
        self.assertGreaterEqual(len(clean["passes"]), 2)
        for item in clean["passes"]:
            self.assertTrue(item["clean"], "--clean must propagate through every publication revalidation")
            self.assertGreater(len(item["calls"]), 0)
            self.assertEqual(item["stats"]["reused_sources"], 0)
        for field in ("schema_version", "generation", "project_root", "handbook", "claim_count",
                      "warnings", "excluded_sources", "sensitive_sources_withheld", "omitted_sections"):
            self.assertEqual(first["result"][field], second["result"][field], field)
            self.assertEqual(second["result"][field], clean["result"][field], field)
        self.assertEqual(evidence_path.read_bytes(), evidence_before)
        self.assertEqual(tree_snapshot(self.cache), cache_before)
        for result in (first, second, clean):
            if "projection_stats" in result["result"]:
                self.assertEqual(result["result"]["projection_stats"]["projected_sources"],
                                 len(result["calls"]))
                statistics = result["result"]["projection_stats"]
                expected_phases = ["initial_compile", "locked_revalidation"]
                if result["staged"]:
                    expected_phases.append("activation_revalidation")
                self.assertEqual([item["phase"] for item in statistics["passes"]],
                                 expected_phases)
                for observed, actual in zip(statistics["passes"], result["passes"]):
                    self.assertEqual(observed["projected_sources"], len(actual["calls"]))

    def test_clean_first_cli_build_never_seeds_and_every_pass_is_real(self):
        clean = self.cli("build", "--clean")
        self.assertFalse(self.cache.exists())
        self.assertGreaterEqual(len(clean["passes"]), 3)
        for item in clean["passes"]:
            self.assertTrue(item["clean"])
            self.assertGreater(len(item["calls"]), 0)
            self.assertEqual(item["stats"]["reused_sources"], 0)
        cold = self.cli("build")
        self.assertGreater(len(cold["passes"][0]["calls"]), 0)
        self.assertEqual(cold["result"]["generation"], clean["result"]["generation"])
        self.assertTrue((self.cache / "entry.json").exists(), "successful no-op normal publication may seed cache")

    def test_source_edit_projects_only_changed_document_in_fresh_process(self):
        self.seed()
        self.write("docs/operations.md", "# Operations\n\nFresh source replacement.\n")
        changed = self.ok("build")
        self.assertEqual(self.actual_first_calls(changed), {"docs/operations.md"})
        self.assertEqual(len(changed["calls"]), 1, "normal revalidations should use the trusted process memo")
        self.assertNotIn(MARKER, json.dumps(changed["result"]))
        self.artifacts_equal(changed, self.ok(clean=True))

    def test_dependency_body_edit_reprojects_exact_transitive_reverse_closure(self):
        rows = records()
        self.seed(records=rows)
        rows[0]["body"] = "Transport now rejects ambiguous frames."
        changed = self.ok("build", records=rows)
        self.assertEqual(self.actual_first_calls(changed), {
            "memory:module/module:transport", "memory:module/module:payments", "memory:decision/decision:retry"})
        self.assertEqual(len(changed["calls"]), 3)
        self.artifacts_equal(changed, self.ok(clean=True, records=rows))

    def test_typed_edge_change_invalidates_owner_and_reverse_dependents(self):
        rows = [
            {"name": "decision:old", "body": "Legacy approach."},
            {"name": "decision:new", "body": "Replacement approach.",
             "metadata": {"handbook": {"conflicts_with": ["decision:old"]}}},
            {"name": "decision:dependent", "body": "Dependent qualification.",
             "metadata": {"handbook": {"conflicts_with": ["decision:new"]}}},
            records()[-1],
        ]
        self.seed(records=rows)
        rows[1]["metadata"]["handbook"] = {"supersedes": ["decision:old"]}
        changed = self.ok(records=rows)
        self.assertEqual(self.actual_first_calls(changed), {
            "memory:decision/decision:new", "memory:decision/decision:dependent"})
        self.artifacts_equal(changed, self.ok(clean=True, records=rows))

    def test_lifecycle_and_conditions_are_semantic_inputs_without_body_change(self):
        rows = records()
        self.seed(records=rows)
        rows[1]["state"] = "withdrawn"
        rows[2]["metadata"]["handbook"]["conditions"] = ["Never dispatch after capture."]
        changed = self.ok(records=rows)
        self.assertEqual(self.actual_first_calls(changed), {
            "memory:module/module:payments", "memory:decision/decision:retry"})
        self.assertIn("Never dispatch after capture.", changed["result"]["handbook"])
        self.assertIn("withdrawn", changed["result"]["handbook"])
        self.artifacts_equal(changed, self.ok(clean=True, records=rows))

    def test_removed_target_and_edge_invalidate_old_reverse_graph(self):
        rows = records()
        self.seed(records=rows)
        rows.pop(0)
        rows[0]["metadata"]["handbook"].pop("depends_on")
        changed = self.ok(records=rows)
        self.assertEqual(self.actual_first_calls(changed), {
            "memory:module/module:payments", "memory:decision/decision:retry"})
        self.assertEqual(changed["passes"][0]["stats"]["removed_sources"], 1)
        self.assertNotIn("Transport owns", json.dumps(changed["result"]))
        self.artifacts_equal(changed, self.ok(clean=True, records=rows))

    def test_dependency_cycle_terminates_and_invalidates_only_component(self):
        rows = records()
        rows[0]["metadata"]["handbook"]["depends_on"] = ["module:payments"]
        self.seed(records=rows)
        rows[1]["body"] = "Payments changed within a bounded cycle."
        changed = self.ok(records=rows)
        self.assertEqual(self.actual_first_calls(changed), {
            "memory:module/module:payments", "memory:module/module:transport", "memory:decision/decision:retry"})
        self.artifacts_equal(changed, self.ok(clean=True, records=rows))

    def test_unresolved_fresh_declaration_fails_even_when_disk_is_warm(self):
        rows = records()
        self.seed(records=rows)
        before = tree_snapshot(self.cache)
        rows[1]["metadata"]["handbook"]["depends_on"] = ["module:nonexistent"]
        response = self.run_worker("build", records=rows)
        self.assertIn("error", response)
        self.assertEqual(response["calls"], [])
        self.assertEqual(tree_snapshot(self.cache), before)

    def test_deleted_document_disappears_without_reprojecting_unchanged_sources(self):
        self.seed()
        (self.root / "docs/operations.md").unlink()
        changed = self.ok("build")
        self.assertEqual(changed["calls"], [])
        self.assertEqual(changed["passes"][0]["stats"]["removed_sources"], 1)
        self.assertNotIn(MARKER, json.dumps(changed["result"]))
        self.artifacts_equal(changed, self.ok(clean=True))

    def test_saved_exclusion_revalidates_policy_and_withholds_cached_original(self):
        self.cli("build")
        self.cli("refresh-config", "--disable", "--exclude", "docs/operations.md")
        changed = self.cli("build")
        self.assertNotIn(MARKER, json.dumps(changed["result"]))
        self.assertEqual(changed["calls"], [])
        clean = self.cli("preview", "--clean")
        self.assertEqual(changed["result"]["generation"], clean["result"]["generation"])
        self.assertEqual(changed["result"]["handbook"], clean["result"]["handbook"])

    def test_fresh_journal_retraction_never_replays_old_cached_claim(self):
        rows = [dict(row, vid=str(index), scope="checkout",
                     provenance={"locator": "synthetic:durable"})
                for index, row in enumerate(records(), 1)]
        self.ok("journal", records=rows)
        self.seed()
        self.ok("journal", records=rows[:-1])
        changed = self.ok("build")
        self.assertEqual(changed["calls"], [])
        self.assertEqual(changed["passes"][0]["stats"]["removed_sources"], 1)
        self.assertNotIn("Reports are independent.", json.dumps(changed["result"]))
        self.artifacts_equal(changed, self.ok(clean=True))

    def test_branch_switch_revalidates_sources_and_generation(self):
        baseline = self.seed()
        self.git("switch", "-c", "fixture-alternate")
        self.write("docs/operations.md", "# Alternate\n\nBRANCH_ONLY_FACT_427.\n")
        self.commit("Alternate synthetic documentation")
        alternate = self.ok("build")
        self.assertEqual(self.actual_first_calls(alternate), {"docs/operations.md"})
        self.artifacts_equal(alternate, self.ok(clean=True))
        self.git("switch", "main")
        restored = self.ok("build")
        self.assertEqual(self.actual_first_calls(restored), {"docs/operations.md"})
        self.assertNotIn("BRANCH_ONLY_FACT_427", json.dumps(restored["result"]))
        self.artifacts_equal(baseline, restored)

    def test_linked_worktree_uses_private_per_checkout_cache_and_rejects_copied_scope(self):
        self.seed()
        linked = self.base / "linked"
        self.git("worktree", "add", "-b", "fixture-linked", str(linked))
        linked_cache = pathlib.Path(self.git("rev-parse", "--absolute-git-dir", root=linked)) / CACHE_NAME
        self.assertNotEqual(linked_cache, self.cache)
        shutil.copytree(self.cache, linked_cache)
        copied = self.ok(root=linked)
        self.assert_cold(copied)
        self.artifacts_equal(copied, self.ok(root=linked, clean=True))
        self.ok("build", root=linked)
        self.assertTrue((linked_cache / "entry.json").exists())
        warm = self.ok(root=linked)
        self.assertEqual(warm["calls"], [])
        self.assertEqual(self.ok()["calls"], [])
        self.assertFalse((linked / CACHE_NAME).exists())

    def test_canonical_nested_and_symlink_root_share_checkout_scope(self):
        seeded = self.seed()
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        for root in (self.root / "docs", alias):
            with self.subTest(root=root.name):
                warm = self.ok(root=root)
                self.assertEqual(warm["calls"], [])
                self.artifacts_equal(seeded, warm)

    def test_preview_and_readonly_cli_never_create_or_rewrite_cache(self):
        before = tree_snapshot(self.root)
        self.cli("preview")
        self.cli("preview", "--clean")
        self.assertFalse(self.cache.exists())
        self.assertEqual(tree_snapshot(self.root), before)
        built = self.cli("build")
        before = tree_snapshot(self.cache)
        generation = built["result"]["generation"]
        for action, extra in (("preview", []), ("preview", ["--clean"]),
                              ("status", []), ("show", []),
                              ("evidence", ["--generation", generation]), ("refresh-config", [])):
            with self.subTest(action=action, extra=extra):
                result = self.cli(action, *extra)
                self.assertEqual(tree_snapshot(self.cache), before)
                if action in {"preview", "status", "show", "evidence"}:
                    self.assertGreater(len(result["collections"]), 0)

    def test_clean_changed_preview_does_not_replace_warm_entry(self):
        seeded = self.seed()
        before = tree_snapshot(self.cache)
        old = (self.root / "README.md").read_text()
        self.write("README.md", "# Changed\n\nClean-only candidate.\n")
        clean = self.ok(clean=True)
        self.assert_cold(clean)
        self.assertEqual(tree_snapshot(self.cache), before)
        self.write("README.md", old)
        warm = self.ok()
        self.assertEqual(warm["calls"], [])
        self.artifacts_equal(seeded, warm)

    def test_private_cache_modes_bounds_and_no_integrity_key_in_artifacts(self):
        seeded = self.seed()
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o700)
        self.assertEqual({path.name for path in self.cache.iterdir()}, {"key", "entry.json", "write.lock"})
        for path in self.cache.iterdir():
            info = path.lstat()
            self.assertTrue(stat.S_ISREG(info.st_mode))
            self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
            self.assertEqual(info.st_uid, os.getuid())
            self.assertEqual(info.st_nlink, 1)
        key = (self.cache / "key").read_bytes()
        self.assertEqual(len(key), 32)
        self.assertLessEqual((self.cache / "entry.json").stat().st_size, 8 * 1024 * 1024)
        output = json.dumps(seeded).encode()
        self.assertNotIn(key.hex().encode(), output)
        self.assertNotIn(key, output)
        self.assertFalse((self.root / CACHE_NAME).exists())

    def test_payload_tamper_and_recomputed_unkeyed_digest_are_not_authority(self):
        original = self.seed()
        path = self.cache / "entry.json"
        encoded = path.read_text()
        self.assertIn(MARKER, encoded, "test must change a real cached projection")
        poisoned = encoded.replace(MARKER, "INJECTED_UNTRUSTED_884")
        payload = json.loads(poisoned)
        # Recompute any ordinary digest field without reading or using the HMAC key.
        def recompute(value):
            if isinstance(value, dict):
                for child in value.values():
                    recompute(child)
                for field in ("digest", "sha256", "checksum", "source_digest"):
                    if field in value:
                        material = {key: item for key, item in value.items() if key != field}
                        value[field] = hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()
            elif isinstance(value, list):
                for child in value:
                    recompute(child)
        recompute(payload)
        path.write_text(json.dumps(payload))
        corrupted = tree_snapshot(self.cache)
        ignored = self.ok()
        self.assert_cold(ignored)
        self.artifacts_equal(original, ignored)
        self.assertNotIn("INJECTED_UNTRUSTED_884", json.dumps(ignored))
        self.assertEqual(tree_snapshot(self.cache), corrupted, "preview cannot repair corrupt cache")
        rebuilt = self.ok("build")
        self.assert_cold(rebuilt)
        self.assertEqual(self.ok()["calls"], [], "fresh successful output may replace corrupt entry")

    def test_version_or_scope_envelope_tamper_is_a_cold_miss(self):
        self.seed()
        path = self.cache / "entry.json"
        raw = path.read_bytes()
        payload = json.loads(raw)
        candidates = [key for key in payload if "version" in key or "scope" in key]
        self.assertTrue(candidates, "authenticated envelope must explicitly bind version/scope")
        for key in candidates:
            with self.subTest(field=key):
                modified = copy.deepcopy(payload)
                modified[key] = "wrong-version-or-scope"
                path.write_text(json.dumps(modified))
                self.assert_cold(self.ok())
                path.write_bytes(raw)

    def test_missing_truncated_key_never_generates_new_key_over_existing_entry(self):
        self.seed()
        path = self.cache / "key"
        for bad in (None, b"", b"short", b"x" * 31, b"x" * 33):
            with self.subTest(length=None if bad is None else len(bad)):
                if path.exists():
                    path.unlink()
                if bad is not None:
                    path.write_bytes(bad)
                    path.chmod(0o600)
                before = tree_snapshot(self.cache)
                result = self.ok("build")
                self.assert_cold(result)
                self.assertEqual(tree_snapshot(self.cache), before)

    def test_malformed_truncated_and_oversized_entry_are_cold_readonly_misses(self):
        self.seed()
        path = self.cache / "entry.json"
        for bad in (b"", b"{", b"[]", b"null", b"x" * (8 * 1024 * 1024 + 1)):
            with self.subTest(size=len(bad)):
                path.write_bytes(bad)
                before = tree_snapshot(self.cache)
                self.assert_cold(self.ok())
                self.assertEqual(tree_snapshot(self.cache), before)

    def test_unsafe_file_modes_are_not_repaired_or_reused(self):
        self.seed()
        for name in ("key", "entry.json", "write.lock"):
            with self.subTest(name=name):
                path = self.cache / name
                path.chmod(0o644)
                before = tree_snapshot(self.cache)
                self.assert_cold(self.ok("build"))
                self.assertEqual(tree_snapshot(self.cache), before)
                path.chmod(0o600)

    def test_unsafe_directory_mode_is_not_repaired_or_reused(self):
        self.seed()
        self.cache.chmod(0o755)
        before = tree_snapshot(self.cache)
        self.assert_cold(self.ok("build"))
        self.assertEqual(tree_snapshot(self.cache), before)

    def test_symlink_cache_directory_is_never_followed(self):
        self.seed()
        outside = self.base / "cache-target"
        self.cache.rename(outside)
        self.cache.symlink_to(outside, target_is_directory=True)
        before = tree_snapshot(outside)
        self.assert_cold(self.ok("build"))
        self.assertEqual(tree_snapshot(outside), before)
        self.assertTrue(self.cache.is_symlink())

    def test_symlink_hardlink_and_fifo_cache_files_are_bounded_cold_misses(self):
        self.seed()
        for name in ("key", "entry.json", "write.lock"):
            path = self.cache / name
            saved = path.read_bytes()
            for kind in ("symlink", "hardlink", "fifo"):
                with self.subTest(name=name, kind=kind):
                    path.unlink()
                    target = self.base / (name + "-" + kind)
                    target.write_bytes(saved)
                    target.chmod(0o600)
                    if kind == "symlink":
                        path.symlink_to(target)
                    elif kind == "hardlink":
                        os.link(target, path)
                    else:
                        os.mkfifo(path, 0o600)
                    before = tree_snapshot(self.cache)
                    target_before = tree_snapshot(target)
                    self.assert_cold(self.ok("build"))
                    self.assertEqual(tree_snapshot(self.cache), before)
                    self.assertEqual(tree_snapshot(target), target_before)
                    path.unlink()
                    path.write_bytes(saved)
                    path.chmod(0o600)

    def test_lock_contention_is_nonblocking_miss_and_does_not_delete_lock(self):
        self.seed()
        before = tree_snapshot(self.cache)
        with (self.cache / "write.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            started = time.monotonic()
            response = self.ok("build")
            self.assertLess(time.monotonic() - started, 8)
            self.assert_cold(response)
            self.assertEqual(tree_snapshot(self.cache), before)
        self.assertEqual(self.ok()["calls"], [])

    def test_staged_failure_cancel_source_race_and_process_exit_never_write_cache(self):
        for fault in ("staged-failure", "staged-cancel", "staged-source-race", "staged-exit"):
            with self.subTest(fault=fault):
                self.seed()
                before = tree_snapshot(self.cache)
                active = (self.root / ".byori/handbook.md").read_bytes()
                self.write("docs/operations.md", "# Candidate\n\n" + fault + ".\n")
                response = self.run_worker("build", fault=fault, expected_exit=73 if fault == "staged-exit" else 0)
                if response is not None:
                    self.assertTrue(response["staged"], "fault must reach real staged evidence")
                    self.assertIn("error", response)
                self.assertEqual((self.root / ".byori/handbook.md").read_bytes(), active)
                self.assertEqual(tree_snapshot(self.cache), before)
                self.assertIsNone(self.ok("read")["result"]["handbook"])

    def test_failed_first_build_does_not_create_cache(self):
        response = self.run_worker("build", fault="staged-failure")
        self.assertIn("error", response)
        self.assertTrue(response["staged"])
        self.assertFalse(self.cache.exists())
        self.assertFalse((self.root / ".byori/handbook.md").exists())

    def test_cache_write_failure_does_not_undo_successful_publication(self):
        self.seed()
        prior_entry = (self.cache / "entry.json").read_bytes()
        self.write("docs/operations.md", "# Replacement\n\nPublished despite cache I/O failure.\n")
        result = self.ok("build", fault="cache-write-failure")
        self.assertTrue(result["result"]["published"])
        self.assertTrue(result["result"]["changed"])
        self.assertEqual((self.root / ".byori/handbook.md").read_text(), result["result"]["handbook"])
        self.assertEqual((self.cache / "entry.json").read_bytes(), prior_entry)
        self.artifacts_equal(result, self.ok(clean=True))

    def test_fingerprint_is_stable_across_fresh_processes_and_hash_seeds(self):
        first = self.seed()
        for seed in ("0", "1", "17493", "random"):
            with self.subTest(hash_seed=seed):
                warm = self.ok(environment={"PYTHONHASHSEED": seed})
                self.assertEqual(warm["implementation"], first["implementation"])
                self.assertEqual(warm["calls"], [], "process randomization cannot defeat durable reuse")
                self.artifacts_equal(first, warm)

    def test_old_loaded_process_cannot_sign_projections_as_replaced_disk_code(self):
        runtime = self.base / "isolated-runtime"
        shutil.copytree(ROOT / "cli", runtime, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        old = self.seed(runtime=str(runtime), rewrite_loaded_runtime=True)
        envelope = json.loads((self.cache / "entry.json").read_bytes())
        self.assertEqual(envelope["scope"][4], old["implementation"])
        self.assertTrue(all(claim["kind"] == "attributed_excerpt" for claim in old["result"]["evidence"]["claims"]))
        new = self.ok(runtime=str(runtime))
        self.assertNotEqual(new["implementation"], old["implementation"])
        self.assert_cold(new)
        self.assertTrue(all(claim["kind"] == "attributed_excerpt_v2" for claim in new["result"]["evidence"]["claims"]))
        self.artifacts_equal(new, self.ok(runtime=str(runtime), clean=True))

    def test_valid_authenticated_entry_from_other_compiler_version_is_not_reused(self):
        runtime = self.base / "isolated-runtime"
        shutil.copytree(ROOT / "cli", runtime, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        path = runtime / "handbook.py"
        original = path.read_text()
        import re
        alternate, count = re.subn(r'COMPILER_VERSION = "[^"]+"',
                                   'COMPILER_VERSION = "0.0.fixture-old"', original, count=1)
        self.assertEqual(count, 1)
        path.write_text(alternate)
        old = self.seed(runtime=str(runtime))
        path.write_text(original)
        new = self.ok(runtime=str(runtime))
        self.assert_cold(new)
        self.assertNotEqual(new["result"]["generation"], old["result"]["generation"])
        self.artifacts_equal(new, self.ok(runtime=str(runtime), clean=True))

    def test_two_real_process_builders_leave_one_authenticated_complete_entry(self):
        first = self.seed()
        request = json.dumps({"root": str(self.root), "action": "build"})
        children = []
        try:
            for _ in range(2):
                child = subprocess.Popen([sys.executable, "-B", str(pathlib.Path(__file__).resolve()), "--worker"],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         text=True, env=self.env, cwd=self.root)
                children.append(child)
                child.stdin.write(request)
                child.stdin.close()
                child.stdin = None
            for child in children:
                stdout, stderr = child.communicate(timeout=25)
                self.assertEqual(child.returncode, 0, stderr[-2000:])
                response = json.loads(stdout)
                self.assertNotIn("error", response, response.get("error"))
                self.artifacts_equal(first, response)
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
        self.assertEqual(self.ok()["calls"], [])
        self.assertEqual({path.name for path in self.cache.iterdir()}, {"entry.json", "key", "write.lock"})


if __name__ == "__main__":
    if sys.argv[1:] == ["--worker"]:
        print(json.dumps(worker(json.load(sys.stdin)), ensure_ascii=False))
    else:
        unittest.main()
