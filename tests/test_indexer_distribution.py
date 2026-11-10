"""Run the installer with local HTTP fixtures, without starting a real service."""
import hashlib
import io
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INDEXER = b"#!/bin/sh\n# fixture indexer\nexit 0\n"


class IndexerDistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = pathlib.Path(self.temporary.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.runtime = self.base / "runtime"
        self.runtime.mkdir()
        self.bin = self.base / "stubs"
        self.bin.mkdir()
        self.engine = self.base / "engine"
        self.engine.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.engine.chmod(0o755)
        self.assets = self.base / "assets"
        self.assets.mkdir()
        for name in ("mcp", "cli", "adapters", "templates"):
            (self.assets / name).symlink_to(ROOT / name, target_is_directory=True)
        (self.assets / "bin").mkdir()
        (self.assets / "bin" / "byori-indexer").write_bytes(INDEXER)
        (self.assets / "bin" / "byori-indexer").chmod(0o755)
        self.make_archive()
        curl = self.bin / "curl"
        curl.write_text("#!" + sys.executable + "\n" + r'''
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
url = next((a for a in args if a.startswith(('https://', 'http://'))), '')
out = pathlib.Path(args[args.index('-o') + 1]) if '-o' in args else None
base, root = pathlib.Path(os.environ['FIXTURE_BASE']), pathlib.Path(os.environ['FIXTURE_REPO'])
if '/health' in url:
    pass
elif '/api/v1/session' in url:
    if out:
        out.write_text(json.dumps({'session_id': '123'}))
    if '-w' in args:
        print('200', end='')
elif 'raw.githubusercontent.com' in url:
    shutil.copyfile(root / url.split('/v0.0.0/', 1)[1], out)
elif url.endswith('.tar.gz.sha256'):
    shutil.copyfile(base / 'indexer.sha256', out)
elif url.endswith('.tar.gz'):
    shutil.copyfile(base / 'indexer.tar.gz', out)
else:
    print('unexpected request: ' + url, file=sys.stderr)
    sys.exit(22)
''', encoding="utf-8")
        curl.chmod(0o755)

    def make_archive(self, symlink=False):
        archive = self.base / "indexer.tar.gz"
        with tarfile.open(archive, "w:gz") as handle:
            binary = tarfile.TarInfo("byori-indexer")
            if symlink:
                binary.type = tarfile.SYMTYPE
                binary.linkname = "/tmp/unwanted-indexer"
                handle.addfile(binary)
            else:
                binary.size = len(INDEXER)
                handle.addfile(binary, io.BytesIO(INDEXER))
            notice = b"fixture license\n"
            member = tarfile.TarInfo("THIRD_PARTY_LICENSES.txt")
            member.size = len(notice)
            handle.addfile(member, io.BytesIO(notice))
        (self.base / "indexer.sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest())

    def install(self, local=True):
        args = ["bash", str(ROOT / "install.sh"), "--binary", str(self.engine),
                "--tag", "v0.0.0", "--no-service", "--no-hooks", "--no-claude", "--no-codex"]
        if local:
            args += ["--assets", str(self.assets)]
        env = dict(os.environ, HOME=str(self.home), BYORIDB_HOME=str(self.runtime),
                   FIXTURE_BASE=str(self.base), FIXTURE_REPO=str(ROOT),
                   PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        return subprocess.run(args, cwd=self.base, env=env, capture_output=True, text=True, timeout=30)

    def test_bundle_installs_indexer_and_sibling_mcp_module(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        binary = self.runtime / "bin" / "byori-indexer"
        self.assertEqual(binary.read_bytes(), INDEXER)
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertEqual((self.runtime / "code_graph.py").read_bytes(), (ROOT / "mcp" / "code_graph.py").read_bytes())

    def test_missing_source_binary_fails_before_replacing_runtime(self):
        (self.assets / "bin" / "byori-indexer").unlink()
        old = self.runtime / "byoridb_mcp.py"
        old.write_text("existing runtime")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scripts/build-indexer.sh", result.stderr)
        self.assertEqual(old.read_text(), "existing runtime")

    def test_online_archive_is_checked_and_installed(self):
        result = self.install(local=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.runtime / "bin" / "byori-indexer").read_bytes(), INDEXER)
        self.assertEqual((self.runtime / "INDEXER_LICENSES.txt").read_text(), "fixture license\n")

    def test_checksum_mismatch_preserves_existing_runtime(self):
        (self.base / "indexer.sha256").write_text("0" * 64)
        old = self.runtime / "byoridb_mcp.py"
        old.write_text("existing runtime")
        result = self.install(local=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertEqual(old.read_text(), "existing runtime")

    def test_archive_cannot_supply_a_binary_symlink(self):
        self.make_archive(symlink=True)
        result = self.install(local=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid code indexer archive", result.stderr)
        self.assertFalse((self.runtime / "bin" / "byori-indexer").exists())


if __name__ == "__main__":
    unittest.main()
