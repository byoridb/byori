"""Independent refresh contract checks using real, isolated Git repositories.

Only this test file belongs to the refresh verifier.  The coordinator may not
exist when this file first lands: defer its import until setUpClass and report
that condition as an explicit skip, never substitute a production module.
Source collection, journal verification, compilation and publication are real.
"""

import fcntl
import importlib
import json
import multiprocessing
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cli"))
import handbook
import handbook_records


def tree_snapshot(root):
    """Capture bytes, modes and mtimes; ignore access times changed by reads."""
    result = {}
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        relative = path.relative_to(root).as_posix()
        if stat.S_ISLNK(info.st_mode):
            value = ("link", os.readlink(path))
        elif stat.S_ISREG(info.st_mode):
            value = ("file", path.read_bytes(), info.st_mtime_ns)
        else:
            value = ("directory",)
        result[relative] = (stat.S_IMODE(info.st_mode), value)
    return result


def refresh_worker(root, channel, gate=None, options=None, cancel_event=None):
    """Pause only scheduling: all source/compiler/publication work stays real."""
    try:
        coordinator = importlib.import_module("handbook_refresh")
        original_atomic = handbook._atomic
        original_quiet = coordinator._quiet
        paused = False

        def pause(label):
            nonlocal paused
            if not paused:
                paused = True
                channel.send(("paused", label))
                if not channel.poll(15):
                    raise AssertionError("parent did not release the compiler gate")
                if channel.recv() != "continue":
                    raise AssertionError("invalid gate release")

        def quiet_real(*args, **kwargs):
            # Exactly after the coordinator's captured build, not compilation
            # performed by either of its preliminary guarded reads.
            if gate == "compiled":
                pause("compiled")
            return original_quiet(*args, **kwargs)

        def atomic_real(fd, name, text):
            result = original_atomic(fd, name, text)
            if gate == "staged" and name == "evidence.json":
                pause("staged")
            return result

        with mock.patch.object(handbook, "_atomic", side_effect=atomic_real), \
                mock.patch.object(coordinator, "_quiet", side_effect=quiet_real):
            arguments = dict(options or {})
            if cancel_event is not None:
                arguments["cancelled"] = cancel_event.is_set
            result = coordinator.refresh_handbook(pathlib.Path(root), automatic=True, **arguments)
        channel.send(("result", result))
    except BaseException as exc:
        channel.send(("exception", type(exc).__name__, str(exc)))
    finally:
        channel.close()


class RefreshAdversarialTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (ROOT / "cli" / "handbook_refresh.py").is_file():
            raise unittest.SkipTest("main has not supplied cli/handbook_refresh.py yet")
        # Import failures in an existing implementation are real failures.
        cls.refresh = importlib.import_module("handbook_refresh")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="byori-refresh-verifier-")
        self.addCleanup(temporary.cleanup)
        self.base = pathlib.Path(temporary.name).resolve()
        self.root = self.base / "project"
        self.root.mkdir()
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_CONFIG_SYSTEM=os.devnull,
                           GIT_CONFIG_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0")
        env_patch = mock.patch.dict(os.environ, environment, clear=True)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        self.git("init", "-b", "main")
        self.write("README.md", "# Fixture\n\nRefresh baseline content.\n")
        self.write("docs/decision.md", "# Decision\n\nRETRACTABLE_MARKER_731.\n")
        self.git("add", ".")
        self.git("-c", "user.name=Refresh verifier", "-c",
                 "user.email=refresh@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-m", "Add synthetic documentation")

    def git(self, *arguments, root=None):
        return subprocess.run(
            ["git", "--no-pager", "-c", "core.hooksPath=/dev/null", "-c",
             "core.fsmonitor=false", "-C", str(root or self.root), *arguments],
            check=True, capture_output=True, text=True, timeout=10,
        ).stdout.strip()

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    @property
    def active(self):
        return self.root / ".byori" / "handbook.md"

    def publish(self):
        return handbook.publish_handbook(handbook.compile_handbook(self.root))

    def enable(self, **kwargs):
        return self.refresh.configure_refresh(self.root, enabled=True, **kwargs)

    def sync(self, **kwargs):
        return self.refresh.refresh_handbook(self.root, automatic=True, **kwargs)

    def cli(self, *arguments):
        environment = dict(os.environ,
                           BYORI_HOME=str(self.base / "isolated-cli-home"),
                           BYORIDB_HOME=str(self.base / "isolated-engine-home"))
        return subprocess.run(
            [sys.executable, "-B", str(ROOT / "cli" / "byori.py"), *arguments],
            capture_output=True, text=True, timeout=15, env=environment,
        )

    def assert_cli_success_without_excluded_body(self, process):
        # Never include stdout/stderr bodies in failure diagnostics.
        self.assertEqual(process.returncode, 0, "isolated CLI command failed")
        self.assertFalse("RETRACTABLE_MARKER_731" in process.stdout + process.stderr,
                         "CLI exposed an excluded synthetic source")
        result = json.loads(process.stdout)
        self.assertTrue("Refresh baseline content" in result["handbook"],
                        "control source was not compiled")
        self.assertLessEqual(len(result["handbook"]), 4096)
        return result

    def assert_withheld(self, response):
        self.assertIn("handbook", response)
        self.assertIsNone(response["handbook"], response)
        self.assertNotEqual(response["state"], "current", response)

    def import_original(self, body="JOURNAL_ORIGINAL_829", expected_revision=None):
        return handbook_records.import_records(self.root, {
            "complete": True,
            "source": {"kind": "synthetic-verifier", "snapshot": body},
            "records": [{"name": "decision:refresh", "type": "decision", "vid": "73",
                         "body": body, "scope": "checkout",
                         "provenance": {"locator": "synthetic:refresh"}}],
        }, expected_revision=expected_revision)

    def worker(self, gate=None, options=None, cancel_event=None):
        context = multiprocessing.get_context("spawn")
        channel, child_channel = context.Pipe()
        child = context.Process(target=refresh_worker,
                                args=(str(self.root), child_channel, gate, options, cancel_event),
                                daemon=True)
        child.start()
        child_channel.close()

        def cleanup():
            if child.is_alive():
                child.terminate()
            child.join(timeout=3)
            if child.is_alive():
                child.kill()
                child.join(timeout=3)
            channel.close()
        self.addCleanup(cleanup)
        return child, channel

    def receive(self, channel, kind="result", timeout=10):
        self.assertTrue(channel.poll(timeout), "refresh exceeded %.1fs test budget" % timeout)
        result = channel.recv()
        self.assertEqual(result[0], kind, result)
        return result[1]

    def stale_fixture(self):
        self.enable()
        first = self.sync()
        self.assertEqual(first["state"], "current")
        self.write("README.md", "# Fixture\n\nRACING_REPLACEMENT_223.\n")
        return self.active.read_bytes()

    def test_disabled_default_config_and_sync_do_not_write_anything(self):
        before = tree_snapshot(self.base)
        config = self.refresh.read_config(self.root)
        self.assertEqual(config["schema_version"], 1)
        self.assertIs(config["enabled"], False)
        self.assertIsNone(config["revision"])
        self.assertEqual(config["project_root"], str(self.root))
        self.assertRegex(config["checkout_id"], r"^[a-f0-9]{64}$")
        self.assertEqual(config["max_chars"], 12000)
        for name, expected in {"max_commits": 100, "max_files": 60,
                               "max_file_bytes": 65536, "max_total_bytes": 1048576}.items():
            self.assertEqual(config["source_limits"][name], expected)
        result = self.sync()
        self.assertEqual(result["refresh"], "disabled")
        self.assert_withheld(result)
        self.assertEqual(before, tree_snapshot(self.base))

    def test_disabled_current_read_is_nonmutating(self):
        build = self.publish()
        before = tree_snapshot(self.base)
        with mock.patch.object(handbook, "publish_handbook", wraps=handbook.publish_handbook) as publisher:
            result = self.sync()
        self.assertEqual(result["refresh"], "disabled")
        self.assertEqual(result["state"], "current")
        self.assertEqual(result["handbook"], build["handbook"])
        publisher.assert_not_called()
        self.assertEqual(before, tree_snapshot(self.base))

    def test_disabled_stale_read_withholds_old_body_and_preserves_generation(self):
        self.publish()
        self.write("README.md", "# Fixture\n\nChanged while disabled.\n")
        before = tree_snapshot(self.base)
        result = self.sync()
        self.assertEqual(result["refresh"], "disabled")
        self.assert_withheld(result)
        self.assertEqual(before, tree_snapshot(self.base))

    def test_explicit_refresh_does_not_implicitly_enable_automatic_mode(self):
        result = self.refresh.refresh_handbook(self.root, automatic=False)
        self.assertEqual(result["refresh"], "rebuilt")
        self.assertEqual(result["state"], "current")
        self.assertIn("Refresh baseline content", result["handbook"])
        self.assertIs(self.refresh.read_config(self.root)["enabled"], False)
        before = tree_snapshot(self.base)
        self.assertEqual(self.sync()["refresh"], "disabled")
        self.assertEqual(before, tree_snapshot(self.base))

    def test_enabled_second_sync_does_not_republish_immutable_generation(self):
        self.enable()
        first = self.sync()
        self.assertEqual(first["refresh"], "rebuilt")
        storage = self.root / ".byori"
        before = tree_snapshot(storage / "generations")
        active_before = self.active.stat()
        with mock.patch.object(handbook, "publish_handbook", wraps=handbook.publish_handbook) as publisher:
            second = self.sync()
        self.assertEqual(second["refresh"], "unchanged")
        self.assertEqual(second["state"], "current")
        self.assertEqual(second["generation"], first["generation"])
        self.assertEqual(second["handbook"], first["handbook"])
        publisher.assert_not_called()
        self.assertEqual(before, tree_snapshot(storage / "generations"))
        self.assertEqual(active_before.st_ino, self.active.stat().st_ino)
        self.assertEqual(active_before.st_mtime_ns, self.active.stat().st_mtime_ns)

    def test_stale_config_cas_cannot_reenable_after_a_completed_disable(self):
        first = self.enable()
        disabled = self.refresh.configure_refresh(
            self.root, enabled=False, expected_revision=first["revision"])
        before = tree_snapshot(self.base)
        with self.assertRaises((RuntimeError, ValueError)):
            self.refresh.configure_refresh(
                self.root, enabled=True, expected_revision=first["revision"])
        self.assertEqual(self.refresh.read_config(self.root), disabled)
        self.assertEqual(before, tree_snapshot(self.base))

    def test_identical_configuration_is_a_true_noop_but_real_mutations_get_new_revisions(self):
        initial = self.enable(debounce_ms=0)
        before = tree_snapshot(self.base)
        unchanged = self.enable(expected_revision=initial["revision"])
        self.assertEqual(unchanged, initial)
        self.assertEqual(before, tree_snapshot(self.base))
        disabled = self.refresh.configure_refresh(self.root, enabled=False)
        reenabled = self.enable()
        self.assertEqual(len({initial["revision"], disabled["revision"], reenabled["revision"]}), 3)
        with self.assertRaises(self.refresh.RefreshConflict):
            self.refresh.configure_refresh(self.root, enabled=False,
                                           expected_revision=initial["revision"])
        self.assertEqual(self.refresh.read_config(self.root), reenabled)

    def test_maximum_exclusion_list_cannot_install_an_unreadable_configuration(self):
        initial = self.enable(debounce_ms=0)
        policy_path = self.root / ".byori" / "refresh.json"
        before = policy_path.read_bytes()
        excluded = ["docs/%02d/" % index + "x" * 1015 + "/" for index in range(64)]
        self.assertTrue(all(len(value.encode("utf-8")) == 1024 for value in excluded))
        try:
            updated = self.enable(source_limits={"exclude_paths": excluded})
        except self.refresh.RefreshError:
            self.assertTrue(policy_path.read_bytes() == before,
                            "rejected oversized policy must preserve the prior config")
            self.assertTrue(self.refresh.read_config(self.root) == initial)
        else:
            self.assertTrue(self.refresh.read_config(self.root) == updated,
                            "a successful setter must leave a readable configuration")

    def test_source_change_and_retraction_propagate_without_deleting_history(self):
        self.enable()
        first = self.sync()
        self.assertIn("RETRACTABLE_MARKER_731", first["handbook"])
        generations = self.root / ".byori" / "generations"
        preserved = tree_snapshot(generations / first["generation"])
        self.write("README.md", "# Fixture\n\nREPLACEMENT_MARKER_941.\n")
        (self.root / "docs" / "decision.md").unlink()
        self.assert_withheld(handbook.read_handbook(self.root))
        result = self.sync()
        self.assertEqual(result["refresh"], "rebuilt")
        self.assertEqual(result["state"], "current")
        self.assertIn("REPLACEMENT_MARKER_941", result["handbook"])
        self.assertNotIn("RETRACTABLE_MARKER_731", result["handbook"])
        self.assertNotEqual(first["generation"], result["generation"])
        self.assertEqual(preserved, tree_snapshot(generations / first["generation"]))

    def test_missing_original_journal_never_becomes_an_empty_rebuild(self):
        self.import_original()
        self.enable()
        result = self.sync()
        self.assertIn("JOURNAL_ORIGINAL_829", result["handbook"])
        (self.root / ".byori" / "records").rename(self.base / "saved-journal")
        preserved = tree_snapshot(self.root / ".byori" / "generations")
        active_before = self.active.read_bytes()
        self.write("README.md", "# Fixture\n\nDirty source must not erase originals.\n")
        result = self.sync()
        self.assertEqual(result["refresh"], "failed")
        self.assert_withheld(result)
        self.assertEqual(active_before, self.active.read_bytes())
        self.assertEqual(preserved, tree_snapshot(self.root / ".byori" / "generations"))

    def test_missing_active_journal_pointer_preserves_originals_and_generation(self):
        self.import_original()
        self.enable()
        self.sync()
        pointer = self.root / ".byori" / "records" / "active.json"
        pointer.rename(self.base / "saved-pointer.json")
        before = self.active.read_bytes()
        journal_before = tree_snapshot(pointer.parent)
        result = self.sync()
        self.assertEqual(result["refresh"], "failed")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())
        self.assertEqual(journal_before, tree_snapshot(pointer.parent))

    def test_journal_revision_change_rebuilds_from_the_real_original(self):
        first = self.import_original()
        self.enable()
        self.sync()
        self.import_original("JOURNAL_REPLACEMENT_953", first["revision"])
        self.assert_withheld(handbook.read_handbook(self.root))
        result = self.sync()
        self.assertEqual(result["refresh"], "rebuilt")
        self.assertEqual(result["state"], "current")
        self.assertIn("JOURNAL_REPLACEMENT_953", result["handbook"])
        self.assertNotIn("JOURNAL_ORIGINAL_829", result["handbook"])

    def test_tampered_active_is_withheld_and_not_silently_overwritten(self):
        self.enable()
        self.sync()
        self.active.write_bytes(self.active.read_bytes() + b"MANUAL_TAMPER_421\n")
        before = self.active.read_bytes()
        result = self.sync()
        self.assertEqual(result["refresh"], "failed")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())

    def test_copied_checkout_cannot_inherit_consent_or_return_original_body(self):
        self.enable()
        self.sync()
        other = self.base / "copied-checkout"
        shutil.copytree(self.root, other)
        before = tree_snapshot(other)
        try:
            config = self.refresh.read_config(other)
        except (RuntimeError, ValueError):
            pass
        else:
            self.assertIs(config["enabled"], False, "copied consent must not auto-enable a new checkout")
        result = self.refresh.refresh_handbook(other, automatic=True)
        self.assert_withheld(result)
        self.assertEqual(before, tree_snapshot(other))

    def test_nested_root_uses_one_canonical_policy_and_output(self):
        first = self.enable()
        nested = self.root / "docs"
        self.assertEqual(self.refresh.read_config(nested), first)
        result = self.refresh.refresh_handbook(nested, automatic=True)
        self.assertEqual(result["state"], "current")
        self.assertTrue(self.active.is_file())
        self.assertFalse((nested / ".byori").exists())

    def test_refresh_leaves_project_host_files_and_other_checkout_untouched(self):
        self.write("AGENTS.md", "User-owned Codex instructions.\n")
        self.write("CLAUDE.md", "User-owned Claude instructions.\n")
        self.write(".mcp.json", '{"synthetic": true}\n')
        other = self.base / "unrelated-project"
        other.mkdir()
        self.git("init", "-b", "main", root=other)
        before_other = tree_snapshot(other)
        before = {name: (self.root / name).read_bytes()
                  for name in ("AGENTS.md", "CLAUDE.md", ".mcp.json")}
        self.enable()
        result = self.sync()
        self.assertEqual(result["state"], "current")
        self.assertEqual(before_other, tree_snapshot(other))
        self.assertEqual(before, {name: (self.root / name).read_bytes() for name in before})
        self.assertFalse((self.root / ".byori" / "connections").exists())

    def test_cooperative_process_contention_returns_bounded_busy_without_stale_body(self):
        before = self.stale_fixture()
        _, first = self.worker(gate="compiled")
        self.assertEqual(self.receive(first, "paused"), "compiled")
        start = time.monotonic()
        _, second = self.worker(options={"wait_timeout": 0.1})
        result = self.receive(second, timeout=5)
        self.assertLess(time.monotonic() - start, 5)
        self.assertEqual(result["refresh"], "busy")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())
        first.send("continue")
        completed = self.receive(first)
        self.assertEqual(completed["refresh"], "rebuilt")
        self.assertEqual(completed["state"], "current")
        self.assertIn("RACING_REPLACEMENT_223", completed["handbook"])

    def test_completed_disable_prevents_a_previously_started_job_publication(self):
        before = self.stale_fixture()
        _, channel = self.worker(gate="compiled")
        self.assertEqual(self.receive(channel, "paused"), "compiled")
        disabled = self.refresh.configure_refresh(self.root, enabled=False)
        self.assertIs(disabled["enabled"], False)
        self.assertEqual(before, self.active.read_bytes())
        channel.send("continue")
        result = self.receive(channel)
        self.assertIn(result["refresh"], {"disabled", "cancelled"})
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())
        self.assertIs(self.refresh.read_config(self.root)["enabled"], False)

    def test_terminated_process_preserves_last_complete_generation_and_releases_lock(self):
        before = self.stale_fixture()
        first_generation = self.root / ".byori" / "generations"
        generations_before = {path.name: tree_snapshot(path)
                              for path in first_generation.iterdir()}
        child, channel = self.worker(gate="staged")
        self.assertEqual(self.receive(channel, "paused"), "staged")
        self.assertEqual(before, self.active.read_bytes())
        child.terminate()
        child.join(timeout=3)
        self.assertFalse(child.is_alive())
        self.assertEqual(before, self.active.read_bytes())
        for generation, snapshot in generations_before.items():
            self.assertEqual(snapshot, tree_snapshot(first_generation / generation))
        # Any leftover status/lock files must not masquerade as a live owner.
        _, retry = self.worker()
        result = self.receive(retry)
        self.assertEqual(result["refresh"], "rebuilt")
        self.assertEqual(result["state"], "current")
        self.assertIn("RACING_REPLACEMENT_223", result["handbook"])

    def test_new_exclusion_withholds_old_body_even_with_automatic_refresh_disabled(self):
        self.enable(debounce_ms=0)
        first = self.sync()
        self.assertIn("RETRACTABLE_MARKER_731", first["handbook"])
        self.refresh.configure_refresh(
            self.root, enabled=False,
            source_limits={"exclude_paths": ["docs/decision.md"]})
        before = tree_snapshot(self.base)
        self.assert_withheld(handbook.read_handbook(self.root))
        evidence = handbook.read_evidence(self.root, first["generation"])
        self.assertIsNone(evidence["evidence"])
        self.assertNotEqual(evidence["state"], "current")
        result = self.sync()
        self.assertEqual(result["refresh"], "disabled")
        self.assert_withheld(result)
        self.assertEqual(before, tree_snapshot(self.base))
        self.assertEqual(self.active.read_text(), first["handbook"])

    def test_exclusion_prefix_does_not_exclude_similarly_named_sibling(self):
        self.write("docs/private/decision.md", "# Private\n\nWITHDRAW_DIRECTORY_427.\n")
        self.write("docs/privateer/decision.md", "# Sibling\n\nRETAIN_SIBLING_428.\n")
        self.git("add", "docs")
        self.enable(debounce_ms=0)
        first = self.sync()
        self.assertIn("WITHDRAW_DIRECTORY_427", first["handbook"])
        self.assertIn("RETAIN_SIBLING_428", first["handbook"])
        self.enable(source_limits={"exclude_paths": ["docs/private/"]})
        self.assert_withheld(handbook.read_handbook(self.root))
        second = self.sync()
        self.assertEqual(second["state"], "current")
        self.assertEqual(second["refresh"], "rebuilt")
        self.assertNotIn("WITHDRAW_DIRECTORY_427", second["handbook"])
        self.assertIn("RETAIN_SIBLING_428", second["handbook"])
        evidence = self.root / ".byori" / "generations" / second["generation"] / "evidence.json"
        self.assertNotIn("WITHDRAW_DIRECTORY_427", evidence.read_text())

    def test_invalid_exclusion_scope_is_rejected_before_any_write(self):
        before = tree_snapshot(self.base)
        for excluded in ("../README.md", "/etc", "docs/*", "docs/../README.md", "docs\\private"):
            with self.subTest(excluded=excluded), self.assertRaises(self.refresh.RefreshError):
                self.enable(source_limits={"exclude_paths": [excluded]})
            self.assertEqual(before, tree_snapshot(self.base))

    def test_changed_bounds_withhold_old_generation_before_rebuild(self):
        self.enable(debounce_ms=0)
        self.sync()
        self.enable(max_chars=2048)
        self.assert_withheld(handbook.read_handbook(self.root))
        result = self.sync()
        self.assertEqual(result["state"], "current")
        self.assertLessEqual(len(result["handbook"]), 2048)

    def test_exclusion_changed_during_job_prevents_old_policy_publication(self):
        before = self.stale_fixture()
        _, channel = self.worker(gate="compiled")
        self.receive(channel, "paused")
        self.enable(source_limits={"exclude_paths": ["docs/"]})
        self.assert_withheld(handbook.read_handbook(self.root))
        channel.send("continue")
        result = self.receive(channel)
        self.assertEqual(result["refresh"], "cancelled")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())

    def test_cancelled_before_start_makes_no_writes(self):
        before = tree_snapshot(self.base)
        result = self.sync(cancelled=lambda: True)
        self.assertEqual(result["refresh"], "cancelled")
        self.assert_withheld(result)
        self.assertEqual(before, tree_snapshot(self.base))

    def test_cancellation_after_guarded_read_does_not_return_the_old_body(self):
        self.enable(debounce_ms=0)
        self.sync()
        import threading
        cancelled = threading.Event()
        original_read = handbook.read_handbook

        def read_then_cancel(*args, **kwargs):
            result = original_read(*args, **kwargs)
            cancelled.set()
            return result

        before = self.active.read_bytes()
        with mock.patch.object(handbook, "read_handbook", side_effect=read_then_cancel):
            result = self.sync(cancelled=cancelled.is_set)
        self.assertEqual(result["refresh"], "cancelled")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())

    def test_cancel_during_compilation_preserves_previous_complete_generation(self):
        before = self.stale_fixture()
        cancelled = multiprocessing.get_context("spawn").Event()
        _, channel = self.worker(gate="compiled", cancel_event=cancelled)
        self.receive(channel, "paused")
        cancelled.set()
        channel.send("continue")
        result = self.receive(channel)
        self.assertEqual(result["refresh"], "cancelled")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())

    def test_cancellation_after_final_verification_withholds_the_new_body(self):
        self.stale_fixture()
        import threading
        cancelled = threading.Event()
        original_read = handbook.read_handbook

        def read_then_cancel_if_current(*args, **kwargs):
            result = original_read(*args, **kwargs)
            if result["state"] == "current":
                cancelled.set()
            return result

        with mock.patch.object(handbook, "read_handbook", side_effect=read_then_cancel_if_current):
            result = self.sync(cancelled=cancelled.is_set)
        self.assertTrue(cancelled.is_set(), "test must reach final verification")
        self.assertEqual(result["refresh"], "cancelled")
        self.assert_withheld(result)
        # Publication completed before cancellation; rollback is not authorized.
        self.assertEqual(handbook.read_handbook(self.root)["state"], "current")

    def test_disable_then_reenable_does_not_resurrect_a_previous_automatic_job(self):
        before = self.stale_fixture()
        _, channel = self.worker(gate="compiled")
        self.receive(channel, "paused")
        self.refresh.configure_refresh(self.root, enabled=False)
        self.enable()
        channel.send("continue")
        result = self.receive(channel)
        self.assertEqual(result["refresh"], "cancelled")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())

    def test_cancel_after_staging_prevents_the_single_activation_write(self):
        before = self.stale_fixture()
        cancelled = multiprocessing.get_context("spawn").Event()
        _, channel = self.worker(gate="staged", cancel_event=cancelled)
        self.receive(channel, "paused")
        cancelled.set()
        channel.send("continue")
        result = self.receive(channel)
        self.assertEqual(result["refresh"], "cancelled")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())

    def test_compiler_lock_contention_is_bounded_not_just_the_refresh_job_lock(self):
        before = self.stale_fixture()
        with (self.root / ".byori" / "compiler.lock").open("r+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            _, channel = self.worker(options={"wait_timeout": 0.1})
            result = self.receive(channel, timeout=5)
        self.assertEqual(result["refresh"], "busy")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())

    def test_disable_cannot_complete_inside_an_existing_publication_policy_lock(self):
        self.stale_fixture()
        _, channel = self.worker(gate="staged")
        self.receive(channel, "paused")
        with self.assertRaises(handbook.HandbookBusy):
            self.refresh.configure_refresh(self.root, enabled=False, wait_timeout=0.1)
        self.assertIs(self.refresh.read_config(self.root)["enabled"], True)
        channel.send("continue")
        result = self.receive(channel)
        self.assertEqual(result["refresh"], "rebuilt")
        disabled = self.refresh.configure_refresh(self.root, enabled=False)
        self.assertIs(disabled["enabled"], False)
        before = tree_snapshot(self.root / ".byori" / "generations")
        active_before = self.active.read_bytes()
        self.assertEqual(self.sync()["refresh"], "disabled")
        self.assertEqual(active_before, self.active.read_bytes())
        self.assertEqual(before, tree_snapshot(self.root / ".byori" / "generations"))

    def test_source_race_is_withheld_when_the_attempt_budget_is_exhausted(self):
        before = self.stale_fixture()
        _, channel = self.worker(gate="compiled", options={"attempts": 1})
        self.receive(channel, "paused")
        self.write("README.md", "# Fixture\n\nChanged after captured source snapshot.\n")
        channel.send("continue")
        result = self.receive(channel)
        self.assertEqual(result["refresh"], "failed")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())

    def test_original_journal_race_is_revalidated_during_publication(self):
        original = self.import_original()
        before = self.stale_fixture()
        _, channel = self.worker(gate="staged", options={"attempts": 1})
        self.receive(channel, "paused")
        updated = self.import_original("NEW_JOURNAL_DURING_PUBLICATION_519", original["revision"])
        channel.send("continue")
        result = self.receive(channel)
        self.assertEqual(result["refresh"], "failed")
        self.assert_withheld(result)
        self.assertEqual(before, self.active.read_bytes())
        self.assertEqual(handbook_records.load_records(self.root)["revision"], updated["revision"])

    def test_leftover_status_file_is_not_proof_of_activity_or_verified_content(self):
        self.enable(debounce_ms=0)
        first = self.sync()
        for status in ("busy", "cancelled", "rebuilt"):
            with self.subTest(status=status):
                self.write("README.md", "# Fixture\n\nStatus decoy: %s.\n" % status)
                decoy = json.dumps({"state": "current", "refresh": status,
                                    "generation": first["generation"], "pid": os.getpid(),
                                    "handbook": "UNVERIFIED_STATUS_BODY_172"})
                # Historical-looking filenames are deliberately not implementation APIs.
                for name in ("refresh-status.json", "handbook-refresh-status.json"):
                    self.write(".byori/" + name, decoy)
                _, channel = self.worker()
                result = self.receive(channel)
                self.assertEqual(result["refresh"], "rebuilt")
                self.assertEqual(result["state"], "current")
                self.assertIn("Status decoy: %s" % status, result["handbook"])
                self.assertNotIn("UNVERIFIED_STATUS_BODY_172", result["handbook"])

    def cli_selected_policy(self):
        return self.refresh.configure_refresh(
            self.root, enabled=False, max_chars=4096, debounce_ms=0,
            source_limits={"max_commits": 0, "max_files": 2,
                           "exclude_paths": ["docs/decision.md"]})

    def test_cli_preview_and_build_use_saved_exclusions_and_nondefault_bounds(self):
        config = self.cli_selected_policy()
        before = tree_snapshot(self.base)
        preview = self.cli("handbook", "preview", str(self.root), "--json")
        self.assert_cli_success_without_excluded_body(preview)
        self.assertEqual(before, tree_snapshot(self.base))
        built = self.cli("handbook", "build", str(self.root), "--json")
        result = self.assert_cli_success_without_excluded_body(built)
        self.assertEqual(self.refresh.read_config(self.root), config)
        evidence_path = self.root / ".byori" / "generations" / result["generation"] / "evidence.json"
        evidence = json.loads(evidence_path.read_text())
        self.assertEqual(evidence["policy"]["source_limits"], config["source_limits"])
        self.assertEqual(evidence["policy"]["max_chars"], 4096)
        self.assertFalse("RETRACTABLE_MARKER_731" in evidence_path.read_text(),
                         "excluded source leaked into published evidence")
        self.assertFalse((self.base / "isolated-engine-home").exists())
        self.assertFalse((self.base / "isolated-cli-home").exists())

    def test_cli_conflicting_explicit_bounds_fail_without_excluded_output_or_writes(self):
        self.cli_selected_policy()
        before = tree_snapshot(self.base)
        for action in ("preview", "build"):
            for flag, value in (("--max-files", "60"), ("--max-commits", "100"),
                                ("--max-chars", "12000")):
                with self.subTest(action=action, flag=flag):
                    process = self.cli("handbook", action, str(self.root), "--json", flag, value)
                    self.assertNotEqual(process.returncode, 0, "conflicting explicit bound was accepted")
                    self.assertFalse("RETRACTABLE_MARKER_731" in process.stdout + process.stderr,
                                     "conflicting request exposed an excluded source")
                    self.assertEqual(before, tree_snapshot(self.base))

    def test_cli_init_handbook_uses_saved_policy_without_engine_or_registry_writes(self):
        config = self.cli_selected_policy()
        before = tree_snapshot(self.base)
        preview = self.cli("init", str(self.root), "--handbook", "--dry-run", "--json")
        self.assert_cli_success_without_excluded_body(preview)
        self.assertEqual(before, tree_snapshot(self.base))
        conflict = self.cli("init", str(self.root), "--handbook", "--json", "--limit", "2000")
        self.assertNotEqual(conflict.returncode, 0, "legacy bound widened selected handbook policy")
        self.assertFalse("RETRACTABLE_MARKER_731" in conflict.stdout + conflict.stderr,
                         "init conflict exposed an excluded source")
        self.assertEqual(before, tree_snapshot(self.base))
        built = self.cli("init", str(self.root), "--handbook", "--json")
        self.assert_cli_success_without_excluded_body(built)
        self.assertEqual(self.refresh.read_config(self.root), config)
        self.assertFalse((self.base / "isolated-engine-home").exists())
        self.assertFalse((self.base / "isolated-cli-home").exists())


if __name__ == "__main__":
    unittest.main()
