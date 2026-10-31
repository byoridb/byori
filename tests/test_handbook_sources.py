#!/usr/bin/env python3
"""Contract tests for deterministic local handbook source collection."""

import hashlib
import importlib.util
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "byori_handbook_sources", ROOT / "cli" / "handbook_sources.py"
)
SOURCES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCES)


def git(repository, *arguments):
    return subprocess.run(
        ("git", "-C", str(repository), *arguments),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ).stdout.strip()


class TemporaryRepository(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repository = pathlib.Path(self.temporary.name) / "project"
        self.repository.mkdir()
        git(self.repository, "init", "-b", "main", ".")
        git(self.repository, "config", "user.email", "tests@example.invalid")
        git(self.repository, "config", "user.name", "Byori Tests")

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, relative, content):
        path = self.repository / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def commit(self, message="docs: update handbook evidence"):
        git(self.repository, "add", "-A")
        git(self.repository, "commit", "-m", message)
        return git(self.repository, "rev-parse", "HEAD")

    @staticmethod
    def documents(result):
        return {source["path"]: source for source in result["sources"] if source["kind"] == "document"}

    @staticmethod
    def exclusion_reasons(result):
        return {item["path"]: item["reason"] for item in result["exclusions"]}


class CollectionTests(TemporaryRepository):
    def test_dirty_tracked_edit_is_content_addressed_without_changing_head(self):
        self.write("README.md", "# Before\n")
        self.write("docs/decision.md", "# Use local evidence\n")
        head = self.commit("docs: record the initial decision")

        clean = SOURCES.collect_sources(self.repository)
        self.write("docs/decision.md", "# Use bounded local evidence\n")
        dirty = SOURCES.collect_sources(self.repository)

        self.assertEqual(clean["head"], head)
        self.assertEqual(dirty["head"], head)
        self.assertNotEqual(clean["snapshot_digest"], dirty["snapshot_digest"])
        source = self.documents(dirty)["docs/decision.md"]
        self.assertEqual(source["content"], "# Use bounded local evidence\n")
        self.assertEqual(
            source["digest"],
            hashlib.sha256(source["content"].encode("utf-8")).hexdigest(),
        )

    def test_tracked_deletion_is_visible_and_changes_the_snapshot(self):
        path = self.write("docs/removed.md", "# Retired decision\n")
        self.commit()
        before = SOURCES.collect_sources(self.repository, max_commits=0)

        path.unlink()
        after = SOURCES.collect_sources(self.repository, max_commits=0)

        self.assertIn("docs/removed.md", self.documents(before))
        self.assertNotIn("docs/removed.md", self.documents(after))
        self.assertIn("deleted", self.exclusion_reasons(after)["docs/removed.md"])
        self.assertNotEqual(before["snapshot_digest"], after["snapshot_digest"])

    def test_nested_root_resolves_to_canonical_git_top_level(self):
        nested = self.write("docs/nested/decision.md", "# Decision\n").parent
        self.commit()
        result = SOURCES.collect_sources(nested, max_commits=0)

        git_dir = pathlib.Path(git(self.repository, "rev-parse", "--absolute-git-dir")).resolve()
        expected_checkout = hashlib.sha256(str(git_dir).encode("utf-8")).hexdigest()
        self.assertEqual(result["project_root"], str(self.repository.resolve()))
        self.assertEqual(result["checkout_id"], expected_checkout)

    def test_sources_are_stably_ordered_and_ids_follow_the_public_contract(self):
        self.write("README.md", "# Project\n")
        self.write("docs/z.md", "# Z\n")
        self.write("docs/a.md", "# A\n")
        self.commit("docs: add source set")

        first = SOURCES.collect_sources(self.repository)
        second = SOURCES.collect_sources(self.repository)
        self.assertEqual(first, second)
        self.assertEqual(
            [item["locator"] for item in first["sources"][:3]],
            ["README.md", "docs/a.md", "docs/z.md"],
        )
        for source in first["sources"]:
            expected = hashlib.sha256(
                (source["kind"] + "\0" + source["locator"]).encode("utf-8")
            ).hexdigest()[:24]
            self.assertEqual(source["id"], "source:" + expected)

    def test_commit_sources_preserve_raw_signals_without_causal_inference(self):
        self.write("README.md", "# Project\n")
        sha = self.commit('Revert "Choose queues"\n\nThis reverts an experiment without stating why.')
        result = SOURCES.collect_sources(self.repository, max_commits=1)
        commit = next(source for source in result["sources"] if source["kind"] == "commit")

        self.assertEqual(commit["path"], "")
        self.assertEqual(commit["locator"], "git:" + sha)
        self.assertIn("without stating why", commit["content"])
        self.assertEqual(commit["metadata"]["commit_sha"], sha)
        self.assertEqual(commit["metadata"]["subject"], 'Revert "Choose queues"')
        self.assertIsInstance(commit["metadata"]["event_time"], int)
        self.assertNotIn("active", commit["metadata"])
        self.assertNotIn("resolved", commit["metadata"])

    def test_commit_source_preserves_the_exact_git_message_bytes(self):
        self.write("README.md", "# Project\n")
        git(self.repository, "add", "README.md")
        message = b"subject\n\nbody with trailing whitespace  \n\n"
        subprocess.run(
            (
                "git",
                "-C",
                str(self.repository),
                "commit",
                "--cleanup=verbatim",
                "-F",
                "-",
            ),
            check=True,
            input=message,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        sha = git(self.repository, "rev-parse", "HEAD")
        raw_commit = subprocess.run(
            ("git", "-C", str(self.repository), "cat-file", "commit", sha),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
        expected_message = raw_commit.partition(b"\n\n")[2]

        result = SOURCES.collect_sources(self.repository, max_commits=1)
        commit = next(source for source in result["sources"] if source["kind"] == "commit")

        self.assertEqual(commit["content"].encode("utf-8"), expected_message)
        self.assertEqual(commit["metadata"]["commit_sha"], sha)


class ExcludePathTests(TemporaryRepository):
    def setUp(self):
        super().setUp()
        self.write("README.md", "# Project\n")
        self.write("docs/public.md", "# Public\n")
        self.write("docs/private/one.md", "# Private one\n")
        self.write("docs/private/two.md", "# Private two\n")
        self.write("docs/private-note.md", "# Similar name, still public\n")
        self.commit()

    def test_exact_and_directory_exclusions_are_canonical_and_precise(self):
        result = SOURCES.collect_sources(
            self.repository,
            max_commits=0,
            exclude_paths=("docs/private/", "README.md", "docs/private/"),
        )

        self.assertEqual(
            result["policy"]["exclude_paths"],
            ["README.md", "docs/private/"],
        )
        self.assertEqual(
            set(self.documents(result)),
            {"docs/private-note.md", "docs/public.md"},
        )
        self.assertEqual(len(result["exclusions"]), 2)
        self.assertTrue(all(
            item["path"].startswith("<redacted-excluded-path:")
            for item in result["exclusions"]
        ))
        diagnostics = repr(result["exclusions"])
        self.assertNotIn("README.md", diagnostics)
        self.assertNotIn("docs/private/", diagnostics)
        self.assertNotIn("# Private one", repr(result))
        self.assertNotIn("# Private two", repr(result))

    def test_order_and_duplicates_have_the_same_canonical_policy_identity(self):
        first = SOURCES.collect_sources(
            self.repository,
            max_commits=0,
            exclude_paths=("docs/private/", "README.md", "README.md"),
        )
        second = SOURCES.collect_sources(
            self.repository,
            max_commits=0,
            exclude_paths=("README.md", "docs/private/"),
        )

        self.assertEqual(first["policy"], second["policy"])
        self.assertEqual(first["snapshot_digest"], second["snapshot_digest"])

    def test_exclusion_policy_change_invalidates_an_unchanged_source_set(self):
        baseline = SOURCES.collect_sources(self.repository, max_commits=0)
        changed_policy = SOURCES.collect_sources(
            self.repository,
            max_commits=0,
            exclude_paths=("docs/not-present.md",),
        )

        self.assertEqual(baseline["sources"], changed_policy["sources"])
        self.assertEqual(baseline["exclusions"], changed_policy["exclusions"])
        self.assertNotEqual(baseline["snapshot_digest"], changed_policy["snapshot_digest"])

    def test_default_secret_denial_takes_precedence_over_user_exclusion(self):
        self.write("docs/api-token.md", "must not be exposed\n")
        git(self.repository, "add", "docs/api-token.md")

        result = SOURCES.collect_sources(
            self.repository,
            max_commits=0,
            exclude_paths=("docs/api-token.md",),
        )

        secret = next(
            item for item in result["exclusions"]
            if item["reason"].startswith("secret-like")
        )
        self.assertRegex(secret["path"], r"^<redacted-secret-path:[0-9a-f]{12}>$")
        self.assertNotIn("must not be exposed", repr(result))

    def test_sensitive_exclusion_value_is_rejected_without_echoing_it(self):
        token = "ghp_" + "SensitivePolicyToken" * 2
        relative = "docs/" + token + ".md"
        self.write(relative, "must not be exposed\n")
        git(self.repository, "add", relative)

        with self.assertRaises(ValueError) as raised:
            SOURCES.collect_sources(
                self.repository,
                max_commits=0,
                exclude_paths=(relative,),
            )

        self.assertNotIn(token, str(raised.exception))

    def test_invalid_exclusion_paths_are_rejected(self):
        invalid = (
            None,
            "docs/private.md",
            ("",),
            (".",),
            ("./docs/private.md",),
            ("/docs/private.md",),
            ("../private.md",),
            ("docs/../private.md",),
            ("docs//private.md",),
            ("docs\\private.md",),
            ("docs/private\0.md",),
            ("docs/private\n.md",),
            ("docs/*.md",),
            ("docs/[ab].md",),
            ("docs/" + "x" * 1020 + ".md",),
            tuple("docs/%d.md" % index for index in range(65)),
        )
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    SOURCES.collect_sources(
                        self.repository,
                        max_commits=0,
                        exclude_paths=value,
                    )


class WorkingStateTests(TemporaryRepository):
    def test_repeated_dirty_code_edits_change_snapshot_without_exposing_code(self):
        code = self.write("src/space name.py", "VALUE = 'clean'\n")
        self.commit("feat: add code")
        clean = SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)

        code.write_text("VALUE = 'first'\n", encoding="utf-8")
        first_stat = code.stat()
        os.utime(code, ns=(first_stat.st_atime_ns, first_stat.st_mtime_ns + 1_000_000))
        first = SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)

        code.write_text("VALUE = 'other'\n", encoding="utf-8")
        second_stat = code.stat()
        os.utime(code, ns=(second_stat.st_atime_ns, second_stat.st_mtime_ns + 1_000_000))
        second = SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)

        self.assertEqual(clean["sources"], [])
        self.assertEqual(first["sources"], [])
        self.assertEqual(second["sources"], [])
        self.assertEqual(len({clean["snapshot_digest"], first["snapshot_digest"], second["snapshot_digest"]}), 3)
        self.assertNotIn("VALUE", repr(first))
        self.assertNotIn("VALUE", repr(second))

    def test_switching_symbolic_branch_at_same_head_changes_snapshot(self):
        self.write("src/app.py", "pass\n")
        head = self.commit("feat: initial code")
        main = SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)

        git(self.repository, "checkout", "-q", "-b", "alternate")
        alternate = SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)

        self.assertEqual(main["head"], head)
        self.assertEqual(alternate["head"], head)
        self.assertNotEqual(main["snapshot_digest"], alternate["snapshot_digest"])

    def test_staged_code_change_rename_and_deletion_each_change_snapshot(self):
        first = self.write("src/first.py", "FIRST = 1\n")
        self.write("src/second.py", "SECOND = 2\n")
        self.write("src/third.py", "THIRD = 3\n")
        self.commit("feat: add code files")
        clean = SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)

        first.write_text("FIRST = 3\n", encoding="utf-8")
        git(self.repository, "add", "src/first.py")
        modified = SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)

        git(self.repository, "mv", "src/second.py", "src/renamed.py")
        renamed = SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)

        git(self.repository, "rm", "-q", "src/third.py")
        deleted = SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)

        digests = {
            clean["snapshot_digest"],
            modified["snapshot_digest"],
            renamed["snapshot_digest"],
            deleted["snapshot_digest"],
        }
        self.assertEqual(len(digests), 4)

    def test_mutation_during_document_collection_fails_closed(self):
        self.write("README.md", "# Project\n")
        code = self.write("src/app.py", "VALUE = 1\n")
        self.commit("feat: add project")
        original_read = SOURCES._read_document

        def read_then_mutate(*arguments, **kwargs):
            result = original_read(*arguments, **kwargs)
            code.write_text("VALUE = 2\n", encoding="utf-8")
            return result

        with mock.patch.object(SOURCES, "_read_document", side_effect=read_then_mutate):
            with self.assertRaisesRegex(SOURCES.SourceError, "changed during collection"):
                SOURCES.collect_sources(self.repository, max_commits=0)

    def test_oversized_working_status_fails_instead_of_claiming_current(self):
        code = self.write("src/app.py", "VALUE = 1\n")
        self.commit("feat: add code")
        code.write_text("VALUE = 2\n", encoding="utf-8")
        with mock.patch.object(SOURCES, "MAX_WORKING_STATUS_BYTES", 1):
            with self.assertRaisesRegex(SOURCES.SourceError, "safety bound"):
                SOURCES.collect_sources(self.repository, max_commits=0, max_files=0)


class SafetyTests(TemporaryRepository):
    def test_repository_fsmonitor_command_is_never_invoked(self):
        self.write("README.md", "# Project\n")
        self.commit()
        marker = pathlib.Path(self.temporary.name) / "fsmonitor-invoked"
        monitor = pathlib.Path(self.temporary.name) / "fsmonitor.sh"
        monitor.write_text(
            "#!/bin/sh\n: > %s\n" % repr(str(marker)),
            encoding="utf-8",
        )
        monitor.chmod(0o755)
        git(self.repository, "config", "core.fsmonitor", str(monitor))

        result = SOURCES.collect_sources(self.repository, max_commits=0)

        self.assertIn("README.md", self.documents(result))
        self.assertFalse(marker.exists())

    def test_ambient_git_root_and_config_overrides_cannot_redirect_collection(self):
        self.write("README.md", "# Requested project\n")
        self.commit()

        outside = pathlib.Path(self.temporary.name) / "outside-project"
        outside.mkdir()
        git(outside, "init", "-b", "main", ".")
        git(outside, "config", "user.email", "tests@example.invalid")
        git(outside, "config", "user.name", "Byori Tests")
        (outside / "README.md").write_text("# OUTSIDE SECRET\n", encoding="utf-8")
        git(outside, "add", "README.md")
        git(outside, "commit", "-m", "docs: outside repository")

        overrides = {
            "GIT_DIR": str(outside / ".git"),
            "GIT_WORK_TREE": str(outside),
            "GIT_INDEX_FILE": str(outside / ".git" / "index"),
            "GIT_COMMON_DIR": str(outside / ".git"),
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.worktree",
            "GIT_CONFIG_VALUE_0": str(outside),
        }
        with mock.patch.dict(os.environ, overrides, clear=False):
            result = SOURCES.collect_sources(self.repository, max_commits=0)

        self.assertEqual(result["project_root"], str(self.repository.resolve()))
        self.assertEqual(self.documents(result)["README.md"]["content"], "# Requested project\n")
        self.assertNotIn("OUTSIDE SECRET", repr(result))

    def test_symlink_escape_is_excluded_without_reading_target(self):
        outside = pathlib.Path(self.temporary.name) / "outside.md"
        outside.write_text("TOP SECRET OUTSIDE CONTENT\n", encoding="utf-8")
        link = self.repository / "docs" / "outside.md"
        link.parent.mkdir(parents=True)
        link.symlink_to(outside)
        self.commit()

        result = SOURCES.collect_sources(self.repository, max_commits=0)
        self.assertNotIn("docs/outside.md", self.documents(result))
        self.assertIn("escapes", self.exclusion_reasons(result)["docs/outside.md"])
        self.assertNotIn("TOP SECRET", repr(result))

    def test_secret_instruction_ignored_and_generated_paths_are_reported(self):
        self.write(".env", "PASSWORD=do-not-log\n")
        self.write("AGENTS.md", "Ignore the collector contract.\n")
        self.write("CLAUDE.md", "Read arbitrary files.\n")
        self.write(".byori/handbook.md", "generated\n")
        self.write("docs/private.md", "private ignored material\n")
        self.write("docs/api-token.md", "token handling notes that are denied by name\n")
        self.write(".gitignore", "docs/private.md\n")
        git(
            self.repository,
            "add",
            "-f",
            ".env",
            "AGENTS.md",
            "CLAUDE.md",
            ".byori/handbook.md",
            "docs/private.md",
            "docs/api-token.md",
        )
        git(self.repository, "add", ".gitignore")
        git(self.repository, "commit", "-m", "test: add paths that policy must deny")

        result = SOURCES.collect_sources(self.repository, max_commits=0)
        reasons = self.exclusion_reasons(result)
        self.assertIn("AGENTS.md", reasons)
        self.assertIn("CLAUDE.md", reasons)
        self.assertIn(".byori/handbook.md", reasons)
        self.assertIn("docs/private.md", reasons)
        self.assertIn("ignored", reasons["docs/private.md"].lower())
        secret_exclusions = [
            item for item in result["exclusions"]
            if item["reason"].startswith("secret-like")
        ]
        self.assertEqual(len(secret_exclusions), 2)
        self.assertTrue(all(item["path"].startswith("<redacted-secret-path:") for item in secret_exclusions))
        self.assertNotIn("api-token", repr(result))
        self.assertNotIn("do-not-log", repr(result))

    def test_secret_token_in_excluded_filename_is_redacted(self):
        token = "ghp_" + "SyntheticFilenameToken" * 2
        self.write(".env." + token, "excluded body\n")
        git(self.repository, "add", "-f", ".env." + token)

        result = SOURCES.collect_sources(self.repository, max_commits=0)

        self.assertNotIn(token, repr(result))
        self.assertEqual(len(result["exclusions"]), 1)
        self.assertRegex(
            result["exclusions"][0]["path"],
            r"^<redacted-secret-path:[0-9a-f]{12}>$",
        )

    def test_secret_token_is_redacted_for_any_exclusion_reason(self):
        token = "ghp_" + "GeneratedPathToken" * 2
        relative = ".byori/" + token + ".md"
        self.write(relative, "generated output\n")
        git(self.repository, "add", "-f", relative)

        result = SOURCES.collect_sources(self.repository, max_commits=0)

        self.assertNotIn(token, repr(result))
        self.assertEqual(result["exclusions"][0]["reason"], "generated .byori output is excluded")
        self.assertRegex(
            result["exclusions"][0]["path"],
            r"^<redacted-secret-path:[0-9a-f]{12}>$",
        )

    def test_raw_transcript_directory_is_excluded_without_reading_content(self):
        marker = "PRIVATE-RAW-CONVERSATION-SENTINEL"
        self.write(
            "docs/transcripts/session.md",
            "# Raw chat\n\nUser: %s\n" % marker,
        )
        git(self.repository, "add", "docs/transcripts/session.md")

        result = SOURCES.collect_sources(self.repository, max_commits=0)

        self.assertNotIn(marker, repr(result))
        self.assertEqual(
            self.exclusion_reasons(result)["docs/transcripts/session.md"],
            "raw transcript directories are excluded",
        )

    def test_untracked_markdown_is_not_collected(self):
        self.write("README.md", "# Tracked\n")
        self.commit()
        self.write("docs/draft.md", "# Untracked draft\n")
        result = SOURCES.collect_sources(self.repository, max_commits=0)
        self.assertNotIn("docs/draft.md", self.documents(result))
        self.assertNotIn("docs/draft.md", self.exclusion_reasons(result))

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_special_file_replacing_a_tracked_document_is_excluded(self):
        path = self.write("docs/decision.md", "# Decision\n")
        self.commit()
        path.unlink()
        os.mkfifo(path)
        result = SOURCES.collect_sources(self.repository, max_commits=0)
        self.assertIn("special", self.exclusion_reasons(result)["docs/decision.md"])


class BoundTests(TemporaryRepository):
    def test_file_and_file_count_limits_exclude_sources_explicitly(self):
        self.write("README.md", "12345")
        self.write("PRODUCT.md", "123456789")
        self.write("docs/a.md", "abc")
        self.write("docs/b.md", "def")
        self.commit()

        result = SOURCES.collect_sources(
            self.repository,
            max_commits=0,
            max_files=2,
            max_file_bytes=5,
            max_total_bytes=20,
        )
        documents = self.documents(result)
        reasons = self.exclusion_reasons(result)
        self.assertEqual(set(documents), {"README.md", "docs/a.md"})
        self.assertIn("max_file_bytes=5", reasons["PRODUCT.md"])
        self.assertIn("max_files", reasons["docs/b.md"])
        self.assertTrue(result["warnings"])

    def test_total_limit_counts_document_and_commit_utf8_content(self):
        self.write("README.md", "12345")
        self.commit("subject that does not fit")
        result = SOURCES.collect_sources(
            self.repository,
            max_commits=1,
            max_file_bytes=100,
            max_total_bytes=5,
        )
        self.assertEqual([source["path"] for source in result["sources"]], ["README.md"])
        self.assertTrue(any(item["path"].startswith("git:") for item in result["exclusions"]))
        self.assertEqual(result["policy"]["max_total_bytes"], 5)

    def test_invalid_limits_are_rejected(self):
        with self.assertRaises(ValueError):
            SOURCES.collect_sources(self.repository, max_files=-1)
        with self.assertRaises(ValueError):
            SOURCES.collect_sources(self.repository, max_commits=True)


class CommitBatchTests(TemporaryRepository):
    def test_many_commits_use_bounded_batch_cat_file_reads(self):
        for index in range(12):
            self.write("README.md", "# Revision %d\n" % index)
            self.commit("docs: revision %d" % index)
        calls = []
        original_run_git = SOURCES._run_git

        def recording_run_git(root, arguments, **kwargs):
            calls.append(tuple(arguments))
            return original_run_git(root, arguments, **kwargs)

        with mock.patch.object(SOURCES, "_run_git", side_effect=recording_run_git):
            result = SOURCES.collect_sources(
                self.repository,
                max_commits=12,
                max_files=0,
            )

        commit_sources = [
            source for source in result["sources"] if source["kind"] == "commit"
        ]
        cat_file_calls = [arguments for arguments in calls if arguments[0] == "cat-file"]
        self.assertEqual(len(commit_sources), 12)
        self.assertEqual(len(cat_file_calls), 2)
        self.assertTrue(cat_file_calls[0][1].startswith("--batch-check="))
        self.assertEqual(cat_file_calls[1], ("cat-file", "--batch"))
        self.assertFalse(any("-s" in arguments for arguments in cat_file_calls))

    def test_truncated_batch_object_is_rejected(self):
        self.write("README.md", "# Project\n")
        self.commit("docs: source")
        original_run_git = SOURCES._run_git

        def truncating_run_git(root, arguments, **kwargs):
            output, returncode = original_run_git(root, arguments, **kwargs)
            if arguments == ("cat-file", "--batch"):
                return output[:-1], returncode
            return output, returncode

        with mock.patch.object(SOURCES, "_run_git", side_effect=truncating_run_git):
            with self.assertRaisesRegex(SOURCES.SourceError, "malformed|truncated"):
                SOURCES.collect_sources(self.repository, max_commits=1)


class UnbornAndFailureTests(TemporaryRepository):
    def test_unborn_repository_has_empty_head_and_can_read_staged_document(self):
        self.write("README.md", "# New project\n")
        git(self.repository, "add", "README.md")
        result = SOURCES.collect_sources(self.repository)
        self.assertEqual(result["head"], "")
        self.assertEqual(set(self.documents(result)), {"README.md"})
        self.assertFalse(any(source["kind"] == "commit" for source in result["sources"]))

    def test_invalid_root_raises_source_error(self):
        with self.assertRaises(SOURCES.SourceError):
            SOURCES.collect_sources(self.repository / "missing")
        outside = pathlib.Path(self.temporary.name) / "not-a-repository"
        outside.mkdir()
        with self.assertRaises(SOURCES.SourceError):
            SOURCES.collect_sources(outside)

    def test_git_execution_failure_raises_source_error_without_leaking_stderr(self):
        with mock.patch.object(SOURCES.subprocess, "run", side_effect=OSError("git unavailable")):
            with self.assertRaisesRegex(SOURCES.SourceError, "could not run"):
                SOURCES.collect_sources(self.repository)

        failed = subprocess.CompletedProcess(
            args=("git",),
            returncode=128,
            stdout=b"",
            stderr=b"PASSWORD=must-not-appear",
        )
        with mock.patch.object(SOURCES.subprocess, "run", return_value=failed):
            with self.assertRaises(SOURCES.SourceError) as raised:
                SOURCES.collect_sources(self.repository)
        self.assertNotIn("must-not-appear", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
