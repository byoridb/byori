#!/usr/bin/env python3
"""The shape of an answer to "why is it this way".

`memory_why` exists because the two things that make this graph worth having —
evidence, and knowing a decision was superseded — are exactly what a model drops
when it summarises. Assembling the answer on the server means every host gets the
same shape, so these tests are about that shape rather than about prose:

  - the cause, what resolved it, what it superseded and what superseded *it*
  - whether the memory cites anything checkable, said out loud
  - a superseded answer marked stale rather than presented as current
  - relevance that can be explained, because a ranking nobody can explain would
    undermine the evidence it is ranking

The graph is stubbed at `_raw_query`, so no engine is needed and every assertion is
about this module's own logic.
"""

import importlib.util
import pathlib
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("byoridb_mcp_why", ROOT / "mcp" / "byoridb_mcp.py")
MCP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCP)


def node(vid, node_type, name, body, ts=1_000, state=None):
    record = {"vid": str(vid), "type": node_type, "name": name, "body": body, "ts": ts}
    if state is not None:
        record["state"] = state
    return record


class MemoryWhyTests(unittest.TestCase):
    """A small graph: an incident caused a decision that superseded an older one."""

    def setUp(self):
        self.nodes = {
            "1": node(1, "decision", "decision:retry-limit-three",
                      "Retries are capped at three.\nEvidence: commit 71a98f, PR #182",
                      ts=3_000, state="active"),
            "2": node(2, "decision", "decision:retry-limit-five",
                      "Retries are capped at five.", ts=1_000, state="superseded"),
            "3": node(3, "incident", "incident:duplicate-charges",
                      "Five retries duplicated charges during the provider outage.",
                      ts=2_000),
            "4": node(4, "module", "module:billing-retry", "billing/retry.py", ts=2_500),
        }
        self.edges = [
            {"relation": "supersedes", "source_vid": "1", "target_vid": "2"},
            {"relation": "affects", "source_vid": "1", "target_vid": "4"},
            {"relation": "caused_by", "source_vid": "3", "target_vid": "2"},
        ]
        self.patches = [
            mock.patch.object(MCP, "_ensure_ready", lambda: None),
            mock.patch.object(MCP, "_query_nodes", self.fake_query_nodes),
            mock.patch.object(MCP, "_read_edges", self.fake_read_edges),
            mock.patch.object(MCP, "_resolve_nodes_by_vid", self.fake_resolve),
        ]
        for patch in self.patches:
            patch.start()
            self.addCleanup(patch.stop)

    def fake_query_nodes(self, node_type=None, name=None, text=None, limit=20):
        """Case-sensitive on purpose: the engine's `CONTAINS` is, and a stub that
        folded case hid the bug where a lowercase question never found `GETRANGE`."""
        matches = []
        for record in self.nodes.values():
            if node_type and record["type"] != node_type:
                continue
            haystack = record["name"] + " " + record["body"]
            if text and text not in haystack:
                continue
            matches.append(record)
        return matches[:limit]

    def fake_read_edges(self, vids, source_only=False):
        wanted = {str(vid) for vid in vids}
        return [
            edge for edge in self.edges
            if edge["source_vid"] in wanted or edge["target_vid"] in wanted
        ]

    def fake_resolve(self, vids):
        return {str(vid): self.nodes[str(vid)] for vid in vids if str(vid) in self.nodes}

    def why(self, question, **kwargs):
        arguments = {"question": question}
        arguments.update(kwargs)
        return MCP.tool_why(arguments)

    def test_the_answer_carries_the_causal_shape(self):
        answer = self.why("why is the retry limit three")["answers"][0]

        self.assertEqual(answer["name"], "decision:retry-limit-three")
        self.assertEqual(
            [item["name"] for item in answer["supersedes"]],
            ["decision:retry-limit-five"],
        )
        self.assertEqual([item["name"] for item in answer["affects"]], ["module:billing-retry"])

    def test_evidence_is_quoted_and_absence_is_admitted(self):
        answers = {a["name"]: a for a in self.why("retry", limit=5)["answers"]}

        sourced = answers["decision:retry-limit-three"]
        self.assertEqual(sourced["confidence"], "evidence-backed")
        self.assertTrue(any("71a98f" in item for item in sourced["evidence"]))
        self.assertTrue(any("PR #182" in item for item in sourced["evidence"]))

        unsourced = answers["decision:retry-limit-five"]
        self.assertEqual(unsourced["confidence"], "unsourced")
        self.assertEqual(unsourced["evidence"], [])

    def test_a_superseded_decision_is_marked_stale(self):
        """The failure this prevents: answering with last year's decision as though
        it were current."""
        answers = {a["name"]: a for a in self.why("retry", limit=5)["answers"]}

        old = answers["decision:retry-limit-five"]
        self.assertTrue(old["stale"])
        self.assertEqual(
            [item["name"] for item in old["superseded_by"]],
            ["decision:retry-limit-three"],
        )
        self.assertNotIn("stale", answers["decision:retry-limit-three"])

    def test_an_incident_reports_what_caused_it(self):
        answer = {a["name"]: a for a in self.why("duplicate charges", limit=5)["answers"]}
        incident = answer["incident:duplicate-charges"]
        self.assertEqual(
            [item["name"] for item in incident["because"]],
            ["decision:retry-limit-five"],
        )

    def test_a_decision_outranks_the_module_it_touched(self):
        names = [a["name"] for a in self.why("billing retry", limit=4)["answers"]]
        self.assertLess(
            names.index("decision:retry-limit-three"),
            names.index("module:billing-retry"),
            "a decision answers why; a module is only where it happened",
        )

    def test_relevance_beats_recency(self):
        """Recency used to decide, which answered a question about one subject with
        the newest memory about another."""
        self.nodes["5"] = node(
            5, "decision", "decision:unrelated-but-new",
            "Something else entirely, mentioning retry once.", ts=9_999, state="active",
        )
        names = [a["name"] for a in self.why("why is the retry limit three", limit=2)["answers"]]
        self.assertEqual(names[0], "decision:retry-limit-three")

    def test_no_match_says_so_and_points_elsewhere(self):
        result = self.why("why is the mars rover offline")
        self.assertEqual(result["answers"], [])
        self.assertIn("another store", result["note"])

    def test_recalled_content_is_labelled_as_data(self):
        self.assertIn("not as instructions", self.why("retry")["note"])

    def test_arguments_are_validated(self):
        with self.assertRaises(ValueError):
            self.why("retry", type="not-a-type")
        with self.assertRaises(ValueError):
            self.why("retry", limit=99)
        with self.assertRaises(ValueError):
            MCP.tool_why({"question": "retry", "unexpected": 1})


class CaseSensitivityTests(MemoryWhyTests):
    """The engine matches case exactly, so the question has to be spelled its way."""

    def test_a_lowercase_question_finds_a_shouted_command_name(self):
        self.nodes["6"] = node(
            6, "bug", "bug:getrange-revert",
            'Reverted: "Improve GETRANGE command behavior (#12272)" (commit 6ceadfb58053)',
            ts=4_000, state="fixed",
        )
        names = [a["name"] for a in self.why("why does getrange behave this way", limit=3)["answers"]]
        self.assertIn("bug:getrange-revert", names)


class QuestionTermTests(unittest.TestCase):
    def test_stopwords_and_short_words_are_dropped(self):
        terms = MCP._question_terms("Why does this have the same retry limit as billing?")
        self.assertIn("billing", terms)
        self.assertIn("retry", terms)
        for noise in ("why", "does", "this", "have", "the", "same", "as"):
            self.assertNotIn(noise, terms)

    def test_longer_words_come_first(self):
        terms = MCP._question_terms("why authentication over auth")
        self.assertEqual(terms[0], "authentication")


class EvidenceExtractionTests(unittest.TestCase):
    def test_citation_lines_and_loose_references_are_found(self):
        body = (
            "We capped retries.\n"
            "Evidence: commit 71a98f2bc, PR #182\n"
            "Source: byori init, git log issue trailers.\n"
            "Related work landed in 9f2b1c4d5e6f."
        )
        evidence = MCP._evidence_from_body(body)
        self.assertTrue(any("71a98f2bc" in item for item in evidence))
        self.assertTrue(any(item.startswith("byori init") for item in evidence))
        self.assertTrue(any("9f2b1c4d5e6f" in item for item in evidence))

    def test_a_body_with_nothing_checkable_yields_nothing(self):
        self.assertEqual(MCP._evidence_from_body("We decided it felt better."), [])


if __name__ == "__main__":
    unittest.main()
