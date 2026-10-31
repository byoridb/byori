#!/usr/bin/env python3
"""Black-box lease contract for the real installer; no engine or live services.

Run: python3 -m unittest discover -s tests -p test_install_runtime_lease.py -v

Only temporary homes are used. PATH is an allowlist, not the developer's PATH.
Every network/service/vendor executable is a recording stub; curl synthesizes
health/auth replies without opening a socket. The local engine only records and
exits, or waits at an explicitly bounded fixture gate for the lifetime test
(the historical --no-service flag still starts its wrapper). Assets come
from this checkout. No source-text assertions or protocol implementation mocks.
"""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
SECRET = "fixture-only-private-credential-DO-NOT-PRINT"
LOCK = ".runtime-mutation.lock"

# Dup only in a fresh child, before exec; never clobber fd 9 in the test runner.
# pass_fds preserves the parent's exact flock open-file description. No preexec_fn
# (unsafe with threads), reopening through /dev/fd, or separate lock acquisition.
DELEGATE = """
import os, sys
fd = int(sys.argv[1])
if fd >= 0:
    os.dup2(fd, 9, inheritable=True)
    if fd != 9:
        os.close(fd)
else:
    try:
        os.close(9)
    except OSError:
        pass
os.execv(sys.argv[2], sys.argv[2:])
"""

# Installed under multiple names, with an absolute Python shebang. Deliberately
# never import a network client or execute a vendor/service command.
STUB = r'''
import json, os, pathlib, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
event = {"command": name, "run": os.environ.get("FIXTURE_RUN", "one")}
if name == "byoridb-server":
    event["inherited_lease_flag"] = "BYORI_RUNTIME_LEASE_FD" in os.environ
    try:
        descriptor = os.fstat(9)
        lease_path = os.stat(pathlib.Path(os.environ["BYORIDB_HOME"]) / ".runtime-mutation.lock")
        event["inherited_runtime_lease"] = (descriptor.st_dev, descriptor.st_ino) == (lease_path.st_dev, lease_path.st_ino)
    except OSError:
        event["inherited_runtime_lease"] = False
# Do not log arguments: auth bodies/env may contain the sentinel credential.
with open(os.environ["FIXTURE_EVENTS"], "a") as out:
    out.write(json.dumps(event) + "\n")
def wait_at_gate():
    gate = os.environ.get("FIXTURE_GATE")
    if not gate:
        return
    pathlib.Path(gate + ".entered").touch()
    deadline = time.monotonic() + 25
    while not pathlib.Path(gate + ".release").exists():
        if time.monotonic() >= deadline:
            raise SystemExit(96)
        time.sleep(0.02)
if name == "cp":
    if os.environ.get("FIXTURE_GATE_PHASE", "staging") == "staging" and args and args[0].endswith("/mcp/byoridb_mcp.py"):
        wait_at_gate()
    os.execv("/bin/cp", ["/bin/cp", *args])
if name == "curl":
    url = next((arg for arg in args if arg.startswith(("http://", "https://"))), "")
    if url.startswith("http://127.0.0.1:19669/"):
        if url.endswith("/health"):
            raise SystemExit(0)
        if "/api/v1/session" in url:
            if os.environ.get("FIXTURE_GATE_PHASE") == "verification" and "DELETE" in args:
                wait_at_gate()
            if "-o" in args:
                pathlib.Path(args[args.index("-o") + 1]).write_text('{"session_id": 17}')
            if "-w" in args:
                sys.stdout.write("200")
            raise SystemExit(0)
    # Even --engine-tag latest and missing --binary must never reach a network.
    raise SystemExit(22)
if name == "byoridb-server" and os.environ.get("FIXTURE_ENGINE_LIFETIME"):
    # A fixture-only lifetime lock proves this child remains alive without PID
    # probes/signals. It is entirely separate from the runtime writer lease.
    import fcntl
    lifetime = os.environ["FIXTURE_ENGINE_LIFETIME"]
    descriptor = os.open(lifetime, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        pathlib.Path(lifetime + ".ready").touch()
        deadline = time.monotonic() + 25
        while not pathlib.Path(lifetime + ".release").exists():
            if time.monotonic() >= deadline:
                raise SystemExit(96)
            time.sleep(0.02)
    finally:
        os.close(descriptor)
        pathlib.Path(lifetime + ".exited").touch()
if name in ("launchctl", "systemctl", "codesign", "byoridb-server"):
    raise SystemExit(0)
raise SystemExit(97)
'''


@unittest.skipUnless(os.name == "posix", "requires real POSIX flock and fd inheritance")
class InstallRuntimeLeaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="byori-lease-test-")
        # macOS /var is an alias; the runtime under test uses canonical paths.
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(self.temporary.cleanup)
        self.home = self.root / "home"
        self.runtime = self.root / "runtime"
        self.stub = self.root / "commands"
        self.tmp = self.root / "tmp"
        for directory in (self.home, self.runtime, self.stub, self.tmp):
            directory.mkdir(mode=0o700)
        self.lock = self.runtime / LOCK
        self.events_path = self.root / "events.jsonl"
        self.events_path.touch()
        # No inherited credentials, proxy settings, BASH_ENV, PYTHONPATH, engine
        # options, service label, or agent profile overrides can affect a run.
        self.env = {
            "HOME": str(self.home), "BYORIDB_HOME": str(self.runtime),
            "PATH": str(self.stub), "TMPDIR": str(self.tmp), "LC_ALL": "C",
            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
            "FIXTURE_EVENTS": str(self.events_path), "FIXTURE_RUN": "one",
        }
        for name in (
            "bash", "sh", "uname", "id", "tar", "awk", "sed", "grep", "mkdir",
            "chmod", "mktemp", "rm", "mv", "dirname", "basename", "date", "cat",
            "ln", "readlink", "cmp", "seq", "sleep", "tail", "shasum", "sha256sum",
            "stat", "touch", "head", "tr", "wc", "sort", "cut", "find", "flock",
        ):
            executable = shutil.which(name, path="/usr/bin:/bin:/usr/sbin:/sbin")
            if executable:
                (self.stub / name).symlink_to(executable)
        (self.stub / "python3").symlink_to(sys.executable)
        for name in (
            "cp", "curl", "wget", "launchctl", "systemctl", "service", "sudo",
            "claude", "codex", "gh", "git", "npm", "npx", "brew", "uv", "pip",
            "pip3", "ssh", "scp", "nc", "open", "osascript", "codesign",
        ):
            self.executable(self.stub / name, STUB)
        self.binary = self.root / "byoridb-server"
        self.executable(self.binary, STUB)
        (self.runtime / "env").write_text(f"BYORIDB_ROOT_PASSWORD={SECRET}\n")
        (self.runtime / "env").chmod(0o600)
        (self.runtime / "data").mkdir(mode=0o700)
        (self.runtime / "data" / "original").write_bytes(b"not-an-engine-database\x00")
        for name in (".claude/settings.json", ".codex/config.toml", ".agents/skills/user/SKILL.md", ".zshrc"):
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("user-owned fixture; do not modify\n")
        self.profile_before = self.tree(self.home)
        self.processes = []
        # Registered last so processes are reaped before their temporary tree.
        self.addCleanup(self.cleanup_processes)

    def executable(self, path, source):
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o700)

    def cleanup_processes(self):
        for process in self.processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)

    def tree(self, directory):
        """Bytes, identities and modes, without following symlinks or reading FIFOs."""
        result = {}
        for path in [directory, *sorted(directory.rglob("*"))]:
            info = path.lstat()
            payload = None
            if stat.S_ISLNK(info.st_mode):
                payload = os.readlink(path)
            elif stat.S_ISREG(info.st_mode):
                payload = path.read_bytes()
            result[str(path.relative_to(directory))] = (
                info.st_dev, info.st_ino, info.st_mode, info.st_nlink, payload,
            )
        return result

    def events(self):
        return [json.loads(line) for line in self.events_path.read_text().splitlines()]

    @contextlib.contextmanager
    def lease(self, path=None, locked=True):
        descriptor = os.open(path or self.lock, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            if locked:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield descriptor
        finally:
            # close, never LOCK_UN: the delegated child shares this description.
            os.close(descriptor)

    def start(self, *extra, fd=None, inherited=None, service=False, pipe=False, **environment):
        env = dict(self.env, **environment)
        if inherited is not None:
            env["BYORI_RUNTIME_LEASE_FD"] = inherited
        arguments = [
            "--assets", str(ROOT), "--binary", str(self.binary),
            "--no-claude", "--no-codex", "--no-hooks",
        ]
        if not service:
            arguments.append("--no-service")
        arguments.extend(extra)
        command = ["/bin/bash", str(INSTALLER), *arguments]
        if pipe:
            command = [
                "/bin/bash", "-o", "pipefail", "-c",
                'cat "$1" | /bin/bash -s -- "${@:2}"',
                "fixture-pipe", str(INSTALLER), *arguments,
            ]
        if fd is not None or inherited is not None:
            command = [sys.executable, "-c", DELEGATE, str(fd if fd is not None else -1), *command]
        process = subprocess.Popen(
            command, cwd=self.root, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            pass_fds=() if fd is None else (fd,), start_new_session=True,
        )
        self.processes.append(process)
        return process

    def finish(self, process, success=True):
        output, _ = process.communicate(timeout=15)
        self.assertNotIn(SECRET, output, "installer leaked fixture credential")
        self.assertNotIn("Traceback (most recent call last)", output)
        self.assertNotIn("Bad file descriptor", output)
        if success:
            self.assertEqual(process.returncode, 0, output)
        else:
            self.assertNotEqual(process.returncode, 0, output)
        return output

    def assert_rejected_untouched(self, *extra, busy=False, **options):
        runtime_before, home_before = self.tree(self.runtime), self.tree(self.home)
        event_count = len(self.events())
        output = self.finish(self.start(*extra, **options), success=False)
        self.assertRegex(output.lower(), r"busy|lease|lock|runtime|private|permission|unsafe")
        if busy:
            self.assertRegex(output.lower(), r"busy|in progress|another.*(operation|process)|retry")
        self.assertEqual(self.events()[event_count:], [], "preflight ran staging/network/service/engine commands")
        self.assertEqual(self.tree(self.runtime), runtime_before, "rejected installer modified runtime or lock")
        self.assertEqual(self.tree(self.home), home_before, "rejected installer modified home/profiles")
        return output

    def assert_installed(self):
        self.assertEqual((self.runtime / "bin/byoridb-server").read_bytes(), self.binary.read_bytes())
        manifest = json.loads((self.runtime / "engine.json").read_text())
        self.assertEqual(manifest["sha256"], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.assertEqual(manifest["source"], "local-binary")
        self.assertIn(SECRET, (self.runtime / "env").read_text())
        self.assertEqual((self.runtime / "data/original").read_bytes(), b"not-an-engine-database\x00")
        for relative, before in self.profile_before.items():
            if relative != ".":
                self.assertEqual(self.tree(self.home)[relative], before)
        self.assertFalse({e["command"] for e in self.events()} & {"claude", "codex", "launchctl", "systemctl"})

    def test_ordinary_local_install_preserves_flags_profiles_secret_and_data(self):
        self.finish(self.start())
        self.assert_installed()
        self.assertTrue(self.lock.is_file())
        self.assertEqual(stat.S_IMODE(self.lock.stat().st_mode), 0o600)
        self.assertEqual(self.lock.stat().st_nlink, 1)

    def test_standalone_stdin_pipe_install_acquires_its_own_lease(self):
        self.finish(self.start(pipe=True))
        self.assert_installed()
        self.assertTrue(self.lock.is_file())
        with self.lease():
            self.assert_rejected_untouched(pipe=True, busy=True)

    def test_background_engine_does_not_inherit_runtime_lease(self):
        self.finish(self.start())
        engine_events = [event for event in self.events() if event["command"] == "byoridb-server"]
        self.assertTrue(engine_events, "--no-service fixture must exercise the background wrapper")
        self.assertFalse(
            any(event["inherited_runtime_lease"] for event in engine_events),
            "a persistent background engine would hold the installer flock after installation exits",
        )
        self.assertFalse(any(event["inherited_lease_flag"] for event in engine_events))

    def test_long_lived_fake_child_does_not_block_another_real_installer(self):
        for pipe in (False, True):
            with self.subTest(pipe=pipe):
                lifetime = self.root / f"fake-child-lifetime-{pipe}"
                event_count = len(self.events())
                try:
                    self.finish(self.start(pipe=pipe, FIXTURE_ENGINE_LIFETIME=str(lifetime)))
                    deadline = time.monotonic() + 5
                    while not Path(str(lifetime) + ".ready").exists():
                        self.assertLess(time.monotonic(), deadline, "fake child never became ready")
                        time.sleep(0.02)
                    self.assert_fake_child_alive(lifetime)
                    engine_events = [event for event in self.events()[event_count:]
                                     if event["command"] == "byoridb-server"]
                    self.assertEqual(len(engine_events), 1)
                    self.assertFalse(engine_events[0]["inherited_runtime_lease"])
                    self.assertFalse(engine_events[0]["inherited_lease_flag"])
                    inode = self.lock.stat().st_ino
                    # The first installer has exited, but its background child
                    # is still alive. The next installer must acquire the same
                    # lock inode immediately and finish, not wait for that child.
                    self.finish(self.start(pipe=pipe))
                    self.assertEqual(self.lock.stat().st_ino, inode)
                    self.assert_fake_child_alive(lifetime)
                    self.assert_installed()
                finally:
                    Path(str(lifetime) + ".release").touch()
                    if Path(str(lifetime) + ".ready").exists():
                        deadline = time.monotonic() + 5
                        while not Path(str(lifetime) + ".exited").exists():
                            self.assertLess(time.monotonic(), deadline, "fake child did not exit after release")
                            time.sleep(0.02)

    def assert_fake_child_alive(self, lifetime):
        descriptor = os.open(lifetime, os.O_RDWR)
        try:
            with self.assertRaises(BlockingIOError, msg="fake child must remain alive and hold its lifetime lock"):
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(descriptor)

    def test_local_binary_reinstall_preserves_user_cli_file_and_replaces_by_rename(self):
        cli = self.home / ".local/bin/byori"
        cli.parent.mkdir(parents=True)
        cli.write_text("user-owned CLI; leave alone\n")
        cli_identity = cli.stat().st_ino
        (self.runtime / "bin").mkdir()
        previous = self.runtime / "bin/byoridb-server"
        self.executable(previous, "raise SystemExit(98)\n")
        old_identity = previous.stat().st_ino
        self.finish(self.start("--tag", "fixture-local", "--engine-tag", "v0.4.2"))
        self.assert_installed()
        self.assertEqual(cli.read_text(), "user-owned CLI; leave alone\n")
        self.assertEqual(cli.stat().st_ino, cli_identity)
        self.assertNotEqual(previous.stat().st_ino, old_identity)
        installed_identity = previous.stat().st_ino
        self.finish(self.start())
        self.assertEqual(previous.stat().st_ino, installed_identity, "same bytes should not replace the engine")
        self.assert_installed()

    def test_busy_os_flock_precedes_all_runtime_mutations_and_retry_after_close(self):
        with self.lease():
            self.assert_rejected_untouched(busy=True)
        inode = self.lock.stat().st_ino
        self.finish(self.start())
        self.assert_installed()
        self.assertEqual(self.lock.stat().st_ino, inode, "lease path must never be recreated")

    def test_busy_precedes_latest_version_probe(self):
        with self.lease():
            self.assert_rejected_untouched("--engine-tag", "latest", busy=True)

    def test_busy_precedes_engine_download_in_explicit_download_case(self):
        with self.lease():
            self.assert_rejected_untouched("--binary", "", busy=True)

    def test_busy_precedes_service_commands_in_explicit_service_case(self):
        agent = self.home / "Library/LaunchAgents/com.byoridb.local.plist"
        agent.parent.mkdir(parents=True)
        agent.write_text("previous service fixture")
        with self.lease():
            self.assert_rejected_untouched(service=True, busy=True)

    def test_busy_uninstall_cannot_mutate_runtime_or_call_service_vendor_stubs(self):
        # No data => no /dev/tty prompt, including with the pre-protocol installer.
        (self.runtime / "data/original").unlink()
        (self.runtime / "data").rmdir()
        with self.lease():
            self.assert_rejected_untouched("--uninstall", service=True, busy=True)

    def test_delegated_uninstall_keeps_root_and_lock_inode_and_parent_ownership(self):
        # Explicit service/vendor stub case; never asks for data deletion.
        (self.runtime / "data/original").unlink()
        (self.runtime / "data").rmdir()
        with self.lease() as fd:
            identity = (self.runtime.stat().st_ino, self.lock.stat().st_ino)
            self.finish(self.start("--uninstall", fd=fd, inherited="9", service=True))
            self.assertTrue(self.runtime.is_dir(), "uninstall must not split the root namespace")
            self.assertTrue(self.lock.is_file(), "uninstall must not unlink its lease")
            self.assertEqual((self.runtime.stat().st_ino, self.lock.stat().st_ino), identity)
            self.assert_rejected_untouched(busy=True)

    def test_valid_delegated_fd9_keeps_parent_lease_through_direct_and_pipe_paths(self):
        for pipe in (False, True):
            with self.subTest(pipe=pipe), self.lease() as fd:
                self.finish(self.start(fd=fd, inherited="9", pipe=pipe))
                self.assert_installed()
                # Child exit must not explicitly unlock the caller's description.
                self.assert_rejected_untouched(busy=True)

    def test_absent_invalid_or_non9_inherited_descriptor_is_not_a_bypass(self):
        for value in ("9", "8", "-1", "garbage", "9;echo injected"):
            with self.subTest(value=value):
                # Create the path first: absolutely no writes allowed on rejection.
                self.lock.touch(mode=0o600, exist_ok=True)
                self.assert_rejected_untouched(inherited=value)

    def test_non9_claim_rejects_even_when_descriptor9_is_legitimate(self):
        with self.lease() as fd:
            self.assert_rejected_untouched(fd=fd, inherited="8")

    def test_different_open_description_cannot_bypass_a_busy_file(self):
        with self.lease(), self.lease(locked=False) as fd:
            self.assert_rejected_untouched(fd=fd, inherited="9", busy=True)

    def test_wrong_file_and_mismatching_runtime_home_reject_delegation(self):
        other = self.root / "other-runtime"
        other.mkdir(mode=0o700)
        for path in (self.root / "unrelated-file", other / LOCK):
            with self.subTest(path=path.name), self.lease(path) as fd:
                self.lock.touch(mode=0o600, exist_ok=True)
                self.assert_rejected_untouched(fd=fd, inherited="9")

    def test_replaced_lock_path_does_not_match_inherited_open_inode(self):
        with self.lease() as fd:
            self.lock.rename(self.runtime / "old-lock")
            self.lock.touch(mode=0o600)
            self.assert_rejected_untouched(fd=fd, inherited="9")

    def test_unsafe_lock_modes_are_not_repaired_or_truncated(self):
        for mode in (0o644, 0o666, 0o640):
            for delegated in (False, True):
                with self.subTest(mode=oct(mode), delegated=delegated), self.lease(locked=delegated) as fd:
                    self.lock.write_text("unchanged lock contents")
                    self.lock.chmod(mode)
                    self.assert_rejected_untouched(**({"fd": fd, "inherited": "9"} if delegated else {}))
                self.lock.chmod(0o600)

    def test_symlink_and_hardlink_locks_rejected_with_and_without_fd(self):
        for kind in ("symlink", "hardlink"):
            for delegated in (False, True):
                with self.subTest(kind=kind, delegated=delegated):
                    target = self.root / f"{kind}-{delegated}"
                    target.write_text("lock target must survive")
                    target.chmod(0o600)
                    if kind == "symlink":
                        self.lock.symlink_to(target)
                    else:
                        os.link(target, self.lock)
                    try:
                        with self.lease(target, locked=delegated) as fd:
                            self.assert_rejected_untouched(**({"fd": fd, "inherited": "9"} if delegated else {}))
                        self.assertEqual(target.read_text(), "lock target must survive")
                        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
                    finally:
                        self.lock.unlink()

    def test_lock_and_root_modes_match_the_native_exact_private_mode_contract(self):
        for mode in (0o700, 0o1600, 0o4600):
            with self.subTest(lock_mode=oct(mode)), self.lease(locked=False):
                self.lock.chmod(mode)
                try:
                    self.assert_rejected_untouched()
                finally:
                    self.lock.chmod(0o600)
        self.runtime.chmod(0o1700)
        try:
            self.assert_rejected_untouched()
        finally:
            self.runtime.chmod(0o700)

    def test_nonregular_lock_path_and_descriptor_are_rejected_without_hanging(self):
        self.lock.mkdir(mode=0o700)
        self.assert_rejected_untouched()
        fd = os.open(self.lock, os.O_RDONLY)
        try:
            self.assert_rejected_untouched(fd=fd, inherited="9")
        finally:
            os.close(fd)

    def test_fifo_lock_is_rejected_without_blocking_open(self):
        os.mkfifo(self.lock, mode=0o600)
        self.assert_rejected_untouched()

    def test_absent_runtime_root_and_lock_are_created_private(self):
        fresh = self.root / "fresh-runtime"
        self.finish(self.start(BYORIDB_HOME=str(fresh)))
        self.assertEqual(stat.S_IMODE(fresh.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((fresh / LOCK).stat().st_mode), 0o600)
        self.assertEqual((fresh / LOCK).stat().st_nlink, 1)
        self.assertTrue((fresh / "engine.json").is_file())

    def test_symlink_world_readable_and_home_runtime_roots_are_rejected(self):
        self.lock.touch(mode=0o600)
        alias = self.root / "runtime-alias"
        alias.symlink_to(self.runtime, target_is_directory=True)
        self.assert_rejected_untouched(BYORIDB_HOME=str(alias))
        self.runtime.chmod(0o755)
        try:
            self.assert_rejected_untouched()
        finally:
            self.runtime.chmod(0o700)
        self.assert_rejected_untouched(BYORIDB_HOME=str(self.home))

    def test_lock_file_contents_are_not_pid_liveness_or_stale_lock_authority(self):
        self.lock.write_text("999999999\nnot-a-pid\n")
        self.lock.chmod(0o600)
        before = self.lock.stat().st_ino
        self.finish(self.start())
        self.assertEqual(self.lock.read_text(), "999999999\nnot-a-pid\n")
        self.assertEqual(self.lock.stat().st_ino, before)

    def test_lease_holder_process_exit_releases_lock_for_real_installer_retry(self):
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600); "
             "fcntl.flock(fd,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.read()",
             str(self.lock)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, start_new_session=True, env=self.env,
        )
        self.processes.append(holder)
        self.assertEqual(holder.stdout.readline().strip(), "locked")
        inode = self.lock.stat().st_ino
        self.assert_rejected_untouched(busy=True)
        holder.communicate(input="", timeout=5)
        self.assertEqual(holder.returncode, 0)
        self.finish(self.start())
        self.assertEqual(self.lock.stat().st_ino, inode)
        self.assert_installed()

    def test_two_real_installers_do_not_interleave_and_retry_after_first_exit(self):
        self.check_two_installers("staging")

    def test_lease_remains_held_through_final_authenticated_verification(self):
        self.check_two_installers("verification")

    def check_two_installers(self, phase):
        gate = self.root / f"{phase}-gate"
        first = self.start(FIXTURE_RUN="first", FIXTURE_GATE=str(gate), FIXTURE_GATE_PHASE=phase)
        deadline = time.monotonic() + 10
        while not Path(str(gate) + ".entered").exists():
            if first.poll() is not None:
                self.fail("first installer did not reach fixture gate: " + first.communicate()[0])
            if time.monotonic() > deadline:
                self.fail("first installer did not reach fixture gate in time")
            time.sleep(0.02)
        try:
            self.assert_rejected_untouched(FIXTURE_RUN="second", busy=True)
            self.assertEqual({e["run"] for e in self.events()}, {"first"})
        finally:
            Path(str(gate) + ".release").touch()
        self.finish(first)
        self.finish(self.start(FIXTURE_RUN="retry"))
        self.assert_installed()


if __name__ == "__main__":
    unittest.main()
