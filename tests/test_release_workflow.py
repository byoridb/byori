#!/usr/bin/env python3
"""Release numbering and main-ancestry guard tests."""

import importlib.util
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "next_release_tag", ROOT / "scripts" / "next_release_tag.py"
)
VERSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERSION)
GUARD = ROOT / "scripts" / "require_release_tag_on_main.sh"


def run(*arguments, cwd, check=True):
    return subprocess.run(
        arguments,
        cwd=cwd,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


class NextReleaseTagTests(unittest.TestCase):
    def test_starts_after_the_grandfathered_082_release(self):
        self.assertEqual(VERSION.next_patch_tag([], "v0.8.2"), "v0.8.3")

    def test_uses_highest_stable_release_and_ignores_non_release_shapes(self):
        tags = ["v0.8.2", "v0.9.0-beta.1", "not-a-version", "v0.10.4"]
        self.assertEqual(VERSION.next_patch_tag(tags, "v0.8.2"), "v0.10.5")

    def test_rejects_a_non_semver_baseline(self):
        with self.assertRaisesRegex(ValueError, "baseline"):
            VERSION.next_patch_tag([], "0.8")


class ReleaseTagMainGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.temporary.name)
        self.remote = root / "remote.git"
        self.repository = root / "repository"
        run("git", "init", "--bare", str(self.remote), cwd=root)
        run("git", "init", "-b", "main", str(self.repository), cwd=root)
        run("git", "config", "user.email", "tests@example.invalid", cwd=self.repository)
        run("git", "config", "user.name", "Byori Tests", cwd=self.repository)
        run("git", "remote", "add", "origin", str(self.remote), cwd=self.repository)
        (self.repository / "README.md").write_text("fixture\n", encoding="utf-8")
        run("git", "add", "README.md", cwd=self.repository)
        run("git", "commit", "-m", "fixture", cwd=self.repository)
        run("git", "push", "-u", "origin", "main", cwd=self.repository)

    def tearDown(self):
        self.temporary.cleanup()

    def test_accepts_a_release_tag_contained_in_origin_main(self):
        run("git", "tag", "v0.8.3", cwd=self.repository)

        result = run(str(GUARD), "v0.8.3", cwd=self.repository)

        self.assertIn("is on origin/main", result.stdout)

    def test_rejects_a_release_tag_from_an_unmerged_branch(self):
        run("git", "switch", "-c", "feature", cwd=self.repository)
        (self.repository / "feature.txt").write_text("change\n", encoding="utf-8")
        run("git", "add", "feature.txt", cwd=self.repository)
        run("git", "commit", "-m", "feature", cwd=self.repository)
        run("git", "tag", "v0.8.3", cwd=self.repository)

        result = run(str(GUARD), "v0.8.3", cwd=self.repository, check=False)

        self.assertEqual(result.returncode, 4)
        self.assertIn("not contained in origin/main", result.stderr)

    def test_rejects_a_tag_that_only_resembles_semver(self):
        run("git", "tag", "v0.8.3oops", cwd=self.repository)

        result = run(str(GUARD), "v0.8.3oops", cwd=self.repository, check=False)

        self.assertEqual(result.returncode, 2)
        self.assertIn("must look like v1.2.3", result.stderr)

    def test_accepts_a_prerelease_tag_when_it_is_on_main(self):
        run("git", "tag", "v0.9.0-beta.1", cwd=self.repository)

        result = run(str(GUARD), "v0.9.0-beta.1", cwd=self.repository)

        self.assertIn("is on origin/main", result.stdout)


if __name__ == "__main__":
    unittest.main()
