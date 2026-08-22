#!/usr/bin/env python3
"""Whether `install.sh` installs the memory checkpoint hooks by default.

The hooks are the mechanism that makes the memory graph present in a session
instead of something an agent has to remember to look for: hosts ship a
file-based memory whose index loads automatically, so an opt-in reminder loses to
it every time and the graph stays connected and empty.

These tests exercise the installer's option handling only. Reaching the hook step
for real needs a working engine — the run dies at the engine download first — so
what is asserted here is the contract a user sees: the flag exists, the default is
on, and the documented axis is independent of `--no-claude`.
"""

import os
import pathlib
import stat
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"

FAILING_CURL = """#!/bin/sh
echo "curl: (22) stubbed failure" >&2; exit 22
"""


class InstallHooksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.stub_directory = self.root / "stub"
        self.stub_directory.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def run_installer(self, *arguments):
        stub = self.stub_directory / "curl"
        stub.write_text(FAILING_CURL, encoding="utf-8")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        environment = dict(os.environ)
        environment.update(
            PATH=f"{self.stub_directory}{os.pathsep}{environment['PATH']}",
            BYORIDB_HOME=str(self.root / "byoridb-home"),
            # A test must never edit the developer's own Claude settings, and the
            # hook step writes under $HOME.
            HOME=str(self.home),
        )
        return subprocess.run(
            [
                "bash",
                str(INSTALLER),
                "--assets",
                str(ROOT),
                "--no-codex",
                "--no-service",
                *arguments,
            ],
            env=environment,
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
        ).stdout

    def test_no_hooks_is_accepted(self):
        output = self.run_installer("--no-hooks")
        self.assertNotIn("unknown option", output)
        self.assertIn("download failed", output, output)

    def test_with_hooks_still_parses_for_callers_that_pass_it(self):
        output = self.run_installer("--with-hooks")
        self.assertNotIn("unknown option", output)

    def test_help_documents_the_default_and_the_axis(self):
        help_text = subprocess.run(
            ["bash", str(INSTALLER), "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        ).stdout
        self.assertIn("--no-hooks", help_text)
        self.assertIn("installed by default", help_text)
        # The app-driven install passes --no-claude, and its users are exactly the
        # ones who need the reminder, so the two flags must stay independent.
        self.assertIn("--no-claude skips MCP registration and skills, not these", help_text)

    def test_hooks_default_to_on_in_the_installer_source(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn("WITH_HOOKS=1;", source)
        # Gated by the hooks flag alone: adding --no-claude back into the
        # condition is the regression this guards.
        self.assertIn('if [ "$WITH_HOOKS" = 1 ]; then', source)


if __name__ == "__main__":
    unittest.main()
