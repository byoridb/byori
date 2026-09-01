#!/usr/bin/env python3
"""Lifecycle contract for the MCP adapter: how the process goes away.

A server that never exits is not a visible failure — it is 25 resident processes
two weeks later, each indistinguishable from a live one. Several tests run the
real script as a subprocess, because the thing under test is process behaviour
rather than a return value. None of them needs a running ByoriDB: startup
validates configuration and reads stdin without connecting.
"""

import contextlib
import importlib.util
import io
import os
import pathlib
import signal
import subprocess
import sys
import time
import unittest
from unittest import mock


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


class SessionLossClassificationTests(unittest.TestCase):
    """Engine 0.4.0 separates the failure classes by status. Retrying the wrong
    one is not a harmless retry: a 403 cannot be fixed by re-authenticating, and
    every attempt is spent against the engine's login throttle."""

    def test_expired_session_is_retried(self):
        self.assertTrue(MCP._is_session_lost(401, '{"code":"SESSION_EXPIRED"}'))

    def test_permission_denied_is_not_retried(self):
        self.assertFalse(
            MCP._is_session_lost(403, '{"error":"Permission denied: requires Write","code":"PERMISSION_DENIED"}'),
            "re-authenticating cannot grant a role, and burns a throttled attempt",
        )

    def test_query_error_is_not_retried_even_when_it_mentions_auth(self):
        """The pre-0.4.0 rule retried any 400 whose body contained `auth`, which
        is exactly how a permission denial arrived back then."""
        self.assertFalse(
            MCP._is_session_lost(400, '{"error":"Query execution failed: Authentication failed: Permission denied","code":"QUERY_ERROR"}')
        )
        self.assertFalse(MCP._is_session_lost(400, '{"error":"syntax error near AUTH","code":"QUERY_ERROR"}'))

    def test_stale_session_on_an_older_engine_is_still_retried(self):
        """Engines before 0.4.0 report a restarted server's stale session as a
        400 carrying `session`, and users can be on one until they reinstall."""
        self.assertTrue(MCP._is_session_lost(400, '{"error":"Invalid session","code":"QUERY_ERROR"}'))

    def test_other_statuses_are_not_retried(self):
        for code in (404, 413, 500, 503):
            with self.subTest(code=code):
                self.assertFalse(MCP._is_session_lost(code, "{}"))


def _http_error(status, body="", headers=None):
    return MCP.urllib.error.HTTPError(
        "http://127.0.0.1:19669/api/v1/session", status, "stub", headers or {},
        io.BytesIO(body.encode()),
    )


class LoginFailureClassTests(unittest.TestCase):
    """The four ways `POST /api/v1/session` can fail, and why they are not one thing.

    Engine 0.4.0+ separates a credential that was *evaluated and rejected* (401/403)
    from one that was *never checked* (429, a spent failure budget or a 300s lockout).
    The difference decides the correct response, and getting it backwards is harmful
    in both directions: retrying a rejected password walks the account into a lockout,
    while refusing to wait out a throttle turns a transient window into a failure.

    Before this, 429 fell through to the generic branch — 30 attempts × 2s of blind
    polling that ignored `Retry-After`, ending in "could not bootstrap ByoriDB", which
    reads as "the engine never came up" rather than "locked for four more minutes".
    """

    def setUp(self):
        MCP._session["id"] = None
        MCP._session["ready"] = False
        self.addCleanup(lambda: MCP._session.update({"id": None, "ready": False}))

    def test_a_rejected_credential_is_classified_and_says_what_to_check(self):
        for status in (401, 403):
            with self.subTest(status=status), mock.patch.object(
                MCP, "_post", side_effect=_http_error(status, '{"code":"AUTH_FAILED"}')
            ):
                with self.assertRaises(MCP.LoginRefused) as raised:
                    MCP._login()
                self.assertEqual(raised.exception.status, status)
                self.assertIn("BYORIDB_ROOT_PASSWORD", str(raised.exception))
                self.assertIn("Not retried", str(raised.exception))

    def test_a_throttle_carries_the_window_from_the_header(self):
        error = _http_error(429, '{"code":"TOO_MANY_ATTEMPTS"}', {"Retry-After": "5"})
        with mock.patch.object(MCP, "_post", side_effect=error):
            with self.assertRaises(MCP.LoginThrottled) as raised:
                MCP._login()

        self.assertEqual(raised.exception.seconds, 5.0)
        self.assertIn("not checked", str(raised.exception))

    def test_the_body_supplies_the_window_when_the_header_is_missing(self):
        """A proxy that drops `Retry-After` must not turn a 300s lockout into a
        guess: the engine repeats the number in the message."""
        error = _http_error(429, "Too many authentication attempts. Retry in 299s.")
        with mock.patch.object(MCP, "_post", side_effect=error):
            with self.assertRaises(MCP.LoginThrottled) as raised:
                MCP._login()

        self.assertEqual(raised.exception.seconds, 299.0)

    def test_an_http_date_falls_back_to_the_bodys_number_not_zero(self):
        error = _http_error(
            429, "Retry in 42s", {"Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"}
        )
        self.assertEqual(MCP._retry_after_seconds(error, "Retry in 42s"), 42.0)

    def test_with_no_hint_at_all_the_budget_window_is_assumed(self):
        self.assertEqual(
            MCP._retry_after_seconds(_http_error(429, "no numbers here"), "no numbers here"),
            MCP.LOGIN_THROTTLE_DEFAULT_WAIT,
        )

    def test_a_status_that_is_not_an_auth_class_still_propagates(self):
        """503 while the server is starting must stay retryable, not be reclassified
        as an authentication problem."""
        with mock.patch.object(MCP, "_post", side_effect=_http_error(503, "starting")):
            with self.assertRaises(MCP.urllib.error.HTTPError):
                MCP._login()


class BootstrapThrottleTests(unittest.TestCase):
    """How `_ensure_ready` spends its retry budget when the engine is throttling."""

    def setUp(self):
        MCP._session["id"] = None
        MCP._session["ready"] = False
        self.addCleanup(lambda: MCP._session.update({"id": None, "ready": False}))
        self.slept = []
        patches = [
            mock.patch.object(MCP.time, "sleep", self.slept.append),
            mock.patch.object(MCP, "_raw_query", lambda *a, **k: {}),
            mock.patch.object(MCP, "_migrate", lambda: None),
            mock.patch.object(MCP, "_describe_space_contents", lambda: "0 memories"),
            mock.patch.object(MCP, "_report_legacy_shared_space", lambda: None),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_a_short_window_is_waited_out_and_the_same_password_reused(self):
        attempts = []

        def login():
            attempts.append(1)
            if len(attempts) == 1:
                raise MCP.LoginThrottled(5.0, "Retry in 5s")
            MCP._session["id"] = "1"

        with mock.patch.object(MCP, "_login", login):
            MCP._ensure_ready()

        self.assertEqual(len(attempts), 2)
        self.assertTrue(MCP._session["ready"])
        # The engine's own number, plus a second so the retry lands after the window
        # rather than on its boundary. Not the old blind 2s.
        self.assertEqual(self.slept, [6.0])

    def test_a_lockout_is_reported_immediately_instead_of_polled(self):
        """The case that used to burn 30 attempts and then blame the bootstrap."""
        attempts = []

        def login():
            attempts.append(1)
            raise MCP.LoginThrottled(300.0, "Too many authentication attempts. Retry in 300s.")

        with mock.patch.object(MCP, "_login", login):
            with self.assertRaises(RuntimeError) as raised:
                MCP._ensure_ready()

        message = str(raised.exception)
        self.assertIn("300s", message)
        self.assertNotIn("could not bootstrap", message)
        self.assertEqual(len(attempts), 1, "a lockout must not be polled")
        self.assertEqual(self.slept, [], "nobody should sleep five minutes in-process")

    def test_repeated_short_windows_stop_rather_than_loop(self):
        attempts = []

        def login():
            attempts.append(1)
            raise MCP.LoginThrottled(5.0, "Retry in 5s")

        with mock.patch.object(MCP, "_login", login):
            with self.assertRaises(RuntimeError):
                MCP._ensure_ready()

        self.assertEqual(len(attempts), MCP.LOGIN_THROTTLE_MAX_WAITS + 1)

    def test_a_rejected_credential_stops_at_the_first_attempt(self):
        attempts = []

        def login():
            attempts.append(1)
            raise MCP.LoginRefused(401, '{"code":"AUTH_FAILED"}')

        with mock.patch.object(MCP, "_login", login):
            with self.assertRaises(RuntimeError) as raised:
                MCP._ensure_ready()

        self.assertEqual(len(attempts), 1, "retrying a rejected password locks the account")
        self.assertIn("BYORIDB_ROOT_PASSWORD", str(raised.exception))

    def test_a_starting_server_still_gets_its_retries(self):
        """The throttle budget is separate; the startup budget must be untouched."""
        attempts = []

        def login():
            attempts.append(1)
            if len(attempts) < 4:
                raise OSError("connection refused")
            MCP._session["id"] = "1"

        with mock.patch.object(MCP, "_login", login):
            MCP._ensure_ready()

        self.assertEqual(len(attempts), 4)
        self.assertEqual(self.slept, [2, 2, 2])


class ThrottledQueryTests(unittest.TestCase):
    """A tool call that needs a fresh session while the engine is throttling."""

    def setUp(self):
        MCP._session["id"] = None
        MCP._session["ready"] = True
        self.addCleanup(lambda: MCP._session.update({"id": None, "ready": False}))

    def test_a_throttle_reaches_the_caller_as_an_actionable_error(self):
        """`_raw_query` calls `_login()` outside its own `try`, so a 429 there used to
        surface to the MCP caller as a raw urllib exception."""
        error = _http_error(429, "Retry in 299s.", {"Retry-After": "299"})
        with mock.patch.object(MCP, "_post", side_effect=error):
            with self.assertRaises(RuntimeError) as raised:
                MCP._raw_query("MATCH (n) RETURN n")

        self.assertNotIsInstance(raised.exception, MCP.urllib.error.HTTPError)
        self.assertIn("299s", str(raised.exception))

    def test_a_failure_on_the_re_login_retry_is_also_a_plain_error(self):
        calls = []

        def post(path, payload, timeout=30):
            calls.append(path)
            if len(calls) == 1:
                raise _http_error(401, '{"code":"SESSION_EXPIRED"}')
            raise _http_error(503, "engine restarting")

        MCP._session["id"] = "1"
        with mock.patch.object(MCP, "_post", post), \
             mock.patch.object(MCP, "_login", lambda: MCP._session.update({"id": "2"})):
            with self.assertRaises(RuntimeError) as raised:
                MCP._raw_query("MATCH (n) RETURN n")

        self.assertNotIsInstance(raised.exception, MCP.urllib.error.HTTPError)
        self.assertIn("after re-login", str(raised.exception))
        self.assertIn("503", str(raised.exception))


class SignOutTests(unittest.TestCase):
    """`DELETE /api/v1/session` releases the session instead of leaving it for the
    24h TTL. It runs while the process is already exiting, so it must never raise."""

    def test_no_session_means_nothing_to_release(self):
        MCP._session["id"] = None
        self.assertIsNone(MCP._logout())

    def test_sends_the_id_in_the_documented_header_and_clears_it(self):
        captured = {}

        def fake_urlopen(request, timeout=None):
            captured["method"] = request.get_method()
            captured["url"] = request.full_url
            captured["header"] = request.get_header("X-byoridb-session-id")
            return contextlib.closing(io.BytesIO(b""))

        MCP._session["id"] = "734817462937615829"
        MCP._session["ready"] = True
        with mock.patch.object(MCP.urllib.request, "urlopen", fake_urlopen):
            self.assertEqual(MCP._logout(), "signed out")

        self.assertEqual(captured["method"], "DELETE")
        self.assertTrue(captured["url"].endswith("/api/v1/session"))
        self.assertEqual(captured["header"], "734817462937615829")
        self.assertIsNone(MCP._session["id"], "a released session must not be reused")
        self.assertFalse(MCP._session["ready"])

    def test_an_engine_without_the_route_is_reported_not_raised(self):
        """Engines before 0.4.0 answer 405 here."""
        def refuse(request, timeout=None):
            raise MCP.urllib.error.HTTPError(request.full_url, 405, "Method Not Allowed", {}, None)

        MCP._session["id"] = "1"
        with mock.patch.object(MCP.urllib.request, "urlopen", refuse):
            outcome = MCP._logout()
        self.assertIn("405", outcome)
        self.assertIn("TTL", outcome)

    def test_an_unreachable_engine_is_reported_not_raised(self):
        def fail(request, timeout=None):
            raise OSError("connection refused")

        MCP._session["id"] = "1"
        with mock.patch.object(MCP.urllib.request, "urlopen", fail):
            outcome = MCP._logout()
        self.assertIn("sign-out failed", outcome)


class ReadOnlyRequestTests(unittest.TestCase):
    def test_read_only_queries_ask_the_engine_to_enforce_it(self):
        """The Python gate still has to be right, but on 0.4.0 a statement that
        slips past it is refused by the engine instead of being executed with the
        session's write authority."""
        sent = []

        def fake_post(path, payload, timeout=30):
            sent.append((path, dict(payload)))
            return 200, {"data": []}

        MCP._session["id"] = "1"
        with mock.patch.object(MCP, "_post", fake_post):
            MCP._raw_query("MATCH (n) RETURN n", read_only=True)
            MCP._raw_query("INSERT VERTEX note() VALUES 1:()")

        self.assertTrue(sent[0][1]["read_only"])
        self.assertNotIn(
            "read_only", sent[1][1],
            "a writing path must not send a flag that would refuse it",
        )


class SpacePinningTests(unittest.TestCase):
    """Which space a statement actually runs in.

    The engine pins a space per session, not per statement, so a `USE` outlives
    the query that sent it. Only `memory_query` — the unrestricted tool the
    `legacy` profile exposes — can send one, and before this every later read
    and write on the process followed it into the other project's space,
    silently, until the session happened to be lost.
    """

    def setUp(self):
        MCP._session.update({"id": "1", "ready": True, "space": MCP.SPACE})
        self.addCleanup(
            lambda: MCP._session.update({"id": None, "ready": False, "space": None})
        )
        self.sent = []

    def _post(self, path, payload, timeout=30):
        if path == "/api/v1/session":
            return 200, {"session_id": "2"}
        self.sent.append(payload["query"])
        return 200, {"results": []}

    def _run(self, *statements):
        with mock.patch.object(MCP, "_post", self._post):
            for statement in statements:
                MCP._raw_query(statement)
        return self.sent

    def test_a_session_known_to_be_pinned_costs_no_extra_round_trip(self):
        """Re-pinning per statement would double every tool call's requests."""
        self.assertEqual(self._run("MATCH (n) RETURN n"), ["MATCH (n) RETURN n"])

    def test_a_redirect_moves_only_the_statement_that_asked_for_it(self):
        sent = self._run("USE other_space", "MATCH (n) RETURN n")

        self.assertEqual(
            sent,
            ["USE other_space", f"USE {MCP.SPACE}", "MATCH (n) RETURN n"],
            "the statement after a redirect must be pinned back first",
        )

    def test_a_use_of_this_space_is_recorded_rather_than_re_pinned(self):
        sent = self._run(f"USE {MCP.SPACE}", "MATCH (n) RETURN n")

        self.assertEqual(sent, [f"USE {MCP.SPACE}", "MATCH (n) RETURN n"])

    def test_a_redirect_inside_a_longer_query_counts_too(self):
        """`USE x; MATCH …` is not a bare `USE` and moves the session all the same."""
        sent = self._run("USE other_space; MATCH (n) RETURN n", "MATCH (n) RETURN n")

        self.assertEqual(sent[-2:], [f"USE {MCP.SPACE}", "MATCH (n) RETURN n"])

    def test_a_statement_that_cannot_be_read_is_assumed_to_have_moved(self):
        """An unterminated literal hides the rest of the statement. Re-pinning
        needlessly costs one request; trusting it costs a write to the wrong
        project's memory."""
        sent = self._run('MATCH (n) WHERE n.note.body == "open', "MATCH (n) RETURN n")

        self.assertEqual(sent[-2:], [f"USE {MCP.SPACE}", "MATCH (n) RETURN n"])

    def test_the_word_use_inside_a_literal_is_not_a_redirect(self):
        """Quoted text is data: a note whose body says "USE" must not re-pin."""
        sent = self._run(
            'MATCH (n) WHERE n.note.body == "USE other_space" RETURN n',
            "MATCH (n) RETURN n",
        )

        self.assertEqual(len(sent), 2, sent)

    def test_create_space_runs_before_the_space_it_creates_exists(self):
        """Bootstrap's first statement. Pinning ahead of it would fail on a
        fresh install with "space not found"."""
        MCP._session["space"] = None
        sent = self._run(f"CREATE SPACE IF NOT EXISTS {MCP.SPACE}(vid_type=INT64)")

        self.assertEqual(len(sent), 1, sent)

    def test_a_new_session_is_pinned_before_its_first_statement(self):
        """`_login` forgets the old session's space, so nothing inherits a pin
        the engine no longer holds."""
        MCP._session["id"] = None
        sent = self._run("MATCH (n) RETURN n")

        self.assertEqual(sent, [f"USE {MCP.SPACE}", "MATCH (n) RETURN n"])

    def test_a_lost_session_is_re_pinned_on_the_retry(self):
        calls = []

        def post(path, payload, timeout=30):
            if path == "/api/v1/session":
                return 200, {"session_id": "2"}
            calls.append(payload["query"])
            if len(calls) == 1:
                raise _http_error(401, '{"code":"SESSION_EXPIRED"}')
            return 200, {"results": []}

        with mock.patch.object(MCP, "_post", post):
            MCP._raw_query("MATCH (n) RETURN n")

        self.assertEqual(
            calls,
            ["MATCH (n) RETURN n", f"USE {MCP.SPACE}", "MATCH (n) RETURN n"],
        )
        self.assertEqual(MCP._session["space"], MCP.SPACE)


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
