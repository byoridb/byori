#!/usr/bin/env python3
"""The DMG's runtime bundle must carry every file install.sh reads from --assets.

The app updates by running the bundled install.sh with --assets pointing at the
bundle. `get` there is a plain cp, so one repo path the installer wants but the
packager forgot makes every in-app update die at validation ("No such file or
directory") and then fail to roll back cleanly.
"""

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "install.sh").read_text()
PACKAGER = (ROOT / "scripts" / "build-macos-dmg.sh").read_text()


class DmgBundlesInstallerAssets(unittest.TestCase):
    def test_every_installer_asset_is_packaged(self):
        wanted = set(re.findall(r'^\s*get "([^"$]+)"', INSTALLER, re.M))
        self.assertIn("adapters/claude/agents/byori-bulk-reader.md", wanted)
        # Templates are packaged by bare name, so compare on the file name.
        missing = sorted(p for p in wanted if pathlib.PurePath(p).name not in PACKAGER)
        self.assertEqual(missing, [], "install.sh gets files build-macos-dmg.sh does not bundle")

    def test_packaged_assets_exist_in_repo(self):
        listed = re.findall(r'^\s+"((?:adapters|templates|cli|mcp)/[^"]+)"$', PACKAGER, re.M)
        for rel in listed:
            self.assertTrue((ROOT / rel).is_file(), rel)


if __name__ == "__main__":
    unittest.main()
