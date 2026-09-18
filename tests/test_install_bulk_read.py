#!/usr/bin/env python3
"""Installer contract for the bulk-read guard.

The checkpoint hooks are on by default because they only add reminders; this
guard DENIES tool calls, so it is opt-in and stays opt-in. What is pinned here:
the flag exists, the default is off in the source, and an uninstall removes the
guard's hook entries — the guard runs a script the uninstall deletes, and a
leftover entry would make every Read and Bash call spawn a failing command.

Like test_install_hooks.py, install runs die at the engine download (stubbed
curl); option handling and uninstall both happen before that point.
"""

import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"

FAILING_CURL = """#!/bin/sh
echo "curl: (22) stubbed failure" >&2; exit 22
"""

NOOP = """#!/bin/sh
exit 0
"""


class BulkReadInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.stub_directory = self.root / "stub"
        self.stub_directory.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()

    def run_installer(self, *arguments):
        stub = self.stub_directory / "curl"
        stub.write_text(FAILING_CURL, encoding="utf-8")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        # The uninstall path invokes the real `claude`/`codex` CLIs when they
        # exist, and a real CLI rewrites the sandboxed settings.json on its way
        # through (observed: it normalized the model value). Stub both.
        for name in ("claude", "codex"):
            cli = self.stub_directory / name
            cli.write_text(NOOP, encoding="utf-8")
            cli.chmod(cli.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        environment = dict(os.environ)
        environment.update(
            PATH=f"{self.stub_directory}{os.pathsep}{environment['PATH']}",
            BYORIDB_HOME=str(self.root / "byoridb-home"),
            # Never the developer's own Claude settings.
            HOME=str(self.home),
        )
        return subprocess.run(
            ["bash", str(INSTALLER), "--assets", str(ROOT), "--no-codex", "--no-service", *arguments],
            env=environment,
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
        ).stdout

    def test_the_flag_is_accepted(self):
        output = self.run_installer("--with-bulk-read-hook")
        self.assertNotIn("unknown option", output)

    def test_help_documents_the_flag_and_that_it_is_off_by_default(self):
        help_text = subprocess.run(
            ["bash", str(INSTALLER), "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        ).stdout
        self.assertIn("--with-bulk-read-hook", help_text)
        self.assertIn("Off by default", " ".join(help_text.split()))
        self.assertIn("byori-bulk-reader", help_text)

    def test_the_guard_defaults_to_off_in_the_installer_source(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn("WITH_BULK_READ_HOOK=0;", source)
        self.assertIn('if [ "$WITH_BULK_READ_HOOK" = 1 ]; then', source)

    def test_the_summary_reports_everything_the_skills_step_installed(self):
        """The final summary is what a user reads to learn what landed; a skill
        it omits is a skill nobody knows to look for. Both summary lines carry
        the bulk-read skill, and the Claude side names the agent file too."""
        source = INSTALLER.read_text(encoding="utf-8")
        skills_lines = [
            line for line in source.splitlines()
            if "skills   :" in line or "codex    :" in line
        ]
        self.assertEqual(len(skills_lines), 2, skills_lines)
        for line in skills_lines:
            self.assertIn("%s,%s,%s", line)
        self.assertIn("'  agents   : %s/%s", source)

    @unittest.skipUnless(shutil.which("jq"), "the uninstall cleanup needs jq, like the install did")
    def test_uninstall_removes_the_guard_hooks_and_keeps_the_users_own(self):
        claude = self.home / ".claude"
        claude.mkdir()
        guard_entry = {
            "matcher": "Read|Bash",
            "hooks": [
                {
                    "type": "command",
                    "command": str(self.root / "byoridb-home" / "bin" / "bulk-read-guard.sh"),
                }
            ],
        }
        user_entry = {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": "echo user-hook"}],
        }
        settings = claude / "settings.json"
        settings.write_text(
            json.dumps({"hooks": {"PreToolUse": [guard_entry, user_entry]}}),
            encoding="utf-8",
        )

        output = self.run_installer("--uninstall")
        self.assertIn("uninstalled", output)

        remaining = json.loads(settings.read_text(encoding="utf-8"))
        commands = [
            hook["command"]
            for entry in remaining["hooks"]["PreToolUse"]
            for hook in entry["hooks"]
        ]
        self.assertEqual(commands, ["echo user-hook"])

    @unittest.skipUnless(shutil.which("jq"), "the uninstall cleanup needs jq, like the install did")
    def test_uninstall_leaves_settings_without_hooks_untouched(self):
        """A settings file that never had hooks must not gain an empty hooks
        shape just because an uninstall ran."""
        claude = self.home / ".claude"
        claude.mkdir()
        settings = claude / "settings.json"
        settings.write_text(json.dumps({"model": "opus"}), encoding="utf-8")

        self.run_installer("--uninstall")

        self.assertEqual(
            json.loads(settings.read_text(encoding="utf-8")), {"model": "opus"}
        )


if __name__ == "__main__":
    unittest.main()
