#!/usr/bin/env python3
"""Behavioral tests for the bulk-read guard hook.

The guard is the enforcement layer of the bulk-reading convention: advice alone
is ignored under context pressure, so large whole-file reads are denied and
pointed at the delegate. Two properties matter more than the denials:

- it fails OPEN — a guard that cannot decide must not break every Read in the
  session; and
- ranged reads always pass — they are how the byori-bulk-reader delegate itself
  reads, so the guard needs no exemption list to avoid deadlocking its own
  escape route.

These run the real script with real files; jq is a hook prerequisite already.
"""

import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
GUARD = ROOT / "adapters" / "claude" / "bulk-read-guard.sh"

BIG = 40_000     # over the 32 KB default threshold
SMALL = 1_000


@unittest.skipUnless(shutil.which("jq"), "the guard is only ever installed where jq exists")
class BulkReadGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.big = self.directory / "big.py"
        self.big.write_bytes(b"x" * BIG)
        self.small = self.directory / "small.py"
        self.small.write_bytes(b"y" * SMALL)

    def run_guard(self, tool_name, tool_input, env=None):
        environment = None
        if env:
            import os

            environment = dict(os.environ)
            environment.update(env)
        result = subprocess.run(
            ["sh", str(GUARD)],
            input=json.dumps({"tool_name": tool_name, "tool_input": tool_input}),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def assert_denied(self, output):
        decision = json.loads(output)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        return decision["permissionDecisionReason"]

    # ---- Read ----

    def test_whole_read_of_a_large_file_is_denied_toward_the_delegate(self):
        reason = self.assert_denied(self.run_guard("Read", {"file_path": str(self.big)}))
        # The denial must name both sanctioned paths, or it is a dead end.
        self.assertIn("byori-bulk-reader", reason)
        self.assertIn("offset/limit", reason)

    def test_ranged_reads_always_pass(self):
        """The delegate reads in ranged chunks and editing follows a digest's
        line ranges — blocking ranged reads would deadlock both."""
        for tool_input in (
            {"file_path": str(self.big), "offset": 100},
            {"file_path": str(self.big), "limit": 200},
            {"file_path": str(self.big), "offset": 0, "limit": 800},
        ):
            with self.subTest(tool_input=tool_input):
                self.assertEqual(self.run_guard("Read", tool_input), "")

    def test_small_files_pass(self):
        self.assertEqual(self.run_guard("Read", {"file_path": str(self.small)}), "")

    def test_a_missing_file_passes(self):
        """Read itself reports the missing file; the guard denying first would
        replace that error with a misleading delegation hint."""
        self.assertEqual(
            self.run_guard("Read", {"file_path": str(self.directory / "absent.py")}), ""
        )

    def test_threshold_is_configurable(self):
        output = self.run_guard(
            "Read",
            {"file_path": str(self.small)},
            env={"BYORI_BULK_READ_MIN_BYTES": "500"},
        )
        self.assert_denied(output)

    def test_a_garbage_threshold_falls_back_instead_of_failing(self):
        self.assertEqual(
            self.run_guard(
                "Read",
                {"file_path": str(self.small)},
                env={"BYORI_BULK_READ_MIN_BYTES": "lots"},
            ),
            "",
        )

    # ---- Bash ----

    def test_plain_cat_of_a_large_file_is_denied(self):
        reason = self.assert_denied(
            self.run_guard("Bash", {"command": f"cat {self.big}"})
        )
        self.assertIn("byori-bulk-reader", reason)

    def test_cat_of_several_files_counts_their_total(self):
        half = self.directory / "half.py"
        half.write_bytes(b"z" * 20_000)
        other = self.directory / "other.py"
        other.write_bytes(b"z" * 20_000)
        self.assert_denied(
            self.run_guard("Bash", {"command": f"cat {half} {other}"})
        )

    def test_cat_feeding_a_pipeline_passes(self):
        """`cat big | grep x` puts matches in context, not the file; denying it
        would push the model toward stranger workarounds."""
        self.assertEqual(
            self.run_guard("Bash", {"command": f"cat {self.big} | grep pattern"}), ""
        )

    def test_cat_of_a_small_file_passes(self):
        self.assertEqual(self.run_guard("Bash", {"command": f"cat {self.small}"}), "")

    def test_unrelated_commands_pass(self):
        for command in (
            f"shasum -a 256 {self.big}",   # the delegate's own identity step
            f"wc -c {self.big}",
            f"head {self.big}",            # bounded by default
            "git status",
        ):
            with self.subTest(command=command):
                self.assertEqual(self.run_guard("Bash", {"command": command}), "")

    def test_a_glob_in_the_command_does_not_expand_against_the_guards_cwd(self):
        """`set -f` before the word split: a literal *.py must stay literal, not
        match whatever directory the hook happens to run in."""
        result = subprocess.run(
            ["sh", str(GUARD)],
            input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "cat *.py"}}),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=self.directory,  # holds big.py, which a glob would find
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")

    # ---- fail open ----

    def test_other_tools_pass(self):
        self.assertEqual(self.run_guard("Grep", {"pattern": "x"}), "")

    def test_malformed_input_passes(self):
        result = subprocess.run(
            ["sh", str(GUARD)],
            input="not json",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
