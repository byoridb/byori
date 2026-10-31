"""Accounting checks: evidence payload is not an inference-provider usage metric."""

import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "dependency_context_eval", Path(__file__).resolve().parents[1]
    / "benchmarks/dependency-context/evaluate.py")
EVAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVAL)


class EvaluationReaderTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.session = Path(self.directory.name)
        self.config = {"roots": {"byori": str(self.session / "byori")},
                       "allowed": {"byori": ["src/api.py", "docs/engine-contract.md"]}}
        self.manifest = {"repositories": {"byori": {"revision": "a" * 40}}}
        (self.session / "config.json").write_text(json.dumps(self.config))
        (self.session / "manifest.json").write_text(json.dumps(self.manifest))

    def arguments(self, **changes):
        values = dict(session=self.session, arm="source", action="source", repo="byori",
                      path="src/api.py", start=1, end=2, term=None)
        values.update(changes)
        return argparse.Namespace(**values)

    def run_read(self, args, body=b"first\nsecond\nthird\n"):
        stream = io.StringIO()
        with mock.patch.object(EVAL.CONTEXT, "_blob", return_value=body), \
             mock.patch.object(EVAL, "tokenized_size", return_value=17), \
             contextlib.redirect_stdout(stream):
            EVAL.read(args)
        return stream.getvalue()

    def records(self, arm="source"):
        return [json.loads(line) for line in (self.session / f"{arm}.reads.jsonl").read_text().splitlines()]

    def test_source_payload_logged_once_without_claiming_model_usage(self):
        output = self.run_read(self.arguments())
        payload = output.split("\nREAD_METRICS ")[0]
        record = self.records()[0]
        self.assertEqual(record["payload_bytes"], len(payload.encode("utf-8")))
        self.assertEqual(record["payload_tokens_o200k_base"], 17)
        self.assertIsNone(record["actual_model_tokens"])
        self.assertIn("a" * 40, payload)
        self.assertIn("1: first\n2: second", payload)
        self.assertNotIn("3: third", payload)

    def test_repeated_reads_are_charged_again_not_deduplicated(self):
        for _ in range(2):
            self.run_read(self.arguments())
        self.assertEqual(len(self.records()), 2)
        self.assertEqual(sum(x["payload_tokens_o200k_base"] for x in self.records()), 34)

    def test_summary_keeps_token_measurement_unavailable_when_any_read_is_unmeasured(self):
        for arm in ("source", "docs", "context"):
            self.run_read(self.arguments(arm=arm))
        path = self.session / "context.reads.jsonl"
        record = json.loads(path.read_text())
        record["payload_tokens_o200k_base"] = None
        path.write_text(json.dumps(record) + "\n")
        summary = EVAL.summarize(self.session)
        self.assertEqual(summary["source"]["payload_tokens_o200k_base"], 17)
        self.assertIsNone(summary["context"]["payload_tokens_o200k_base"])
        self.assertIsNone(summary["source"]["actual_model_tokens"])
        self.assertIn("excludes", summary["source"]["note"])

    def test_baseline_arms_cannot_read_curated_brief(self):
        for arm in ("source", "docs"):
            with self.subTest(arm=arm), self.assertRaises(ValueError):
                self.run_read(self.arguments(arm=arm, action="brief"))

    def test_context_brief_is_revalidated_not_read_from_a_stale_file(self):
        (self.session / "brief.md").write_text("UNSAFE STALE COPY")
        with mock.patch.object(EVAL.CONTEXT, "inspect_context", return_value={"status": "needs_review"}) as inspect, \
             mock.patch.object(EVAL.CONTEXT, "render_context", return_value="Claims withheld.\n"):
            output = self.run_read(self.arguments(arm="context", action="brief"))
        inspect.assert_called_once()
        self.assertIn("Claims withheld", output)
        self.assertNotIn("UNSAFE STALE COPY", output)

    def test_unindexed_or_traversing_paths_refused_before_blob_read(self):
        for path in ("../outside", ".env", "not-indexed.py"):
            with self.subTest(path=path), mock.patch.object(EVAL.CONTEXT, "_blob") as blob, \
                 self.assertRaises(ValueError):
                EVAL.read(self.arguments(path=path))
            blob.assert_not_called()

    def test_search_is_literal_bounded_and_reports_truncation(self):
        output = self.run_read(self.arguments(action="search", term="[hit]"), b"[hit]\n" * 45)
        self.assertIn("40: [hit]", output)
        self.assertNotIn("41: [hit]", output)
        self.assertIn("Additional matches omitted", output)

    def test_source_read_bounds(self):
        for start, end in ((0, 1), (3, 2), (1, 121), (1, 4)):
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                self.run_read(self.arguments(start=start, end=end))

    def test_all_arms_may_read_existing_docs_and_source_evidence(self):
        for arm in ("source", "docs", "context"):
            for action in ("docs", "source"):
                with self.subTest(arm=arm, action=action):
                    self.assertIn("first", self.run_read(self.arguments(arm=arm, action=action)))


if __name__ == "__main__":
    unittest.main()
