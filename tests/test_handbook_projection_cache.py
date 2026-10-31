"""Durable cache fixtures only: real temporary Git metadata, no live runtime."""

import contextlib
import copy
import fcntl
import hashlib
import hmac
import json
import os
import pathlib
import select
import stat
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "cli"))
import handbook_projection_cache as storage
import handbook_sources
from handbook_projection_cache import ProjectionCache


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"), allow_nan=False).encode("utf-8")


def example(body="compiler fixture — 한글"):
    return {"keys": {"a": hashlib.sha256(b"fresh a").hexdigest(),
                     "b": hashlib.sha256(b"fresh b").hexdigest()},
            "edges": [["a", "depends_on", "b"]],
            "units": {"a": {"claims": [{"text": body, "ordinal": 1}], "conditions": []},
                      "b": {"claims": [], "lifecycle": None}}}


class ProjectionCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="byori-projection-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name).resolve()
        self.root = self.base / "checkout"
        self.root.mkdir()
        self.git(self.root, "init", "--quiet")
        canonical, self.git_dir = handbook_sources._canonical_repository(self.root)
        self.assertEqual(canonical, self.root)
        self.scope = (str(self.root), hashlib.sha256(
            handbook_sources._encode_identity(str(self.git_dir))).hexdigest(),
            "1.1.0", "2", hashlib.sha256(b"compiler implementation fixture").hexdigest())
        self.cache = ProjectionCache(self.root, self.scope)
        self.directory = self.git_dir / storage.DIRECTORY
        self.path = self.directory / "entry.json"
        self.key = self.directory / "key"
        self.lock = self.directory / "write.lock"
        self.entry = example()

    @staticmethod
    def git(root, *arguments):
        env = os.environ.copy()
        for name in tuple(env):
            if name.startswith("GIT_"):
                env.pop(name, None)
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
                   GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
        return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-C", str(root),
                               *arguments], env=env, check=True, capture_output=True).stdout

    def seed(self):
        self.assertTrue(self.cache.save(self.entry))
        self.assertEqual(self.cache.load(), self.entry)

    def raw(self, raw):
        # Fixture tampering deliberately changes only the temporary cache.
        self.path.write_bytes(raw)

    def envelope(self):
        return json.loads(self.path.read_bytes())

    def authenticated(self, envelope):
        payload = {key: envelope[key] for key in ("format_version", "scope", "entry")}
        envelope["mac"] = hmac.new(self.key.read_bytes(), encoded(payload), hashlib.sha256).hexdigest()
        self.raw(encoded(envelope))

    def tree(self):
        return sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))

    def test_constructor_and_cold_load_are_read_only(self):
        before = self.tree()
        with mock.patch.object(storage.os, "mkdir", side_effect=AssertionError("write")), \
                mock.patch.object(storage.os, "write", side_effect=AssertionError("write")):
            cache = ProjectionCache(self.root, list(self.scope))
            self.assertIsNone(cache.load())
        self.assertEqual(self.tree(), before)
        self.assertFalse(self.directory.exists())

    def test_constructor_does_not_even_resolve_git(self):
        with mock.patch.object(handbook_sources, "_canonical_repository", side_effect=OSError):
            cache = ProjectionCache(self.root, self.scope)
            self.assertIsNone(cache.load())
            self.assertFalse(cache.save(self.entry))

    def test_roundtrip_private_modes_key_and_authenticated_whole_payload(self):
        self.seed()
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        for path in (self.key, self.path, self.lock):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(path.stat().st_nlink, 1)
            self.assertEqual(path.stat().st_uid, os.getuid())
        self.assertEqual(len(self.key.read_bytes()), 32)
        envelope = self.envelope()
        payload = {key: envelope[key] for key in ("format_version", "scope", "entry")}
        expected = hmac.new(self.key.read_bytes(), encoded(payload), hashlib.sha256).hexdigest()
        self.assertEqual(envelope["mac"], expected)
        self.assertEqual(set(envelope), {"format_version", "scope", "entry", "mac"})

    def test_warm_constructor_and_load_do_not_write(self):
        self.seed()
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns)
                  for path in (self.key, self.path, self.lock)}
        with mock.patch.object(storage.os, "write", side_effect=AssertionError("write")), \
                mock.patch.object(storage.os, "mkdir", side_effect=AssertionError("write")), \
                mock.patch.object(storage.os, "replace", side_effect=AssertionError("write")):
            self.assertEqual(ProjectionCache(self.root, self.scope).load(), self.entry)
        self.assertEqual(before, {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in before})

    def test_list_scope_and_tuple_edges_normalize_to_json(self):
        self.entry["edges"] = [("a", "affects", "b")]
        self.assertTrue(ProjectionCache(self.root, list(self.scope)).save(self.entry))
        expected = copy.deepcopy(self.entry)
        expected["edges"] = [["a", "affects", "b"]]
        self.assertEqual(self.cache.load(), expected)

    def test_empty_entry_is_valid(self):
        entry = {"keys": {}, "edges": [], "units": {}}
        self.assertTrue(self.cache.save(entry))
        self.assertEqual(self.cache.load(), entry)

    def test_caller_mutations_do_not_alias_disk_or_load_results(self):
        original = copy.deepcopy(self.entry)
        self.seed()
        self.entry["units"]["a"]["claims"][0]["text"] = "caller edit"
        loaded = self.cache.load()
        self.assertEqual(loaded, original)
        loaded["units"].clear()
        self.assertEqual(self.cache.load(), original)

    def test_new_process_loads_without_receiving_key_in_environment(self):
        self.seed()
        script = ("import json,sys; from handbook_projection_cache import ProjectionCache; "
                  "value=ProjectionCache(sys.argv[1],json.loads(sys.argv[2])).load(); "
                  "print(json.dumps(value,sort_keys=True,ensure_ascii=False))")
        env = os.environ.copy()
        env["PYTHONPATH"] = str(pathlib.Path(storage.__file__).parent)
        result = subprocess.run([sys.executable, "-B", "-c", script, str(self.root), json.dumps(self.scope)],
                                env=env, capture_output=True, timeout=15, check=True)
        self.assertEqual(json.loads(result.stdout), self.entry)
        self.assertEqual(result.stderr, b"")

    def test_scope_versions_and_implementation_identity_miss(self):
        self.seed()
        old = self.path.read_bytes()
        for index in range(5):
            scope = list(self.scope)
            scope[index] = "0" * 64 if index in (1, 4) else "different"
            with self.subTest(index=index):
                cache = ProjectionCache(self.root, scope)
                self.assertIsNone(cache.load())
                if index < 2:
                    self.assertFalse(cache.save(self.entry))
        self.assertEqual(self.path.read_bytes(), old)

    def test_scope_changes_save_with_existing_key_and_replace_single_entry(self):
        self.seed()
        key = self.key.read_bytes()
        scope = list(self.scope)
        scope[4] = hashlib.sha256(b"new implementation").hexdigest()
        changed = ProjectionCache(self.root, scope)
        self.assertTrue(changed.save(example("new")))
        self.assertEqual(changed.load(), example("new"))
        self.assertIsNone(self.cache.load())
        self.assertEqual(self.key.read_bytes(), key)

    def test_invalid_scope_and_noncanonical_or_nested_root_do_not_create(self):
        nested = self.root / "nested"
        nested.mkdir()
        link = self.base / "alias"
        link.symlink_to(self.root, target_is_directory=True)
        cases = [(self.root, ()), (self.root, "not a scope"), (nested, self.scope),
                 (link, self.scope), (self.root, [*self.scope[:4], "not a sha"]),
                 (self.root, [*self.scope, None]), (self.root, [*self.scope, "\ud800"])]
        for root, scope in cases:
            with self.subTest(root=root, scope=repr(scope)):
                cache = ProjectionCache(root, scope)
                self.assertIsNone(cache.load())
                self.assertFalse(cache.save(self.entry))
        self.assertFalse(self.directory.exists())

    def test_separate_git_metadata_is_resolved_not_guessed(self):
        root = self.base / "separate-checkout"
        root.mkdir()
        metadata = self.base / "separate-metadata"
        self.git(root, "init", "--quiet", "--separate-git-dir", str(metadata))
        top, git_dir = handbook_sources._canonical_repository(root)
        scope = (str(top), hashlib.sha256(handbook_sources._encode_identity(str(git_dir))).hexdigest(),
                 *self.scope[2:])
        cache = ProjectionCache(top, scope)
        self.assertTrue(cache.save(self.entry))
        self.assertEqual(cache.load(), self.entry)
        self.assertTrue((metadata / storage.DIRECTORY / "entry.json").exists())
        self.assertTrue((root / ".git").is_file())
        self.assertFalse((root / storage.DIRECTORY).exists())

    def test_copy_cache_from_another_checkout_cannot_authenticate(self):
        self.seed()
        old = self.path.read_bytes()
        root = self.base / "other-checkout"
        root.mkdir()
        self.git(root, "init", "--quiet")
        top, git_dir = handbook_sources._canonical_repository(root)
        scope = (str(top), hashlib.sha256(handbook_sources._encode_identity(str(git_dir))).hexdigest(),
                 *self.scope[2:])
        other = ProjectionCache(top, scope)
        self.assertTrue(other.save(self.entry))
        other_path = git_dir / storage.DIRECTORY / "entry.json"
        envelope = json.loads(old)
        envelope["scope"] = list(scope)
        other_path.write_bytes(encoded(envelope))
        self.assertIsNone(other.load())

    def test_payload_and_recomputed_unkeyed_digest_are_not_trusted(self):
        self.seed()
        envelope = self.envelope()
        envelope["entry"]["units"]["a"] = {"claims": [{"text": "untrusted claim"}]}
        envelope["entry"]["keys"]["a"] = hashlib.sha256(b"untrusted claim").hexdigest()
        payload = {key: envelope[key] for key in ("format_version", "scope", "entry")}
        envelope["mac"] = hashlib.sha256(encoded(payload)).hexdigest()
        self.raw(encoded(envelope))
        self.assertIsNone(self.cache.load())

    def test_every_envelope_field_is_bound_or_strictly_rejected(self):
        self.seed()
        original = self.path.read_bytes()
        changes = [("mac", "0" * 64), ("scope", [*self.scope, "extra"]),
                   ("format_version", 2), ("format_version", True),
                   ("entry", example("edited")), ("unknown", "extension")]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                envelope = json.loads(original)
                envelope[key] = value
                self.raw(encoded(envelope))
                self.assertIsNone(self.cache.load())

    def test_typed_edges_and_input_keys_are_authenticated(self):
        self.seed()
        original = self.path.read_bytes()
        for field in ("edges", "keys"):
            envelope = json.loads(original)
            if field == "edges":
                envelope["entry"][field] = [["a", "affects", "b"]]
            else:
                envelope["entry"][field]["a"] = "0" * 64
            self.raw(encoded(envelope))
            self.assertIsNone(self.cache.load())

    def test_malformed_utf8_json_unicode_depth_duplicates_and_constants_miss(self):
        self.seed()
        cases = [b"", b"{", b"\xff", b"[]", b"null", b'{"entry":1,"entry":2}',
                 b'"\\ud800"', b"[" * 1500 + b"0" + b"]" * 1500, b"NaN", b"Infinity"]
        for raw in cases:
            with self.subTest(raw=raw[:30]):
                self.raw(raw)
                self.assertIsNone(self.cache.load())

    def test_authenticated_but_invalid_entry_shapes_still_miss(self):
        self.seed()
        original = self.envelope()
        cases = []
        for field, value in (("keys", []), ("units", []), ("edges", {})):
            entry = example()
            entry[field] = value
            cases.append(entry)
        entry = example()
        entry["units"].pop("a")
        cases.append(entry)
        entry = example()
        entry["keys"]["a"] = "invalid"
        cases.append(entry)
        entry = example()
        entry["edges"] = [["a", "derived_from", "b"]]
        cases.append(entry)
        entry = example()
        entry["edges"] = [["a", "depends_on", "absent"]]
        cases.append(entry)
        entry = example()
        entry["units"]["a"] = []
        cases.append(entry)
        entry = example()
        entry["extra"] = 1
        cases.append(entry)
        for entry in cases:
            with self.subTest(entry=entry):
                envelope = copy.deepcopy(original)
                envelope["entry"] = entry
                self.authenticated(envelope)
                self.assertIsNone(self.cache.load())
                self.assertFalse(self.cache.save(entry))

    def test_strict_depth_unicode_numbers_and_collection_bounds_on_save(self):
        invalid = []
        deep = "leaf"
        for _ in range(40):
            deep = [deep]
        invalid.extend([deep, "\ud800", float("nan"), 1 << 100, object(), [0] * 65537])
        for value in invalid:
            with self.subTest(kind=type(value).__name__):
                entry = example()
                entry["units"]["a"]["invalid"] = value
                self.assertFalse(self.cache.save(entry))
        self.assertFalse(self.directory.exists())

    def test_cyclic_caller_entry_fails_without_mutation(self):
        self.entry["units"]["a"]["cycle"] = self.entry
        self.assertFalse(self.cache.save(self.entry))
        self.assertFalse(self.directory.exists())

    def test_source_count_bound(self):
        entry = {"keys": {str(i): "a" * 64 for i in range(4097)},
                 "units": {str(i): {} for i in range(4097)}, "edges": []}
        self.assertFalse(self.cache.save(entry))
        self.assertFalse(self.directory.exists())

    def test_bounded_encoded_file_and_custom_limit(self):
        self.seed()
        small = ProjectionCache(self.root, self.scope, max_bytes=512)
        before = self.path.read_bytes()
        self.assertIsNone(small.load())
        self.assertFalse(small.save(example("x" * 600)))
        self.assertEqual(self.path.read_bytes(), before)
        self.raw(b" " * (storage.MAX_BYTES + 1))
        with mock.patch.object(storage.os, "read", side_effect=AssertionError("unbounded read")):
            # The key still needs one bounded read; test the cache reader directly.
            with contextlib.ExitStack() as stack:
                parent = os.open(self.directory, os.O_RDONLY)
                stack.callback(os.close, parent)
                fd, _ = storage._file(stack, parent, "entry.json")
                with self.assertRaises(ValueError):
                    storage._read(fd, parent, "entry.json", storage.MAX_BYTES)

    def test_invalid_byte_limits_disable_cache(self):
        for limit in (0, -1, True, None, storage.MAX_BYTES + 1):
            cache = ProjectionCache(self.root, self.scope, max_bytes=limit)
            self.assertIsNone(cache.load())
            self.assertFalse(cache.save(self.entry))
        self.assertFalse(self.directory.exists())

    def test_corrupt_private_entry_replaced_only_with_valid_existing_key(self):
        self.seed()
        key = self.key.read_bytes()
        self.raw(b"unverifiable old private data")
        self.assertIsNone(self.cache.load())
        self.assertTrue(self.cache.save(example("fresh compiler result")))
        self.assertEqual(self.cache.load(), example("fresh compiler result"))
        self.assertEqual(self.key.read_bytes(), key)

    def test_missing_key_over_existing_entry_is_never_created(self):
        self.seed()
        self.key.unlink()
        before = self.path.read_bytes()
        self.assertIsNone(self.cache.load())
        self.assertFalse(self.cache.save(example("fresh")))
        self.assertFalse(self.key.exists())
        self.assertEqual(self.path.read_bytes(), before)

    def test_damaged_key_is_never_repaired(self):
        self.seed()
        for raw in (b"", b"short", b"x" * 33):
            with self.subTest(length=len(raw)):
                self.key.write_bytes(raw)
                self.assertIsNone(self.cache.load())
                self.assertFalse(self.cache.save(self.entry))
                self.assertEqual(self.key.read_bytes(), raw)

    def test_same_length_changed_key_fails_mac_but_can_sign_fresh_result(self):
        self.seed()
        self.key.write_bytes(b"x" * 32)
        self.assertIsNone(self.cache.load())
        self.assertTrue(self.cache.save(example("fresh recomputation")))
        self.assertEqual(self.cache.load(), example("fresh recomputation"))

    def test_bad_directory_modes_never_repaired(self):
        self.seed()
        for mode in (0o755, 0o770, 0o500, 0o1700):
            with self.subTest(mode=oct(mode)):
                self.directory.chmod(mode)
                self.assertIsNone(self.cache.load())
                self.assertFalse(self.cache.save(self.entry))
                self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), mode)
        self.directory.chmod(0o700)

    def test_bad_file_modes_never_repaired(self):
        self.seed()
        for path in (self.key, self.path, self.lock):
            for mode in (0o644, 0o400, 0o660, 0o4600):
                with self.subTest(file=path.name, mode=oct(mode)):
                    path.chmod(mode)
                    self.assertIsNone(self.cache.load())
                    self.assertFalse(self.cache.save(self.entry))
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)
                    path.chmod(0o600)

    def test_wrong_owner_is_refused(self):
        self.seed()
        with mock.patch.object(storage.os, "getuid", return_value=os.getuid() + 1):
            self.assertIsNone(self.cache.load())
            self.assertFalse(self.cache.save(self.entry))

    def test_hardlinked_files_are_refused_and_not_changed(self):
        self.seed()
        for path in (self.key, self.path, self.lock):
            alias = self.base / (path.name + "-hardlink")
            os.link(path, alias)
            before = alias.read_bytes()
            with self.subTest(file=path.name):
                self.assertIsNone(self.cache.load())
                self.assertFalse(self.cache.save(example("fresh")))
                self.assertEqual(alias.read_bytes(), before)
            alias.unlink()

    def test_symlinked_files_are_refused_and_targets_not_changed(self):
        self.seed()
        for path in (self.key, self.path, self.lock):
            target = self.base / (path.name + "-target")
            path.rename(target)
            before = target.read_bytes()
            path.symlink_to(target)
            with self.subTest(file=path.name):
                self.assertIsNone(self.cache.load())
                self.assertFalse(self.cache.save(self.entry))
                self.assertEqual(target.read_bytes(), before)
                self.assertTrue(path.is_symlink())
            path.unlink()
            target.rename(path)

    def test_symlinked_private_directory_never_traversed(self):
        self.seed()
        target = self.base / "private-directory-target"
        self.directory.rename(target)
        self.directory.symlink_to(target, target_is_directory=True)
        before = (target / "entry.json").read_bytes()
        self.assertIsNone(self.cache.load())
        self.assertFalse(self.cache.save(self.entry))
        self.assertEqual((target / "entry.json").read_bytes(), before)

    def test_fifos_and_directory_files_miss_without_opening_or_blocking(self):
        self.seed()
        for path in (self.key, self.path, self.lock):
            saved = self.base / (path.name + "-saved")
            path.rename(saved)
            for kind in ("fifo", "directory"):
                with self.subTest(file=path.name, kind=kind):
                    if kind == "fifo":
                        os.mkfifo(path, 0o600)
                    else:
                        path.mkdir(mode=0o600)
                    self.assertIsNone(self.cache.load())
                    self.assertFalse(self.cache.save(self.entry))
                    if kind == "fifo":
                        path.unlink()
                    else:
                        path.rmdir()
            saved.rename(path)

    def test_file_path_descriptor_disagreement_is_refused(self):
        self.seed()
        actual_open = storage.os.open
        switched = False

        def racing_open(name, *args, **kwargs):
            nonlocal switched
            fd = actual_open(name, *args, **kwargs)
            if name == "key" and not switched:
                switched = True
                self.key.rename(self.base / "original-key")
                self.key.write_bytes(b"x" * 32)
                self.key.chmod(0o600)
            return fd

        with mock.patch.object(storage.os, "open", side_effect=racing_open):
            self.assertIsNone(self.cache.load())
        self.assertTrue(switched)

    def test_directory_path_descriptor_disagreement_is_refused(self):
        self.seed()
        actual_open = storage.os.open

        def racing_open(name, *args, **kwargs):
            fd = actual_open(name, *args, **kwargs)
            if name == storage.DIRECTORY:
                self.directory.rename(self.base / "old-private-directory")
                self.directory.mkdir(mode=0o700)
            return fd

        with mock.patch.object(storage.os, "open", side_effect=racing_open):
            self.assertIsNone(self.cache.load())
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_nonblocking_lock_contention_no_stale_lock_unlink(self):
        self.seed()
        before = self.path.read_bytes()
        inode = self.lock.stat().st_ino
        with self.lock.open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertIsNone(self.cache.load())
            self.assertFalse(self.cache.save(example("contended")))
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.lock.stat().st_ino, inode)
        self.assertTrue(self.cache.save(example("after lock release")))
        self.assertEqual(self.lock.stat().st_ino, inode)

    def test_another_process_holds_lock_nonblocking(self):
        self.seed()
        script = ("import fcntl,sys; f=open(sys.argv[1],'rb'); "
                  "fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.readline()")
        process = subprocess.Popen([sys.executable, "-B", "-c", script, str(self.lock)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline(), b"ready\n")
            self.assertIsNone(self.cache.load())
            self.assertFalse(self.cache.save(self.entry))
        finally:
            process.communicate(input=b"release\n", timeout=10)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(self.cache.load(), self.entry)

    def test_nonempty_lock_refused_and_preserved(self):
        self.seed()
        self.lock.write_bytes(b"stale-looking lock data")
        self.assertIsNone(self.cache.load())
        self.assertFalse(self.cache.save(self.entry))
        self.assertEqual(self.lock.read_bytes(), b"stale-looking lock data")

    def test_atomic_replace_observes_old_complete_then_new_complete_entry(self):
        self.seed()
        old = self.path.read_bytes()
        old_inode = self.path.stat().st_ino
        key = self.key.read_bytes()
        actual_replace = storage.os.replace
        observed = []

        def observe(source, destination, **kwargs):
            observed.append(self.path.read_bytes())
            stage = self.directory / source
            self.assertEqual(stat.S_IMODE(stage.stat().st_mode), 0o600)
            self.assertEqual(json.loads(stage.read_bytes())["entry"], example("atomic new"))
            actual_replace(source, destination, **kwargs)
            observed.append(self.path.read_bytes())

        with mock.patch.object(storage.os, "replace", side_effect=observe):
            self.assertTrue(self.cache.save(example("atomic new")))
        self.assertEqual(observed[0], old)
        self.assertEqual(json.loads(observed[1])["entry"], example("atomic new"))
        self.assertNotEqual(self.path.stat().st_ino, old_inode)
        self.assertEqual(self.key.read_bytes(), key)
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()),
                         ["entry.json", "key", "write.lock"])

    def test_failed_atomic_replace_preserves_previous_entry_and_cleans_own_stage(self):
        self.seed()
        old = self.path.read_bytes()
        with mock.patch.object(storage.os, "replace", side_effect=OSError("fixture failure")):
            self.assertFalse(self.cache.save(example("not published to cache")))
        self.assertEqual(self.path.read_bytes(), old)
        self.assertEqual(self.cache.load(), self.entry)
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()),
                         ["entry.json", "key", "write.lock"])

    def test_stage_name_collision_does_not_overwrite_or_unlink_existing_file(self):
        self.seed()
        stage = self.directory / (".entry-" + "f" * 32)
        stage.write_bytes(b"preexisting unrelated stage")
        stage.chmod(0o600)
        old = self.path.read_bytes()
        with mock.patch.object(storage.secrets, "token_hex", return_value="f" * 32):
            self.assertFalse(self.cache.save(example("new")))
        self.assertEqual(stage.read_bytes(), b"preexisting unrelated stage")
        self.assertEqual(self.path.read_bytes(), old)

    def test_interrupted_process_leaves_old_entry_valid_and_lock_reusable(self):
        self.seed()
        old = self.path.read_bytes()
        key = self.key.read_bytes()
        lock_inode = self.lock.stat().st_ino
        script = """
import json, sys
import handbook_projection_cache as cache
def before_replace(*args, **kwargs):
    print('staged', flush=True)
    sys.stdin.readline()
    raise OSError('fixture interruption fallback')
cache.os.replace = before_replace
cache.ProjectionCache(sys.argv[1], json.loads(sys.argv[2])).save(json.loads(sys.argv[3]))
"""
        env = os.environ.copy()
        env["PYTHONPATH"] = str(pathlib.Path(storage.__file__).parent)
        process = subprocess.Popen([sys.executable, "-B", "-c", script, str(self.root),
                                    json.dumps(self.scope), json.dumps(example("interrupted"))],
                                   env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 10)
            self.assertTrue(ready, "fixture child did not reach staging")
            self.assertEqual(process.stdout.readline(), b"staged\n")
            self.assertEqual(self.path.read_bytes(), old)
        finally:
            process.kill()
            process.communicate(timeout=10)
        self.assertEqual(self.cache.load(), self.entry)
        self.assertEqual(self.key.read_bytes(), key)
        self.assertEqual(self.lock.stat().st_ino, lock_inode)
        abandoned = list(self.directory.glob(".entry-*"))
        self.assertEqual(len(abandoned), 1)
        # Unknown abandoned files are neither trusted nor stale-lock cleanup.
        self.assertTrue(self.cache.save(example("after interruption")))
        self.assertEqual(self.cache.load(), example("after interruption"))
        self.assertTrue(abandoned[0].exists())

    def test_post_replace_directory_fsync_failure_returns_false_without_undo(self):
        self.seed()
        actual_fsync = storage.os.fsync

        def fail_directory_fsync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("fixture directory fsync failure")
            actual_fsync(fd)

        with mock.patch.object(storage.os, "fsync", side_effect=fail_directory_fsync):
            self.assertFalse(self.cache.save(example("complete replacement")))
        # Atomic replacement already occurred; best-effort failure cannot undo
        # publication, and the replacement still authenticates if readable.
        self.assertEqual(self.cache.load(), example("complete replacement"))

    def test_stage_fsync_failure_preserves_previous_entry(self):
        self.seed()
        before = self.path.read_bytes()
        with mock.patch.object(storage.os, "fsync", side_effect=OSError("fixture failure")):
            self.assertFalse(self.cache.save(example("new")))
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.cache.load(), self.entry)

    def test_short_writes_are_completed(self):
        actual_write = storage.os.write

        def short_write(fd, raw):
            return actual_write(fd, raw[:7])

        with mock.patch.object(storage.os, "write", side_effect=short_write):
            self.assertTrue(self.cache.save(self.entry))
        self.assertEqual(self.cache.load(), self.entry)

    def test_io_failures_are_silent_misses(self):
        self.seed()
        with mock.patch.object(handbook_sources, "_canonical_repository",
                               return_value=(self.root, self.git_dir)):
            for name in ("stat", "open", "read", "fstat"):
                with self.subTest(operation=name), \
                        mock.patch.object(storage.os, name, side_effect=OSError("private sensitive value")):
                    self.assertIsNone(self.cache.load())
            for name in ("stat", "open", "write", "fsync", "replace"):
                with self.subTest(operation=name), \
                        mock.patch.object(storage.os, name, side_effect=OSError("private sensitive value")):
                    self.assertFalse(self.cache.save(self.entry))

    def test_close_failure_cannot_break_cache_call(self):
        self.seed()
        actual_close = storage.os.close

        def close_then_fail(fd):
            actual_close(fd)
            raise OSError("fixture close failure")

        # os is shared with subprocess; isolate Git resolution from this injected
        # cache-descriptor failure rather than disrupting child pipe cleanup.
        with mock.patch.object(handbook_sources, "_canonical_repository",
                               return_value=(self.root, self.git_dir)), \
                mock.patch.object(storage.os, "close", side_effect=close_then_fail):
            self.assertEqual(self.cache.load(), self.entry)
            self.assertTrue(self.cache.save(example("new")))

    def test_cooperative_concurrent_writers_never_leave_partial_json(self):
        self.seed()
        values = [example("writer " + str(i)) for i in range(16)]
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(self.cache.save, values))
        self.assertTrue(any(results))
        loaded = self.cache.load()
        self.assertIn(loaded, values)
        self.assertIn(self.envelope()["entry"], values)
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()),
                         ["entry.json", "key", "write.lock"])


if __name__ == "__main__":
    unittest.main()
