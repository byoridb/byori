#!/usr/bin/env python3
"""Dependency-free tests for per-project memory space resolution.

A memory space belongs to a project. It used to belong to whichever launcher
started the agent — only the manager app passed `BYORIDB_MEMORY_SPACE`, and
everything else fell back to one shared `claude_memory` space — so these tests
pin the two properties that stopped that from being possible: resolution never
falls back to a shared space, and the three implementations of the derived name
(this, cli/byori.py, WorkspacePersistence.swift) agree character for character.
"""

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MCP = _load("byoridb_mcp_space", "mcp/byoridb_mcp.py")
CLI = _load("byori_cli_space", "cli/byori.py")

# The same vectors are asserted in Swift
# (ByoriManagerCoreTests/WorkspacePersistenceTests.swift). A change here that is
# not mirrored there splits a project's memory across two spaces, which is the
# failure this whole mechanism exists to prevent.
GOLDEN_VECTORS = (
    ("/Users/teo/byori", "byori_byori_89107dac"),
    ("/Users/teo/My Project!", "byori_my_project_c7270d6a"),
    # A slug that does not start with a letter takes the `p_` prefix.
    ("/Users/teo/2048", "byori_p_2048_5123ef0f"),
    # Nothing ASCII-alphanumeric survives, so the slug falls back.
    ("/Users/teo/프로젝트", "byori_project_3d2e3680"),
    # Cut to 36 characters, then any trailing underscore removed.
    ("/Users/teo/" + "a" * 35 + "-b", "byori_" + "a" * 35 + "_31597749"),
    ("/", "byori_project_8a5edab2"),
    ("/tmp/repo.git", "byori_repo_git_148929e4"),
)


def _run(*argv, cwd=None):
    subprocess.run(
        list(argv),
        cwd=str(cwd) if cwd else None,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def _repository(path):
    path.mkdir(parents=True, exist_ok=True)
    _run("git", "init", "-b", "main", str(path))
    _run("git", "config", "user.email", "tests@example.invalid", cwd=path)
    _run("git", "config", "user.name", "Byori Tests", cwd=path)
    (path / "README.md").write_text("# Fixture\n", encoding="utf-8")
    _run("git", "add", "README.md", cwd=path)
    _run("git", "commit", "-m", "fixture", cwd=path)
    return path.resolve()


class DerivedNameTests(unittest.TestCase):
    def test_golden_vectors(self):
        for root, expected in GOLDEN_VECTORS:
            with self.subTest(root=root):
                self.assertEqual(MCP._memory_space_for_root(pathlib.Path(root)), expected)

    def test_cli_derives_the_same_names_as_the_mcp_server(self):
        for root, expected in GOLDEN_VECTORS:
            with self.subTest(root=root):
                self.assertEqual(CLI.memory_space_for_root(pathlib.Path(root)), expected)

    def test_derived_names_are_valid_space_identifiers(self):
        for root, expected in GOLDEN_VECTORS:
            with self.subTest(root=root):
                self.assertEqual(MCP._validate_space_name(expected), expected)

    def test_name_depends_on_the_whole_path_not_just_the_basename(self):
        first = MCP._memory_space_for_root(pathlib.Path("/a/byori"))
        second = MCP._memory_space_for_root(pathlib.Path("/b/byori"))
        self.assertNotEqual(first, second)


class ResolutionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = pathlib.Path(self.temporary.name).resolve()
        self.byori_home = self.base / "byori-home"
        self.byori_home.mkdir()

    def resolve(self, project_dir, override="", byori_home=None):
        """Resolve as a server started in `project_dir` would.

        Empty environment values stand in for unset ones: the resolver treats them
        the same, and clearing the real environment would take git's PATH with it.
        """
        environment = {
            "BYORIDB_MEMORY_SPACE": override,
            "CLAUDE_PROJECT_DIR": str(project_dir),
        }
        with mock.patch.dict(os.environ, environment), mock.patch.object(
            MCP, "BYORI_HOME", byori_home or self.byori_home
        ):
            return MCP._resolve_memory_space()

    def write_registry(self, projects=(), removed=()):
        (self.byori_home / "projects.json").write_text(
            json.dumps({
                "schema_version": 1,
                "projects": list(projects),
                "removed_projects": list(removed),
            }),
            encoding="utf-8",
        )

    def test_explicit_override_wins(self):
        repository = _repository(self.base / "repo")
        self.write_registry([{"root": str(repository), "space": "registered_space"}])
        self.assertEqual(self.resolve(repository, override="chosen_space"), "chosen_space")

    def test_invalid_override_is_refused_rather_than_replaced(self):
        with self.assertRaises(ValueError):
            self.resolve(self.base, override="not a space")

    def test_registered_project_resolves_to_its_recorded_space(self):
        """The acceptance criterion: a session that was handed no space at all
        reaches the same space the manager app passes explicitly."""
        repository = _repository(self.base / "repo")
        self.write_registry([{"root": str(repository), "space": "byori_repo_deadbeef"}])
        self.assertEqual(self.resolve(repository, override=""), "byori_repo_deadbeef")

    def test_registry_lookup_works_from_a_subdirectory(self):
        repository = _repository(self.base / "repo")
        nested = repository / "cli" / "deep"
        nested.mkdir(parents=True)
        self.write_registry([{"root": str(repository), "space": "byori_repo_deadbeef"}])
        self.assertEqual(self.resolve(nested), "byori_repo_deadbeef")

    def test_removed_project_keeps_its_space(self):
        """Un-trusting a project archives the record; it does not delete the space,
        and the memories in it still belong to that repository."""
        repository = _repository(self.base / "repo")
        self.write_registry(removed=[{"root": str(repository), "space": "byori_repo_archived"}])
        self.assertEqual(self.resolve(repository), "byori_repo_archived")

    def test_active_registration_beats_an_archived_one(self):
        repository = _repository(self.base / "repo")
        self.write_registry(
            projects=[{"root": str(repository), "space": "byori_repo_active"}],
            removed=[{"root": str(repository), "space": "byori_repo_archived"}],
        )
        self.assertEqual(self.resolve(repository), "byori_repo_active")

    def test_invalid_registry_space_is_ignored_and_the_name_is_derived(self):
        repository = _repository(self.base / "repo")
        self.write_registry([{"root": str(repository), "space": "not a space"}])
        self.assertEqual(
            self.resolve(repository), MCP._memory_space_for_root(repository)
        )

    def test_unreadable_registry_does_not_fail_resolution(self):
        repository = _repository(self.base / "repo")
        (self.byori_home / "projects.json").write_text("{not json", encoding="utf-8")
        self.assertEqual(
            self.resolve(repository), MCP._memory_space_for_root(repository)
        )

    def test_missing_registry_derives_the_name(self):
        repository = _repository(self.base / "repo")
        self.assertEqual(
            self.resolve(repository, byori_home=self.base / "absent"),
            MCP._memory_space_for_root(repository),
        )

    def test_unregistered_project_never_falls_back_to_the_shared_space(self):
        repository = _repository(self.base / "repo")
        resolved = self.resolve(repository)
        self.assertNotEqual(resolved, MCP.LEGACY_SHARED_SPACE)
        self.assertTrue(resolved.startswith("byori_"), resolved)

    def test_directory_that_is_not_a_repository_still_gets_its_own_space(self):
        plain = self.base / "notes"
        plain.mkdir()
        resolved = self.resolve(plain)
        self.assertNotEqual(resolved, MCP.LEGACY_SHARED_SPACE)
        self.assertEqual(resolved, MCP._memory_space_for_root(plain))

    def test_subdirectory_of_a_repository_resolves_to_the_repository(self):
        repository = _repository(self.base / "repo")
        nested = repository / "cli"
        nested.mkdir()
        self.assertEqual(
            self.resolve(nested), MCP._memory_space_for_root(repository)
        )

    def test_linked_worktree_resolves_to_the_main_worktree(self):
        """byori runs tasks in worktrees of the same project; a space per checkout
        would scatter one project's memory across every task it ever ran."""
        repository = _repository(self.base / "repo")
        worktree = self.base / "task-worktree"
        _run("git", "worktree", "add", str(worktree), "-b", "task", cwd=repository)
        self.assertEqual(
            self.resolve(worktree.resolve()),
            MCP._memory_space_for_root(repository),
        )

    def test_worktree_registered_as_its_own_project_wins(self):
        repository = _repository(self.base / "repo")
        worktree = (self.base / "task-worktree")
        _run("git", "worktree", "add", str(worktree), "-b", "task", cwd=repository)
        self.write_registry([{"root": str(worktree.resolve()), "space": "byori_wt_own"}])
        self.assertEqual(self.resolve(worktree.resolve()), "byori_wt_own")

    def test_falls_back_to_the_working_directory_without_a_project_dir(self):
        repository = _repository(self.base / "repo")
        previous = os.getcwd()
        os.chdir(repository)
        try:
            with mock.patch.dict(
                os.environ, {"BYORIDB_MEMORY_SPACE": "", "CLAUDE_PROJECT_DIR": ""}
            ), mock.patch.object(MCP, "BYORI_HOME", self.byori_home):
                resolved = MCP._resolve_memory_space()
        finally:
            os.chdir(previous)
        self.assertEqual(resolved, MCP._memory_space_for_root(repository))


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = pathlib.Path(self.temporary.name).resolve()

    def test_registration_records_the_derived_space(self):
        repository = _repository(self.base / "repo")
        registry = CLI.ProjectRegistry(self.base / "byori-home")
        project, created = registry.add(repository)
        self.assertTrue(created)
        self.assertEqual(project["space"], CLI.memory_space_for_root(repository))

    def test_registration_and_server_resolution_agree(self):
        """Registering a project must not move its memory: the space the CLI
        records is the one a server would have resolved on its own."""
        repository = _repository(self.base / "repo")
        home = self.base / "byori-home"
        registry = CLI.ProjectRegistry(home)
        project, _ = registry.add(repository)
        with mock.patch.dict(
            os.environ,
            {"BYORIDB_MEMORY_SPACE": "", "CLAUDE_PROJECT_DIR": str(repository)},
        ), mock.patch.object(MCP, "BYORI_HOME", home):
            self.assertEqual(MCP._resolve_memory_space(), project["space"])

    def test_colliding_space_is_refused(self):
        first = _repository(self.base / "repo")
        second = _repository(self.base / "other")
        registry = CLI.ProjectRegistry(self.base / "byori-home")
        registry.add(first)
        with mock.patch.object(
            CLI, "memory_space_for_root", return_value=CLI.memory_space_for_root(first)
        ):
            with self.assertRaises(CLI.ByoriError):
                registry.add(second)


if __name__ == "__main__":
    unittest.main()
