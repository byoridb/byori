#!/usr/bin/env python3
"""What `byori doctor` concludes, and whether it says how to recover.

Each check here exists because of an incident, so the tests are written from the
incident: a rolled-back install whose manifest lied (byori#57), a failed update that
left the launchd job unloaded (byori#58), a full disk that stopped even the
diagnosis, a space that resolves but is empty, and an agent that was never told the
graph existed.

Judgement is separated from gathering, so none of this needs a machine in a
particular state. A check that fails must also carry the command that recovers —
that is the whole point of shipping the diagnosis.
"""

import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("byori_doctor", ROOT / "cli" / "doctor.py")
DOCTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOCTOR)

GIGABYTE = 1024 ** 3


class DiskTests(unittest.TestCase):
    def test_a_full_disk_fails_because_it_loses_writes(self):
        check = DOCTOR.check_disk(200 * 1024 ** 2, "/Users/x/.byoridb")
        self.assertEqual(check.status, DOCTOR.FAIL)
        self.assertIn("loses writes", check.detail)

    def test_a_nearly_full_disk_warns(self):
        self.assertEqual(DOCTOR.check_disk(3 * GIGABYTE, "/x").status, DOCTOR.WARN)

    def test_plenty_of_room_passes(self):
        self.assertEqual(DOCTOR.check_disk(60 * GIGABYTE, "/x").status, DOCTOR.OK)

    def test_an_unreadable_volume_warns_rather_than_claiming_anything(self):
        self.assertEqual(DOCTOR.check_disk(None, "/x").status, DOCTOR.WARN)


class EngineIdentityTests(unittest.TestCase):
    def test_a_rolled_back_install_is_caught_by_the_sha(self):
        """byori#57: rollback restores the binary but not engine.json, so the record
        names a version that is not on disk."""
        check = DOCTOR.check_engine_identity(
            manifest={"tag": "v0.4.2", "sha256": "b8c973d4fed1aaaa"},
            binary_exists=True,
            binary_sha="94d502bd8786bbbb",
            reported_version="byoridb-server 0.4.0 (commit fbeb4ac55417, release)",
            probe_skipped_reason=None,
        )
        self.assertEqual(check.status, DOCTOR.FAIL)
        self.assertIn("v0.4.2", check.detail)
        self.assertIn("94d502bd8786", check.detail)
        self.assertIsNotNone(check.fix)

    def test_a_matching_record_passes_and_says_the_binary_agrees(self):
        check = DOCTOR.check_engine_identity(
            manifest={"tag": "v0.4.2", "sha256": "b8c973d4fed1"},
            binary_exists=True,
            binary_sha="b8c973d4fed1",
            reported_version="byoridb-server 0.4.2 (commit f7ff47a55f50, release)",
            probe_skipped_reason=None,
        )
        self.assertEqual(check.status, DOCTOR.OK)
        self.assertIn("binary agrees", check.detail)

    def test_a_version_disagreement_fails_even_when_the_sha_is_unknown(self):
        check = DOCTOR.check_engine_identity(
            manifest={"tag": "v0.3.3", "sha256": ""},
            binary_exists=True,
            binary_sha="",
            reported_version="byoridb-server 0.4.2 (commit f7ff47a55f50, release)",
            probe_skipped_reason=None,
        )
        self.assertEqual(check.status, DOCTOR.FAIL)

    def test_a_skipped_probe_is_reported_rather_than_hidden(self):
        """An engine before 0.4.0 ignores `--version` and would start a server
        against the live data directory, so it is not asked — and the answer says so
        instead of implying agreement."""
        check = DOCTOR.check_engine_identity(
            manifest={"tag": "v0.3.3", "sha256": "b55ffa606a66"},
            binary_exists=True,
            binary_sha="b55ffa606a66",
            reported_version=None,
            probe_skipped_reason="engines before 0.4.0 ignore --version",
        )
        self.assertEqual(check.status, DOCTOR.OK)
        self.assertIn("not asked", check.detail)

    def test_a_missing_binary_fails_with_the_way_to_install_it(self):
        check = DOCTOR.check_engine_identity({}, False, "", None, None)
        self.assertEqual(check.status, DOCTOR.FAIL)
        self.assertIsNotNone(check.fix)


class ServiceTests(unittest.TestCase):
    def test_an_unloaded_job_fails_with_the_bootstrap_command(self):
        """byori#58 cost three manual recoveries; the command is the deliverable."""
        check = DOCTOR.check_service(False, "com.byoridb.local", "gui/501/com.byoridb.local", "launchd")
        self.assertEqual(check.status, DOCTOR.FAIL)
        self.assertIn("launchctl bootstrap", check.fix)
        self.assertIn("com.byoridb.local", check.fix)

    def test_systemd_gets_its_own_command(self):
        check = DOCTOR.check_service(False, "byoridb-local", "byoridb-local.service", "systemd")
        self.assertIn("systemctl --user enable --now", check.fix)

    def test_a_loaded_job_passes(self):
        self.assertEqual(
            DOCTOR.check_service(True, "com.byoridb.local", "t", "launchd").status, DOCTOR.OK
        )


class EndpointAndCredentialTests(unittest.TestCase):
    def test_a_dead_endpoint_names_whoever_holds_the_port(self):
        check = DOCTOR.check_endpoint(False, "http://127.0.0.1:19669", "byoridb-s (pid 980)")
        self.assertEqual(check.status, DOCTOR.FAIL)
        self.assertIn("pid 980", check.detail)

    def test_health_alone_is_not_trusted(self):
        """A stale process can own the port and answer /health, which is why the
        credential is checked separately."""
        check = DOCTOR.check_credential("refused", "http://127.0.0.1:19669")
        self.assertEqual(check.status, DOCTOR.FAIL)
        self.assertIn("another process", check.detail)

    def test_a_locked_account_says_to_wait_and_cites_the_engine_bug(self):
        check = DOCTOR.check_credential("locked", "http://127.0.0.1:19669")
        self.assertEqual(check.status, DOCTOR.FAIL)
        self.assertIn("byoridb#90", check.detail)
        self.assertIn("wait", check.fix)

    def test_an_unreachable_engine_leaves_the_credential_unjudged(self):
        check = DOCTOR.check_credential("unreachable", "http://127.0.0.1:19669")
        self.assertEqual(check.status, DOCTOR.WARN)


class MemorySpaceTests(unittest.TestCase):
    def test_an_empty_space_warns_and_offers_init(self):
        """"Connected but empty" is what every project looked like before `byori
        init`, and nobody noticed because nothing said so."""
        check = DOCTOR.check_memory_space("byori_shop_1a2b", 0, reachable=True)
        self.assertEqual(check.status, DOCTOR.WARN)
        self.assertIn("another store", check.detail)
        self.assertIn("byori init", check.fix)

    def test_a_populated_space_reports_the_count(self):
        check = DOCTOR.check_memory_space("byori_shop_1a2b", 28, reachable=True)
        self.assertEqual(check.status, DOCTOR.OK)
        self.assertIn("28 memories", check.detail)

    def test_nothing_is_claimed_when_the_engine_is_down(self):
        self.assertEqual(
            DOCTOR.check_memory_space("s", None, reachable=False).status, DOCTOR.WARN
        )


class AgentWiringTests(unittest.TestCase):
    def test_missing_wiring_is_named_item_by_item(self):
        check = DOCTOR.check_agent_wiring(
            mcp_registered=False,
            skills={"byoridb-memory": False, "byori-design": True},
            hooks_present=False,
        )
        self.assertEqual(check.status, DOCTOR.WARN)
        self.assertIn("MCP server not registered", check.detail)
        self.assertIn("byoridb-memory", check.detail)
        self.assertIn("hooks absent", check.detail)

    def test_complete_wiring_passes(self):
        check = DOCTOR.check_agent_wiring(
            True, {"byoridb-memory": True, "byori-design": True}, True
        )
        self.assertEqual(check.status, DOCTOR.OK)


class PrerequisiteTests(unittest.TestCase):
    def test_a_missing_requirement_fails(self):
        check = DOCTOR.check_prerequisites({"git": False, "python3": True, "tmux": True, "jq": True})
        self.assertEqual(check.status, DOCTOR.FAIL)
        self.assertIn("git", check.detail)

    def test_missing_optional_tools_only_warn_and_say_what_they_cost(self):
        check = DOCTOR.check_prerequisites({"git": True, "python3": True, "tmux": False, "jq": False})
        self.assertEqual(check.status, DOCTOR.WARN)
        self.assertIn("tmux keeps sessions alive", check.detail)


class SummaryTests(unittest.TestCase):
    def test_one_failure_decides_the_whole_run(self):
        checks = [
            DOCTOR.Check("a", DOCTOR.OK, ""),
            DOCTOR.Check("b", DOCTOR.WARN, ""),
            DOCTOR.Check("c", DOCTOR.FAIL, ""),
        ]
        self.assertEqual(DOCTOR.worst(checks), DOCTOR.FAIL)

    def test_warnings_alone_are_not_a_failure(self):
        checks = [DOCTOR.Check("a", DOCTOR.OK, ""), DOCTOR.Check("b", DOCTOR.WARN, "")]
        self.assertEqual(DOCTOR.worst(checks), DOCTOR.WARN)

    def test_every_failing_check_carries_a_way_out(self):
        """A diagnosis without a next step is just a nicer error message."""
        failing = [
            DOCTOR.check_disk(100, "/x"),
            DOCTOR.check_engine_identity({}, False, "", None, None),
            DOCTOR.check_service(False, "com.byoridb.local", "t", "launchd"),
            DOCTOR.check_endpoint(False, "http://127.0.0.1:19669", None),
            DOCTOR.check_credential("refused", "http://127.0.0.1:19669"),
            DOCTOR.check_prerequisites({"git": False, "python3": True}),
        ]
        for check in failing:
            with self.subTest(check=check.name):
                self.assertEqual(check.status, DOCTOR.FAIL)
                self.assertTrue(check.fix, "a failing check must say what to run")


class VersionParsingTests(unittest.TestCase):
    def test_tags_and_binary_output_both_parse(self):
        self.assertEqual(DOCTOR.parse_version("v0.4.2"), (0, 4, 2))
        self.assertEqual(
            DOCTOR.parse_version("byoridb-server 0.4.2 (commit f7ff47a55f50, release)"),
            (0, 4, 2),
        )
        self.assertIsNone(DOCTOR.parse_version("unknown"))


if __name__ == "__main__":
    unittest.main()
