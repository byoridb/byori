"""The app bridge binds memory to its checkout without leaking request bodies."""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("memory_cli", ROOT / "cli/byori.py")
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


class MemoryCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name).resolve() / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-b", "main", str(self.root)], check=True, capture_output=True)
        patch = mock.patch.dict(os.environ, {
            "BYORI_HOME": str(self.root.parent / "state"),
            "BYORIDB_HOME": str(self.root.parent / "runtime"),
            "CLAUDE_PROJECT_DIR": "/another/project",
        })
        patch.start()
        self.addCleanup(patch.stop)

    def invoke(self, action, *args):
        output, error = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            status = CLI.main(["memory", action, str(self.root), "--space", "project_space", "--json", *args])
        return status, output.getvalue(), error.getvalue()

    def test_readonly_profile_explicit_root_and_cleanup(self):
        previous = pathlib.Path.cwd()
        for action in ("read", "resume"):
            with self.subTest(action=action), mock.patch.object(CLI, "MemoryWriter") as writer:
                def read(action, request):
                    self.assertEqual(pathlib.Path.cwd(), self.root)
                    self.assertEqual(os.environ["CLAUDE_PROJECT_DIR"], str(self.root))
                    return {"items": [], "links": [], "truncated": False}
                writer.return_value.module.memory_cli_action.side_effect = read
                status, output, error = self.invoke(action)
                self.assertEqual((status, error), (0, ""))
                self.assertEqual(json.loads(output)["items"], [])
                writer.assert_called_once_with("project_space", self.root.parent / "runtime", profile="readonly")
                writer.return_value.module._logout.assert_called_once_with()
            self.assertEqual(pathlib.Path.cwd(), previous)
            self.assertEqual(os.environ["CLAUDE_PROJECT_DIR"], "/another/project")

    def test_writes_use_safe_profile_and_exact_private_payload(self):
        body = {"goal": "literal $(test)\n한글", "task_id": "task-1"}
        path = self.root.parent / "request.json"
        path.write_text(json.dumps(body), encoding="utf-8")
        for action in ("checkpoint", "policy"):
            with self.subTest(action=action), mock.patch.object(CLI, "MemoryWriter") as writer:
                writer.return_value.module.memory_cli_action.return_value = {"ok": True}
                self.assertEqual(self.invoke(action, "--payload-file", str(path))[0], 0)
                self.assertEqual(writer.call_args.kwargs["profile"], "safe")
                writer.return_value.module.memory_cli_action.assert_called_once_with(action, body)

    def test_failure_logs_out_and_restores_checkout(self):
        previous = pathlib.Path.cwd()
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.module.memory_cli_action.side_effect = RuntimeError("unavailable")
            status, output, error = self.invoke("resume")
            self.assertEqual(status, 2)
            self.assertEqual(output, "")
            self.assertIn("could not access project memory", error)
            writer.return_value.module._logout.assert_called_once_with()
        self.assertEqual(pathlib.Path.cwd(), previous)
        self.assertEqual(os.environ["CLAUDE_PROJECT_DIR"], "/another/project")

    def test_bad_or_oversized_payload_never_connects(self):
        bad_file = self.root.parent / "invalid.json"
        bad_file.write_bytes(b"\xff")
        symlink = self.root.parent / "link.json"
        symlink.symlink_to(bad_file)
        for arguments in (("--payload", "[]"), ("--payload", "{"),
                          ("--payload", "x" * 65537), ("--payload-file", str(bad_file)),
                          ("--payload-file", str(symlink))):
            with self.subTest(arguments=arguments[:1]), mock.patch.object(CLI, "MemoryWriter") as writer:
                self.assertEqual(self.invoke("checkpoint", *arguments)[0], 2)
                writer.assert_not_called()

    def test_display_bounds_keep_json_valid_and_pagination_explicit(self):
        items = [{"vid": str(i), "body": "한" * 5000} for i in range(100)]
        result = {"items": items, "links": [], "truncated": False}
        with mock.patch.object(CLI, "MemoryWriter") as writer:
            writer.return_value.module.memory_cli_action.return_value = result
            status, output, error = self.invoke("read", "--payload", '{"offset":20}')
        self.assertEqual((status, error), (0, ""))
        self.assertLessEqual(len(output.encode()), 192 * 1024)
        parsed = json.loads(output)
        self.assertGreater(len(parsed["items"]), 0)
        self.assertTrue(parsed["truncated"])
        self.assertTrue(all(item["body_truncated"] for item in parsed["items"]))
        self.assertEqual(parsed["next_offset"], 20 + len(parsed["items"]))


if __name__ == "__main__":
    unittest.main()
