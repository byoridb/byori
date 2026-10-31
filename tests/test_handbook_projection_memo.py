"""Compiler-owned memo invariants, independent of storage and Git collection."""

import copy
import pathlib
import sys
import unittest
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "cli"))
from handbook_projection import ProjectionMemo


def edge(source, target, relation="depends_on"):
    return {"source": source, "relation": relation, "target": target}


class ProjectionMemoTests(unittest.TestCase):
    def setUp(self):
        self.memo = ProjectionMemo()
        self.calls = []

    def projector(self, value):
        self.calls.append(copy.deepcopy(value))
        return {"body": value["body"], "nested": [value]}

    def project(self, inputs, edges=(), *, scope="checkout-a", clean=False):
        return self.memo.project(scope, inputs, edges, self.projector, clean=clean)

    def test_cold_warm_clean_artifacts_and_actual_projector_calls(self):
        inputs = {"a": {"body": "A"}, "b": {"body": "B"}}
        cold, cold_stats = self.project(inputs)
        warm, warm_stats = self.project(inputs)
        clean, clean_stats = self.project(inputs, clean=True)
        self.assertEqual(cold, warm)
        self.assertEqual(warm, clean)
        self.assertEqual(len(self.calls), 4)
        self.assertEqual(cold_stats["projected_sources"], 2)
        self.assertEqual(warm_stats["projected_sources"], 0)
        self.assertEqual(warm_stats["reused_sources"], 2)
        self.assertEqual(clean_stats["mode"], "clean")
        self.assertEqual(clean_stats["reused_sources"], 0)

    def test_change_invalidates_transitive_reverse_closure_not_unrelated_unit(self):
        inputs = {key: {"body": key} for key in "abcd"}
        edges = [edge("a", "b"), edge("b", "c")]
        self.project(inputs, edges)
        inputs["c"]["body"] = "changed"
        self.calls.clear()
        actual, stats = self.project(inputs, edges)
        self.assertEqual(stats["projected_sources"], 3)
        self.assertEqual(stats["reused_sources"], 1)
        self.assertEqual({value["body"] for value in self.calls}, {"a", "b", "changed"})
        self.assertEqual(actual, self.project(inputs, edges, clean=True)[0])

    def test_cycle_is_bounded_and_invalidates_component(self):
        inputs = {key: {"body": key} for key in "abc"}
        edges = [edge("a", "b"), edge("b", "a")]
        self.project(inputs, edges)
        inputs["b"]["body"] = "new"
        _, stats = self.project(inputs, edges)
        self.assertEqual(stats["projected_sources"], 2)
        self.assertEqual(stats["reused_sources"], 1)

    def test_removal_and_removed_edge_invalidate_old_dependents(self):
        inputs = {key: {"body": key} for key in "abcd"}
        self.project(inputs, [edge("a", "b"), edge("b", "c")])
        inputs.pop("c")
        _, stats = self.project(inputs, [edge("a", "b")])
        self.assertEqual(stats["removed_sources"], 1)
        self.assertEqual(stats["projected_sources"], 2)
        self.assertEqual(stats["reused_sources"], 1)

    def test_relation_type_change_invalidates_owner_and_reverse_dependents(self):
        inputs = {key: {"body": key} for key in "abc"}
        self.project(inputs, [edge("a", "b"), edge("c", "a")])
        _, stats = self.project(inputs, [edge("a", "b", "affects"), edge("c", "a")])
        self.assertEqual(stats["projected_sources"], 2)
        self.assertEqual(stats["reused_sources"], 1)

    def test_reordered_input_and_duplicate_edges_do_not_invalidate(self):
        self.project({"a": {"body": "A", "extra": 1}, "b": {"body": "B"}}, [edge("a", "b")])
        _, stats = self.project({"b": {"body": "B"}, "a": {"extra": 1, "body": "A"}},
                                [edge("a", "b"), edge("a", "b")])
        self.assertEqual(stats["projected_sources"], 0)

    def test_inputs_outputs_and_projector_retained_values_do_not_alias_cache(self):
        inputs = {"a": {"body": "A"}}
        retained = []

        def retaining(value):
            result = {"nested": [value]}
            retained.append(result)
            return result

        original, _ = self.memo.project("scope", inputs, [], retaining)
        expected = copy.deepcopy(original)
        inputs["a"]["body"] = "changed"
        original["a"]["nested"][0]["body"] = "poisoned output"
        retained[0]["nested"][0]["body"] = "poisoned retained"
        actual, stats = self.memo.project("scope", {"a": {"body": "A"}}, [], retaining)
        self.assertEqual(actual, expected)
        self.assertEqual(stats["projected_sources"], 0)

    def test_scope_and_compiler_identity_isolate_entries(self):
        inputs = {"a": {"body": "A"}}
        for scope in (("checkout-a", "1"), ("checkout-b", "1"), ("checkout-a", "2")):
            _, stats = self.project(inputs, scope=scope)
            self.assertEqual(stats["projected_sources"], 1)
        _, stats = self.project(inputs, scope=("checkout-a", "1"))
        self.assertEqual(stats["reused_sources"], 1)

    def test_clean_pass_does_not_seed_or_replace_memo(self):
        inputs = {"a": {"body": "old"}}
        self.project(inputs, clean=True)
        self.assertEqual(self.project(inputs)[1]["projected_sources"], 1)
        self.project({"a": {"body": "new"}}, clean=True)
        self.assertEqual(self.project(inputs)[1]["projected_sources"], 0)

    def test_failed_projection_keeps_last_complete_memo(self):
        inputs = {"a": {"body": "old"}}
        expected, _ = self.project(inputs)

        def fail(_value):
            raise ValueError("projection failed")

        with self.assertRaises(ValueError):
            self.memo.project("checkout-a", {"a": {"body": "new"}}, [], fail)
        actual, stats = self.project(inputs)
        self.assertEqual(actual, expected)
        self.assertEqual(stats["reused_sources"], 1)

    def test_lru_and_clear_are_bounded(self):
        self.memo = ProjectionMemo(max_scopes=2)
        inputs = {"a": {"body": "A"}}
        for scope in ("a", "b", "a", "c"):
            self.project(inputs, scope=scope)
        self.assertEqual(self.project(inputs, scope="a")[1]["reused_sources"], 1)
        self.assertEqual(self.project(inputs, scope="b")[1]["projected_sources"], 1)
        self.memo.clear()
        self.assertEqual(self.project(inputs, scope="b")[1]["projected_sources"], 1)

    def test_oversized_entry_or_disabled_memo_is_not_reused(self):
        for memo in (ProjectionMemo(max_bytes=1), ProjectionMemo(max_scopes=0)):
            self.memo = memo
            for _ in range(2):
                _, stats = self.project({"a": {"body": "body"}})
                self.assertEqual(stats["projected_sources"], 1)

    def test_concurrent_callers_receive_complete_isolated_results(self):
        def compile_one(index):
            inputs = {"a": {"body": str(index % 3)}}
            actual, _ = self.project(inputs)
            self.assertEqual(actual["a"]["body"], str(index % 3))
            actual["a"]["body"] = "caller mutation"

        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(compile_one, range(30)))

    def test_authenticated_entry_hydrates_new_memo_without_projector_calls(self):
        store = AuthenticatedStore()
        inputs = {"a": {"body": "A"}, "b": {"body": "B"}}
        expected, _ = self.project(inputs)
        self.assertEqual(store.saves, 0)
        self.assertTrue(self.memo.persist("checkout-a", store))
        self.memo = ProjectionMemo()
        self.calls.clear()
        actual, stats = self.memo.project("checkout-a", inputs, [], self.projector, cache=store)
        self.assertEqual(actual, expected)
        self.assertEqual(self.calls, [])
        self.assertEqual(stats["mode"], "durable")
        self.assertEqual(stats["reused_sources"], 2)
        self.assertEqual(store.saves, 1, "projection alone must not write disk state")

    def test_durable_prior_uses_the_same_reverse_dependency_invalidation(self):
        store = AuthenticatedStore()
        inputs = {key: {"body": key} for key in "abcd"}
        edges = [edge("a", "b"), edge("b", "c")]
        self.project(inputs, edges)
        self.memo.persist("checkout-a", store)
        # JSON arrays are restored as lists, unlike the original tuple edges.
        store.entry["edges"] = [list(value) for value in store.entry["edges"]]
        self.memo = ProjectionMemo()
        inputs["c"]["body"] = "changed"
        self.calls.clear()
        actual, stats = self.memo.project("checkout-a", inputs, edges, self.projector, cache=store)
        self.assertEqual(stats["projected_sources"], 3)
        self.assertEqual(stats["reused_sources"], 1)
        self.assertEqual({value["body"] for value in self.calls}, {"a", "b", "changed"})
        self.assertEqual(actual, self.project(inputs, edges, clean=True)[0])

    def test_clean_projection_never_loads_or_seeds_durable_state(self):
        store = AuthenticatedStore()
        inputs = {"a": {"body": "A"}}
        actual, stats = self.memo.project("checkout-a", inputs, [], self.projector, clean=True, cache=store)
        self.assertEqual(stats["mode"], "clean")
        self.assertEqual(stats["projected_sources"], 1)
        self.assertFalse(self.memo.persist("checkout-a", store))
        self.assertEqual((store.loads, store.saves), (0, 0))
        self.assertEqual(actual["a"]["body"], "A")

    def test_persisted_output_does_not_alias_the_trusted_process_memo(self):
        store = AuthenticatedStore()
        expected, _ = self.project({"a": {"body": "A"}})
        self.memo.persist("checkout-a", store)
        store.entry["units"]["a"]["body"] = "edited external output"
        actual, stats = self.project({"a": {"body": "A"}})
        self.assertEqual(actual, expected)
        self.assertEqual(stats["reused_sources"], 1)

    def test_optional_cache_io_failure_causes_real_projection(self):
        class FailedStore(AuthenticatedStore):
            def load(self):
                raise OSError("fixture read failed")

        actual, stats = self.memo.project("checkout-a", {"a": {"body": "A"}}, [],
                                         self.projector, cache=FailedStore())
        self.assertEqual(actual["a"]["body"], "A")
        self.assertEqual(stats["projected_sources"], 1)


class AuthenticatedStore:
    """Boundary double only; real HMAC/file verification has separate tests."""
    def __init__(self):
        self.entry = None
        self.loads = self.saves = 0

    def load(self):
        self.loads += 1
        return copy.deepcopy(self.entry)

    def save(self, entry):
        self.saves += 1
        self.entry = entry
        return True


if __name__ == "__main__":
    unittest.main()
