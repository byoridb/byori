#!/usr/bin/env python3
"""Which ByoriDB engine release `install.sh` decides to install.

The app's single install button passes `--engine-tag latest`, so the engine stops
waiting on a byori release to move forward. These tests run the real installer
with a stubbed `curl` and let it fail at the engine download: the failure names
the tag it resolved, which is the decision under test. Nothing is downloaded, no
engine is started, and `--assets` keeps every Byori-owned file local.
"""

import os
import pathlib
import stat
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
PINNED_TAG = "v0.4.0"

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
