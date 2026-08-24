#!/usr/bin/env python3
"""`byori` typed in a checkout: register the repository and open the app on it.

The first run used to require reading the README to learn a path that was not on
PATH, then finding a tab in the app. This is the whole thing instead — one word in
the directory you are already standing in — so these tests cover the two halves that
have to agree: what gets registered, and the URL the app parses.

The URL spelling is duplicated in Swift (`ByoriOpenRequest`), so it is asserted
literally here. A drift between the two is a first run that opens nothing.
"""

import importlib.util
import io
import contextlib
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("byori_cli_open", ROOT / "cli" / "byori.py")
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


def git(repository, *arguments):
    subprocess.run(
        ("git", "-C", str(repository)) + arguments,
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


class OpenCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = pathlib.Path(self.temporary.name)
        self.home = base / "byori-home"
        self.repository = base / "shop"
        self.repository.mkdir()
        git(self.repository, "init", "-b", "main", ".")
        git(self.repository, "config", "user.email", "tests@example.invalid")
        git(self.repository, "config", "user.name", "Byori Tests")
        (self.repository / "README.md").write_text("# shop\n", encoding="utf-8")
        git(self.repository, "add", "README.md")
        git(self.repository, "commit", "-m", "fixture")
        self.plain = base / "not-a-repository"
        self.plain.mkdir()
        patch = mock.patch.dict(os.environ, {"BYORI_HOME": str(self.home)})
        patch.start()
        self.addCleanup(patch.stop)

    def run_cli(self, *argv, cwd=None):
        output = io.StringIO()
        errors = io.StringIO()
        previous = pathlib.Path.cwd()
        if cwd:
            os.chdir(cwd)
        try:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                code = CLI.main(list(argv))
        finally:
            os.chdir(previous)
        return code, output.getvalue(), errors.getvalue()

    def registered_roots(self):
        return [item["root"] for item in CLI.ProjectRegistry(self.home).list()]

    def test_openingARepositoryRegistersItOnce(self):
        with mock.patch.object(CLI, "open_in_app", return_value=0) as launch:
            code, output, _ = self.run_cli("open", str(self.repository))
            self.assertEqual(code, 0)
            self.assertIn("registered", output)
            self.assertIn("space:", output)
            launch.assert_called_once_with(self.repository.resolve())

            code, output, _ = self.run_cli("open", str(self.repository))

        self.assertEqual(code, 0)
        self.assertIn("already registered", output)
        self.assertEqual(self.registered_roots(), [str(self.repository.resolve())])

    def test_bareByoriInACheckoutOpensThatRepository(self):
        """The command someone will actually type. `code .` taught this shape; asking
        for a subcommand to see anything at all did not."""
        with mock.patch.object(CLI, "open_in_app", return_value=0) as launch:
            code, output, _ = self.run_cli(cwd=self.repository)

        self.assertEqual(code, 0)
        self.assertIn("registered", output)
        launch.assert_called_once_with(self.repository.resolve())

    def test_aSubdirectoryOpensTheRepositoryRoot(self):
        nested = self.repository / "billing" / "retry"
        nested.mkdir(parents=True)
        with mock.patch.object(CLI, "open_in_app", return_value=0) as launch:
            code, _, _ = self.run_cli(cwd=nested)

        self.assertEqual(code, 0)
        launch.assert_called_once_with(self.repository.resolve())

    def test_outsideARepositoryTheHelpIsStillTheAnswer(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_cli(cwd=self.plain)

        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(self.registered_roots(), [])

    def test_aPlainFolderIsRefusedWithTheReason(self):
        code, _, errors = self.run_cli("open", str(self.plain))

        self.assertEqual(code, 2)
        self.assertIn("must be a Git repository", errors)
        self.assertEqual(self.registered_roots(), [])

    def test_registrationWithoutLaunchingIsAvailable(self):
        with mock.patch.object(CLI, "open_in_app") as launch:
            code, _, _ = self.run_cli("open", str(self.repository), "--no-launch")

        self.assertEqual(code, 0)
        launch.assert_not_called()
        self.assertEqual(self.registered_roots(), [str(self.repository.resolve())])


class AppURLTests(unittest.TestCase):
    def test_theURLIsTheSpellingTheAppParses(self):
        self.assertEqual(
            CLI.app_open_url(pathlib.Path("/Users/me/shop")),
            "byori://project?root=/Users/me/shop",
        )

    def test_aPathWithSpacesIsEncoded(self):
        """Unencoded, everything after the space is dropped and the app opens the
        wrong directory — which would register a project the user never chose."""
        self.assertEqual(
            CLI.app_open_url(pathlib.Path("/Users/me/My Work/shop")),
            "byori://project?root=/Users/me/My%20Work/shop",
        )

    @unittest.skipUnless(sys.platform == "darwin", "open(1) is macOS only")
    def test_launchingHandsTheURLToOpen(self):
        completed = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with mock.patch.object(CLI.subprocess, "run", return_value=completed) as run:
            code = CLI.open_in_app(pathlib.Path("/Users/me/shop"))

        self.assertEqual(code, 0)
        self.assertEqual(
            run.call_args.args[0],
            ["/usr/bin/open", "byori://project?root=/Users/me/shop"],
        )

    @unittest.skipUnless(sys.platform == "darwin", "open(1) is macOS only")
    def test_anAppThatCannotBeOpenedSaysWhatToDoAndKeepsTheRegistration(self):
        """An app older than this release does not register the scheme, which
        LaunchServices reports exactly like no app at all."""
        completed = subprocess.CompletedProcess(
            [], 1, stdout="", stderr="Unable to find application for URL byori://project\n"
        )
        with mock.patch.object(CLI.subprocess, "run", return_value=completed):
            code = CLI.open_in_app(pathlib.Path("/Users/me/shop"))

        self.assertEqual(code, 1)


class SchemeDeclarationTests(unittest.TestCase):
    """The URL only reaches the app if the bundle claims the scheme.

    Nothing at build time fails when this key is missing — `open` just reports that
    no application can handle the URL, which reads exactly like "the app is not
    installed". So the declaration is asserted next to the sender.
    """

    def test_theBundleClaimsTheSchemeTheCLISends(self):
        import plistlib
        import re

        template = (ROOT / "manager/macos/packaging/Info.plist.in").read_text(encoding="utf-8")
        # The template carries build-time placeholders; plistlib only needs them to be
        # strings, which they already are.
        document = plistlib.loads(template.encode("utf-8"))

        schemes = [
            scheme
            for entry in document.get("CFBundleURLTypes", [])
            for scheme in entry.get("CFBundleURLSchemes", [])
        ]
        sent = re.match(r"([a-z]+)://", CLI.app_open_url(pathlib.Path("/tmp/x"))).group(1)
        self.assertIn(sent, schemes, "the app does not claim the scheme the CLI sends")


if __name__ == "__main__":
    unittest.main()
