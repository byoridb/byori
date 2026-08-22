#!/usr/bin/env python3
"""What `byori init` reads out of a repository's history.

Every assertion here is about a fact the history states outright — an issue
trailer, a revert, a merge naming a pull request, a decision document, a directory
a fix touched. That is the whole contract of this pass: no summarising, no guessed
causes, and every node carrying the commit or path it came from, because a wrong
causal edge is read later with the same confidence as a true one.

The fixture is a real scratch repository, so the tests exercise the same Git
plumbing the command does rather than a stubbed transcript of it.
"""

import importlib.util
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("byori_archaeology", ROOT / "cli" / "archaeology.py")
ARCHAEOLOGY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ARCHAEOLOGY)


def git(repository, *arguments, **kwargs):
    return subprocess.run(
        ("git", "-C", str(repository)) + arguments,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        **kwargs,
    ).stdout.strip()


class ArchaeologyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.repository = pathlib.Path(cls.temporary.name) / "shop"
        cls.repository.mkdir()
        repository = cls.repository
        git(repository, "init", "-b", "main", ".")
        git(repository, "config", "user.email", "tests@example.invalid")
        git(repository, "config", "user.name", "Byori Tests")

        def write(relative, text):
            path = repository / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")

        def commit(message):
            git(repository, "add", "-A")
            git(repository, "commit", "-m", message)
            return git(repository, "rev-parse", "HEAD")

        # A module worth naming: three tracked files under one directory.
        for name in ("service.py", "retry.py", "ledger.py"):
            write("billing/" + name, "# %s\n" % name)
        for name in ("app.py", "views.py", "urls.py"):
            write("web/" + name, "# %s\n" % name)
        commit("chore: initial layout")

        # A decision document, with YAML frontmatter that must not be read as body.
        write(
            "docs/adr/0001-retry-limit.md",
            "---\nstatus: accepted\ntags: [billing]\n---\n\n"
            "# Limit payment retries to three\n\n"
            "Five retries duplicated charges during the March provider outage.\n\n"
            "## Alternatives\n\nUnlimited retries with idempotency keys.\n",
        )
        cls.decision_commit = commit("docs: record the retry-limit decision")

        # A bug: a `fix:` commit closing an issue.
        write("billing/retry.py", "RETRY_LIMIT = 3\n")
        cls.fix_commit = commit("fix(billing): cap retries at three\n\nFixes #41")

        # Work delivered, not a bug: a `feat:` commit closing an issue.
        write("web/app.py", "# app v2\n")
        cls.feature_commit = commit("feat(web): show the retry count\n\nCloses #42")

        # Something undone.
        write("billing/ledger.py", "# experiment\n")
        cls.reverted_commit = commit("feat(billing): serialize the ledger")
        git(repository, "revert", "--no-edit", cls.reverted_commit)
        cls.revert_commit = git(repository, "rev-parse", "HEAD")

        # A merge that names a pull request, carrying a fix under it.
        git(repository, "checkout", "-q", "-b", "hotfix")
        write("billing/service.py", "# guard\n")
        cls.merged_fix = commit("fix(billing): guard the zero amount\n\nFixes #43")
        git(repository, "checkout", "-q", "main")
        git(
            repository, "merge", "--no-ff", "-m",
            "Merge pull request #77 from example/hotfix", "hotfix",
        )

        cls.plan = ARCHAEOLOGY.excavate(repository, "shop", limit=200)
        cls.nodes = {node.name: node for node in cls.plan.nodes}

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_a_fix_closing_an_issue_becomes_a_fixed_bug(self):
        node = self.nodes["bug:shop-issue-41"]
        self.assertEqual(node.state, "fixed")
        self.assertIn("cap retries at three", node.body)
        self.assertIn(self.fix_commit[:12], node.body, "the commit is the evidence")

    def test_a_feature_closing_an_issue_is_a_finished_task_not_a_bug(self):
        """`feat(...) Closes #42` is work delivered. Calling it a bug would put a
        defect in the graph that never existed — typed from the commit's own prefix
        rather than guessed."""
        self.assertNotIn("bug:shop-issue-42", self.nodes)
        node = self.nodes["task:shop-issue-42"]
        self.assertEqual(node.state, "done")
        self.assertIn("show the retry count", node.body)

    def test_a_revert_is_recorded_without_inventing_a_reason(self):
        reverts = [name for name in self.nodes if name.startswith("bug:shop-revert-")]
        self.assertEqual(len(reverts), 1, self.nodes.keys())
        body = self.nodes[reverts[0]].body
        self.assertIn("serialize the ledger", body)
        self.assertIn(self.reverted_commit[:12], body)
        self.assertIn("why it was wrong is not in the commit", body)

    def test_a_merge_lends_its_pull_request_to_the_commits_it_brought(self):
        """"Where was this discussed" lives on the merge, but the fix is the commit
        under it, so the number has to reach that commit's evidence."""
        self.assertIn("[PR #77]", self.nodes["bug:shop-issue-43"].body)

    def test_a_decision_document_is_quoted_not_summarised_and_skips_frontmatter(self):
        node = self.nodes["decision:shop-0001-retry-limit"]
        self.assertEqual(node.state, "active")
        self.assertIn("Limit payment retries to three", node.body)
        self.assertIn("Five retries duplicated charges", node.body)
        self.assertNotIn("status: accepted", node.body, "frontmatter is metadata, not rationale")
        self.assertIn("docs/adr/0001-retry-limit.md", node.body)
        self.assertIn(self.decision_commit[:12], node.body, "Git knows when it arrived")

    def test_modules_come_from_the_tree_and_a_fix_affects_the_one_it_touched(self):
        self.assertIn("module:shop-billing", self.nodes)
        edges = {
            (edge.source[1], edge.relation, edge.target[1])
            for edge in self.plan.edges
        }
        self.assertIn(("bug:shop-issue-41", "affects", "module:shop-billing"), edges)
        # A delivered task is *about* a module; it did not break it.
        self.assertIn(("task:shop-issue-42", "about", "module:shop-web"), edges)

    def test_every_node_says_where_it_came_from(self):
        for name, node in self.nodes.items():
            self.assertIn("Source: byori init", node.body, name)

    def test_stats_report_what_was_read(self):
        self.assertGreaterEqual(self.plan.stats["commits_scanned"], 6)
        self.assertEqual(self.plan.stats["issues_closed"], 3)
        self.assertEqual(self.plan.stats["decision_documents"], 1)
        self.assertEqual(self.plan.stats["nodes"], len(self.plan.nodes))


class SlugTests(unittest.TestCase):
    def test_names_stay_inside_the_canonical_charset(self):
        cases = {
            "manager/macos": "manager-macos",
            "  Billing Service  ": "billing-service",
            "docs/adr/0001-retry.md": "docs-adr-0001-retry.md",
            "___": "x",
            "": "x",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(ARCHAEOLOGY.slug(value), expected)

    def test_a_name_that_cannot_start_with_a_letter_is_still_canonical(self):
        # Stripping is enough for a leading dash; a value with nothing else left
        # needs the prefix, because the canonical form must start alphanumeric.
        self.assertEqual(ARCHAEOLOGY.slug("-leading"), "leading")
        self.assertTrue(ARCHAEOLOGY.slug("-").startswith("x"))
        self.assertTrue(ARCHAEOLOGY.slug("...").startswith("x"))


class ModuleSelectionTests(unittest.TestCase):
    def test_dependencies_and_build_output_are_not_modules(self):
        paths = [
            "node_modules/left-pad/index.js",
            "node_modules/left-pad/package.json",
            "node_modules/left-pad/readme.md",
            "vendor/lib/a.c",
            "vendor/lib/b.c",
            "vendor/lib/c.c",
            "src/one.py",
            "src/two.py",
            "src/three.py",
        ]
        modules = ARCHAEOLOGY.module_directories(paths)
        self.assertEqual(set(modules), {"src"})

    def test_a_directory_with_too_few_files_is_not_a_module(self):
        modules = ARCHAEOLOGY.module_directories(["tiny/one.py", "tiny/two.py"])
        self.assertEqual(modules, {})

    def test_the_longest_matching_module_owns_a_path(self):
        modules = {"packages": 400, "packages/api": 12}
        self.assertEqual(
            ARCHAEOLOGY.owning_modules(["packages/api/handler.ts"], modules),
            ["packages/api"],
        )


if __name__ == "__main__":
    unittest.main()
