"""Bounded doctor uses real temporary Git/compiler/delivery, never live hosts.

Run with python3 -B -m unittest discover -s tests -p test_handbook_doctor.py.
Write guards cover Python mutations; tree fingerprints also cover Git children.
"""

import builtins
import contextlib
import dataclasses
import io
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cli"))
import byori
import doctor
import handbook
import handbook_delivery as delivery
import handbook_refresh as refresh


def tree_snapshot(root):
    result = {}
    for path in [root, *sorted(root.rglob("*"))]:
        info = path.lstat()
        content = (os.readlink(path) if path.is_symlink()
                   else path.read_bytes() if path.is_file() else None)
        result[str(path.relative_to(root))] = (
            info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns, content)
    return result


@contextlib.contextmanager
def no_python_writes(forbidden_home):
    original_open, original_io_open, original_os_open = builtins.open, io.open, os.open
    original_write = os.write

    def guarded_open(original, file, mode="r", *args, **kwargs):
        # Git's bounded stdin is a pipe, not a filesystem write.
        if isinstance(file, int) and stat.S_ISFIFO(os.fstat(file).st_mode):
            return original(file, mode, *args, **kwargs)
        if not isinstance(file, int) and str(file).startswith(str(forbidden_home)):
            raise AssertionError("doctor read a normal host/runtime profile")
        if any(flag in mode for flag in "wax+"):
            raise AssertionError("doctor attempted a file write")
        return original(file, mode, *args, **kwargs)

    def guarded_os_open(path, flags, *args, **kwargs):
        if str(path).startswith(str(forbidden_home)):
            raise AssertionError("doctor read a normal host/runtime profile")
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            raise AssertionError("doctor attempted writable os.open")
        return original_os_open(path, flags, *args, **kwargs)

    def guarded_write(fd, data):
        if not stat.S_ISFIFO(os.fstat(fd).st_mode):
            raise AssertionError("doctor attempted a filesystem write")
        return original_write(fd, data)

    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch("builtins.open", side_effect=lambda *a, **k: guarded_open(original_open, *a, **k)))
        stack.enter_context(mock.patch("io.open", side_effect=lambda *a, **k: guarded_open(original_io_open, *a, **k)))
        stack.enter_context(mock.patch("os.open", side_effect=guarded_os_open))
        stack.enter_context(mock.patch("os.write", side_effect=guarded_write))
        for name in ("mkdir", "makedirs", "chmod", "fchmod", "chown", "fchown",
                     "unlink", "remove", "rmdir", "rename", "replace",
                     "truncate", "ftruncate", "utime", "symlink", "link"):
            stack.enter_context(mock.patch.object(os, name, side_effect=AssertionError("doctor attempted " + name)))
        yield


class HandbookDoctorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.root = self.base / "project with spaces"
        self.root.mkdir()
        self.home = self.base / "isolated home"
        self.home.mkdir()
        self.addCleanup(mock.patch.stopall)
        mock.patch.dict(os.environ, {
            "HOME": str(self.home), "BYORI_HOME": str(self.home / ".byori"),
            "BYORIDB_HOME": str(self.home / "no-engine"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
        }).start()
        # Poisoned normal configuration must neither be used nor echoed.
        for relative in (".claude.json", ".claude/settings.json", ".codex/config.toml",
                         ".byori/projects.json", "no-engine/env/runtime.env"):
            path = self.home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("PRIVATE_PROFILE_PASSWORD=DO_NOT_READ\x1b[31m\n")
        self.git("init", "-b", "main")
        self.readme = self.root / "README.md"
        self.readme.write_text("# Fixture\n\nSOURCE_BODY_MUST_NOT_APPEAR: keep retries bounded.\n")
        (self.root / "docs").mkdir()
        (self.root / "docs" / "policy.md").write_text("# Policy\n\nUse a bounded quiet window.\n")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-m", "Initial local fixture")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args],
                              check=True, capture_output=True, timeout=15)

    def publish(self):
        return refresh.compile_project_handbook(self.root, publish=True)

    @contextlib.contextmanager
    def isolated_read(self):
        before = tree_snapshot(self.base)
        original_run = subprocess.run

        def only_local_git(argv, *args, **kwargs):
            self.assertEqual(argv[0], "git", "no engine/model/vendor CLI or service commands")
            self.assertNotIn("fetch", argv)
            self.assertNotIn("push", argv)
            env = kwargs.get("env", {})
            self.assertEqual(env.get("GIT_OPTIONAL_LOCKS"), "0")
            self.assertEqual(env.get("GIT_NO_LAZY_FETCH"), "1")
            self.assertEqual(env.get("GIT_CONFIG_GLOBAL"), os.devnull)
            return original_run(argv, *args, **kwargs)

        with contextlib.ExitStack() as stack:
            for name in ("gather", "_run", "_http_status", "_authenticated_probe",
                         "_mcp_registered", "_hooks_present", "_port_owner"):
                stack.enter_context(mock.patch.object(doctor, name, side_effect=AssertionError("normal probe: " + name)))
            for name in ("read_runtime_env", "ProjectRegistry", "default_byori_home",
                         "default_byoridb_home", "repository_root", "memory_space_for_root"):
                stack.enter_context(mock.patch.object(byori, name, side_effect=AssertionError("normal config: " + name)))
            for module, names in ((handbook, ("publish_handbook", "protect_outputs", "_open_lock")),
                                  (refresh, ("refresh_handbook", "configure_refresh")),
                                  (delivery, ("connect", "disconnect", "preview_connection"))):
                for name in names:
                    stack.enter_context(mock.patch.object(module, name, side_effect=AssertionError("mutation: " + name)))
            stack.enter_context(mock.patch("urllib.request.urlopen", side_effect=AssertionError("HTTP forbidden")))
            stack.enter_context(mock.patch("socket.socket", side_effect=AssertionError("network forbidden")))
            stack.enter_context(mock.patch("pathlib.Path.home", side_effect=AssertionError("normal host profile forbidden")))
            stack.enter_context(mock.patch("subprocess.run", side_effect=only_local_git))
            stack.enter_context(no_python_writes(self.home))
            yield
        self.assertEqual(tree_snapshot(self.base), before)
        # The shared checkout's caches can change due to other workers. Cold
        # sibling imports are checked in the isolated installed-runtime test.

    def diagnose(self, path=None, json_output=True):
        output, errors = io.StringIO(), io.StringIO()
        argv = ["doctor", str(path or self.root), "--handbook-only"]
        if json_output:
            argv.append("--json")
        with self.isolated_read(), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = byori.main(argv)
        self.assertEqual(errors.getvalue(), "")
        text = output.getvalue()
        for forbidden in ("SOURCE_BODY_MUST_NOT_APPEAR", "DO_NOT_READ", "\x1b", "PRIVATE_PROFILE_PASSWORD"):
            self.assertNotIn(forbidden, text)
        return code, json.loads(text) if json_output else text

    def checks(self, payload):
        return {check["name"]: check for check in payload["checks"]}

    def test_missing_is_warning_and_disabled_defaults_are_intentional(self):
        code, payload = self.diagnose()
        checks = self.checks(payload)
        self.assertEqual((code, payload["status"]), (0, "warn"))
        self.assertEqual(checks["handbook-sources"]["status"], "ok")
        self.assertEqual(checks["handbook-snapshot"]["status"], "warn")
        self.assertIn("No published", checks["handbook-snapshot"]["detail"])
        self.assertEqual(checks["handbook-refresh"]["status"], "ok")
        self.assertIn("off (intentional)", checks["handbook-refresh"]["detail"])
        self.assertFalse((self.root / ".byori").exists())

    def test_actual_published_current_is_only_snapshot_and_consumption_unverified(self):
        self.publish()
        for host in ("claude", "codex"):
            delivery.connect(self.root, host)
        code, payload = self.diagnose()
        checks = self.checks(payload)
        self.assertEqual(code, 0)
        self.assertEqual(checks["handbook-snapshot"]["status"], "ok")
        self.assertIn("snapshot only", checks["handbook-snapshot"]["detail"])
        for host in ("claude", "codex"):
            self.assertEqual(checks["handbook-" + host]["status"], "ok")
            consumption = checks["handbook-" + host + "-consumption"]
            self.assertEqual(consumption["status"], "warn")
            self.assertIn("unverified", consumption["detail"])

    def test_stale_warns_without_refreshing_even_when_enabled(self):
        refresh.configure_refresh(self.root, True, debounce_ms=0)
        self.publish()
        self.readme.write_text("# Changed\n\nNow use two retries.\n")
        code, payload = self.diagnose()
        checks = self.checks(payload)
        self.assertEqual(code, 0)
        self.assertIn("stale", checks["handbook-snapshot"]["detail"])
        self.assertEqual(checks["handbook-refresh"]["status"], "ok")
        self.assertIn("refresh on", checks["handbook-refresh"]["detail"])

    def test_policy_change_stales_previous_snapshot_and_reports_saved_bounds(self):
        self.publish()
        refresh.configure_refresh(self.root, False, source_limits={"max_commits": 0,
                                  "max_files": 1, "exclude_paths": ["docs/policy.md"]},
                                  max_chars=4096, debounce_ms=17)
        code, payload = self.diagnose()
        checks = self.checks(payload)
        self.assertEqual(code, 0)
        self.assertIn("stale", checks["handbook-snapshot"]["detail"])
        detail = checks["handbook-refresh"]["detail"]
        for expected in ("off (intentional)", "saved", "0 commits", "1 documents",
                         "4096 handbook characters", "17 ms", "1 excluded path rules"):
            self.assertIn(expected, detail)
        self.assertNotIn("docs/policy.md", json.dumps(payload))
        self.assertEqual(checks["handbook-coverage"]["status"], "warn")

    def test_sensitive_sources_and_whole_section_omissions_are_counted_not_echoed(self):
        (self.root / "docs" / "safety.md").write_text("# Unsafe\n\npassword=DO_NOT_READ\x1b[31m\n")
        (self.root / "docs" / "large.md").write_text("# Large\n\n" + "Large context. " * 1800)
        self.git("add", ".")
        refresh.configure_refresh(self.root, False, max_chars=2048)
        self.publish()
        code, payload = self.diagnose()
        coverage = self.checks(payload)["handbook-coverage"]
        self.assertEqual((code, coverage["status"]), (0, "warn"))
        self.assertIn("sensitive sources withheld: 1", coverage["detail"])
        self.assertNotIn("whole sections omitted: 0", coverage["detail"])

    def test_collection_bound_omissions_are_reported_before_first_publication(self):
        refresh.configure_refresh(self.root, False, source_limits={"max_files": 0, "max_commits": 0})
        _, payload = self.diagnose()
        coverage = self.checks(payload)["handbook-coverage"]
        self.assertEqual(coverage["status"], "warn")
        self.assertIn("Selected sources: 0", coverage["detail"])
        self.assertNotIn("excluded: 0", coverage["detail"])

    def test_subdirectory_and_symlink_alias_select_canonical_git_checkout(self):
        self.publish()
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        for path in (self.root / "docs", alias / "docs"):
            code, payload = self.diagnose(path)
            self.assertEqual(code, 0)
            self.assertEqual(payload["project"], str(self.root.resolve()))
            self.assertEqual(len(payload["checkout_id"]), 64)

    def test_bad_roots_fail_generically_and_never_fall_back_to_runtime(self):
        for path in (self.base / "absent", self.home, self.readme):
            with self.subTest(path=path):
                code, payload = self.diagnose(path)
                self.assertEqual((code, payload["status"]), (1, "fail"))
                self.assertIsNone(payload["project"])
                self.assertIsNotNone(self.checks(payload)["handbook-sources"]["fix"])

    def test_corrupt_active_handbook_fails_and_never_exposes_body(self):
        self.publish()
        (self.root / ".byori" / "handbook.md").write_text("MANUAL password=DO_NOT_READ\x1b[31m\n")
        code, payload = self.diagnose()
        check = self.checks(payload)["handbook-snapshot"]
        self.assertEqual((code, check["status"]), (1, "fail"))
        self.assertIn("preserve manual edits", check["fix"])

    def test_missing_generation_is_unavailable_not_current(self):
        built = self.publish()
        (self.root / ".byori" / "generations" / built["generation"] / "evidence.json").unlink()
        code, payload = self.diagnose()
        self.assertEqual((code, self.checks(payload)["handbook-snapshot"]["status"]), (1, "fail"))

    def test_missing_required_original_records_withholds_published_snapshot(self):
        originals = [{"name": "decision:retry-bound", "body": "At most three retries."}]
        built = handbook.compile_handbook(self.root, accepted_records=originals)
        handbook.publish_handbook(built, accepted_records=originals)
        code, payload = self.diagnose()
        self.assertEqual((code, self.checks(payload)["handbook-snapshot"]["status"]), (1, "fail"))

    def test_published_snapshot_from_another_checkout_is_unavailable(self):
        self.publish()
        other = self.base / "other snapshot checkout"
        other.mkdir()
        subprocess.run(["git", "init", str(other)], check=True, capture_output=True)
        shutil.copytree(self.root / ".byori", other / ".byori")
        code, payload = self.diagnose(other)
        self.assertEqual((code, self.checks(payload)["handbook-snapshot"]["status"]), (1, "fail"))

    def test_symlinked_active_handbook_is_unavailable(self):
        self.publish()
        path = self.root / ".byori" / "handbook.md"
        path.unlink()
        path.symlink_to(self.readme)
        code, payload = self.diagnose()
        self.assertEqual(code, 1)
        self.assertEqual(self.checks(payload)["handbook-snapshot"]["status"], "fail")

    def test_malformed_and_symlink_refresh_config_fail_without_raw_errors(self):
        for linked in (False, True):
            with self.subTest(linked=linked):
                path = self.root / ".byori" / "refresh.json"
                path.parent.mkdir(exist_ok=True)
                if path.exists() or path.is_symlink():
                    path.unlink()
                if linked:
                    path.symlink_to(self.home / ".claude.json")
                else:
                    path.write_text('{"password":"DO_NOT_READ\\u001b[31m"}')
                code, payload = self.diagnose()
                self.assertEqual(code, 1)
                self.assertEqual(self.checks(payload)["handbook-refresh"]["status"], "fail")

    def test_config_from_another_checkout_is_rejected(self):
        refresh.configure_refresh(self.root, False)
        other = self.base / "other"
        other.mkdir()
        subprocess.run(["git", "init", str(other)], check=True, capture_output=True)
        (other / ".byori").mkdir()
        shutil.copyfile(self.root / ".byori" / "refresh.json", other / ".byori" / "refresh.json")
        code, payload = self.diagnose(other)
        self.assertEqual(code, 1)
        self.assertEqual(self.checks(payload)["handbook-refresh"]["status"], "fail")

    def test_unknown_blocks_fail_for_each_host_with_actionable_review(self):
        for host, filename in (("claude", "CLAUDE.md"), ("codex", "AGENTS.md")):
            with self.subTest(host=host):
                path = self.root / filename
                path.write_bytes(delivery.START_MARKER + b"\npassword=DO_NOT_READ\x1b[31m\n" + delivery.END_MARKER + b"\n")
                code, payload = self.diagnose()
                check = self.checks(payload)["handbook-" + host]
                self.assertEqual((code, check["status"]), (1, "fail"))
                self.assertIn("review", check["fix"])
                self.assertIn("never repair", check["fix"])
                path.unlink()

    def test_manually_edited_managed_blocks_fail_without_repair(self):
        self.publish()
        for host, filename in (("claude", "CLAUDE.md"), ("codex", "AGENTS.md")):
            delivery.connect(self.root, host)
            path = self.root / filename
            path.write_bytes(path.read_bytes().replace(b"byori handbook sync", b"password=DO_NOT_READ\x1b[31m"))
        code, payload = self.diagnose()
        self.assertEqual(code, 1)
        for host in ("claude", "codex"):
            self.assertEqual(self.checks(payload)["handbook-" + host]["status"], "fail")

    def test_malformed_markers_and_symlink_instruction_files_fail(self):
        for host, filename in (("claude", "CLAUDE.md"), ("codex", "AGENTS.md")):
            path = self.root / filename
            for linked in (False, True):
                with self.subTest(host=host, linked=linked):
                    if linked:
                        path.symlink_to(self.home / ".claude.json")
                    else:
                        path.write_bytes(delivery.START_MARKER + b" DO_NOT_READ\x1b\n")
                    code, payload = self.diagnose()
                    self.assertEqual((code, self.checks(payload)["handbook-" + host]["status"]), (1, "fail"))
                    path.unlink()

    def test_malformed_and_symlink_connection_records_fail(self):
        self.publish()
        for host in ("claude", "codex"):
            delivery.connect(self.root, host)
        for host in ("claude", "codex"):
            record = self.root / ".byori" / "connections" / (host + ".json")
            for linked in (False, True):
                with self.subTest(host=host, linked=linked):
                    record.unlink()
                    if linked:
                        record.symlink_to(self.home / ".claude.json")
                    else:
                        record.write_text("DO_NOT_READ\x1b[31m")
                        record.chmod(0o600)
                    code, payload = self.diagnose()
                    self.assertEqual((code, self.checks(payload)["handbook-" + host]["status"]), (1, "fail"))

    def test_disconnected_and_codex_override_remain_distinct_configuration_states(self):
        self.publish()
        delivery.connect(self.root, "claude")
        delivery.disconnect(self.root, "claude")
        delivery.connect(self.root, "codex")
        (self.root / "AGENTS.override.md").write_text("PRIVATE_PROFILE_PASSWORD=DO_NOT_READ\x1b\n")
        code, payload = self.diagnose()
        checks = self.checks(payload)
        self.assertEqual(code, 0)
        self.assertIn("disconnected", checks["handbook-claude"]["detail"])
        self.assertIn("configured", checks["handbook-codex"]["detail"])
        self.assertEqual(checks["handbook-codex"]["status"], "warn")

    def test_space_combination_is_rejected_before_gathering(self):
        with self.isolated_read(), mock.patch.object(doctor, "gather_handbook", side_effect=AssertionError("must not gather")), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            code = byori.main(["doctor", str(self.root), "--handbook-only", "--space", "fixture", "--json"])
        self.assertEqual(code, 2)
        self.assertIn("cannot be combined", errors.getvalue())

    def test_text_output_is_safe_and_has_review_guidance(self):
        code, output = self.diagnose(json_output=False)
        self.assertEqual(code, 0)
        self.assertIn("handbook-only", output)
        self.assertIn("review:", output)
        self.assertIn("consumption remains unverified", output)

    def test_control_or_credential_like_project_root_is_redacted_in_both_formats(self):
        for name in ("password=DO_NOT_READ\x1b[31m", "password=DO_NOT_READ", "untrusted\u202eproject"):
            unsafe = self.base / name
            self.root.rename(unsafe)
            self.root = unsafe
            for json_output in (True, False):
                code, output = self.diagnose(json_output=json_output)
                self.assertEqual(code, 0)
                if json_output:
                    self.assertEqual(output["project"], "[redacted project root]")
                else:
                    self.assertIn("[redacted project root]", output)

    def test_malicious_exclusion_and_raw_exception_never_reach_plain_details(self):
        refresh.configure_refresh(self.root, False)
        path = self.root / ".byori" / "refresh.json"
        config = json.loads(path.read_text())
        config["source_limits"]["exclude_paths"] = ["docs/password=DO_NOT_READ\x1b[31m.md"]
        path.write_text(json.dumps(config))
        for json_output in (True, False):
            code, _ = self.diagnose(json_output=json_output)
            self.assertEqual(code, 1)
        with mock.patch.object(handbook, "collect_sources",
                               side_effect=handbook.SourceError("password=DO_NOT_READ\x1b[31m raw exception")):
            for json_output in (True, False):
                code, output = self.diagnose(json_output=json_output)
                self.assertEqual(code, 1)
                self.assertNotIn("raw exception", str(output))

    def test_default_doctor_dispatch_and_json_schema_remain_unchanged(self):
        output = io.StringIO()
        with mock.patch.object(doctor, "gather", return_value={}) as gather, \
                mock.patch.object(doctor, "judge", return_value=[doctor.Check("fixture", "ok", "Synthetic default")]), \
                mock.patch.object(doctor, "gather_handbook", side_effect=AssertionError("default must remain legacy")), \
                mock.patch.object(byori, "read_runtime_env", return_value={}), \
                mock.patch.object(byori, "default_byoridb_home", return_value=self.home / "no-engine"), \
                mock.patch.object(byori, "default_byori_home", return_value=self.home / ".byori"), \
                contextlib.redirect_stdout(output):
            code = byori.main(["doctor", "--space", "fixture", "--json"])
        self.assertEqual(code, 0)
        self.assertEqual(gather.call_count, 1)
        payload = json.loads(output.getvalue())
        self.assertEqual(set(payload), {"status", "space", "project", "checks"})
        self.assertEqual(payload["space"], "fixture")

    def test_pure_judgment_ignores_claimed_connection_verification(self):
        with self.isolated_read():
            facts = doctor.gather_handbook(self.root)
        for host in ("claude", "codex"):
            facts["connections"][host] = {"status": "configured", "warnings": 0,
                                           "verification": "verified", "startup_consumption": "verified"}
        with mock.patch.object(doctor, "gather_handbook", side_effect=AssertionError("judgment must be pure")):
            checks = {check.name: dataclasses.asdict(check) for check in doctor.judge_handbook(facts)}
        for host in ("claude", "codex"):
            self.assertIn("unverified", checks["handbook-" + host + "-consumption"]["detail"])

    def test_installed_siblings_no_engine_and_no_bytecode_even_without_B(self):
        installed = self.base / "installed"
        installed.mkdir()
        for source in (ROOT / "cli").glob("*.py"):
            shutil.copy2(source, installed / source.name)
        before = tree_snapshot(self.base)
        # No -B here: the handbook-only handler itself suppresses sibling caches.
        environment = dict(os.environ)
        environment.pop("PYTHONDONTWRITEBYTECODE", None)
        result = subprocess.run([sys.executable, str(installed / "byori.py"), "doctor",
                                 str(self.root), "--handbook-only", "--json"],
                                capture_output=True, text=True, timeout=30, env=environment,
                                cwd=str(self.home))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["mode"], "handbook-only")
        self.assertEqual(tree_snapshot(self.base), before)
        self.assertFalse((installed / "__pycache__").exists())


if __name__ == "__main__":
    unittest.main()
