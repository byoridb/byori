"""Independent frozen quality fixtures for the knowledge/projection slice.

Fixtures were fixed against the projection contract before compiler integration.
Only temporary repositories/journals are mutated. Production collection,
projection, publication and reads remain real; scheduling spies, where used,
call through. Missing implementation is a pending failure, never a fake pass.
No claim here establishes durable cache reuse, real-host consumption or truth.
"""

import copy
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
sys.path.insert(0, str(ROOT / "cli"))
import handbook
import handbook_records
import handbook_refresh


# Frozen semantic expectations: these exact conditions must survive selection,
# not merely the source IDs or a few matching keywords.
OVERVIEW = "A synthetic payment service with checkout-local records."
MODULE = "The payment adapter owns retry dispatch, not ledger reconciliation."
CONDITION = "Only for transient errors before settlement; never after capture."
DECISION = "Retry at most twice."
PITFALL = "Replaying a captured payment can duplicate a charge; reconcile first."
DOC = "Operators inspect the reconciliation queue before manually replaying work."
OLD_RULE = "Use synchronous reconciliation for the legacy provider."
NEW_RULE = "Use queued reconciliation for the replacement provider."
OLD_CONDITION = "Only while the legacy provider is configured."
NEW_CONDITION = "Only after the replacement provider migration is complete."
SYNTHETIC_SECRET = "ghp_" + "Z" * 32


def record(name, body, **declaration):
    return {"name": name, "type": name.split(":", 1)[0], "body": body,
            "state": "accepted", "metadata": {"handbook": declaration}}


def quality_records():
    return [record("module:payments", MODULE, module_paths=["src/payments/adapter.py"]),
            record("decision:retry", DECISION, conditions=[CONDITION], affects=["module:payments"]),
            record("bug:captured-replay", PITFALL, conditions=["When capture has already succeeded."],
                   affects=["module:payments"])]


def conflict_records(*, supersedes=False):
    relation = {"supersedes" if supersedes else "conflicts_with": ["decision:legacy"]}
    return [record("decision:legacy", OLD_RULE, conditions=[OLD_CONDITION]),
            record("decision:replacement", NEW_RULE, conditions=[NEW_CONDITION], **relation)]


def dependency_records():
    return [record("module:transport", "Transport owns the wire protocol.", module_paths=["src/wire.py"]),
            record("module:payments", MODULE, depends_on=["module:transport"]),
            record("decision:retry", DECISION, conditions=[CONDITION], affects=["module:payments"]),
            record("bug:captured-replay", PITFALL, affects=["module:payments"]),
            record("module:reports", "Reports are independent of payment transport.")]


def invalid_records():
    """Explicit unresolved/ambiguous edges and a supersession cycle are errors."""
    ambiguous = record("decision:legacy", OLD_RULE)
    duplicate = dict(copy.deepcopy(ambiguous), vid="2")
    ambiguous["vid"] = "1"
    return {
        "missing": [record("decision:retry", DECISION, affects=["module:missing"])],
        "ambiguous": [ambiguous, duplicate,
                      record("decision:replacement", NEW_RULE, supersedes=["decision:legacy"])],
        "supersession-cycle": [record("decision:a", "First claim.", supersedes=["decision:b"]),
                               record("decision:b", "Second claim.", supersedes=["decision:a"])],
        "secret-target": [record("module:private", SYNTHETIC_SECRET),
                          record("decision:retry", DECISION, affects=["module:private"])],
    }


def snapshot(root):
    """Read-only checks include mtimes so a rewritten cache cannot hide."""
    return {p.relative_to(root).as_posix(): (p.read_bytes(), p.stat().st_mtime_ns)
            for p in sorted(root.rglob("*")) if p.is_file() and not p.is_symlink()}


class ProjectionAdversarialTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="byori-projection-verifier-")
        self.addCleanup(temporary.cleanup)
        self.base = pathlib.Path(temporary.name).resolve()
        self.root = self.base / "project"
        self.root.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
                           GIT_CONFIG_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0")
        self.environment = environment
        patch = mock.patch.dict(os.environ, environment, clear=True)
        patch.start()
        self.addCleanup(patch.stop)
        self.git("init", "-b", "main")
        self.write("README.md", "# Synthetic payments\n\n" + OVERVIEW + "\n")
        self.write("docs/operations.md", "# Operations\n\n" + DOC + "\n")
        self.git("add", ".")
        self.git("commit", "-m", "Document synthetic payment boundaries")

    def git(self, *args):
        return subprocess.run(
            ["git", "--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
             "-c", "user.name=Projection verifier", "-c", "user.email=projection@example.invalid",
             "-c", "commit.gpgsign=false", "-C", str(self.root), *args],
            env=self.environment, check=True, capture_output=True, text=True, timeout=15).stdout.strip()

    def write(self, name, body):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body, encoding="utf-8")

    def large_overview(self):
        # Each section fits on its own; a greedy overview-first renderer consumes
        # the budget before reaching the semantically important records.
        text = "# Synthetic payments\n\n" + OVERVIEW + "\n"
        for index in range(36):
            text += "\n## Overview appendix %02d\n\n" % index + ("Routine overview detail. " * 18) + "\n"
        self.write("README.md", text)

    def compile(self, records=None, **options):
        return handbook.compile_handbook(self.root, accepted_records=records, **options)

    def assert_artifacts_equal(self, first, second):
        for key in ("generation", "handbook", "evidence"):
            self.assertEqual(first[key], second[key], key)

    def assert_grounded(self, build):
        evidence = build["evidence"]
        sources = {source["id"]: source for source in evidence["sources"]}
        self.assertTrue(evidence["claims"])
        for claim in evidence["claims"]:
            source = sources[claim["source_id"]]
            self.assertEqual(claim["state"], "unverified")
            self.assertEqual(claim["support"], "verbatim_source_excerpt")
            self.assertIn(claim["body"], source["content"])
            self.assertEqual(claim["source_digest"], source["digest"])
            self.assertIn(claim["id"], build["handbook"])
            self.assertIn({"source": claim["id"], "relation": "derived_from", "target": source["id"]},
                          evidence["relationships"])

    def explicit_links(self, build):
        sources = {source["id"]: source for source in build["evidence"]["sources"]}
        return {(sources[edge["source"]]["metadata"]["name"], edge["relation"],
                 sources[edge["target"]]["metadata"]["name"])
                for edge in build["evidence"]["relationships"]
                if edge["source"] in sources and edge["target"] in sources}

    def test_large_overview_cannot_starve_module_qualified_decision_or_pitfall(self):
        self.large_overview()
        build = self.compile(quality_records(), max_chars=6500)
        for meaning in (OVERVIEW, MODULE, DECISION, CONDITION, PITFALL, DOC):
            self.assertIn(meaning, build["handbook"])
        self.assertLessEqual(len(build["handbook"]), 6500)
        self.assertGreater(build["evidence"]["omitted_sections"], 0)
        self.assert_grounded(build)

    def test_declarations_are_explicit_source_links_not_verified_truth(self):
        records = quality_records()
        build = self.compile(records)
        self.assertEqual(self.explicit_links(build), {
            ("decision:retry", "affects", "module:payments"),
            ("bug:captured-replay", "affects", "module:payments")})
        self.assertIn(CONDITION, build["handbook"])
        self.assertIn("src/payments/adapter.py", build["handbook"])
        self.assertIn("unverified", build["handbook"].lower())
        self.assert_grounded(build)
        self.assertIn("projection_version", build["evidence"])
        declarations = build["evidence"]["source_declarations"]
        self.assertEqual(len(declarations), len(records))
        for declaration in declarations.values():
            self.assertEqual(set(declaration), {"module_paths", "conditions", "depends_on", "affects",
                                                "conflicts_with", "supersedes"})

    def test_conflict_and_supersession_keep_both_sides_and_conditions(self):
        for supersedes in (False, True):
            with self.subTest(supersedes=supersedes):
                build = self.compile(conflict_records(supersedes=supersedes))
                for meaning in (OLD_RULE, NEW_RULE, OLD_CONDITION, NEW_CONDITION):
                    self.assertIn(meaning, build["handbook"])
                relation = "supersedes" if supersedes else "conflicts_with"
                self.assertIn(("decision:replacement", relation, "decision:legacy"), self.explicit_links(build))
                self.assert_grounded(build)

    def test_budget_never_selects_only_one_member_of_a_declared_component(self):
        for supersedes in (False, True):
            for budget in (2048, 3500, 6500):
                with self.subTest(supersedes=supersedes, budget=budget):
                    records = conflict_records(supersedes=supersedes)
                    records[1]["body"] += " " + ("Lengthy migration qualification. " * 240)
                    build = self.compile(records, max_chars=budget)
                    self.assertNotIn(OLD_RULE, build["handbook"])
                    self.assertNotIn(NEW_RULE, build["handbook"])
                    self.assertGreaterEqual(build["evidence"]["omitted_sections"], 2)
                    self.assertTrue(self.explicit_links(build), "withholding is not evidence deletion")
                    self.assertLessEqual(len(build["handbook"]), budget)

    def test_lexical_disagreement_and_revert_do_not_invent_relationships_or_cause(self):
        self.write("docs/yes.md", "# Policy A\n\nAlways retry captured payments.\n")
        self.write("docs/no.md", "# Policy B\n\nNever retry captured payments.\n")
        self.git("add", "docs")
        self.git("commit", "-m", 'Revert "Enable retry dispatch"')
        build = self.compile()
        self.assertEqual(self.explicit_links(build), set())
        self.assertTrue(all(edge["relation"] == "derived_from" for edge in build["evidence"]["relationships"]))
        self.assertIn("unknown", build["handbook"].lower())
        self.assertIn("does not establish the reason", build["handbook"])
        self.assertIn('Revert "Enable retry dispatch"', build["handbook"])
        self.assert_grounded(build)

    def test_unresolved_ambiguous_and_cyclic_declarations_fail_closed_without_writes(self):
        before = snapshot(self.base)
        for label, records in invalid_records().items():
            with self.subTest(case=label):
                with self.assertRaises((handbook.HandbookError, ValueError)) as raised:
                    self.compile(records)
                self.assertNotIn(SYNTHETIC_SECRET, str(raised.exception))
                self.assertNotIn(DECISION, str(raised.exception))
                self.assertEqual(before, snapshot(self.base))

    def test_module_dependency_cycle_is_allowed_and_stays_unverified(self):
        records = [record("module:a", "A delegates to B.", depends_on=["module:b"]),
                   record("module:b", "B delegates to A.", depends_on=["module:a"])]
        build = self.compile(records)
        self.assertEqual(self.explicit_links(build), {
            ("module:a", "depends_on", "module:b"), ("module:b", "depends_on", "module:a")})
        self.assert_grounded(build)

    def test_secret_in_condition_withholds_entire_source_before_projection(self):
        records = quality_records()
        records.append(record("decision:private", "PRIVATE_BODY_MUST_NOT_PROJECT",
                              conditions=[SYNTHETIC_SECRET]))
        build = self.compile(records)
        serialized = json.dumps(build)
        self.assertNotIn(SYNTHETIC_SECRET, serialized)
        self.assertNotIn("PRIVATE_BODY_MUST_NOT_PROJECT", serialized)
        self.assertGreater(build["evidence"]["sensitive_sources_withheld"], 0)

    def test_clean_and_memo_artifacts_identical_without_disk_writes(self):
        records = dependency_records()
        before = snapshot(self.base)
        cold, warm, clean = {}, {}, {}
        first = self.compile(records, projection_stats=cold)
        second = self.compile(records, projection_stats=warm)
        third = self.compile(records, clean_projection=True, projection_stats=clean)
        self.assert_artifacts_equal(first, second)
        self.assert_artifacts_equal(second, third)
        self.assertGreater(cold["projected_sources"], 0)
        self.assertEqual(warm["projected_sources"], 0)
        self.assertEqual(warm["reused_sources"], len(second["evidence"]["sources"]))
        self.assertEqual(clean["reused_sources"], 0)
        self.assertEqual(warm["mode"], "process-local")
        for key in ("projected_sources", "reused_sources", "projection_stats"):
            self.assertNotIn(key, second["evidence"])
        self.assertEqual(before, snapshot(self.base))

    def test_mutated_returned_build_and_caller_records_cannot_poison_memo(self):
        records = dependency_records()
        returned = self.compile(records)
        expected = copy.deepcopy(returned)
        returned["handbook"] = "FORGED_RENDER"
        returned["evidence"]["sources"][0]["content"] = "FORGED_ORIGINAL"
        returned["evidence"]["claims"][0]["body"] = "FORGED_CLAIM"
        returned["evidence"]["source_declarations"].clear()
        returned["evidence"]["relationships"].clear()
        records[0]["body"] = "CALLER_MUTATION"
        warm = {}
        actual = self.compile(dependency_records(), projection_stats=warm)
        self.assert_artifacts_equal(expected, actual)
        self.assertGreater(warm["reused_sources"], 0)
        self.assert_artifacts_equal(actual, self.compile(dependency_records(), clean_projection=True))

    def test_changed_target_invalidates_reverse_dependency_closure_only(self):
        records = dependency_records()
        self.compile(records)
        records[0]["body"] = "Transport now requires framed messages."
        stats = {}
        # A call-through spy proves real projector work, not only claimed counters.
        with mock.patch.object(handbook, "_project_source", wraps=handbook._project_source) as projector:
            build = self.compile(records, projection_stats=stats)
        self.assertEqual(projector.call_count, 4)
        projected_names = {call.args[0]["source"]["metadata"]["name"] for call in projector.call_args_list}
        self.assertEqual(projected_names, {"module:transport", "module:payments", "decision:retry", "bug:captured-replay"})
        self.assertEqual(stats["projected_sources"], 4)
        self.assertGreater(stats["reused_sources"], 0)
        self.assert_artifacts_equal(build, self.compile(records, clean_projection=True))

    def test_removed_dependency_edge_and_record_do_not_leave_stale_projection(self):
        records = dependency_records()
        self.compile(records)
        records[1]["metadata"]["handbook"]["depends_on"] = []
        records.pop(0)
        stats = {}
        build = self.compile(records, projection_stats=stats)
        self.assertEqual(stats["removed_sources"], 1)
        self.assertNotIn("Transport owns the wire protocol.", build["handbook"])
        self.assertFalse(any("module:transport" in edge for edge in self.explicit_links(build)))
        self.assert_artifacts_equal(build, self.compile(records, clean_projection=True))

    def test_changed_budget_rerenders_and_does_not_reuse_old_selection(self):
        self.large_overview()
        records = quality_records()
        wide = self.compile(records, max_chars=12000)
        small = self.compile(records, max_chars=3500)
        self.assertNotEqual(wide["generation"], small["generation"])
        self.assertLessEqual(len(small["handbook"]), 3500)
        self.assert_artifacts_equal(small, self.compile(records, max_chars=3500, clean_projection=True))

    def test_dense_bounded_original_does_not_overflow_evidence_with_omission_metadata(self):
        # 336 KB original / approximately 480 KB input JSON, both well within
        # the original-record bound. Repeated source IDs/reasons for omitted
        # sections must not turn this into more than 4 MiB of derived evidence.
        section_count = 48000
        records = [{"name": "note:dense", "body": "# H\n\nx\n" * section_count}]
        self.assertLess(len(json.dumps(records).encode("utf-8")), 1048576)
        before = snapshot(self.base)
        build = self.compile(records, max_chars=2048)
        self.assertLessEqual(len(build["handbook"]), 2048)
        self.assertLessEqual(len(handbook._json(build["evidence"]).encode("utf-8")), handbook.MAX_STORED_BYTES)
        source = next(item for item in build["evidence"]["sources"] if item["kind"] == "checkpoint")
        selected = sum(claim["source_id"] == source["id"] for claim in build["evidence"]["claims"])
        omitted = sum(item["sections"] for item in build["evidence"]["projection_omissions"]
                      if item["source_ids"] == [source["id"]])
        self.assertEqual(selected + omitted, section_count)
        self.assertEqual(source["content"], records[0]["body"])
        self.assert_artifacts_equal(build, self.compile(records, max_chars=2048, clean_projection=True))
        self.assertEqual(before, snapshot(self.base))

    def test_fresh_source_recollection_detects_same_size_edit_with_restored_mtime(self):
        first = self.compile()
        path = self.root / "docs/operations.md"
        old = path.stat()
        self.write("docs/operations.md", path.read_text().replace("manually", "remotely"))
        os.utime(path, ns=(old.st_atime_ns, old.st_mtime_ns))
        changed = self.compile()
        self.assertNotEqual(first["generation"], changed["generation"])
        self.assertIn("remotely replaying", changed["handbook"])
        self.assert_artifacts_equal(changed, self.compile(clean_projection=True))

    def test_copied_checkout_has_cold_scope_and_rejects_foreign_scoped_records(self):
        records = dependency_records()
        first = self.compile(records)
        other = self.base / "copied-checkout"
        shutil.copytree(self.root, other)
        before = snapshot(self.base)
        stats = {}
        second = handbook.compile_handbook(other, accepted_records=records, projection_stats=stats)
        self.assertEqual(stats["reused_sources"], 0)
        self.assertNotEqual(first["generation"], second["generation"])
        self.assertNotEqual(first["evidence"]["checkout_id"], second["evidence"]["checkout_id"])
        scoped = copy.deepcopy(records)
        scoped[0]["checkout_id"] = first["evidence"]["checkout_id"]
        with self.assertRaises(handbook.HandbookError):
            handbook.compile_handbook(other, accepted_records=scoped)
        self.assertEqual(before, snapshot(self.base))

    def test_forged_persisted_unit_caches_are_not_inputs(self):
        records = dependency_records()
        expected = self.compile(records, clean_projection=True)
        forged = json.dumps({"generation": expected["generation"], "digest": expected["evidence"]["snapshot_digest"],
                             "units": expected["evidence"], "handbook": "FORGED_PERSISTED_PROJECTION"})
        for name in ("projection.json", "projection-cache.json", "units/forged.json"):
            self.write(".byori/" + name, forged)
        before = snapshot(self.base)
        self.assert_artifacts_equal(expected, self.compile(records))
        self.assertEqual(before, snapshot(self.base))

    def test_publish_read_and_source_deletion_preserve_original_evidence(self):
        records = quality_records() + conflict_records()
        build = self.compile(records)
        handbook.publish_handbook(build, accepted_records=records)
        self.assertEqual(handbook.read_handbook(self.root, accepted_records=records)["handbook"], build["handbook"])
        storage = snapshot(self.base)
        evidence = handbook.read_evidence(self.root, build["generation"], accepted_records=records)
        self.assertEqual(evidence["state"], "current")
        self.assertEqual(evidence["evidence"]["relationships"], build["evidence"]["relationships"])
        checkpoint = next(source for source in build["evidence"]["sources"]
                          if source.get("metadata", {}).get("name") == "decision:retry")
        detail = handbook.read_evidence(self.root, build["generation"], source_id=checkpoint["id"],
                                        accepted_records=records)
        self.assertEqual(detail["state"], "current")
        self.assertEqual(detail["evidence"]["source"], checkpoint)
        self.assertEqual(checkpoint["metadata"]["handbook"]["conditions"], [CONDITION])
        stored = self.root / ".byori" / "generations" / build["generation"] / "evidence.json"
        self.assertEqual(json.loads(stored.read_text()), build["evidence"])
        self.assertEqual(storage, snapshot(self.base))
        before = snapshot(self.root / ".byori" / "generations")
        (self.root / "docs/operations.md").unlink()
        self.assertIsNone(handbook.read_handbook(self.root, accepted_records=records)["handbook"])
        with self.assertRaises(handbook.HandbookError):
            handbook.publish_handbook(build, accepted_records=records)
        self.assertEqual(before, snapshot(self.root / ".byori" / "generations"))
        changed = self.compile(records)
        self.assertNotIn(DOC, changed["handbook"])
        self.assert_artifacts_equal(changed, self.compile(records, clean_projection=True))

    def test_deleted_declared_target_withholds_read_and_preserves_last_publication(self):
        records = dependency_records()
        build = self.compile(records)
        handbook.publish_handbook(build, accepted_records=records)
        before = snapshot(self.root / ".byori")
        remaining = records[1:]
        result = handbook.read_handbook(self.root, accepted_records=remaining)
        self.assertIsNone(result["handbook"])
        self.assertNotEqual(result["state"], "current")
        with self.assertRaises(handbook.HandbookError):
            self.compile(remaining)
        self.assertEqual(before, snapshot(self.root / ".byori"))

    def test_transitive_mixed_conflict_component_cannot_lose_one_side(self):
        records = conflict_records()
        records.append(record("decision:third", "Third rule with a long indivisible qualification. " + "detail " * 1100,
                              supersedes=["decision:replacement"], conditions=["Only in a third deployment."]))
        build = self.compile(records, max_chars=6500)
        for meaning in (OLD_RULE, NEW_RULE, "Third rule with a long indivisible qualification."):
            self.assertNotIn(meaning, build["handbook"])
        self.assertGreaterEqual(build["evidence"]["omitted_sections"], 3)
        self.assertEqual(len(self.explicit_links(build)), 2)

    def test_empty_or_heading_only_counterpart_cannot_render_one_sided_component(self):
        # A declared edge survives annotation even when an endpoint contributes
        # zero excerpt claims. Grouping claims alone must not erase that endpoint.
        for supersedes in (False, True):
            for empty_index in (0, 1):
                for empty_body in ("", "# Decision without prose\n", "# Decision\n\n## Qualification\n"):
                    with self.subTest(supersedes=supersedes, empty_index=empty_index, body=empty_body):
                        records = conflict_records(supersedes=supersedes)
                        records[empty_index]["body"] = empty_body
                        remaining_rule = records[1 - empty_index]["body"]
                        build = self.compile(records, max_chars=12000)
                        self.assertEqual(len(self.explicit_links(build)), 1,
                                         "withhold the projection, not the original relationship")
                        self.assertEqual(sum(source["kind"] == "checkpoint"
                                             for source in build["evidence"]["sources"]), 2)
                        self.assertFalse(remaining_rule in build["handbook"],
                                         "a zero-claim counterpart must not disappear from an atomic component")
                        self.assertFalse(any(claim["body"] == remaining_rule
                                             for claim in build["evidence"]["claims"]))
                        source_ids = sorted(source["id"] for source in build["evidence"]["sources"]
                                            if source["kind"] == "checkpoint")
                        self.assertIn({"reason": "related_source_has_no_complete_excerpt",
                                       "source_ids": source_ids, "sections": 1},
                                      build["evidence"]["projection_omissions"])
                        self.assertIn("incomplete related source", build["handbook"])

    def test_fresh_process_starts_cold_but_produces_identical_artifacts(self):
        records = dependency_records()
        expected = self.compile(records)
        before = snapshot(self.base)
        script = (
            "import json,pathlib,sys; sys.path.insert(0,sys.argv[1]); import handbook; "
            "stats={}; result=handbook.compile_handbook(pathlib.Path(sys.argv[2]), "
            "accepted_records=json.loads(sys.stdin.read()), projection_stats=stats); "
            "print(json.dumps({'build':result,'stats':stats}))")
        process = subprocess.run([sys.executable, "-B", "-c", script, str(ROOT / "cli"), str(self.root)],
                                 input=json.dumps(records), capture_output=True, text=True,
                                 env=self.environment, timeout=20, check=True)
        actual = json.loads(process.stdout)
        self.assertEqual(actual["stats"]["reused_sources"], 0)
        self.assertEqual(actual["stats"]["projected_sources"], len(actual["build"]["evidence"]["sources"]))
        self.assert_artifacts_equal(expected, actual["build"])
        self.assertEqual(before, snapshot(self.base))

    def import_records(self, records, revision=None):
        originals = [dict(copy.deepcopy(value), vid=str(index + 1), scope="checkout",
                          provenance={"locator": "synthetic-frozen-fixture"})
                     for index, value in enumerate(records)]
        return handbook_records.import_records(self.root, {
            "complete": True, "source": {"kind": "projection-verifier", "snapshot": "synthetic"},
            "records": originals}, expected_revision=revision)

    def test_warm_refresh_cancel_after_real_staging_preserves_active_generation(self):
        self.import_records(quality_records())
        handbook_refresh.configure_refresh(self.root, enabled=True, debounce_ms=0)
        first = handbook_refresh.refresh_handbook(self.root)
        self.assertEqual(first["state"], "current")
        active = self.root / ".byori/handbook.md"
        before = active.read_bytes()
        self.write("docs/operations.md", "# Operations\n\nFresh operation qualification.\n")
        cancelled = threading.Event()
        real_atomic = handbook._atomic

        def stage_then_cancel(fd, name, text):
            result = real_atomic(fd, name, text)
            if name == "evidence.json":
                cancelled.set()
            return result

        with mock.patch.object(handbook, "_atomic", side_effect=stage_then_cancel):
            result = handbook_refresh.refresh_handbook(self.root, cancelled=cancelled.is_set)
        self.assertTrue(cancelled.is_set(), "must actually stage a real generation")
        self.assertEqual(result["refresh"], "cancelled")
        self.assertIsNone(result["handbook"])
        self.assertEqual(before, active.read_bytes())

    def test_warm_publication_revalidates_declared_record_snapshot_after_staging(self):
        records = quality_records()
        original = self.import_records(records)
        first = handbook.compile_handbook(self.root)
        handbook.publish_handbook(first)
        active = self.root / ".byori/handbook.md"
        before = active.read_bytes()
        self.write("docs/operations.md", "# Operations\n\nCandidate source revision.\n")
        candidate = handbook.compile_handbook(self.root)
        real_atomic = handbook._atomic
        changed = []

        def stage_then_change_declaration(fd, name, text):
            result = real_atomic(fd, name, text)
            if name == "evidence.json" and not changed:
                changed.append(True)
                records[1]["metadata"]["handbook"]["conditions"] = ["Never retry after settlement."]
                self.import_records(records, original["revision"])
            return result

        with mock.patch.object(handbook, "_atomic", side_effect=stage_then_change_declaration):
            with self.assertRaises(handbook.HandbookError):
                handbook.publish_handbook(candidate)
        self.assertTrue(changed, "must race a real staged generation")
        self.assertEqual(before, active.read_bytes())
        self.assertIsNone(handbook.read_handbook(self.root)["handbook"])
        current = handbook.compile_handbook(self.root)
        self.assertIn("Never retry after settlement.", current["handbook"])
        self.assert_artifacts_equal(current, handbook.compile_handbook(self.root, clean_projection=True))


if __name__ == "__main__":
    unittest.main()
