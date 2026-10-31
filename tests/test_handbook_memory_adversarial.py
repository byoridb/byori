"""Independent adversarial checks of the reviewed KC01 observation contract.

Only this file is owned by this verifier. Git/journal/compiler operations use
temporary repositories; all engine reads use the context-managed reader below.
No implementation-dependent skips, live transport, models, or engine writes.
Two equal reads establish a best-effort observation, not transactional backup.
"""

import contextlib
import copy
import importlib
import io
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cli"))
handbook = importlib.import_module("handbook")
handbook_records = importlib.import_module("handbook_records")


TYPES = ("note", "module", "decision", "bug", "incident", "concept", "entity", "task")
SECRET = "ghp_" + "Z" * 36  # Synthetic token-shaped content, never a credential.
PUBLIC_FIELDS = {
    "schema_version", "state", "project_root", "review_digest", "base_revision",
    "record_count", "new_records", "changed_records", "unchanged_records",
    "retained_records", "withheld_records", "records",
}


def node(name="decision:retry", vid="41", body="Retry at most twice.", **fields):
    node_type = fields.pop("type", name.split(":", 1)[0])
    result = {"type": node_type, "vid": vid, "name": name, "body": body, "ts": 1700000123}
    if node_type == "note":
        result["kind"] = "decision"
    elif node_type in {"decision", "bug", "task"}:
        result["state"] = {"decision": "active", "bug": "open", "task": "done"}[node_type]
    elif node_type == "incident":
        result["resolved"] = "false"
    result.update(fields)
    return result


def edge(src="41", dst="42", edge_type="affects", **fields):
    result = dict(src=src, dst=dst, edge_type=edge_type, relation=None)
    result.update(fields)
    return result


def tree(root):
    """Include empty directories, symlinks, modes and mtimes, not read atimes."""
    result = {}
    for path in [root, *sorted(root.rglob("*"))]:
        info = path.lstat()
        payload = (os.readlink(path) if path.is_symlink() else
                   path.read_bytes() if path.is_file() else None)
        result[str(path.relative_to(root))] = (stat.S_IMODE(info.st_mode), info.st_mtime_ns, payload)
    return result


class Reader:
    """Strict read-only fixture: unknown queries are test failures, not empties.

    A repeated query advances its observation version. Node fixtures include a
    local-only type discriminator, stripped before returning projected columns.
    The row mutator corrupts actual query envelopes rather than mocking capture.
    """

    def __init__(self, nodes=(), links=(), *, later_nodes=None, later_links=None,
                 space="byori_adversarial", endpoint="http://127.0.0.1:19878",
                 mutate=None, on_exit=None):
        self.versions = [(copy.deepcopy(list(nodes)), copy.deepcopy(list(links))),
                         (copy.deepcopy(list(nodes if later_nodes is None else later_nodes)),
                          copy.deepcopy(list(links if later_links is None else later_links)))]
        self.space, self.endpoint = space, endpoint
        self.mutate, self.on_exit = mutate, on_exit
        self.calls = []
        self.counts = Counter()
        self.roots = []
        self.entered = self.exited = 0

    @contextlib.contextmanager
    def factory(self, root):
        self.roots.append(pathlib.Path(root))
        self.entered += 1
        try:
            yield self
        finally:
            self.exited += 1
            if self.on_exit:
                self.on_exit()

    def query(self, ngql):
        self.calls.append(ngql)
        assert not re.search(r"\b(INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|UPSERT|REBUILD)\b", ngql, re.I), ngql
        count = self.counts[ngql]
        self.counts[ngql] += 1
        nodes, links = self.versions[min(count, 1)]
        match = re.search(r"MATCH\s*\(\w+:`?(" + "|".join(TYPES) + r")`?\)", ngql, re.I)
        if match:
            category = "nodes"
            rows = [dict(n) for n in nodes if n["type"] == match.group(1)]
            selected = re.search(r"\.name\s*==\s*'((?:\\.|[^'])*)'", ngql)
            if selected:
                name = selected.group(1).replace("\\'", "'").replace("\\\\", "\\")
                rows = [n for n in rows if n["name"] == name]
            rows.sort(key=lambda n: int(n["vid"]))
            for row in rows:
                row.pop("type")
        elif re.search(r"MATCH\s*\(\w+\)\s*-\[", ngql, re.I):
            category = "links"
            rows = copy.deepcopy(links)
        else:
            raise AssertionError("Undocumented reader query: " + ngql)
        response = {"results": rows, "row_count": len(rows)}
        return self.mutate(category, count, response) if self.mutate else response


class MemoryCaptureAdversarialTests(unittest.TestCase):
    def setUp(self):
        # Deliberate failure, not skip, if the concurrent implementation is absent.
        self.memory = importlib.import_module("handbook_memory")
        temporary = tempfile.TemporaryDirectory(prefix="byori-memory-adversarial-")
        self.addCleanup(temporary.cleanup)
        self.base = pathlib.Path(temporary.name).resolve()
        self.root = self.repository("project")
        network_guard = mock.patch("socket.create_connection", side_effect=AssertionError("live network forbidden"))
        network_guard.start()
        self.addCleanup(network_guard.stop)

    def repository(self, name):
        root = self.base / name
        root.mkdir(parents=True)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "init", "-b", "main", str(root)],
                       check=True, capture_output=True, env=environment)
        (root / "README.md").write_text("# Capture fixture\n\nAn isolated checkout for original memories.\n")
        return root

    def capture(self, reader=None, *, root=None, **options):
        reader = reader if reader is not None else Reader([node()])
        return self.memory.capture_memory(root or self.root, client_factory=reader.factory, **options)

    def review_apply(self, nodes=None, links=(), **options):
        nodes = [node()] if nodes is None else nodes
        preview = self.capture(Reader(nodes, links), **options)
        applied = self.capture(Reader(nodes, links), apply=True,
                               expected_digest=preview["review_digest"], **options)
        return preview, applied

    def originals(self):
        snapshot = handbook_records.load_records(self.root)
        self.assertIsNotNone(snapshot)
        return {r["name"]: r for r in snapshot["records"]}

    def reject(self, reader, pattern, **options):
        before = tree(self.base)
        with self.assertRaisesRegex(self.memory.MemoryCaptureError, pattern):
            self.capture(reader, **options)
        self.assertEqual(tree(self.base), before, "rejected observation changed the filesystem")
        self.assertEqual(reader.entered, reader.exited, "reader context leaked on failure")

    def manual(self, name="note:manual", vid="700", body="Caller-accepted original."):
        current = handbook_records.load_records(self.root)
        records = [] if current is None else [self.journal_input(r) for r in current["records"]]
        records.append({"type": name.split(":")[0], "name": name, "vid": vid, "body": body,
                        "scope": "checkout", "provenance": {"adapter": "caller-accepted-test"},
                        "metadata": {"nested": {"keep": ["exact", 17, False]}}})
        return handbook_records.import_records(
            self.root, {"complete": True, "source": {"kind": "manual-test"}, "records": records},
            expected_revision=current["revision"] if current else None)

    @staticmethod
    def journal_input(record):
        result = {key: copy.deepcopy(record[key]) for key in
                  ("type", "name", "vid", "body", "provenance", "metadata", "state")}
        result["scope"] = record["scope"]["kind"]
        if "original_state" in record:
            result["state"] = record["original_state"]
        return result

    def test_preview_has_required_review_fields_and_zero_filesystem_writes(self):
        reader = Reader([node()])
        before = tree(self.base)
        preview = self.capture(reader)
        self.assertTrue(PUBLIC_FIELDS <= preview.keys())
        self.assertEqual(preview["state"], "preview")
        self.assertEqual(preview["project_root"], str(self.root))
        self.assertRegex(preview["review_digest"], r"^[0-9a-f]{64}$")
        self.assertIsNone(preview["base_revision"])
        self.assertEqual(preview["record_count"], 1)
        self.assertEqual(preview["new_records"], 1)
        self.assertEqual(tree(self.base), before)
        self.assertEqual((reader.entered, reader.exited), (1, 1))
        self.assertTrue(reader.counts)
        self.assertTrue(all(count == 2 for count in reader.counts.values()), reader.counts)
        self.assertEqual(preview, self.capture(Reader([node()])))

    def test_preview_of_existing_journal_and_generation_is_read_only(self):
        self.review_apply()
        handbook.publish_handbook(handbook.compile_handbook(self.root, max_commits=0))
        before = tree(self.base)
        preview = self.capture(Reader([node(body="A changed original for review.")]))
        self.assertEqual(preview["changed_records"], 1)
        self.assertEqual(tree(self.base), before)

    def test_two_pass_node_race_rejects_without_writing(self):
        self.reject(Reader([node()], later_nodes=[node(body="Different second observation.")]),
                    r"(?i)(observ|chang|race|retry)")

    def test_two_pass_link_only_race_rejects_without_writing(self):
        nodes = [node(), node("module:transport", "42")]
        self.reject(Reader(nodes, [edge()], later_links=[]), r"(?i)(observ|chang|race|retry)")

    def test_two_pass_withheld_content_race_is_still_a_race(self):
        private = node(body="Token: " + SECRET)
        self.reject(Reader([private], later_nodes=[dict(private, body="New token: " + SECRET)]),
                    r"(?i)(observ|chang|race|retry)")

    def test_apply_requires_review_digest(self):
        self.reject(Reader([node()]), r"(?i)(digest|review|consent)", apply=True)

    def test_stale_body_review_cannot_apply(self):
        preview = self.capture()
        self.reject(Reader([node(body="Changed since the review.")]), r"(?i)(digest|review|stale|chang)",
                    apply=True, expected_digest=preview["review_digest"])

    def test_stale_links_review_cannot_apply(self):
        nodes = [node(), node("module:transport", "42")]
        preview = self.capture(Reader(nodes, [edge()]))
        self.reject(Reader(nodes, []), r"(?i)(digest|review|stale|chang)",
                    apply=True, expected_digest=preview["review_digest"])

    def test_journal_revision_invalidates_previously_reviewed_digest(self):
        preview = self.capture()
        self.manual()
        self.reject(Reader([node()]), r"(?i)(revision|digest|review|stale|chang)",
                    apply=True, expected_digest=preview["review_digest"])
        self.assertEqual(set(self.originals()), {"note:manual"})

    def test_optimistic_revision_race_at_real_journal_commit_keeps_winner(self):
        preview = self.capture()
        original_import = handbook_records.import_records
        winners = []

        def race(root, records, expected_revision=None):
            # Introduce the competing real revision after capture validated consent.
            with mock.patch.object(handbook_records, "import_records", original_import):
                winners.append(self.manual())
            return original_import(root, records, expected_revision=expected_revision)

        with mock.patch.object(handbook_records, "import_records", side_effect=race):
            with self.assertRaisesRegex(self.memory.MemoryCaptureError, r"(?i)(revision|conflict|chang|stale)"):
                self.capture(apply=True, expected_digest=preview["review_digest"])
        self.assertEqual(len(winners), 1, "race did not reach the real journal write boundary")
        self.assertEqual(handbook_records.load_records(self.root), winners[0])
        snapshots = list((self.root / ".byori/records/snapshots").glob("*.json"))
        self.assertEqual(len(snapshots), 1, "loser left an unreviewed snapshot")

    def test_journal_change_during_observation_invalidates_preview(self):
        winners = []
        reader = Reader([node()], on_exit=lambda: winners.append(self.manual()))
        with self.assertRaisesRegex(self.memory.MemoryCaptureError, r"(?i)(revision|chang|stale|conflict)"):
            self.capture(reader)
        self.assertEqual(len(winners), 1)
        self.assertEqual(handbook_records.load_records(self.root), winners[0])
        self.assertEqual((reader.entered, reader.exited), (1, 1))

    def test_unseen_records_and_manual_originals_are_retained_exactly(self):
        self.manual()
        self.review_apply([node(), node("bug:unseen", "88")])
        before = self.originals()
        old_snapshot = handbook_records.load_records(self.root)
        old_path = self.root / ".byori/records/snapshots" / (old_snapshot["revision"] + ".json")
        old_bytes = old_path.read_bytes()
        selection = [{"type": "decision", "name": "decision:retry"}]
        preview, applied = self.review_apply([node(body="Now retry once.")], selection=selection)
        after = self.originals()
        self.assertEqual(preview["retained_records"], 2)
        self.assertTrue(applied["changed"])
        self.assertEqual(after["note:manual"], before["note:manual"])
        self.assertEqual(after["bug:unseen"], before["bug:unseen"])
        self.assertEqual(after["decision:retry"]["body"], "Now retry once.")
        self.assertEqual(old_path.read_bytes(), old_bytes)

    def test_empty_graph_does_not_retract_captured_originals(self):
        self.review_apply()
        before = self.originals()
        self.review_apply([])
        self.assertEqual(self.originals(), before)

    def test_unchanged_reviewed_apply_is_noop_without_snapshot_churn(self):
        _, first = self.review_apply()
        preview = self.capture()
        before = tree(self.base)
        result = self.capture(apply=True, expected_digest=preview["review_digest"])
        self.assertEqual(preview["unchanged_records"], 1)
        self.assertFalse(result["changed"])
        self.assertEqual(result["revision"], first["revision"])
        self.assertEqual(tree(self.base), before)

    def test_exact_manual_record_identity_is_not_adapter_owned(self):
        self.manual(name="decision:retry", vid="41")
        self.reject(Reader([node()]), r"(?i)(conflict|manual|own|collision|caller)")

    def test_canonical_name_collision_at_different_vid_is_not_silently_merged(self):
        self.manual(name="decision:retry", vid="999")
        self.reject(Reader([node()]), r"(?i)(conflict|ambig|identity|identit|collision|own|canonical)")

    def test_digest_binds_engine_space_and_endpoint(self):
        preview = self.capture()
        for overrides in ({"space": "byori_other"}, {"endpoint": "http://127.0.0.1:19879"}):
            with self.subTest(overrides=overrides):
                other = self.capture(Reader([node()], **overrides))
                self.assertNotEqual(preview["review_digest"], other["review_digest"])
                self.reject(Reader([node()], **overrides), r"(?i)(digest|review|namespace|stale|chang)",
                            apply=True, expected_digest=preview["review_digest"])

    def test_existing_capture_cannot_be_reowned_by_another_namespace(self):
        self.review_apply()
        self.reject(Reader([node()], space="byori_other"), r"(?i)(namespace|conflict|own|collision|engine)")

    def test_same_content_in_other_checkout_has_different_review_digest(self):
        other = self.repository("elsewhere/project")
        original = self.capture()
        elsewhere = self.capture(root=other)
        self.assertNotEqual(original["review_digest"], elsewhere["review_digest"])
        self.reject(Reader([node()]), r"(?i)(digest|review|checkout|stale|chang)", root=other,
                    apply=True, expected_digest=original["review_digest"])

    def test_nested_and_symlink_paths_bind_canonical_checkout(self):
        nested = self.root / "nested"
        nested.mkdir()
        alias = self.base / "project-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        canonical = self.capture()
        for path in (nested, alias):
            with self.subTest(path=path):
                reader = Reader([node()])
                result = self.capture(reader, root=path)
                self.assertEqual(result, canonical)
                self.assertEqual(reader.roots, [self.root])

    def test_ambient_git_and_space_overrides_cannot_rebind_capture(self):
        other = self.repository("other")
        expected = self.capture()
        with mock.patch.dict(os.environ, {"GIT_DIR": str(other / ".git"),
                                          "GIT_WORK_TREE": str(other),
                                          "BYORIDB_MEMORY_SPACE": "byori_ambient_wrong"}):
            reader = Reader([node()])
            actual = self.capture(reader)
        self.assertEqual(actual, expected)
        self.assertEqual(reader.roots, [self.root])

    def test_selection_is_bound_even_if_observed_content_is_equal(self):
        preview = self.capture()
        selection = [{"type": "decision", "name": "decision:retry"}]
        selected = self.capture(selection=selection)
        self.assertNotEqual(preview["review_digest"], selected["review_digest"])
        self.reject(Reader([node()]), r"(?i)(digest|review|stale|chang)", selection=selection,
                    apply=True, expected_digest=preview["review_digest"])

    def test_exact_vid_body_timestamp_kind_lifecycle_and_links_are_preserved(self):
        body = "  Original — 한글 e\u0301\r\n\tsecond line  \n"
        nodes = [node(vid="9223372036854775807", body=body, state="superseded", ts=-123456789),
                 node("note:raw", "-9223372036854775808", type="note", kind="legacy custom kind"),
                 node("incident:raw", 9007199254740993, resolved="true"),
                 node("module:transport", "42")]
        links = [edge("9223372036854775807", "42", ts=-234567890),
                 edge("-9223372036854775808", "9007199254740993", "relates_to"),
                 edge("42", "-999", "depends_on")]
        preview, applied = self.review_apply(nodes, links)
        self.assertEqual(applied["state"], "imported")
        originals = self.originals()
        self.assertEqual(len(originals), len(nodes))
        for source in nodes:
            with self.subTest(name=source["name"]):
                saved = originals[source["name"]]
                for key in ("type", "name", "body"):
                    self.assertEqual(saved[key], source[key])
                self.assertEqual(saved["vid"], str(source["vid"]))
                self.assertEqual(saved["state"], "unverified")
                self.assertEqual(saved["scope"]["kind"], "checkout")
                self.assertEqual(saved["metadata"]["graph_node"], dict(source, vid=str(source["vid"])))
                self.assertEqual(saved["provenance"]["recorded_time"], source["ts"])
                self.assertNotIn("source_event_time", saved)
                self.assertNotIn("source_event_time", saved["provenance"])
                self.assertEqual(saved["provenance"]["adapter"], "byoridb-memory-capture-v1")
                expected_links = [link for link in links if str(source["vid"]) in (link["src"], link["dst"])]
                self.assertCountEqual(saved["metadata"]["graph_links"], expected_links)
        self.assertEqual(preview["records"], applied["records"])
        compiled = handbook.compile_handbook(self.root, max_commits=0)
        source = next(s for s in compiled["evidence"]["sources"]
                      if s["kind"] == "checkpoint" and s["metadata"]["name"] == "decision:retry")
        claims = [claim for claim in compiled["evidence"]["claims"] if claim["source_id"] == source["id"]]
        self.assertTrue(claims)
        self.assertTrue(all(claim["state"] == "unverified" for claim in claims))
        self.assertTrue(all("superseded" in claim["source_declared_states"] for claim in claims))

    def test_noncanonical_legacy_resolved_string_is_preserved_not_reinterpreted(self):
        original = node("incident:raw", "-73", resolved="TRUE")
        self.review_apply([original])
        self.assertEqual(self.originals()["incident:raw"]["metadata"]["graph_node"]["resolved"], "TRUE")
        self.assertEqual(self.originals()["incident:raw"]["state"], "unverified")

    def test_string_vid_spelling_is_not_rewritten_through_integer_conversion(self):
        self.review_apply([node(vid="000041")])
        self.assertEqual(self.originals()["decision:retry"]["vid"], "000041")
        self.assertEqual(self.originals()["decision:retry"]["metadata"]["graph_node"]["vid"], "000041")

    def test_opaque_legacy_note_name_survives_journal_and_compiler(self):
        name = "이전 메모 / retry policy (v1)"
        original = node(name, "-17", "Keep this legacy original exactly.", type="note")
        self.review_apply([original])
        self.assertEqual(self.originals()[name]["name"], name)
        compiled = handbook.compile_handbook(self.root, max_commits=0)
        sources = [s for s in compiled["evidence"]["sources"] if s["kind"] == "checkpoint"]
        self.assertEqual(len(sources), 1)
        self.assertEqual(sources[0]["metadata"]["name"], name)
        self.assertEqual(sources[0]["content"], original["body"])

    def test_supported_relation_is_explicit_and_dangling_relation_stays_raw(self):
        nodes = [node(), node("module:transport", "42")]
        links = [edge(), edge("42", "-999", "depends_on"),
                 edge("41", "42", "rel", relation="legacy-custom-association")]
        self.review_apply(nodes, links)
        originals = self.originals()
        self.assertEqual(originals["decision:retry"]["metadata"]["handbook"]["affects"], ["module:transport"])
        self.assertNotIn("depends_on", originals["module:transport"]["metadata"].get("handbook", {}))
        self.assertNotIn("legacy-custom-association", originals["decision:retry"]["metadata"].get("handbook", {}))
        self.assertTrue(originals["module:transport"]["metadata"]["graph_links"])
        handbook.compile_handbook(self.root, max_commits=0)

    def test_unobserved_retained_endpoint_is_not_used_to_invent_relation(self):
        self.review_apply([node("module:transport", "42")])
        self.review_apply([node()], [edge()], selection=[{"type": "decision", "name": "decision:retry"}])
        saved = self.originals()["decision:retry"]
        self.assertNotIn("affects", saved["metadata"].get("handbook", {}))
        self.assertTrue(saved["metadata"]["graph_links"])

    def test_opaque_note_is_not_a_typed_handbook_relation_target(self):
        nodes = [node("module:transport", "42"), node("legacy free form / note", "43", type="note")]
        self.review_apply(nodes, [edge("42", "43", "depends_on")])
        saved = self.originals()["module:transport"]
        self.assertNotIn("depends_on", saved["metadata"].get("handbook", {}))
        self.assertTrue(saved["metadata"]["graph_links"])
        handbook.compile_handbook(self.root, max_commits=0)

    def test_cyclic_supported_declarations_are_validated_before_any_write(self):
        nodes = [node("decision:first", "41"), node("decision:second", "42")]
        self.reject(Reader(nodes, [edge("41", "42", "supersedes"), edge("42", "41", "supersedes")]),
                    r"(?i)(cycle|cyclic|supersed|invalid|declaration)")

    def test_secret_is_withheld_from_preview_output_and_import(self):
        nodes = [node(), node("note:private", "99", "Token: " + SECRET, type="note")]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            preview, applied = self.review_apply(nodes)
        self.assertEqual(preview["withheld_records"], 1)
        self.assertNotIn(SECRET, json.dumps([preview, applied]) + output.getvalue())
        self.assertEqual(set(self.originals()), {"decision:retry"})
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn(SECRET.encode(), path.read_bytes(), str(path))

    def test_withheld_content_digest_still_binds_consent(self):
        private = node("note:private", "99", "Token: " + SECRET, type="note")
        preview = self.capture(Reader([private]))
        changed = dict(private, body="Different token: " + SECRET)
        second = self.capture(Reader([changed]))
        self.assertNotEqual(preview["review_digest"], second["review_digest"])
        self.reject(Reader([changed]), r"(?i)(digest|review|stale|chang)",
                    apply=True, expected_digest=preview["review_digest"])

    def test_secret_replacement_does_not_delete_previously_captured_record(self):
        self.review_apply()
        before = self.originals()
        preview, _ = self.review_apply([node(body="Token: " + SECRET)])
        self.assertEqual(preview["withheld_records"], 1)
        self.assertEqual(self.originals(), before)

    def test_secret_target_cannot_leave_dangling_handbook_declaration(self):
        nodes = [node(), node("module:private", "42", SECRET)]
        preview, _ = self.review_apply(nodes, [edge()])
        self.assertEqual(preview["withheld_records"], 1)
        self.assertNotIn("affects", self.originals()["decision:retry"]["metadata"].get("handbook", {}))
        compiled = handbook.compile_handbook(self.root, max_commits=0)
        self.assertNotIn(SECRET, json.dumps(compiled))

    def test_selected_missing_and_duplicate_identities_fail_closed(self):
        selection = [{"type": "decision", "name": "decision:retry"}]
        self.reject(Reader([]), r"(?i)(missing|found|exact|selected)", selection=selection)
        self.reject(Reader([node(), node(vid="42")]), r"(?i)(duplicate|ambig|unique|identity|identit)",
                    selection=selection)

    def test_invalid_selection_never_becomes_broad_capture(self):
        selections = [[], [{"type": "decision"}], [{"type": "decision", "name": "decision:retry", "extra": 1}],
                      [{"type": "decision", "name": "note:wrong"}],
                      [{"type": "decision", "name": "decision:retry"}] * 2]
        for selection in selections:
            with self.subTest(selection=selection):
                self.reject(Reader([node()]), r"(?i)(selection|select|name|prefix|duplicate|unique|field)",
                            selection=selection)

    def test_record_overflow_fails_instead_of_truncating(self):
        nodes = [node("decision:item-%d" % i, str(i)) for i in range(201)]
        self.reject(Reader(nodes), r"(?i)(limit|bound|200|many|overflow)")

    def test_record_bound_is_global_across_types(self):
        nodes = [node("decision:item-%d" % i, str(i)) for i in range(101)]
        nodes += [node("note:item-%d" % i, str(1000 + i), type="note") for i in range(100)]
        self.reject(Reader(nodes), r"(?i)(limit|bound|200|many|overflow)")

    def test_selection_overflow_fails_before_engine_observation(self):
        selection = [{"type": "decision", "name": "decision:item-%d" % i} for i in range(201)]
        reader = Reader([node()])
        self.reject(reader, r"(?i)(limit|bound|200|many|overflow|selection)", selection=selection)
        self.assertEqual(reader.calls, [])

    def test_link_overflow_fails_instead_of_truncating(self):
        links = [edge("41", str(1000 + i), "relates_to") for i in range(2001)]
        self.reject(Reader([node()], links), r"(?i)(limit|bound|2,?000|many|overflow)")

    def test_normalized_compiler_input_overflow_fails_before_journal_write(self):
        self.reject(Reader([node(body="x" * 1048577)]), r"(?i)(limit|bound|byte|size|large|MiB)")

    def test_merged_snapshot_limit_is_checked_not_just_current_observation(self):
        nodes = [node("decision:item-%d" % i, str(i)) for i in range(200)]
        self.review_apply(nodes)
        self.reject(Reader([node("decision:extra", "201")]), r"(?i)(limit|bound|200|many|overflow)")

    def test_partial_or_malformed_envelopes_cannot_look_like_empty_observation(self):
        corruptions = {
            "missing count": lambda r: {"results": r["results"]},
            "partial count": lambda r: dict(r, row_count=len(r["results"]) + 1),
            "negative count": lambda r: dict(r, row_count=-1),
            "boolean count": lambda r: dict(r, row_count=True),
            "string count": lambda r: dict(r, row_count=str(r["row_count"])),
            "non-list results": lambda r: dict(r, results={}),
            "bad row": lambda r: {"results": [None], "row_count": 1},
            "explicit partial": lambda r: dict(r, partial=True),
            "error with rows": lambda r: dict(r, error="synthetic query failed"),
        }
        for label, corruption in corruptions.items():
            with self.subTest(case=label):
                reader = Reader([node()], mutate=lambda category, count, response: corruption(response))
                self.reject(reader, r"(?i)(malformed|invalid|row|count|partial|complete|response)")

    def test_malformed_node_fields_fail_without_coercion_or_defaults(self):
        mutations = {"missing body": lambda r: r.pop("body"), "missing timestamp": lambda r: r.pop("ts"),
                     "float vid": lambda r: r.update(vid=9007199254740992.0),
                     "null body": lambda r: r.update(body=None),
                     "boolean timestamp": lambda r: r.update(ts=True),
                     "wrong prefix": lambda r: r.update(name="bug:wrong"),
                     "nonstring state": lambda r: r.update(state=False),
                     "wrong supplied type": lambda r: r.update(type="bug"),
                     "missing state": lambda r: r.pop("state")}
        for label, mutation in mutations.items():
            with self.subTest(case=label):
                def corrupt(category, count, response):
                    if category == "nodes":
                        for row in response["results"]:
                            mutation(row)
                    return response
                self.reject(Reader([node()], mutate=corrupt),
                            r"(?i)(malformed|invalid|row|field|body|timestamp|vid|state|prefix|name|string)")

    def test_partial_links_fail_even_when_node_reads_are_complete(self):
        def corrupt(category, count, response):
            return dict(response, row_count=1) if category == "links" else response
        self.reject(Reader([node()], mutate=corrupt), r"(?i)(partial|count|row|complete|response)")

    def test_malformed_link_cannot_be_silently_discarded(self):
        mutations = {"missing source": lambda r: r.pop("src"),
                     "float target": lambda r: r.update(dst=42.0),
                     "missing type": lambda r: r.pop("edge_type"),
                     "object relation": lambda r: r.update(relation={"unexpected": True})}
        for label, mutation in mutations.items():
            with self.subTest(case=label):
                def corrupt(category, count, response):
                    if category == "links":
                        for row in response["results"]:
                            mutation(row)
                    return response
                self.reject(Reader([node()], [edge()], mutate=corrupt),
                            r"(?i)(link|edge|malformed|invalid|vid|field|row|relation)")

    def test_transport_error_text_is_not_returned_or_printed(self):
        def fail(category, count, response):
            raise RuntimeError("raw transport Authorization: " + SECRET)
        before = tree(self.base)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(self.memory.MemoryCaptureError) as caught:
                self.capture(Reader([node()], mutate=fail))
        self.assertNotIn(SECRET, str(caught.exception) + output.getvalue())
        self.assertEqual(tree(self.base), before)

    def test_capture_compile_changed_capture_staleness_and_rebuild(self):
        old_body, new_body = "Retry at most twice before settlement.", "Retry at most once before settlement."
        _, first = self.review_apply([node(body=old_body)])
        built = handbook.publish_handbook(handbook.compile_handbook(self.root, max_commits=0))
        self.assertEqual(handbook.handbook_status(self.root)["state"], "current")
        self.assertIn(old_body, handbook.read_handbook(self.root)["handbook"])
        old_snapshot = self.root / ".byori/records/snapshots" / (first["revision"] + ".json")
        old_bytes = old_snapshot.read_bytes()
        _, changed = self.review_apply([node(body=new_body)])
        self.assertNotEqual(first["revision"], changed["revision"])
        self.assertEqual(handbook.handbook_status(self.root)["state"], "stale")
        self.assertIsNone(handbook.read_handbook(self.root)["handbook"])
        with self.assertRaises(handbook.HandbookError):
            handbook.publish_handbook(built)
        rebuilt = handbook.publish_handbook(handbook.compile_handbook(self.root, max_commits=0))
        self.assertNotEqual(rebuilt["generation"], built["generation"])
        self.assertEqual(handbook.handbook_status(self.root)["state"], "current")
        self.assertIn(new_body, handbook.read_handbook(self.root)["handbook"])
        self.assertNotIn(old_body, handbook.read_handbook(self.root)["handbook"])
        self.assertEqual(old_snapshot.read_bytes(), old_bytes)
        self.assertTrue((self.root / ".byori/generations" / built["generation"] / "evidence.json").is_file())


if __name__ == "__main__":
    unittest.main()
