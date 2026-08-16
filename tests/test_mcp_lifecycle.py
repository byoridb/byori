#!/usr/bin/env python3
"""Lifecycle contract for the MCP adapter: how the process goes away.

A server that never exits is not a visible failure — it is 25 resident processes
two weeks later, each indistinguishable from a live one. Several tests run the
real script as a subprocess, because the thing under test is process behaviour
rather than a return value. None of them needs a running ByoriDB: startup
validates configuration and reads stdin without connecting.
"""

import importlib.util
import os
import pathlib
import signal
import subprocess
import sys
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "mcp" / "byoridb_mcp.py"
SPEC = importlib.util.spec_from_file_location("byoridb_mcp_lifecycle", SCRIPT)
MCP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCP)


def _spawn(**env_overrides):
    env = dict(os.environ)
    env.pop("BYORIDB_MCP_IDLE_TIMEOUT", None)
    env.update(env_overrides)
    return subprocess.Popen(
        [sys.executable, str(SCRIPT)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
    )


class _Spawned:
    """Kills the process if an assertion left it running."""

    def __init__(self, **env_overrides):
        self.process = _spawn(**env_overrides)

    def __enter__(self):
        return self.process

    def __exit__(self, *_):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=5)
        return False


class IdleTimeoutConfigurationTests(unittest.TestCase):
    def test_disabled_by_default(self):
        self.assertIsNone(MCP._validate_idle_timeout(""))
        self.assertIsNone(MCP._validate_idle_timeout("0"))
        self.assertIsNone(MCP._validate_idle_timeout("   "))
        self.assertIsNone(MCP._validate_idle_timeout(None))

    def test_accepts_seconds_at_or_above_the_floor(self):
        self.assertEqual(MCP._validate_idle_timeout("60"), 60.0)
        self.assertEqual(MCP._validate_idle_timeout(" 900 "), 900.0)

    def test_rejects_values_that_would_exit_between_two_requests(self):
        for value in ("1", "59", "0.5", "-30"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MCP._validate_idle_timeout(value)

    def test_rejects_non_numeric(self):
        for value in ("soon", "30s", "later"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MCP._validate_idle_timeout(value)


class RequestReaderTests(unittest.TestCase):
    """`_requests` reads the descriptor directly when a timeout is set, so the
    line framing it does itself has to be exactly right."""

    def _read(self, payload, timeout):
        read_fd, write_fd = os.pipe()
        os.write(write_fd, payload)
        os.close(write_fd)
        original = sys.stdin
        sys.stdin = os.fdopen(read_fd, "r")
        try:
            return list(MCP._requests(timeout))
        finally:
            sys.stdin.close()
            sys.stdin = original

    def test_yields_whole_lines_including_a_trailing_partial(self):
        self.assertEqual(
            self._read(b'{"a":1}\n{"b":2}\n{"c":3}', 60.0),
            ['{"a":1}', '{"b":2}', '{"c":3}'],
            "a final line without a newline must not be dropped",
        )

    def test_splits_a_line_that_arrives_in_one_chunk_with_others(self):
        self.assertEqual(
            self._read(b'{"a":1}\n\n{"b":2}\n', 60.0),
            ['{"a":1}', "", '{"b":2}'],
        )

    def test_returns_when_idle_rather_than_blocking_forever(self):
        read_fd, write_fd = os.pipe()
        original = sys.stdin
        sys.stdin = os.fdopen(read_fd, "r")
        try:
            started = time.monotonic()
            # The write end stays open, which is exactly the state the leaked
            # processes were in: a live parent holding the pipe.
            self.assertEqual(list(MCP._requests(0.2)), [])
            self.assertLess(time.monotonic() - started, 5)
        finally:
            sys.stdin.close()
            os.close(write_fd)
            sys.stdin = original

    def test_without_a_timeout_the_default_reader_is_used(self):
        self.assertEqual(self._read(b'{"a":1}\n', None), ['{"a":1}\n'])


class ProcessExitTests(unittest.TestCase):
    def test_closing_stdin_ends_the_process(self):
        """The normal signal that the host is gone."""
        with _Spawned() as process:
            process.stdin.close()
            self.assertEqual(process.wait(timeout=15), 0)
            self.assertIn("exiting (stdin closed)", process.stderr.read())

    def test_sigterm_exits_and_reports_the_reason(self):
        with _Spawned() as process:
            self._wait_for_start(process)
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=15), 0)
            self.assertIn("exiting (signal:SIGTERM)", process.stderr.read())

    def test_sighup_exits_and_reports_the_reason(self):
        """A closed terminal reaches the server as SIGHUP, not as EOF."""
        with _Spawned() as process:
            self._wait_for_start(process)
            process.send_signal(signal.SIGHUP)
            self.assertEqual(process.wait(timeout=15), 0)
            self.assertIn("exiting (signal:SIGHUP)", process.stderr.read())

    def test_startup_opens_no_session_and_says_so_on_exit(self):
        """Startup must not authenticate; the exit line is the evidence, and it
        is what makes an abandoned session traceable when there is one."""
        with _Spawned() as process:
            process.stdin.close()
            process.wait(timeout=15)
            stderr = process.stderr.read()
            self.assertIn("no ByoriDB session was opened", stderr)
            self.assertIn("idle-timeout=off", stderr)

    def test_configured_timeout_is_reported_and_does_not_fire_immediately(self):
        with _Spawned(BYORIDB_MCP_IDLE_TIMEOUT="60") as process:
            self._wait_for_start(process)
            time.sleep(0.5)
            self.assertIsNone(
                process.poll(),
                "a 60s timeout must not end the process half a second in",
            )
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=15)

    def test_a_timeout_below_the_floor_refuses_to_start(self):
        with _Spawned(BYORIDB_MCP_IDLE_TIMEOUT="5") as process:
            self.assertNotEqual(process.wait(timeout=15), 0)
            self.assertIn("at least 60 seconds", process.stderr.read())

    def _wait_for_start(self, process, timeout=15):
        """Blocks until the server logged its startup line, so a signal cannot
        arrive before the handlers are installed."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = process.stderr.readline()
            if "starting;" in line:
                return
            if process.poll() is not None:
                self.fail(f"server exited during startup: {line}")
        self.fail("server never logged a startup line")


if __name__ == "__main__":
    unittest.main()
