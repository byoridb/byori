#!/usr/bin/env python3
"""Dependency-free tests for the Byori multi-agent CLI."""

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("byori_cli_contract", ROOT / "cli" / "byori.py")
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


def run(*argv, cwd=None):
    return subprocess.run(
        list(argv),
        cwd=str(cwd) if cwd else None,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


class TemporaryRepository:
    def setUp(self):
        super().setUp()
        self.temporary = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temporary.name)
        self.repo = self.base / "repo"
        self.home = self.base / "byori-home"
        self.repo.mkdir()
        run("git", "init", "-b", "main", str(self.repo))
        run("git", "config", "user.email", "tests@example.invalid", cwd=self.repo)
        run("git", "config", "user.name", "Byori Tests", cwd=self.repo)
        (self.repo / "README.md").write_text("# Fixture\n", encoding="utf-8")
        run("git", "add", "README.md", cwd=self.repo)
        run("git", "commit", "-m", "fixture", cwd=self.repo)
        self.fake = self.base / "fake-agent"
        self.fake.write_text(
            """#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import sys
import time

if os.environ.get('BYORIDB_ROOT_PASSWORD') or os.environ.get('BYORIDB_PASSWORD'):
    print('ByoriDB secret leaked to worker', file=sys.stderr)
    raise SystemExit(9)
if '--version' in sys.argv:
    print('fake-agent 1.0')
    raise SystemExit(0)
provider = 'claude' if '--print' in sys.argv else 'codex'
mode = os.environ.get('BYORI_TEST_MODE', 'normal')
if mode == 'early-output':
    print(json.dumps({'type': 'message', 'text': 'x' * 200000}), flush=True)
prompt = sys.stdin.read()
started = time.time()
if provider == 'codex':
    print(json.dumps({'type': 'thread.started', 'thread_id': 'codex-test-thread'}), flush=True)
else:
    print(json.dumps({'type': 'system', 'session_id': 'claude-test-session'}), flush=True)
if mode == 'hang':
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
    pathlib.Path('worker-pids.json').write_text(json.dumps({
        'worker': os.getpid(), 'child': child.pid,
    }), encoding='utf-8')
    time.sleep(60)
if mode == 'oversize':
    print(json.dumps({'type': 'message', 'text': 'x' * (5 * 1024 * 1024)}), flush=True)
    time.sleep(1)
    raise SystemExit(0)
time.sleep(float(os.environ.get('BYORI_TEST_DELAY', '0.25')))
finished = time.time()
pathlib.Path('agent-output.json').write_text(json.dumps({
    'provider': provider,
    'started': started,
    'finished': finished,
    'prompt_has_task': '<task>' in prompt,
}), encoding='utf-8')
if mode == 'commit':
    subprocess.run(['git', 'add', 'agent-output.json'], check=True)
    subprocess.run(['git', 'commit', '-m', 'fake agent result'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(json.dumps({'type': 'result', 'result': provider + ' complete'}), flush=True)
""",
            encoding="utf-8",
        )
        self.fake.chmod(0o755)
        self.environment = {
            "BYORI_HOME": str(self.home),
            "BYORI_CLAUDE_BIN": str(self.fake),
            "BYORI_CODEX_BIN": str(self.fake),
            "BYORI_TEST_DELAY": "0.25",
            "BYORIDB_ROOT_PASSWORD": "must-not-reach-workers",
        }

    def tearDown(self):
        self.temporary.cleanup()
        super().tearDown()

    def cli(self, arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.dict(os.environ, self.environment, clear=False),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            code = CLI.main(arguments)
        return code, stdout.getvalue(), stderr.getvalue()


class ConfigurationTests(unittest.TestCase):
    def test_space_validation(self):
        for value in ("claude_memory", "_private", "Byori1"):
            self.assertEqual(CLI.validate_space(value), value)
        for value in ("", "1space", "has-dash", "has space", "a" * 65):
            with self.subTest(value=value), self.assertRaises(CLI.ByoriError):
                CLI.validate_space(value)

    def test_child_environment_is_readonly_and_does_not_leak_database_secret(self):
        with mock.patch.dict(
            os.environ,
            {"BYORIDB_ROOT_PASSWORD": "secret", "BYORIDB_PASSWORD": "stale"},
            clear=False,
        ):
            environment = CLI.child_environment("project_memory", True)
        self.assertNotIn("BYORIDB_ROOT_PASSWORD", environment)
        self.assertNotIn("BYORIDB_PASSWORD", environment)
        self.assertEqual(environment["BYORIDB_MCP_PROFILE"], "readonly")
        self.assertEqual(environment["BYORIDB_MEMORY_SPACE"], "project_memory")

    def test_provider_argv_uses_stdin_modes_and_no_bypass(self):
        claude = CLI.ClaudeAdapter().build_argv("/bin/claude", "session", False)
        self.assertIn("--print", claude)
        self.assertIn("dontAsk", claude)
        self.assertNotIn("Bash", claude[-1])
        self.assertFalse(any("dangerously" in argument for argument in claude))

        codex = CLI.CodexAdapter().build_argv("/bin/codex", "ignored", False)
        self.assertEqual(codex[-1], "-")
        self.assertIn("workspace-write", codex)
        self.assertIn("never", codex)
        self.assertFalse(any("dangerously" in argument for argument in codex))

    def test_context_is_bounded_and_marked_untrusted(self):
        payload = {
            "items": [
                {
                    "vid": str(index),
                    "type": "decision",
                    "name": "decision:item-%s" % index,
                    "body": "authentication choice " + ("x" * 2000),
                    "ts": index,
                }
                for index in range(20)
            ],
            "links": [],
        }
        selected = CLI.select_context(payload, "fix authentication")
        self.assertEqual(len(selected["items"]), CLI.CONTEXT_ITEM_LIMIT)
        rendered = CLI.format_context(selected)
        self.assertIn("untrusted reference", rendered)
        self.assertLess(len(rendered), 10000)


class ProjectRegistryTests(TemporaryRepository, unittest.TestCase):
    def test_add_is_idempotent_and_registry_is_private(self):
        with mock.patch.dict(os.environ, self.environment, clear=False):
            registry = CLI.ProjectRegistry(self.home)
            first, created = registry.add(self.repo)
            second, created_again = registry.add(self.repo)
        self.assertTrue(created)
        self.assertFalse(created_again)
        self.assertEqual(first, second)
        self.assertRegex(first["space"], CLI.SPACE_RE)
        self.assertEqual(self.home.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.home / "projects.json").stat().st_mode & 0o777, 0o600)

    def test_remove_is_nondestructive_and_readd_restores_identity(self):
        with mock.patch.dict(os.environ, self.environment, clear=False):
            registry = CLI.ProjectRegistry(self.home)
            original, _ = registry.add(self.repo)

            state = json.loads((self.home / "projects.json").read_text())
            state["projects"][0]["future_field"] = {"preserve": True}
            CLI.atomic_write_json(self.home / "projects.json", state)
            task_sentinel = self.home / "tasks" / "kept" / "state.json"
            task_sentinel.parent.mkdir(parents=True)
            task_sentinel.write_text("keep")

            removed = registry.remove(original["id"])
            self.assertEqual(registry.list(), [])
            self.assertTrue(self.repo.exists())
            self.assertEqual(task_sentinel.read_text(), "keep")

            persisted = json.loads((self.home / "projects.json").read_text())
            self.assertEqual(persisted["projects"], [])
            self.assertEqual(persisted["removed_projects"][0]["id"], original["id"])
            self.assertEqual(persisted["removed_projects"][0]["future_field"], {"preserve": True})

            restored, created = registry.add(self.repo)
        self.assertTrue(created)
        self.assertEqual(removed["id"], restored["id"])
        self.assertEqual(original["space"], restored["space"])
        self.assertEqual(restored["future_field"], {"preserve": True})

    def test_remove_command_requires_exact_registered_id(self):
        with mock.patch.dict(os.environ, self.environment, clear=False):
            project, _ = CLI.ProjectRegistry(self.home).add(self.repo)
        code, stdout, stderr = self.cli(["project", "remove", project["id"]])
        self.assertEqual(code, 0, stderr)
        self.assertIn("removed from Byori", stdout)
        self.assertTrue(self.repo.exists())

        code, _, stderr = self.cli(["project", "remove", project["id"]])
        self.assertEqual(code, 2)
        self.assertIn("project is not registered", stderr)

    def test_run_requires_explicit_project_registration(self):
        code, _, stderr = self.cli(
            ["run", "--project", str(self.repo), "--agent", "claude", "--no-memory", "task"]
        )
        self.assertEqual(code, 2)
        self.assertIn("project is not registered", stderr)


class OrchestrationTests(TemporaryRepository, unittest.TestCase):
    def register(self):
        code, _, stderr = self.cli(["project", "add", str(self.repo)])
        self.assertEqual(code, 0, stderr)

    def test_two_agents_run_concurrently_in_distinct_worktrees(self):
        self.register()
        started = time.monotonic()
        code, stdout, stderr = self.cli(
            [
                "run",
                "--project",
                str(self.repo),
                "--agent",
                "claude",
                "--agent",
                "codex",
                "--no-memory",
                "--quiet",
                "--timeout",
                "10",
                "implement the fixture",
            ]
        )
        elapsed = time.monotonic() - started
        self.assertEqual(code, 0, stderr)
        self.assertIn("status:  completed", stdout)
        states = CLI.load_run_states(self.home)
        self.assertEqual(len(states), 1)
        state = states[0]
        self.assertEqual(state["status"], "completed")
        self.assertEqual(len(state["agents"]), 2)
        worktrees = {agent["worktree"] for agent in state["agents"]}
        branches = {agent["branch"] for agent in state["agents"]}
        self.assertEqual(len(worktrees), 2)
        self.assertEqual(len(branches), 2)
        intervals = []
        for path in worktrees:
            payload = json.loads((pathlib.Path(path) / "agent-output.json").read_text())
            self.assertTrue(payload["prompt_has_task"])
            intervals.append((payload["started"], payload["finished"]))
        self.assertLess(max(start for start, _ in intervals), min(end for _, end in intervals))
        self.assertLess(elapsed, 2.0)
        run_text = (self.home / "runs" / state["run_id"] / "state.json").read_text()
        self.assertNotIn("must-not-reach-workers", run_text)

    def test_dirty_project_is_rejected_before_workers_start(self):
        self.register()
        (self.repo / "README.md").write_text("dirty\n", encoding="utf-8")
        code, _, stderr = self.cli(
            [
                "run",
                "--project",
                str(self.repo),
                "--agent",
                "claude",
                "--no-memory",
                "task",
            ]
        )
        self.assertEqual(code, 2)
        self.assertIn("uncommitted changes", stderr)
        state = CLI.load_run_states(self.home)[0]
        self.assertEqual(state["status"], "failed")

    def test_single_agent_can_use_explicit_in_place_mode(self):
        self.register()
        code, _, stderr = self.cli(
            [
                "run",
                "--project",
                str(self.repo),
                "--agent",
                "codex",
                "--no-memory",
                "--in-place",
                "task",
            ]
        )
        self.assertEqual(code, 0, stderr)
        state = CLI.load_run_states(self.home)[0]
        self.assertEqual(state["agents"][0]["worktree"], str(self.repo.resolve()))

    def test_large_prompt_and_early_output_do_not_deadlock(self):
        self.register()
        self.environment["BYORI_TEST_MODE"] = "early-output"
        code, _, stderr = self.cli(
            [
                "run",
                "--project",
                str(self.repo),
                "--agent",
                "claude",
                "--no-memory",
                "--quiet",
                "--timeout",
                "10",
                "x" * 900_000,
            ]
        )
        self.assertEqual(code, 0, stderr)
        self.assertEqual(CLI.load_run_states(self.home)[0]["status"], "completed")

    def test_oversized_json_event_fails_agent_without_stale_running_state(self):
        self.register()
        self.environment["BYORI_TEST_MODE"] = "oversize"
        code, _, stderr = self.cli(
            [
                "run",
                "--project",
                str(self.repo),
                "--agent",
                "codex",
                "--no-memory",
                "--quiet",
                "--timeout",
                "10",
                "task",
            ]
        )
        self.assertEqual(code, 1, stderr)
        state = CLI.load_run_states(self.home)[0]
        self.assertEqual(state["status"], "failed")
        self.assertEqual(state["agents"][0]["status"], "failed")
        self.assertIn("limit", state["agents"][0]["error"])

    def test_committed_agent_result_is_captured_against_base_revision(self):
        self.register()
        self.environment["BYORI_TEST_MODE"] = "commit"
        code, _, stderr = self.cli(
            [
                "run",
                "--project",
                str(self.repo),
                "--agent",
                "codex",
                "--no-memory",
                "--quiet",
                "task",
            ]
        )
        self.assertEqual(code, 0, stderr)
        state = CLI.load_run_states(self.home)[0]
        agent = state["agents"][0]
        self.assertEqual(agent["commit_count"], "1")
        self.assertNotEqual(agent["after_sha"], state["base_sha"])
        self.assertIn("agent-output.json", agent["commit_diff_stat"])

    def test_sigterm_cancels_worker_process_group_and_finalizes_state(self):
        self.register()
        environment = dict(os.environ)
        environment.update(self.environment)
        environment["BYORI_TEST_MODE"] = "hang"
        coordinator = subprocess.Popen(
            [
                sys.executable,
                str(ROOT / "cli" / "byori.py"),
                "run",
                "--project",
                str(self.repo),
                "--agent",
                "claude",
                "--no-memory",
                "--quiet",
                "--timeout",
                "60",
                "task",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        worker_pids = None
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                states = CLI.load_run_states(self.home)
                if states and states[0]["agents"][0].get("worktree"):
                    pid_file = pathlib.Path(states[0]["agents"][0]["worktree"]) / "worker-pids.json"
                    if pid_file.exists():
                        worker_pids = json.loads(pid_file.read_text())
                        break
                time.sleep(0.05)
            self.assertIsNotNone(worker_pids, "worker did not reach running state")
            coordinator.send_signal(signal.SIGTERM)
            coordinator.communicate(timeout=15)
            self.assertEqual(coordinator.returncode, 128 + signal.SIGTERM)
            state = CLI.load_run_states(self.home)[0]
            self.assertEqual(state["status"], "cancelled")
            self.assertEqual(state["agents"][0]["status"], "cancelled")

            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                alive = []
                for pid in worker_pids.values():
                    try:
                        os.kill(pid, 0)
                        alive.append(pid)
                    except ProcessLookupError:
                        pass
                if not alive:
                    break
                time.sleep(0.05)
            self.assertFalse(alive, "worker process group survived coordinator SIGTERM")
        finally:
            if coordinator.poll() is None:
                coordinator.kill()
                coordinator.communicate(timeout=5)
            if worker_pids:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(worker_pids["worker"], signal.SIGKILL)

    def test_partial_worktree_setup_rolls_back_on_keyboard_interrupt(self):
        agents = CLI.unique_agent_specs(["claude", "codex"])
        with (
            mock.patch.object(CLI, "git_output", return_value=""),
            mock.patch.object(
                CLI,
                "command_output",
                side_effect=["", KeyboardInterrupt()],
            ),
            mock.patch.object(CLI.subprocess, "run") as cleanup,
        ):
            with self.assertRaises(KeyboardInterrupt):
                CLI.prepare_worktrees(
                    self.home,
                    self.repo,
                    "run-id",
                    agents,
                    "a" * 40,
                    False,
                )
        commands = [call.args[0] for call in cleanup.call_args_list]
        self.assertTrue(any("worktree" in command and "remove" in command for command in commands))
        self.assertTrue(any("branch" in command and "-D" in command for command in commands))


class CheckpointTests(unittest.TestCase):
    def test_coordinator_promotes_only_project_and_task_records(self):
        module = mock.Mock()
        bridge = object.__new__(CLI.MemoryBridge)
        bridge.module = module
        project = {
            "id": "abc123",
            "name": "sample",
            "remote": "https://example.invalid/sample",
            "space": "sample_memory",
        }
        run_state = {
            "run_id": "run123",
            "base_sha": "deadbeef",
            "status": "completed",
            "prompt": "Implement a bounded feature",
            "agents": [
                {
                    "label": "codex",
                    "provider": "codex",
                    "status": "completed",
                    "exit_code": 0,
                    "branch": "byori/run123/codex",
                    "diff_stat": "one file changed",
                }
            ],
        }
        bridge.checkpoint_start(project, run_state)
        bridge.checkpoint_finish(run_state)

        calls = [call.args[0] for call in module.tool_wiki_upsert.call_args_list]
        self.assertEqual([item["type"] for item in calls], ["entity", "task", "task"])
        self.assertEqual(calls[-1]["state"], "done")
        self.assertNotIn("stdout", calls[-1]["body"])
        module.tool_link.assert_called_once()


if __name__ == "__main__":
    unittest.main()
