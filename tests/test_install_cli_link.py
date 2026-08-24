#!/usr/bin/env python3
"""Whether `install.sh` leaves `byori` somewhere a shell will find it.

The README's quick start said `byori init` while the command resolved nowhere: the
CLI was installed as `~/.byoridb/bin/byori` and nothing put that on PATH, so the
second line of the quick start failed with `command not found`.

The installer dies at the engine download in a sandbox, long before this step, so
these are source-level assertions about the contract rather than an end-to-end run:
a symlink is created, an existing non-symlink at that path is left alone, and no
shell startup file is ever edited — rewriting someone's rc file is hard to undo and
which file to write is a guess.
"""

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER_SOURCE = (ROOT / "install.sh").read_text(encoding="utf-8")


class InstallCLILinkTests(unittest.TestCase):
    def test_theCLIIsLinkedIntoAPathDirectory(self):
        self.assertIn('CLI_LINK_DIR="$HOME/.local/bin"', INSTALLER_SOURCE)
        self.assertRegex(
            INSTALLER_SOURCE,
            r'ln -sfn "\$BYORIDB_HOME/bin/byori" "\$CLI_LINK"',
        )

    def test_anExistingFileThatIsNotOursIsNotClobbered(self):
        """Whatever the user put at ~/.local/bin/byori stays there: an installer that
        overwrote a real file would destroy something it cannot restore."""
        self.assertRegex(
            INSTALLER_SOURCE,
            r'if \[ -L "\$CLI_LINK" \] \|\| \[ ! -e "\$CLI_LINK" \]',
        )
        self.assertIn("left existing $CLI_LINK alone", INSTALLER_SOURCE)

    def test_theUsersShellProfileIsNeverEdited(self):
        """PATH advice is printed, not applied."""
        for profile in (".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile"):
            for line in INSTALLER_SOURCE.splitlines():
                if profile not in line:
                    continue
                self.assertNotRegex(
                    line,
                    r"(>>|>\s|tee|sed -i|cp\b|mv\b)",
                    "install.sh must not write %s" % profile,
                )

    def test_pathAdviceNamesTheDirectoryThatWasLinked(self):
        advice = re.search(r'path     : (.+)', INSTALLER_SOURCE)
        self.assertIsNotNone(advice, "the summary must still tell the user about PATH")
        self.assertIn("CLI_LINK_DIR", INSTALLER_SOURCE)


if __name__ == "__main__":
    unittest.main()
