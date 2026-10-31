"""Pure six-list declaration contract, including the exact field/type matrix.

module_paths: module. conditions: decision/bug/incident/task.
depends_on: module -> module. affects: decision/bug -> module.
conflicts_with and supersedes: decision -> decision.
Field presence on any other type is invalid, including an empty list.
Paths/conditions reject all Cc/Cf, surrogates, and Zl/Zp (no newline/tab).
Module paths are literal POSIX-relative paths without empty/dot/parent segments,
backslashes, colons, *?[]{} or surrounding whitespace; no lookup or expansion.
Valid Unicode and conditions' surrounding spaces are preserved, not normalized.
Self-conflicts fail closed rather than counting as actual conflict pairs.
"""

import ast
import copy
import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "cli" / "handbook_knowledge.py"
SPEC = importlib.util.spec_from_file_location("byori_handbook_knowledge", MODULE_PATH)
KNOWLEDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(KNOWLEDGE)
FIELDS = ("module_paths", "conditions", "depends_on", "affects", "conflicts_with", "supersedes")
TYPES = ("note", "module", "decision", "bug", "incident", "concept", "entity", "task")


def checkpoint(name, handbook=None, *, source_id=None, node_type=None):
    metadata = {"name": name, "type": node_type or name.split(":", 1)[0]}
    if handbook is not None:
        metadata["handbook"] = handbook
    return {"id": source_id or "source:" + name, "kind": "checkpoint",
            "metadata": metadata, "content": "Unverified original body."}


class KnowledgeTests(unittest.TestCase):
    def annotate(self, *sources):
        return KNOWLEDGE.annotate_sources(list(sources))

    def test_error_contract(self):
        self.assertTrue(issubclass(KNOWLEDGE.KnowledgeError, ValueError))

    def test_empty_snapshot_reports_unknown_not_proof_of_absence(self):
        result = self.annotate()
        self.assertEqual(result["declarations"], {})
        self.assertEqual(result["relationships"], [])
        self.assertEqual(result["coverage"], {"declared_modules": 0, "conditional_records": 0,
                                              "conflict_pairs": 0, "supersession_links": 0})
        self.assertEqual(len(result["warnings"]), 2)
        self.assertTrue(all("unknown" in warning for warning in result["warnings"]))

    def test_all_typed_checkpoints_without_handbook_have_six_empty_lists(self):
        sources = [checkpoint(node_type + ":x") for node_type in TYPES]
        result = KNOWLEDGE.annotate_sources(sources)
        self.assertEqual(len(result["declarations"]), len(TYPES))
        for declaration in result["declarations"].values():
            self.assertEqual(declaration, {field: [] for field in FIELDS})
        self.assertEqual(result["coverage"]["declared_modules"], 1)

    def test_metadata_absent_and_noncheckpoints_are_not_declarations(self):
        result = self.annotate({"id": "source:bare", "kind": "checkpoint"},
                               {"id": "source:doc", "kind": "document", "metadata": {
                                   "handbook": {"conflicts_with": ["decision:missing"]}}})
        self.assertEqual(result["declarations"], {})
        self.assertEqual(result["relationships"], [])

    def test_target_without_handbook_resolves_by_canonical_identity_not_locator(self):
        source = checkpoint("module:a", {"depends_on": ["module:b"]})
        target = checkpoint("module:b", source_id="source:opaque")
        target["locator"] = "misleading:locator"
        result = self.annotate(source, target)
        self.assertEqual(result["relationships"], [
            {"source": source["id"], "relation": "depends_on", "target": "source:opaque"}])
        self.assertEqual(result["declarations"][source["id"]]["depends_on"], ["module:b"])
        self.assertEqual(result["coverage"]["declared_modules"], 2)

    def test_exact_field_and_relation_matrix_for_every_type(self):
        allowed = {"module_paths": {"module"}, "conditions": {"decision", "bug", "incident", "task"},
                   "depends_on": {"module"}, "affects": {"decision", "bug"},
                   "conflicts_with": {"decision"}, "supersedes": {"decision"}}
        for field in FIELDS:
            for node_type in TYPES:
                for empty in (False, True):
                    with self.subTest(field=field, node_type=node_type, empty=empty):
                        value = {"module_paths": "cli/example.py", "conditions": "Only when offline.",
                                 "depends_on": "module:target", "affects": "module:target",
                                 "conflicts_with": "decision:target", "supersedes": "decision:target"}[field]
                        source = checkpoint(node_type + ":subject", {field: [] if empty else [value]})
                        targets = [checkpoint("module:target"), checkpoint("decision:target")]
                        if node_type in allowed[field]:
                            result = self.annotate(source, *targets)
                            self.assertEqual(result["declarations"][source["id"]][field], [] if empty else [value])
                            if field in {"depends_on", "affects", "conflicts_with", "supersedes"}:
                                self.assertEqual(len(result["relationships"]), 0 if empty else 1)
                        else:
                            with self.assertRaises(KNOWLEDGE.KnowledgeError):
                                self.annotate(source, *targets)

    def test_affects_is_explicit_decision_and_bug_to_module(self):
        result = self.annotate(checkpoint("module:m"), checkpoint("decision:d", {"affects": ["module:m"]}),
                               checkpoint("bug:b", {"affects": ["module:m"]}))
        self.assertEqual(result["relationships"], [
            {"source": "source:bug:b", "relation": "affects", "target": "source:module:m"},
            {"source": "source:decision:d", "relation": "affects", "target": "source:module:m"}])

    def test_wrong_target_types_fail_closed_for_all_relations(self):
        for relation, owner, target in (("depends_on", "module", "decision"),
                                         ("affects", "decision", "bug"),
                                         ("affects", "bug", "decision"),
                                         ("conflicts_with", "decision", "module"),
                                         ("supersedes", "decision", "bug")):
            with self.subTest(relation=relation, owner=owner, target=target):
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    self.annotate(checkpoint(owner + ":a", {relation: [target + ":b"]}),
                                  checkpoint(target + ":b"))

    def test_conditions_and_paths_preserved_verbatim_and_normalized(self):
        condition = "  Only if offline; never retry after payment.  "
        path = "cli/declared.py"
        result = self.annotate(checkpoint("decision:d", {"conditions": [condition, "Z", condition]}),
                               checkpoint("module:m", {"module_paths": [path, "a", path]}))
        self.assertEqual(result["declarations"]["source:decision:d"]["conditions"], [condition, "Z"])
        self.assertEqual(result["declarations"]["source:module:m"]["module_paths"], ["a", path])
        self.assertEqual(result["coverage"]["conditional_records"], 1)

    def test_reciprocal_conflicts_are_not_inferred_or_resolved(self):
        first = checkpoint("decision:a", {"conditions": ["Only before migration."],
                                            "conflicts_with": ["decision:b", "decision:b"]})
        second = checkpoint("decision:b", {"conditions": ["Only after migration."],
                                             "conflicts_with": ["decision:a"], "supersedes": ["decision:a"]})
        second["metadata"].update(state="accepted", recorded_time="far-future")
        result = self.annotate(first, second)
        self.assertEqual(result["coverage"], {"declared_modules": 0, "conditional_records": 2,
                                              "conflict_pairs": 1, "supersession_links": 1})
        self.assertEqual(len(result["relationships"]), 3)
        self.assertEqual(result["declarations"][first["id"]]["conditions"], ["Only before migration."])

    def test_lexical_disagreement_and_reverts_never_create_links(self):
        first, second = checkpoint("decision:a"), checkpoint("decision:b")
        first["content"] = "Always use queues. Supersedes decision:b."
        second["content"] = "Never use queues. Revert decision:a; fixed bug:b."
        result = self.annotate(first, second, checkpoint("bug:b"))
        self.assertEqual(result["relationships"], [])
        self.assertEqual(result["coverage"]["conflict_pairs"], 0)

    def test_self_conflicts_fail_closed_with_generic_errors(self):
        sentinel = "SENSITIVE_DO_NOT_ECHO"
        name = "decision:" + sentinel
        for targets in ([name], ["decision:other", name], [name, name]):
            with self.subTest(count=len(targets)):
                source = checkpoint(name, {"conflicts_with": targets})
                source["content"] = sentinel
                with self.assertRaises(KNOWLEDGE.KnowledgeError) as caught:
                    self.annotate(source, checkpoint("decision:other"))
                self.assertNotIn(sentinel, str(caught.exception))

    def test_paths_and_conditions_reject_controls_format_and_line_separators(self):
        # Entire C0/C1 ranges plus representative format/invisible characters.
        forbidden = ([chr(code) for code in range(0x20)]
                     + [chr(code) for code in range(0x7f, 0xa0)]
                     + list("\u00ad\u061c\u200b\u200c\u200d\u200e\u200f\u202a\u202b\u202c"
                            "\u202d\u202e\u2060\u2066\u2067\u2068\u2069\ufeff\U000e0001\u2028\u2029"))
        sentinel = "SENSITIVE_DO_NOT_ECHO"
        for field, node_type in (("module_paths", "module"), ("conditions", "decision")):
            for char in forbidden:
                with self.subTest(field=field, code=ord(char)):
                    value = sentinel + char + ".py"
                    with self.assertRaises(KNOWLEDGE.KnowledgeError) as caught:
                        self.annotate(checkpoint(node_type + ":a", {field: [value]}))
                    self.assertNotIn(sentinel, str(caught.exception))

    def test_module_paths_require_safe_literal_relative_segments(self):
        invalid = ("/etc/passwd", "//host/share", "../secret", "src/../secret", "src/..", ".", "..",
                   "./src/file.py", "src/./file.py", "src/", "src//file.py", "\\absolute",
                   "src\\file.py", "C:/file.py", "C:file.py", "https://host/file", "src/a:b",
                   "src/*.py", "src/**/file.py", "src/a?.py", "src/[ab].py", "src/{a,b}.py",
                   " src/file.py", "src/file.py ", "\u00a0src/file.py", "src/file.py\u00a0")
        for path in invalid:
            with self.subTest(path=path):
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    self.annotate(checkpoint("module:a", {"module_paths": [path]}))

    def test_valid_relative_paths_and_unicode_conditions_remain_verbatim(self):
        # Nonexistent paths remain declarations, not verified modules. Tilde and
        # percent escapes are literal names, never expanded or URI-decoded.
        paths = ["src/not-present.py", "모듈/결제.py", "src/with space.py", ".hidden/file.py",
                 "~literal/file.py", "src/%2e%2e/file.py", "src/cafe\u0301.py"]
        conditions = ["  Only in staging.  ", "결제 완료 전만 적용", "cafe\u0301 ≠ café"]
        result = self.annotate(checkpoint("module:a", {"module_paths": paths}),
                               checkpoint("decision:a", {"conditions": conditions}))
        self.assertEqual(result["declarations"]["source:module:a"]["module_paths"], sorted(paths))
        self.assertEqual(result["declarations"]["source:decision:a"]["conditions"], sorted(conditions))

    def test_module_cycles_including_self_dependency_are_valid(self):
        result = self.annotate(checkpoint("module:a", {"depends_on": ["module:b", "module:a"]}),
                               checkpoint("module:b", {"depends_on": ["module:a"]}))
        self.assertEqual(len(result["relationships"]), 3)

    def test_supersession_cycles_including_self_cycle_are_rejected(self):
        for sources in ([checkpoint("decision:a", {"supersedes": ["decision:a"]})],
                        [checkpoint("decision:a", {"supersedes": ["decision:b"]}),
                         checkpoint("decision:b", {"supersedes": ["decision:c"]}),
                         checkpoint("decision:c", {"supersedes": ["decision:a"]})]):
            with self.subTest(length=len(sources)):
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    KNOWLEDGE.annotate_sources(sources)

    def test_maximum_supersession_chain_and_diamond_are_valid(self):
        sources = [checkpoint("decision:d" + str(index),
                              {"supersedes": ["decision:d" + str(index + 1)]} if index < 199 else {})
                   for index in range(200)]
        self.assertEqual(KNOWLEDGE.annotate_sources(sources)["coverage"]["supersession_links"], 199)
        diamond = [checkpoint("decision:a", {"supersedes": ["decision:b", "decision:c"]}),
                   checkpoint("decision:b", {"supersedes": ["decision:d"]}),
                   checkpoint("decision:c", {"supersedes": ["decision:d"]}), checkpoint("decision:d")]
        self.assertEqual(KNOWLEDGE.annotate_sources(diamond)["coverage"]["supersession_links"], 4)

    def test_missing_deleted_or_out_of_snapshot_targets_are_rejected(self):
        for relation, owner in (("depends_on", "module"), ("affects", "bug"),
                                ("conflicts_with", "decision"), ("supersedes", "decision")):
            target_type = "module" if relation in {"depends_on", "affects"} else "decision"
            with self.subTest(relation=relation):
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    self.annotate(checkpoint(owner + ":a", {relation: [target_type + ":missing"]}))

    def test_canonical_name_ambiguity_across_vids_fails_closed(self):
        first = checkpoint("module:target", source_id="source:one")
        second = checkpoint("module:target", source_id="source:two")
        first["metadata"]["vid"], second["metadata"]["vid"] = "1", "2"
        with self.assertRaises(KNOWLEDGE.KnowledgeError):
            self.annotate(checkpoint("module:a", {"depends_on": ["module:target"]}), first, second)
        # Ambiguity without a declaration is not itself a semantic claim.
        self.assertEqual(self.annotate(first, second)["relationships"], [])

    def test_legacy_note_cannot_impersonate_typed_target_or_remove_ambiguity(self):
        note = checkpoint("module:target", node_type="note", source_id="source:note")
        source = checkpoint("module:a", {"depends_on": ["module:target"]})
        for targets in ([note], [note, checkpoint("module:target")]):
            with self.subTest(count=len(targets)):
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    self.annotate(source, *targets)

    def test_handbook_unknown_fields_and_nonobjects_fail_closed(self):
        for handbook in (None, [], "bad", 1, True, {"unknown": []}):
            with self.subTest(handbook=handbook):
                source = checkpoint("module:a")
                source["metadata"]["handbook"] = handbook
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    self.annotate(source)

    def test_list_shape_and_raw_entry_count_strict_before_deduplication(self):
        for values in ("x", ("x",), {}, None, True, [None], [1], [[]], [""], [" \n\t"], ["x"] * 17):
            with self.subTest(values=values):
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    self.annotate(checkpoint("module:a", {"module_paths": values}))
        self.assertEqual(self.annotate(checkpoint("module:a", {"module_paths": ["x"] * 16}))[
            "declarations"]["source:module:a"]["module_paths"], ["x"])

    def test_utf8_byte_bounds_and_surrogates_for_paths_and_conditions(self):
        for field, node_type in (("module_paths", "module"), ("conditions", "decision")):
            for value in ("x" * 1024, "é" * 512):
                with self.subTest(field=field, valid=True, length=len(value)):
                    self.assertEqual(self.annotate(checkpoint(node_type + ":a", {field: [value]}))[
                        "declarations"]["source:" + node_type + ":a"][field], [value])
            for value in ("x" * 1025, "é" * 513, "\ud800", "\udfff", "x\ud800x", "\ud83d\ude00"):
                with self.subTest(field=field, valid=False, length=len(value)):
                    with self.assertRaises(KNOWLEDGE.KnowledgeError):
                        self.annotate(checkpoint(node_type + ":a", {field: [value]}))

    def test_canonical_target_bounds_and_format(self):
        name = "module:" + "x" * (256 - len("module:"))
        self.assertEqual(len(self.annotate(checkpoint("module:a", {"depends_on": [name]}),
                                           checkpoint(name))["relationships"]), 1)
        for name in (name + "x", "module:../x", "module:", "Module:x", "module:x y", " module:x", "module:x\n"):
            with self.subTest(name=name):
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    self.annotate(checkpoint("module:a", {"depends_on": [name]}))

    def test_identity_shapes_fail_closed_without_echoing_values(self):
        for metadata in (None, [], {}, {"name": "module:a"}, {"type": "module"},
                         {"name": "decision:a", "type": "module"}, {"name": "bad", "type": "module"},
                         {"name": "module:a", "type": []}):
            with self.subTest(metadata=metadata):
                source = checkpoint("module:a")
                source["metadata"] = metadata
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    self.annotate(source)

    def test_checkpoint_bound_includes_undeclared_and_metadata_absent(self):
        sources = [checkpoint("module:m" + str(index)) for index in range(200)]
        documents = [{"id": "source:doc" + str(index), "kind": "document"} for index in range(201)]
        self.assertEqual(KNOWLEDGE.annotate_sources(sources + documents)["coverage"]["declared_modules"], 200)
        with self.assertRaises(KNOWLEDGE.KnowledgeError):
            KNOWLEDGE.annotate_sources(sources + [{"id": "source:bare", "kind": "checkpoint"}])

    def test_source_shapes_and_duplicate_ids_are_rejected(self):
        for sources in ({}, "bad", iter([]), [None], [{}], [{"id": 1}],
                        [checkpoint("module:a"), checkpoint("module:a")]):
            with self.subTest(shape=type(sources).__name__):
                with self.assertRaises(KNOWLEDGE.KnowledgeError):
                    KNOWLEDGE.annotate_sources(sources)

    def test_other_metadata_is_ignored_not_projected(self):
        source = checkpoint("decision:a")
        source["metadata"].update(provenance={"unrelated": ["private original"]},
                                 conditions=["Not handbook conditions"], links=[{"relation": "supersedes"}])
        result = self.annotate(source)
        self.assertEqual(result["declarations"][source["id"]], {field: [] for field in FIELDS})
        self.assertNotIn("private original", repr(result))

    def test_errors_never_echo_body_target_or_unknown_key(self):
        sentinel = "SENSITIVE_DO_NOT_ECHO"
        sources = [checkpoint("decision:a", {"conflicts_with": ["decision:" + sentinel]}),
                   checkpoint("module:a", {sentinel: []}),
                   checkpoint("module:a", {"module_paths": [sentinel * 100]})]
        for source in sources:
            source["content"] = sentinel
            with self.subTest(field=list(source["metadata"]["handbook"])[0]):
                with self.assertRaises(KNOWLEDGE.KnowledgeError) as caught:
                    self.annotate(source)
                self.assertNotIn(sentinel, str(caught.exception))

    def test_deterministic_order_and_no_mutation_or_shared_outputs(self):
        sources = [checkpoint("decision:d", {"affects": ["module:b", "module:a", "module:b"]}),
                   checkpoint("module:b"), checkpoint("module:a", {"module_paths": ["z", "a"]})]
        before = copy.deepcopy(sources)
        result = KNOWLEDGE.annotate_sources(sources)
        self.assertEqual(result, KNOWLEDGE.annotate_sources(list(reversed(sources))))
        self.assertEqual(sources, before)
        result["declarations"]["source:decision:d"]["affects"].append("module:fake")
        result["relationships"][0]["target"] = "source:fake"
        self.assertEqual(sources, before)
        self.assertNotEqual(result, KNOWLEDGE.annotate_sources(sources))

    def test_implementation_has_no_filesystem_engine_handbook_or_model_imports(self):
        tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
        imports = [node for node in ast.walk(tree) if isinstance(node, (ast.Import, ast.ImportFrom))]
        self.assertTrue(all(isinstance(node, ast.Import) for node in imports))
        self.assertEqual([alias.name for node in imports for alias in node.names], ["re", "unicodedata"])


if __name__ == "__main__":
    unittest.main()
