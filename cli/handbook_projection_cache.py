"""Private, authenticated, disposable projection storage (stdlib only).

The caller supplies fresh compiler output to save ONLY after successful explicit
publication. Read-only/clean/failed operations must not call save. Authentication
does not replace fresh source validation; same-user access to the key and compiler
is outside the threat model. No diagnostics contain cache content or key material.
"""

import contextlib
import fcntl
import hashlib
import hmac
import json
import math
import os
import pathlib
import secrets
import stat

import handbook_sources


MAX_BYTES = 8 * 1024 * 1024
FORMAT_VERSION = 1
DIRECTORY = ".byori-projection-cache-v1"
_RELATIONS = {"depends_on", "affects", "conflicts_with", "supersedes"}


def _require(condition):
    if not condition:
        raise ValueError("unusable projection cache")


def _json_bytes(value, limit):
    # iterencode bounds allocation even for caller-supplied oversized entries.
    parts = []
    size = 0
    encoder = json.JSONEncoder(ensure_ascii=False, sort_keys=True,
                               separators=(",", ":"), allow_nan=False)
    for part in encoder.iterencode(value):
        part = part.encode("utf-8")
        size += len(part)
        _require(size <= limit)
        parts.append(part)
    return b"".join(parts)


def _json_tree(value, limit):
    pending = [(value, 0)]
    nodes = 0
    while pending:
        item, depth = pending.pop()
        nodes += 1
        _require(nodes <= 200000 and depth <= 32)
        if type(item) is dict:
            _require(len(item) <= 65536)
            for key, child in item.items():
                _require(type(key) is str and len(key.encode("utf-8")) <= 2048)
                pending.append((child, depth + 1))
        elif type(item) in (list, tuple):
            _require(len(item) <= 65536)
            pending.extend((child, depth + 1) for child in item)
        elif type(item) is str:
            _require(len(item.encode("utf-8")) <= limit)
        elif type(item) is int:
            _require(item.bit_length() <= 64)
        elif type(item) is float:
            _require(math.isfinite(item))
        else:
            _require(item is None or type(item) is bool)


def _sha(value):
    return (type(value) is str and len(value) == 64
            and all(char in "0123456789abcdef" for char in value))


def _entry(value, limit):
    _json_tree(value, limit)
    _require(type(value) is dict and set(value) == {"keys", "edges", "units"})
    keys, edges, units = value["keys"], value["edges"], value["units"]
    _require(type(keys) is dict and type(units) is dict and type(edges) is list)
    _require(len(keys) <= 4096 and len(edges) <= 65536 and set(keys) == set(units))
    for key, digest in keys.items():
        _require(key and _sha(digest) and type(units[key]) is dict)
    for edge in edges:
        _require(type(edge) in (list, tuple) and len(edge) == 3)
        source, relation, target = edge
        _require(type(source) is str and type(target) is str and type(relation) is str)
        _require(source in keys and target in keys and relation in _RELATIONS)
    return value


def _object(pairs):
    value = {}
    for key, child in pairs:
        _require(key not in value)
        value[key] = child
    return value


def _decode(raw):
    def invalid_constant(_value):
        raise ValueError("unusable projection cache")
    return json.loads(raw.decode("utf-8"), object_pairs_hook=_object,
                      parse_constant=invalid_constant)


def _identity(info):
    return info.st_dev, info.st_ino


def _private(info, directory=False):
    _require(info.st_uid == os.getuid())
    _require(stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600))
    _require(stat.S_ISDIR(info.st_mode) if directory else
             stat.S_ISREG(info.st_mode) and info.st_nlink == 1)


def _same(fd, parent, name, directory=False):
    descriptor = os.fstat(fd)
    path = os.stat(name, dir_fd=parent, follow_symlinks=False)
    _private(descriptor, directory)
    _private(path, directory)
    _require(_identity(descriptor) == _identity(path))
    return descriptor


def _close(fd):
    # Even close failures must not turn a successful publication into failure.
    with contextlib.suppress(OSError):
        os.close(fd)


def _file(stack, parent, name, flags=os.O_RDONLY, create=False):
    try:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        _require(create)
        info = None
    if info is not None:
        _private(info)
    options = flags | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    if info is None:
        options |= os.O_CREAT | os.O_EXCL
    fd = os.open(name, options, 0o600, dir_fd=parent)
    stack.callback(_close, fd)
    opened = _same(fd, parent, name)
    if info is not None:
        _require(_identity(info) == _identity(opened))
    return fd, info is None


def _read(fd, parent, name, limit):
    before = _same(fd, parent, name)
    _require(before.st_size <= limit)
    chunks = []
    remaining = limit + 1
    while remaining:
        chunk = os.read(fd, min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    raw = b"".join(chunks)
    after = _same(fd, parent, name)
    _require(len(raw) <= limit and len(raw) == before.st_size)
    _require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
             (after.st_size, after.st_mtime_ns, after.st_ctime_ns))
    return raw


def _write(fd, raw):
    view = memoryview(raw)
    while view:
        count = os.write(fd, view)
        _require(count > 0)
        view = view[count:]
    os.fsync(fd)


class ProjectionCache:
    """ProjectionCache(root, scope, max_bytes=8*1024*1024).

    scope is a tuple/list of strings: canonical root, collector checkout ID,
    compiler version, projection version, implementation SHA256 (additional
    identity strings may follow). Constructor and load never create/write.
    load() -> {keys: dict[id, sha64], edges: list[triples], units: dict} | None.
    save(entry) -> bool, best effort; no exceptions escape cache operations.
    """

    def __init__(self, root, scope, max_bytes=MAX_BYTES):
        # Defer filesystem/Git operations to load/save, including invalid roots.
        self._root = root
        self._scope = tuple(scope) if type(scope) in (tuple, list) else None
        self._max_bytes = max_bytes

    def _directory(self, stack, create=False):
        _require(type(self._max_bytes) is int and 0 < self._max_bytes <= MAX_BYTES)
        scope = self._scope
        _require(scope is not None and 5 <= len(scope) <= 32)
        _require(all(type(part) is str and part and len(part.encode("utf-8")) <= 8192
                     for part in scope))
        _require(_sha(scope[1]) and _sha(scope[4]))
        root, git_dir = handbook_sources._canonical_repository(pathlib.Path(self._root))
        checkout = hashlib.sha256(handbook_sources._encode_identity(str(git_dir))).hexdigest()
        _require(str(self._root) == str(root) == scope[0] and checkout == scope[1])
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        info = os.stat(git_dir, follow_symlinks=False)
        _require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid())
        git_fd = os.open(git_dir, flags)
        stack.callback(_close, git_fd)
        _require(_identity(info) == _identity(os.fstat(git_fd)))
        if create:
            try:
                os.mkdir(DIRECTORY, 0o700, dir_fd=git_fd)
                os.fsync(git_fd)
            except FileExistsError:
                pass
        before = os.stat(DIRECTORY, dir_fd=git_fd, follow_symlinks=False)
        _private(before, directory=True)
        cache_fd = os.open(DIRECTORY, flags, dir_fd=git_fd)
        stack.callback(_close, cache_fd)
        _require(_identity(before) == _identity(_same(cache_fd, git_fd, DIRECTORY, True)))
        return git_dir, git_fd, cache_fd

    def _boundary(self, git_dir, git_fd, cache_fd):
        current = os.stat(git_dir, follow_symlinks=False)
        _require(stat.S_ISDIR(current.st_mode) and current.st_uid == os.getuid()
                 and _identity(current) == _identity(os.fstat(git_fd)))
        _same(cache_fd, git_fd, DIRECTORY, True)

    def load(self):
        """Return an isolated authenticated entry, or None; never write anything."""
        try:
            with contextlib.ExitStack() as stack:
                git_dir, git_fd, cache_fd = self._directory(stack)
                lock, _ = _file(stack, cache_fd, "write.lock")
                _require(os.fstat(lock).st_size == 0)
                fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
                key_fd, _ = _file(stack, cache_fd, "key")
                key = _read(key_fd, cache_fd, "key", 32)
                _require(len(key) == 32)
                fd, _ = _file(stack, cache_fd, "entry.json")
                envelope = _decode(_read(fd, cache_fd, "entry.json", self._max_bytes))
                _require(type(envelope) is dict and
                         set(envelope) == {"format_version", "scope", "entry", "mac"})
                _require(type(envelope["format_version"]) is int
                         and envelope["format_version"] == FORMAT_VERSION
                         and envelope["scope"] == list(self._scope) and _sha(envelope["mac"]))
                entry = _entry(envelope["entry"], self._max_bytes)
                payload = {name: envelope[name] for name in ("format_version", "scope", "entry")}
                mac = hmac.new(key, _json_bytes(payload, self._max_bytes), hashlib.sha256).hexdigest()
                _require(hmac.compare_digest(mac, envelope["mac"]))
                _same(fd, cache_fd, "entry.json")
                _same(lock, cache_fd, "write.lock")
                _same(key_fd, cache_fd, "key")
                self._boundary(git_dir, git_fd, cache_fd)
                return entry
        except Exception:
            return None

    def save(self, entry):
        """Persist compiler-fresh entry after publication; unsafe/contended -> False."""
        try:
            _entry(entry, self._max_bytes)
            # Snapshot/normalize tuples without sharing caller-owned objects.
            entry = _decode(_json_bytes(entry, self._max_bytes))
            with contextlib.ExitStack() as stack:
                git_dir, git_fd, cache_fd = self._directory(stack, create=True)
                lock, _ = _file(stack, cache_fd, "write.lock", os.O_RDWR, create=True)
                _require(os.fstat(lock).st_size == 0)
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                # Existing data must be safe to replace, but need not authenticate
                # if a valid existing key can sign freshly computed compiler data.
                try:
                    old = os.stat("entry.json", dir_fd=cache_fd, follow_symlinks=False)
                except FileNotFoundError:
                    old = None
                if old is not None:
                    _private(old)
                try:
                    os.stat("key", dir_fd=cache_fd, follow_symlinks=False)
                    key_exists = True
                except FileNotFoundError:
                    key_exists = False
                _require(key_exists or old is None)
                key_fd, created = _file(stack, cache_fd, "key", os.O_RDWR, create=not key_exists)
                if created:
                    _write(key_fd, secrets.token_bytes(32))
                    os.fsync(cache_fd)
                    os.lseek(key_fd, 0, os.SEEK_SET)
                key = _read(key_fd, cache_fd, "key", 32)
                _require(len(key) == 32)
                payload = {"format_version": FORMAT_VERSION, "scope": list(self._scope), "entry": entry}
                envelope = {**payload, "mac": hmac.new(
                    key, _json_bytes(payload, self._max_bytes), hashlib.sha256).hexdigest()}
                raw = _json_bytes(envelope, self._max_bytes)
                stage = ".entry-" + secrets.token_hex(16)
                stage_fd, stage_created = _file(stack, cache_fd, stage, os.O_WRONLY, create=True)
                _require(stage_created)
                # Only our own staging inode is cleaned up; locks are never unlinked.
                def cleanup():
                    with contextlib.suppress(Exception):
                        _same(stage_fd, cache_fd, stage)
                        os.unlink(stage, dir_fd=cache_fd)
                stack.callback(cleanup)
                _write(stage_fd, raw)
                _same(stage_fd, cache_fd, stage)
                _same(lock, cache_fd, "write.lock")
                _same(key_fd, cache_fd, "key")
                self._boundary(git_dir, git_fd, cache_fd)
                try:
                    current = os.stat("entry.json", dir_fd=cache_fd, follow_symlinks=False)
                except FileNotFoundError:
                    current = None
                _require((old is None and current is None) or
                         (old is not None and current is not None
                          and _identity(old) == _identity(current)))
                if current is not None:
                    _private(current)
                os.replace(stage, "entry.json", src_dir_fd=cache_fd, dst_dir_fd=cache_fd)
                os.fsync(cache_fd)
                return True
        except Exception:
            return False
