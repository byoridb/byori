#!/usr/bin/env python3
"""Contract for the opt-in usage status line.

What is pinned here: Claude's numbers come only from the status line payload and
an expired window is never shown; Codex's come from the newest session log; the
user's own statusLine is run with the same payload and its output leads; install
records it once (a re-install must not record our own line as the original) and
uninstall puts it back, unless the user has replaced ours since. Installer-level
tests follow test_install_bulk_read.py: install runs die at the stubbed engine
download, while option handling and uninstall happen before that point.
"""

import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "adapters" / "claude" / "byori-statusline.py"
INSTALLER = ROOT / "install.sh"

_spec = importlib.util.spec_from_file_location("byori_statusline", SCRIPT)
statusline = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(statusline)

NOW = 1_800_000_000


def claude_payload(five_hour=None, seven_day=None):
    limits = {}
    if five_hour is not None:
        limits["five_hour"] = {"used_percentage": five_hour[0], "resets_at": five_hour[1]}
    if seven_day is not None:
        limits["seven_day"] = {"used_percentage": seven_day[0], "resets_at": seven_day[1]}
    return json.dumps({"model": {"id": "x"}, "rate_limits": limits}).encode()


def codex_record(used, resets_at, window=10080, credits=None):
    return {
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "rate_limits": {
                "primary": {"used_percent": used, "window_minutes": window, "resets_at": resets_at},
                "secondary": None,
                "credits": credits,
            },
        },
    }


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.state = self.root / "statusline.previous.json"
        self.codex = self.root / "codex"

    def write_codex_log(self, records, day="2027/01/15", name="rollout-a.jsonl"):
        directory = self.codex / "sessions" / day
        directory.mkdir(parents=True, exist_ok=True)
        log = directory / name
        log.write_text("".join(json.dumps(r) + "\n" for r in records), encoding="utf-8")
        return log

    def render(self, payload=b"{}"):
        return statusline.render(payload, self.state, now=NOW, codex_home=self.codex)

    def test_claude_windows_show_percent_and_time_to_reset(self):
        line = self.render(claude_payload((23.5, NOW + 3600 + 52 * 60), (41.2, NOW + 3 * 86400 + 7200)))
        self.assertEqual(line, "Claude 5h 24% (1h52m) · 7d 41% (3d2h)")

    def test_a_window_that_already_reset_is_not_shown(self):
        line = self.render(claude_payload((90, NOW - 1), (41, NOW + 7200)))
        self.assertEqual(line, "Claude 7d 41% (2h)")

    def test_no_rate_limits_and_no_codex_renders_nothing(self):
        self.assertEqual(self.render(json.dumps({"model": {}}).encode()), "")

    def test_codex_reads_the_last_snapshot_and_credits(self):
        self.write_codex_log([
            codex_record(10, NOW + 86400),
            {"type": "event_msg", "payload": {"type": "token_count", "rate_limits": None}},
            codex_record(75, NOW + 2 * 86400, credits={"has_credits": True, "unlimited": False, "balance": "62500.0000"}),
        ])
        self.assertEqual(self.render(), "Codex 7d 75% (2d) · credits 62,500")

    def test_codex_prefers_the_most_recently_written_log_over_the_newest_directory(self):
        """A long session keeps writing into the directory of the day it started."""
        older_day = self.write_codex_log([codex_record(60, NOW + 86400)], day="2027/01/10", name="rollout-long.jsonl")
        newer_day = self.write_codex_log([codex_record(5, NOW + 86400)], day="2027/01/15", name="rollout-short.jsonl")
        os.utime(newer_day, (NOW - 3600, NOW - 3600))
        os.utime(older_day, (NOW, NOW))
        self.assertIn("Codex 7d 60%", self.render())

    def test_unlimited_or_absent_credits_are_not_shown(self):
        self.write_codex_log([codex_record(5, NOW + 3600, window=300, credits={"has_credits": True, "unlimited": True})])
        self.assertEqual(self.render(), "Codex 5h 5% (1h)")

    def test_both_sources_are_joined(self):
        self.write_codex_log([codex_record(75, NOW + 86400)])
        line = self.render(claude_payload((10, NOW + 600)))
        self.assertEqual(line, "Claude 5h 10% (10m) │ Codex 7d 75% (1d)")

    def test_an_unparseable_codex_log_is_skipped(self):
        self.write_codex_log([])
        (self.codex / "sessions" / "2027/01/15" / "rollout-a.jsonl").write_text('{"rate_limits": {broken\n', encoding="utf-8")
        self.assertEqual(self.render(claude_payload((10, NOW + 600))), "Claude 5h 10% (10m)")

    def test_the_previous_status_line_gets_the_same_payload_and_leads(self):
        received = self.root / "received.json"
        self.state.write_text(json.dumps({"previous": {
            "type": "command",
            "command": f"cat > '{received}'; printf 'mine'",
        }}), encoding="utf-8")
        payload = claude_payload((10, NOW + 600))
        self.assertEqual(self.render(payload), "mine │ Claude 5h 10% (10m)")
        self.assertEqual(received.read_bytes(), payload)

    def test_the_previous_status_line_alone_when_there_is_no_usage(self):
        self.state.write_text(json.dumps({"previous": {"type": "command", "command": "printf 'line1\\nline2\\n'"}}), encoding="utf-8")
        self.assertEqual(self.render(), "line1\nline2")

    def test_a_failing_previous_status_line_does_not_blank_ours(self):
        self.state.write_text(json.dumps({"previous": {"type": "command", "command": "exit 3"}}), encoding="utf-8")
        self.assertEqual(self.render(claude_payload((10, NOW + 600))), "Claude 5h 10% (10m)")

    def test_a_hanging_previous_status_line_is_cut_off(self):
        self.state.write_text(json.dumps({"previous": {"type": "command", "command": "exec sleep 30"}}), encoding="utf-8")
        line = self.render(claude_payload((10, NOW + 600)))
        self.assertEqual(line, "Claude 5h 10% (10m)")

    def test_the_command_line_entry_point_exits_zero_on_garbage(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input=b"not json",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "CODEX_HOME": str(self.codex)},
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.settings = self.root / "claude" / "settings.json"
        self.state = self.root / "statusline.previous.json"
        self.command = f"python3 {self.root}/bin/byori-statusline.py"

    def write_settings(self, value):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(value), encoding="utf-8")

    def read_settings(self):
        return json.loads(self.settings.read_text(encoding="utf-8"))

    def install(self):
        return statusline.install(self.settings, self.state, self.command, 60)

    def uninstall(self):
        return statusline.uninstall(self.settings, self.state)

    def test_fresh_install_without_settings(self):
        self.assertEqual(self.install(), "installed")
        self.assertEqual(self.read_settings()["statusLine"], {"type": "command", "refreshInterval": 60, "command": self.command})
        self.assertEqual(json.loads(self.state.read_text())["previous"], None)

    def test_an_existing_status_line_is_wrapped_and_its_settings_kept(self):
        original = {"type": "command", "command": "~/mine.sh", "padding": 2, "refreshInterval": 5}
        self.write_settings({"model": "opus", "statusLine": original})
        self.assertEqual(self.install(), "wrapped")
        settings = self.read_settings()
        self.assertEqual(settings["model"], "opus")
        self.assertEqual(settings["statusLine"], {"type": "command", "padding": 2, "refreshInterval": 5, "command": self.command})
        self.assertEqual(json.loads(self.state.read_text())["previous"], original)

    def test_reinstall_keeps_the_original_it_recorded_first(self):
        original = {"type": "command", "command": "~/mine.sh"}
        self.write_settings({"statusLine": original})
        self.install()
        self.command = "python3.12 /new/bin/byori-statusline.py"
        self.assertEqual(self.install(), "updated")
        self.assertEqual(self.read_settings()["statusLine"]["command"], self.command)
        self.assertEqual(json.loads(self.state.read_text())["previous"], original)

    def test_uninstall_restores_the_original(self):
        original = {"type": "command", "command": "~/mine.sh", "padding": 2}
        self.write_settings({"statusLine": original, "model": "opus"})
        self.install()
        self.assertEqual(self.uninstall(), "restored")
        self.assertEqual(self.read_settings(), {"statusLine": original, "model": "opus"})
        self.assertFalse(self.state.exists())

    def test_uninstall_without_an_original_removes_ours(self):
        self.write_settings({"model": "opus"})
        self.install()
        self.assertEqual(self.uninstall(), "removed")
        self.assertEqual(self.read_settings(), {"model": "opus"})

    def test_uninstall_leaves_a_status_line_the_user_replaced_since(self):
        self.write_settings({"statusLine": {"type": "command", "command": "~/mine.sh"}})
        self.install()
        replaced = {"type": "command", "command": "~/newer.sh"}
        self.write_settings({"statusLine": replaced})
        self.assertEqual(self.uninstall(), "statusLine changed since install; left alone")
        self.assertEqual(self.read_settings(), {"statusLine": replaced})

    def test_unreadable_settings_are_not_overwritten(self):
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text("{ not json", encoding="utf-8")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(self.settings.read_text(encoding="utf-8"), "{ not json")
        self.assertEqual(self.uninstall(), "settings unreadable; left alone")
        self.assertEqual(self.settings.read_text(encoding="utf-8"), "{ not json")


FAILING_CURL = """#!/bin/sh
echo "curl: (22) stubbed failure" >&2; exit 22
"""

NOOP = """#!/bin/sh
exit 0
"""


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.stub_directory = self.root / "stub"
        self.stub_directory.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.byori_home = self.root / "byoridb-home"
        self.indexer = self.root / "byori-indexer"
        self.indexer.write_text(NOOP, encoding="utf-8")
        self.indexer.chmod(0o755)

    def run_installer(self, *arguments):
        for name, body in (("curl", FAILING_CURL), ("claude", NOOP), ("codex", NOOP)):
            stub = self.stub_directory / name
            stub.write_text(body, encoding="utf-8")
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        environment = dict(os.environ)
        environment.update(
            PATH=f"{self.stub_directory}{os.pathsep}{environment['PATH']}",
            BYORIDB_HOME=str(self.byori_home),
            HOME=str(self.home),  # never the developer's own Claude settings
        )
        return subprocess.run(
            ["bash", str(INSTALLER), "--assets", str(ROOT), "--indexer-binary", str(self.indexer),
             "--no-codex", "--no-service", *arguments],
            env=environment,
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
        ).stdout

    def test_the_flag_is_accepted(self):
        self.assertNotIn("unknown option", self.run_installer("--with-usage-statusline"))

    def test_help_documents_the_flag_and_that_it_is_off_by_default(self):
        help_text = subprocess.run(
            ["bash", str(INSTALLER), "--help"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=60,
        ).stdout
        self.assertIn("--with-usage-statusline", help_text)
        self.assertIn("Off by default: the status line", " ".join(help_text.split()))

    def test_the_status_line_defaults_to_off_and_the_script_always_ships(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn("WITH_USAGE_STATUSLINE=0;", source)
        self.assertIn('if [ "$WITH_USAGE_STATUSLINE" = 1 ]; then', source)
        ship = 'cp "$WORK/byori-statusline.py" "$BYORIDB_HOME/bin/byori-statusline.py"'
        self.assertIn(ship, source)
        self.assertLess(source.index(ship), source.index('if [ "$WITH_USAGE_STATUSLINE" = 1 ]; then'))

    def test_the_wired_command_names_the_real_interpreter_not_a_shim(self):
        """A version-manager shim resolves per directory; failing in one project it
        would take the wrapped user status line down with ours."""
        source = INSTALLER.read_text(encoding="utf-8")
        block = source[source.index("# 9c) usage status line"):]
        self.assertIn("[sys.executable] + sys.argv[1:]", block[: block.index("\nfi\n")])

    def test_uninstall_restores_the_users_status_line(self):
        bin_directory = self.byori_home / "bin"
        bin_directory.mkdir(parents=True)
        (bin_directory / "byori-statusline.py").write_bytes(SCRIPT.read_bytes())
        settings = self.home / ".claude" / "settings.json"
        settings.parent.mkdir()
        original = {"type": "command", "command": "~/mine.sh"}
        settings.write_text(json.dumps({"statusLine": original}), encoding="utf-8")
        statusline.install(
            settings, self.byori_home / "statusline.previous.json",
            f"python3 {bin_directory}/byori-statusline.py", 60,
        )

        output = self.run_installer("--uninstall")
        self.assertIn("uninstalled", output)
        self.assertEqual(json.loads(settings.read_text(encoding="utf-8")), {"statusLine": original})


if __name__ == "__main__":
    unittest.main()
