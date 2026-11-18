#!/usr/bin/env python3
"""How install.sh drives the launchd job (byori#58).

The installer used the legacy `load`/`unload` while the app used `bootstrap`/
`bootout`. Measured on macOS 27: `load -w` on a job that is already loaded
prints "Load failed: 5: Input/output error" and still exits 0, and `bootstrap`
fails with the same error 5 both for a loaded job and for a disabled one. These
tests run the installer's launchd functions against a fake `launchctl` that
behaves that way, so no real job is touched.
"""

import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "install.sh").read_text(encoding="utf-8")
LAUNCHD_BLOCK = re.search(
    r"^# ---- launchd -+\n(.*?)^# ---- uninstall", INSTALLER, re.S | re.M
).group(1)

# A launchd stand-in. State: whether the job is loaded and whether it is
# disabled; `bootout` takes `linger` more `print` calls to finish, as a job
# whose process is still exiting does.
FAKE_LAUNCHCTL = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["FAKE_LAUNCHD"]
state = json.load(open(path))
verb = sys.argv[1]
state["calls"].append(" ".join(sys.argv[1:]))
code = 0
if verb == "print":
    if state["linger"] > 0:
        state["linger"] -= 1
    elif state["unloading"]:
        state["unloading"] = False
        state["loaded"] = False
    if not state["loaded"]:
        code = 113
    else:
        print("\tstate = running\n\tlast exit code = (never exited)")
elif verb == "bootout":
    if state["loaded"]:
        state["unloading"] = True
    else:
        code = 3
elif verb == "enable":
    state["disabled"] = False
elif verb == "bootstrap":
    if state["loaded"] or state["disabled"] or state["refuse"]:
        print("Bootstrap failed: 5: Input/output error", file=sys.stderr)
        code = 5
    else:
        state["loaded"] = True
elif verb == "kickstart":
    code = 0 if state["loaded"] else 113
json.dump(state, open(path, "w"))
sys.exit(code)
'''


class InstallerLaunchdTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        stub = self.root / "bin" / "launchctl"
        stub.parent.mkdir()
        stub.write_text(FAKE_LAUNCHCTL, encoding="utf-8")
        stub.chmod(0o755)
        (self.root / "work").mkdir()
        self.state_path = self.root / "launchd.json"

    def tearDown(self):
        self.temporary.cleanup()

    def run_functions(self, script, *, loaded=False, disabled=False, linger=0, refuse=False):
        self.state_path.write_text(json.dumps({
            "loaded": loaded, "disabled": disabled, "linger": linger,
            "unloading": False, "refuse": refuse, "calls": [],
        }))
        program = "\n".join([
            "set -u",
            'warn() { echo "warn: $*" >&2; }',
            # The real loop sleeps between polls; the fake needs no time to pass.
            "sleep() { :; }",
            "LABEL=com.byoridb.test",
            f"WORK={self.root / 'work'}",
            LAUNCHD_BLOCK,
            script,
        ])
        environment = dict(os.environ)
        environment["PATH"] = f"{self.root / 'bin'}{os.pathsep}{environment['PATH']}"
        environment["FAKE_LAUNCHD"] = str(self.state_path)
        result = subprocess.run(
            ["bash", "-c", program], env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60,
        )
        state = json.loads(self.state_path.read_text())
        verbs = [call.split()[0] for call in state["calls"] if not call.startswith("print")]
        return result, state, verbs

    def test_the_installer_no_longer_uses_the_legacy_api(self):
        commands = re.findall(r"launchctl\s+(\w[\w-]*)", INSTALLER)
        self.assertNotIn("load", commands)
        self.assertNotIn("unload", commands)

    def test_a_fresh_job_is_enabled_then_bootstrapped(self):
        result, state, verbs = self.run_functions('launchd_load /tmp/x.plist; echo "rc=$?"')

        self.assertIn("rc=0", result.stdout)
        self.assertTrue(state["loaded"])
        self.assertEqual(verbs, ["enable", "bootstrap"])
        self.assertIn("bootstrap gui/", state["calls"][1])

    def test_a_job_left_disabled_still_loads(self):
        result, state, _ = self.run_functions('launchd_load /tmp/x.plist; echo "rc=$?"', disabled=True)

        self.assertIn("rc=0", result.stdout)
        self.assertTrue(state["loaded"])
        self.assertFalse(state["disabled"])

    def test_unload_waits_until_launchd_has_let_go(self):
        result, state, verbs = self.run_functions(
            'launchd_unload; launchd_loaded && echo still || echo gone; launchd_load /tmp/x.plist; echo "rc=$?"',
            loaded=True, linger=3,
        )

        self.assertIn("gone", result.stdout)
        self.assertIn("rc=0", result.stdout)
        self.assertEqual(verbs, ["bootout", "enable", "bootstrap"], "no bootstrap while still loaded")

    def test_a_bootstrap_refused_for_a_loaded_job_restarts_it(self):
        result, state, verbs = self.run_functions('launchd_load /tmp/x.plist; echo "rc=$?"', loaded=True)

        self.assertIn("rc=0", result.stdout)
        self.assertEqual(verbs, ["enable", "bootstrap", "kickstart"])

    def test_a_job_that_will_not_load_fails_with_launchds_view(self):
        result, state, _ = self.run_functions('launchd_load /tmp/x.plist; echo "rc=$?"', refuse=True)

        self.assertIn("rc=1", result.stdout)
        self.assertIn("Bootstrap failed: 5", result.stdout)
        self.assertIn("gui/", result.stdout)
        self.assertIn("is not loaded", result.stdout)

    def test_uninstall_leaves_a_job_this_home_did_not_install_alone(self):
        """The label is the user's, not the home's: an uninstall run with another
        $HOME (as the installer tests do) must not boot out the real service.
        Measured: before this guard, a local test run stopped the live engine."""
        home = self.root / "home"
        home.mkdir()
        self.state_path.write_text(json.dumps({
            "loaded": True, "disabled": False, "linger": 0,
            "unloading": False, "refuse": False, "calls": [],
        }))
        environment = {
            # Only the fake launchctl and the base system: no agent CLIs whose
            # MCP configuration an uninstall would edit.
            "PATH": f"{self.root / 'bin'}{os.pathsep}/usr/bin{os.pathsep}/bin",
            "HOME": str(home),
            "BYORIDB_HOME": str(self.root / "byoridb-home"),
            "FAKE_LAUNCHD": str(self.state_path),
        }
        subprocess.run(
            ["bash", str(ROOT / "install.sh"), "--uninstall"],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=120,
        )

        state = json.loads(self.state_path.read_text())
        self.assertTrue(state["loaded"])
        self.assertFalse(
            [call for call in state["calls"] if call.startswith("bootout")],
            state["calls"],
        )

    def test_unloading_a_job_that_is_not_loaded_is_quiet(self):
        result, state, verbs = self.run_functions('launchd_unload; echo "rc=$?"')

        self.assertIn("rc=0", result.stdout)
        self.assertEqual(verbs, [])


if __name__ == "__main__":
    unittest.main()
