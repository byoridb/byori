"""Real local Git fixtures for the deterministic handbook vertical slice."""

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cli"))
import handbook


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout.strip()


class HandbookTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name) / "shop"
        self.root.mkdir()
        git(self.root, "init", "-b", "main")
        git(self.root, "config", "user.name", "Byori tests")
        git(self.root, "config", "user.email", "test@example.invalid")
        (self.root / "README.md").write_text(
            "# Shop\n\nLocal payments service.\n\n## Constraint\n\n"
            "Retry payments at most three times, only for transient failures.\n", encoding="utf-8")
        (self.root / "docs" / "adr").mkdir(parents=True)
        (self.root / "docs" / "adr" / "001-retries.md").write_text(
            "# Retry limits\n\nStatus: proposed\n\n## Reason\n\n"
            "The provider can duplicate charges after repeated requests.\n", encoding="utf-8")
        git(self.root, "add", ".")
        git(self.root, "commit", "-m", "Document retry boundaries")

    def compile(self, **kwargs):
        return handbook.compile_handbook(self.root, **kwargs)

    def cli(self, *args):
        return subprocess.run([sys.executable, "-B", str(ROOT / "cli" / "byori.py"),
                               "handbook", *args, str(self.root), "--json"],
                              capture_output=True, text=True)

    def test_preview_is_deterministic_and_nonmutating(self):
        first = self.compile()
        self.assertEqual(first, self.compile())
        self.assertFalse((self.root / ".byori").exists())
        self.assertIn("only for transient failures", first["handbook"])
        self.assertTrue(first["evidence"]["claims"])
        self.assertTrue(all(c["state"] == "unverified" for c in first["evidence"]["claims"]))

    def test_source_excerpts_and_dependencies_are_exact(self):
        build = self.compile()
        sources = {s["id"]: s for s in build["evidence"]["sources"]}
        for claim in build["evidence"]["claims"]:
            self.assertIn(claim["body"], sources[claim["source_id"]]["content"])
            self.assertIn({"source": claim["id"], "relation": "derived_from", "target": claim["source_id"]},
                          build["evidence"]["relationships"])

    def test_lifecycle_labels_qualify_every_excerpt_without_promoting_policy(self):
        build = self.compile()
        adr = next(source for source in build["evidence"]["sources"] if source["path"].endswith("001-retries.md"))
        claims = [claim for claim in build["evidence"]["claims"] if claim["source_id"] == adr["id"]]
        self.assertGreater(len(claims), 1)
        self.assertTrue(all(claim["source_declared_states"] == ["proposed"] for claim in claims))
        self.assertTrue(all(claim["state"] == "unverified" for claim in claims))
        self.assertIn("do not adopt it as an active rule", build["handbook"])
        historical = self.compile(accepted_records=[{"name": "decision:old", "body": "Retry five times.", "state": "superseded"}])
        self.assertIn("Source-declared lifecycle: `superseded`", historical["handbook"])

    def test_legacy_note_identity_is_preserved_without_renaming(self):
        original = {"type": "note", "name": "pref:korean-responses", "vid": "9223372036854775001",
                    "body": "Use Korean for replies.", "provenance": {"locator": "original-checkpoint"}}
        build = self.compile(accepted_records=[original])
        source = next(source for source in build["evidence"]["sources"] if source["kind"] == "checkpoint")
        self.assertEqual(source["metadata"]["name"], original["name"])
        self.assertEqual(source["metadata"]["vid"], original["vid"])
        self.assertEqual(source["metadata"]["provenance"], original["provenance"])

    def test_existing_original_journal_is_read_and_its_revision_invalidates_output(self):
        import handbook_records
        envelope = {"complete": True, "source": {"kind": "test-originals", "snapshot": "one"},
                    "records": [{"type": "note", "name": "pref:review-window", "vid": "19",
                                 "body": "Review during the morning window.", "scope": "checkout",
                                 "provenance": {"locator": "accepted-checkpoint"}}]}
        first = handbook_records.import_records(self.root, envelope)
        built = handbook.publish_handbook(self.compile())
        self.assertIn("morning window", handbook.read_handbook(self.root)["handbook"])
        self.assertEqual(built["evidence"]["record_mode"], "provided")
        checkpoint = next(source for source in built["evidence"]["sources"] if source["kind"] == "checkpoint")
        self.assertEqual(checkpoint["metadata"]["revision"], first["revision"])
        envelope["records"][0]["body"] = "Review during the afternoon window."
        handbook_records.import_records(self.root, envelope, expected_revision=first["revision"])
        self.assertEqual(handbook.handbook_status(self.root)["state"], "stale")
        with self.assertRaises(handbook.HandbookError):
            handbook.publish_handbook(built)
        rebuilt = handbook.publish_handbook(self.compile())
        self.assertIn("afternoon window", rebuilt["handbook"])
        from unittest import mock
        with mock.patch.object(handbook_records, "load_records", side_effect=handbook_records.RecordError("snapshot unavailable")):
            self.assertIsNone(handbook.read_handbook(self.root)["handbook"])
        self.assertTrue((self.root / ".byori" / "records" / "snapshots" / (first["revision"] + ".json")).exists())

    def test_publish_noop_and_changed_source_freshness(self):
        first = self.compile()
        self.assertTrue(handbook.publish_handbook(first)["changed"])
        self.assertFalse(handbook.publish_handbook(first)["changed"])
        self.assertEqual(handbook.handbook_status(self.root)["state"], "current")
        self.assertEqual(handbook.read_handbook(self.root)["handbook"], first["handbook"])
        with (self.root / "README.md").open("a") as f:
            f.write("\n## Correction\n\nOnly two retries are permitted now.\n")
        self.assertEqual(handbook.handbook_status(self.root)["state"], "stale")
        self.assertIsNone(handbook.read_handbook(self.root)["handbook"])
        with self.assertRaises(handbook.HandbookError):
            handbook.publish_handbook(first)
        second = self.compile()
        handbook.publish_handbook(second)
        self.assertNotEqual(first["generation"], second["generation"])
        self.assertTrue((self.root / ".byori" / "generations" / first["generation"] / "evidence.json").is_file())

    def test_manual_edit_is_not_overwritten(self):
        handbook.publish_handbook(self.compile())
        path = self.root / ".byori" / "handbook.md"
        changed = path.read_text() + "manual correction\n"
        path.write_text(changed)
        with self.assertRaises(handbook.HandbookError):
            handbook.publish_handbook(self.compile())
        self.assertEqual(path.read_text(), changed)
        self.assertEqual(handbook.handbook_status(self.root)["state"], "unavailable")

    def test_generated_evidence_is_locally_ignored_without_editing_gitignore(self):
        exclude = self.root / ".git" / "info" / "exclude"
        original = exclude.read_bytes()
        handbook.publish_handbook(self.compile())
        self.assertTrue(exclude.read_bytes().startswith(original))
        self.assertIn(".byori/handbook.md", git(self.root, "check-ignore", ".byori/handbook.md"))
        self.assertFalse((self.root / ".gitignore").exists())
        git(self.root, "add", ".")
        self.assertEqual(git(self.root, "ls-files", "--", ".byori"), "")
        first = exclude.read_bytes()
        handbook.publish_handbook(self.compile())
        self.assertEqual(exclude.read_bytes(), first)

    def test_already_tracked_generated_output_is_not_overwritten(self):
        output = self.root / ".byori"
        output.mkdir()
        (output / "old.txt").write_text("user data")
        git(self.root, "add", ".byori/old.txt")
        with self.assertRaisesRegex(handbook.HandbookError, "already tracked"):
            handbook.publish_handbook(self.compile())
        self.assertEqual((output / "old.txt").read_text(), "user data")
        self.assertFalse((output / "handbook.md").exists())

    def test_git_exclude_symlink_is_refused(self):
        exclude = self.root / ".git" / "info" / "exclude"
        exclude.unlink()
        outside = pathlib.Path(self.temporary.name) / "private"
        outside.write_text("user settings")
        exclude.symlink_to(outside)
        with self.assertRaises(handbook.HandbookError):
            handbook.publish_handbook(self.compile())
        self.assertEqual(outside.read_text(), "user settings")

    def test_secret_content_is_withheld_from_both_outputs(self):
        secret = "ghp_" + "X" * 32
        (self.root / "README.md").write_text("# Credentials\n\n" + secret + "\n")
        build = self.compile()
        self.assertNotIn(secret, json.dumps(build))
        self.assertGreater(build["evidence"]["sensitive_sources_withheld"], 0)

    def test_small_budget_omits_whole_sections(self):
        (self.root / "README.md").write_text("# Huge\n\n" + "x" * 10000 + "\n")
        build = self.compile(max_chars=2048)
        self.assertLessEqual(len(build["handbook"]), 2048)
        self.assertGreater(build["evidence"]["omitted_sections"], 0)
        self.assertNotIn("x" * 30, build["handbook"])
        self.assertTrue(any("x" * 10000 in s["content"] for s in build["evidence"]["sources"]))

    def test_accepted_records_are_never_implicitly_dropped(self):
        records = [{"name": "decision:payment-limit", "body": "Manual acceptance: three retries, transient failures only."}]
        build = self.compile(accepted_records=records)
        handbook.publish_handbook(build, accepted_records=records)
        self.assertEqual(handbook.handbook_status(self.root)["state"], "unavailable")
        with self.assertRaises(handbook.HandbookError):
            handbook.publish_handbook(self.compile())
        self.assertEqual(handbook.handbook_status(self.root, accepted_records=records)["state"], "current")

    def test_missing_and_preview_cli(self):
        self.assertEqual(handbook.handbook_status(self.root)["state"], "missing")
        result = self.cli("preview")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["published"])
        self.assertFalse((self.root / ".byori").exists())

    def test_cli_cannot_be_redirected_by_ambient_git_environment(self):
        other = pathlib.Path(self.temporary.name) / "other"
        other.mkdir()
        git(other, "init", "-b", "main")
        (other / "README.md").write_text("# Wrong project\n\nDo not leak this context.\n")
        git(other, "add", ".")
        environment = dict(os.environ, GIT_DIR=str(other / ".git"), GIT_WORK_TREE=str(other))
        result = subprocess.run([sys.executable, "-B", str(ROOT / "cli" / "byori.py"),
                                 "handbook", "preview", str(self.root), "--json"],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(pathlib.Path(payload["project_root"]), self.root.resolve())
        self.assertNotIn("Do not leak this context", payload["handbook"])

    def test_evidence_reads_pin_generation_and_withhold_stale_sources(self):
        build = handbook.publish_handbook(self.compile())
        source = build["evidence"]["sources"][0]
        listing = handbook.read_evidence(self.root, build["generation"])
        self.assertTrue(listing["evidence"]["sources"])
        self.assertNotIn("content", listing["evidence"]["sources"][0])
        detailed = handbook.read_evidence(self.root, build["generation"], source_id=source["id"])
        self.assertEqual(detailed["evidence"]["source"], source)
        self.assertIsNone(handbook.read_evidence(self.root, "0" * 64)["evidence"])
        missing = handbook.read_evidence(self.root, build["generation"], source_id="source:" + "0" * 24)
        self.assertIsNone(missing["evidence"])
        result = subprocess.run([sys.executable, "-B", str(ROOT / "cli" / "byori.py"),
                                 "handbook", "evidence", str(self.root), "--generation",
                                 build["generation"], "--source", source["id"], "--json"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["evidence"]["source"], source)
        (self.root / "README.md").write_text("# Changed\n\nThis replaces the selected source.\n")
        self.assertIsNone(handbook.read_evidence(self.root, build["generation"])["evidence"])

    def test_init_opt_in_and_build_cli(self):
        result = subprocess.run([sys.executable, "-B", str(ROOT / "cli" / "byori.py"),
                                 "init", str(self.root), "--handbook", "--dry-run", "--json"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["published"])
        result = self.cli("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["published"])
        self.assertEqual(self.cli("status").returncode, 0)


if __name__ == "__main__":
    unittest.main()
