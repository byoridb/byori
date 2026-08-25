#!/usr/bin/env python3
"""Which ByoriDB engine release `install.sh` decides to install.

The app's single install button passes `--engine-tag latest`, so the engine stops
waiting on a byori release to move forward. These tests run the real installer
with a stubbed `curl` and let it fail at the engine download: the failure names
the tag it resolved, which is the decision under test. Nothing is downloaded, no
engine is started, and `--assets` keeps every Byori-owned file local.
"""

import json
import os
import pathlib
import re
import stat
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
# Read from the installer, the way CI does, so bumping the pin cannot leave these
# tests asserting a version nothing installs any more.
PINNED_TAG = re.search(
    r'^ENGINE_TAG_DEFAULT="([^"]+)"', INSTALLER.read_text(encoding="utf-8"), re.MULTILINE
).group(1)

# Answers the engine releases API and fails every other request, so the run stops
# at the engine download with the resolved tag in the message.
RESOLVING_CURL = """#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in
  *api.github.com/repos/byoridb/byoridb/releases/latest)
    printf '{"tag_name": "%s"}\\n' "$RESOLVED_TAG" > "$out"; exit 0 ;;
esac
echo "curl: (22) stubbed failure for $url" >&2; exit 22
"""

FAILING_CURL = """#!/bin/sh
echo "curl: (22) stubbed failure" >&2; exit 22
"""


class InstallEngineTagTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.stub_directory = self.root / "stub"
        self.stub_directory.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def install(self, curl_script, *arguments, resolved_tag=""):
        stub = self.stub_directory / "curl"
        stub.write_text(curl_script, encoding="utf-8")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        environment = dict(os.environ)
        environment.update(
            PATH=f"{self.stub_directory}{os.pathsep}{environment['PATH']}",
            BYORIDB_HOME=str(self.root / "byoridb-home"),
            # $HOME too, not only $BYORIDB_HOME. A run that gets past the engine step
            # links `~/.local/bin/byori`, and with the real home that pointed the
            # developer's own command at this test's temporary directory — measured,
            # after the downgrade cases below made the installer reach that step.
            HOME=str(self.home),
            RESOLVED_TAG=resolved_tag,
        )
        # PIPESTATUS is not asserted: the point of each run is the message on the
        # way out, and the installer is expected to fail once curl refuses.
        return subprocess.run(
            [
                "bash",
                str(INSTALLER),
                "--assets",
                str(ROOT),
                "--no-claude",
                "--no-codex",
                "--no-service",
                *arguments,
            ],
            env=environment,
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
        ).stdout

    def test_latest_resolves_the_newest_engine_release(self):
        output = self.install(
            RESOLVING_CURL, "--engine-tag", "latest", resolved_tag="v9.9.9"
        )

        self.assertIn("latest engine release: v9.9.9", output)
        self.assertIn(
            "byoridb/byoridb/releases/download/v9.9.9/byoridb-v9.9.9-", output
        )
        self.assertNotIn(f"downloading engine {PINNED_TAG}", output)

    def test_latest_falls_back_to_the_validated_tag_when_github_is_unreachable(self):
        output = self.install(FAILING_CURL, "--engine-tag", "latest")

        self.assertIn("could not resolve the latest engine release", output)
        self.assertIn(f"downloading engine {PINNED_TAG}", output)

    def test_an_explicit_tag_is_never_resolved(self):
        # What CI and a reproducible install rely on: naming a tag reaches the
        # download untouched, with no API call in between.
        output = self.install(
            RESOLVING_CURL, "--engine-tag", "v0.3.3", resolved_tag="v9.9.9"
        )

        self.assertIn("downloading engine v0.3.3", output)
        self.assertNotIn("latest engine release", output)
        self.assertNotIn("v9.9.9", output)

    def test_the_default_stays_the_validated_tag(self):
        output = self.install(RESOLVING_CURL, resolved_tag="v9.9.9")

        self.assertIn(f"downloading engine {PINNED_TAG}", output)
        self.assertNotIn("v9.9.9", output)

    def install_engine_record(self, tag):
        """Pretend an engine is already installed, the way a real machine would."""
        home = self.root / "byoridb-home"
        (home / "bin").mkdir(parents=True, exist_ok=True)
        server = home / "bin" / "byoridb-server"
        server.write_text("#!/bin/sh\n", encoding="utf-8")
        server.chmod(server.stat().st_mode | stat.S_IXUSR)
        (home / "engine.json").write_text(
            json.dumps({"tag": tag, "sha256": "0" * 64}), encoding="utf-8"
        )

    def test_a_newer_installed_engine_is_kept_instead_of_rolled_back(self):
        """Running the documented one-liner on a machine with a later engine used to
        downgrade it silently, against a data directory that engine had written."""
        self.install_engine_record("v9.9.9")

        output = self.install(RESOLVING_CURL)

        self.assertIn("keeping installed engine v9.9.9", output)
        self.assertIn("--allow-engine-downgrade", output)
        self.assertNotIn("downloading engine", output)

    def test_the_cli_link_obeys_the_home_it_was_given(self):
        """Skipping the engine step lets the run reach the `~/.local/bin` link, which
        is how this was found: with the real `$HOME`, a test run repointed the
        developer's own `byori` at its own temporary directory, and the command
        stopped working once the directory was cleaned up."""
        self.install_engine_record("v9.9.9")

        self.install(RESOLVING_CURL)

        link = self.home / ".local" / "bin" / "byori"
        self.assertTrue(link.is_symlink(), "the installer must link the CLI")
        self.assertEqual(
            os.readlink(link), str(self.root / "byoridb-home" / "bin" / "byori")
        )

    def test_a_downgrade_is_available_when_it_is_asked_for(self):
        self.install_engine_record("v9.9.9")

        output = self.install(RESOLVING_CURL, "--allow-engine-downgrade")

        self.assertIn(f"downgrading engine v9.9.9 -> {PINNED_TAG}", output)
        self.assertIn(f"downloading engine {PINNED_TAG}", output)

    def test_an_older_installed_engine_is_still_upgraded(self):
        """The guard is about direction, not about refusing to touch anything."""
        self.install_engine_record("v0.1.0")

        output = self.install(RESOLVING_CURL)

        self.assertIn(f"downloading engine {PINNED_TAG}", output)
        self.assertNotIn("keeping installed engine", output)

    def test_release_order_decides_not_string_order(self):
        """v0.4.10 is newer than v0.4.9, which sorting as text gets backwards."""
        self.install_engine_record("v0.4.10")

        output = self.install(RESOLVING_CURL, "--engine-tag", "v0.4.9")

        self.assertIn("keeping installed engine v0.4.10", output)

    def test_identical_bytes_leave_the_running_engine_alone(self):
        """Reinstalling to pick up a new MCP server or CLI must not restart a healthy
        engine. Same sha means replacing the file would buy nothing and cost a
        downtime window — and every replacement is a chance to corrupt the binary."""
        staged, digest = self.stage_local_engine()
        home = self.root / "byoridb-home"
        (home / "bin").mkdir(parents=True, exist_ok=True)
        installed = home / "bin" / "byoridb-server"
        installed.write_bytes(staged.read_bytes())
        (home / "engine.json").write_text(
            json.dumps({"tag": "v0.4.2", "sha256": digest}), encoding="utf-8"
        )

        output = self.install(FAILING_CURL, "--binary", str(staged))

        self.assertIn("engine bytes unchanged", output)
        self.assertIn(digest[:12], output)

    def test_different_bytes_are_installed_by_rename_not_written_in_place(self):
        """The corruption that killed the engine: copying over the file a running
        process is executing left bytes that no longer matched their own signature,
        and macOS killed every start. Rename swaps the directory entry instead, so the
        inode a live process holds is never touched — which is observable here as the
        installed file being a *different* inode than the one that was there before."""
        staged, digest = self.stage_local_engine(content=b"#!/bin/sh\n# new build\n")
        home = self.root / "byoridb-home"
        (home / "bin").mkdir(parents=True, exist_ok=True)
        installed = home / "bin" / "byoridb-server"
        installed.write_bytes(b"#!/bin/sh\n# old build\n")
        before = installed.stat().st_ino

        output = self.install(FAILING_CURL, "--binary", str(staged))

        self.assertNotIn("engine bytes unchanged", output)
        self.assertEqual(installed.read_bytes(), b"#!/bin/sh\n# new build\n")
        self.assertNotEqual(
            installed.stat().st_ino, before,
            "an in-place write keeps the inode, and that is what corrupted a running engine",
        )
        # Nothing is left behind for the next run to trip over.
        self.assertEqual(
            list((home / "bin").glob(".byoridb-server*")), [],
            "the staging file must be renamed, not left in place",
        )

    def test_the_record_describes_the_bytes_that_are_actually_installed(self):
        staged, digest = self.stage_local_engine(content=b"#!/bin/sh\n# recorded\n")
        output = self.install(FAILING_CURL, "--binary", str(staged))

        record = json.loads(
            (self.root / "byoridb-home" / "engine.json").read_text(encoding="utf-8")
        )
        self.assertEqual(record["sha256"], digest)
        self.assertIn(f"recorded engine build: local ({digest[:12]})", output)

    def stage_local_engine(self, content=b"#!/bin/sh\nexit 0\n"):
        """A `--binary` engine, so these cases need no download and no signature."""
        import hashlib

        staged = self.root / "staged-byoridb-server"
        staged.write_bytes(content)
        staged.chmod(staged.stat().st_mode | stat.S_IXUSR)
        return staged, hashlib.sha256(content).hexdigest()

    def test_a_resolved_tag_that_could_alter_a_url_is_refused(self):
        output = self.install(
            RESOLVING_CURL,
            "--engine-tag",
            "latest",
            resolved_tag="v1.0.0 --upload-file /etc/passwd",
        )

        self.assertIn("invalid tag", output)
        self.assertNotIn("downloading engine", output)


if __name__ == "__main__":
    unittest.main()
