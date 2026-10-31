#!/usr/bin/env python3
"""Deterministic, bounded source collection for the project handbook.

This adapter only reads a trusted local Git checkout.  Repository documents are
data: nothing in them is imported, evaluated, passed to a shell, or interpreted
as policy.  A caller that plans to publish derived output should collect again
immediately before publication and compare ``snapshot_digest`` values.
"""

import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import unicodedata
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple


DEFAULT_TIMEOUT_SECONDS = 30
COMMIT_HEADER_ALLOWANCE = 256 * 1024
MAX_WORKING_STATUS_BYTES = 4 * 1024 * 1024
MAX_DIRTY_PATHS = 10_000
MAX_EXCLUDE_PATHS = 64
MAX_CAT_FILE_BATCH_OBJECTS = 64
MARKDOWN_SUFFIXES = frozenset({".md", ".markdown"})
INSTRUCTION_NAMES = frozenset({"agents.md", "claude.md"})
RAW_TRANSCRIPT_DIRECTORIES = frozenset({
    "chat-transcripts",
    "chat-histories",
    "chat-history",
    "conversation-transcripts",
    "conversation-histories",
    "conversation-history",
    "raw-transcripts",
    "reasoning-traces",
    "session-transcripts",
    "transcript",
    "transcripts",
})
SENSITIVE_PATH_VALUE = re.compile(
    r"(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16})"
)
SENSITIVE_POLICY_VALUE = re.compile(
    r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|"
    r"\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16})\b|"
    r"(?im:^\s*(?:export\s+)?[\w-]*(?:password|secret|api[_-]?key|access[_-]?token)"
    r"[\w-]*\s*[:=]\s*[\"']?[^\s\"']{8,})"
)
OBJECT_ID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
GLOB_CHARACTERS = frozenset("*?[]")
SECRET_NAME_TOKENS = frozenset({
    "credential",
    "credentials",
    "passwd",
    "password",
    "privatekey",
    "secret",
    "secrets",
    "token",
    "tokens",
})
GIT_ENVIRONMENT_OVERRIDES = frozenset({
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CEILING_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CONFIG",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_SYSTEM",
    "GIT_DIR",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    "GIT_EXEC_PATH",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_NAMESPACE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_PREFIX",
    "GIT_QUARANTINE_PATH",
    "GIT_REPLACE_REF_BASE",
    "GIT_SHALLOW_FILE",
    "GIT_SUPER_PREFIX",
    "GIT_WORK_TREE",
})


class SourceError(RuntimeError):
    """The source root is invalid or required Git plumbing failed."""


def _run_git(
    root: pathlib.Path,
    arguments: Sequence[str],
    *,
    input_bytes: Optional[bytes] = None,
    allowed_returncodes: Iterable[int] = (),
) -> Tuple[bytes, int]:
    command = (
        "git",
        "--no-pager",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "diff.external=",
        "-C",
        str(root),
        *arguments,
    )
    environment = os.environ.copy()
    for name in tuple(environment):
        if (
            name in GIT_ENVIRONMENT_OVERRIDES
            or name.startswith("GIT_CONFIG_KEY_")
            or name.startswith("GIT_CONFIG_VALUE_")
        ):
            environment.pop(name, None)
    environment.update({
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": os.devnull,
        "GIT_EXTERNAL_DIFF": "",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
    })
    try:
        result = subprocess.run(
            command,
            check=False,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=DEFAULT_TIMEOUT_SECONDS,
            env=environment,
        )
    except subprocess.TimeoutExpired as exc:
        raise SourceError("git %s timed out" % arguments[0]) from exc
    except OSError as exc:
        raise SourceError("git %s could not run: %s" % (arguments[0], exc)) from exc

    allowed = set(allowed_returncodes)
    if result.returncode != 0 and result.returncode not in allowed:
        # Do not copy stderr into the error: paths and configuration diagnostics
        # can contain values that should not appear in logs.
        raise SourceError(
            "git %s failed with exit %d" % (arguments[0], result.returncode)
        )
    if result.stderr:
        # Successful Git commands can still report skipped or unreadable paths.
        # Continuing would turn a bounded collection gap into a current-looking
        # snapshot, so fail without echoing potentially sensitive diagnostics.
        raise SourceError("git %s reported unexpected diagnostics" % arguments[0])
    return result.stdout, result.returncode


def _decode_path(value: bytes) -> str:
    return value.decode("utf-8", errors="surrogateescape")


def _encode_identity(value: str) -> bytes:
    return value.encode("utf-8", errors="surrogatepass")


def _canonical_repository(root: pathlib.Path) -> Tuple[pathlib.Path, pathlib.Path]:
    try:
        requested = pathlib.Path(root).resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise SourceError("source root does not exist or cannot be resolved") from exc
    if not requested.is_dir():
        raise SourceError("source root is not a directory")

    raw_top, _ = _run_git(requested, ("rev-parse", "--show-toplevel"))
    raw_git_dir, _ = _run_git(requested, ("rev-parse", "--absolute-git-dir"))
    try:
        top = pathlib.Path(_decode_path(raw_top.rstrip(b"\n"))).resolve(strict=True)
        git_dir = pathlib.Path(_decode_path(raw_git_dir.rstrip(b"\n"))).resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise SourceError("Git returned an invalid repository path") from exc
    if not top.is_dir() or not git_dir.is_dir():
        raise SourceError("Git repository paths are not directories")
    return top, git_dir


def _head(root: pathlib.Path) -> str:
    raw, returncode = _run_git(
        root,
        ("rev-parse", "--verify", "--quiet", "HEAD^{commit}"),
        allowed_returncodes=(1,),
    )
    if returncode == 0:
        return raw.decode("ascii", errors="strict").strip()

    # A symbolic HEAD with no commit is a valid unborn repository.  Other
    # failures (for example, a corrupt or unreadable HEAD) are not concealed as
    # an empty history.
    _symbolic, symbolic_returncode = _run_git(
        root,
        ("symbolic-ref", "--quiet", "HEAD"),
        allowed_returncodes=(1,),
    )
    if symbolic_returncode == 0:
        return ""
    raise SourceError("Git HEAD could not be resolved")


def _tracked_paths(root: pathlib.Path) -> List[str]:
    raw, _ = _run_git(root, ("ls-files", "--cached", "-z"))
    paths = {_decode_path(item) for item in raw.split(b"\0") if item}
    return sorted(paths)


def _unmerged_paths(root: pathlib.Path) -> Set[str]:
    raw, _ = _run_git(root, ("ls-files", "--unmerged", "-z"))
    paths: Set[str] = set()
    for item in raw.split(b"\0"):
        if not item:
            continue
        _metadata, separator, path = item.partition(b"\t")
        if separator:
            paths.add(_decode_path(path))
    return paths


def _status_paths(raw_status: bytes) -> List[bytes]:
    """Return paths from porcelain-v2 ``-z`` output without decoding delimiters."""

    records = raw_status.split(b"\0")
    paths: List[bytes] = []
    index = 0
    while index < len(records):
        record = records[index]
        index += 1
        if not record:
            continue
        record_type = record[:1]
        if record_type == b"1":
            fields = record.split(b" ", 8)
            if len(fields) != 9:
                raise SourceError("Git returned malformed ordinary status data")
            paths.append(fields[8])
        elif record_type == b"2":
            fields = record.split(b" ", 9)
            if len(fields) != 10 or index >= len(records):
                raise SourceError("Git returned malformed rename status data")
            paths.extend((fields[9], records[index]))
            index += 1
        elif record_type == b"u":
            fields = record.split(b" ", 10)
            if len(fields) != 11:
                raise SourceError("Git returned malformed unmerged status data")
            paths.append(fields[10])
        else:
            # Untracked and ignored records were disabled. Refusing unknown
            # records avoids silently hashing an incomplete working state when
            # Git extends or corrupts the porcelain contract.
            raise SourceError("Git returned unsupported working status data")
    return paths


def _working_state(root: pathlib.Path) -> Dict[str, str]:
    branch_raw, branch_returncode = _run_git(
        root,
        ("symbolic-ref", "--quiet", "HEAD"),
        allowed_returncodes=(1,),
    )
    branch = (
        _decode_path(branch_raw.rstrip(b"\n"))
        if branch_returncode == 0
        else "(detached)"
    )
    status_raw, _ = _run_git(
        root,
        (
            "status",
            "--porcelain=v2",
            "-z",
            "--untracked-files=no",
            "--no-renames",
        ),
    )
    if len(status_raw) > MAX_WORKING_STATUS_BYTES:
        raise SourceError(
            "tracked working status exceeds the %d-byte safety bound"
            % MAX_WORKING_STATUS_BYTES
        )
    raw_paths = sorted(set(_status_paths(status_raw)))
    if len(raw_paths) > MAX_DIRTY_PATHS:
        raise SourceError(
            "tracked working status exceeds the %d-path safety bound"
            % MAX_DIRTY_PATHS
        )

    dirty_paths: List[Dict[str, object]] = []
    for raw_path in raw_paths:
        relative_path = _decode_path(raw_path)
        candidate = root.joinpath(*pathlib.PurePosixPath(relative_path).parts)
        path_digest = hashlib.sha256(raw_path).hexdigest()
        try:
            details = candidate.lstat()
        except FileNotFoundError:
            dirty_paths.append({"path_digest": path_digest, "missing": True})
            continue
        except OSError as exc:
            raise SourceError("a tracked dirty path could not be inspected") from exc
        dirty_paths.append({
            "path_digest": path_digest,
            "missing": False,
            "device": details.st_dev,
            "inode": details.st_ino,
            "mode": details.st_mode,
            "size": details.st_size,
            "mtime_ns": details.st_mtime_ns,
            "ctime_ns": details.st_ctime_ns,
        })

    state = {
        "branch": branch,
        "status_digest": hashlib.sha256(status_raw).hexdigest(),
        "status_bytes": len(status_raw),
        "dirty_paths": dirty_paths,
    }
    serialized = json.dumps(
        state,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return {
        "branch": branch,
        "fingerprint": hashlib.sha256(serialized).hexdigest(),
    }


def _ignored_paths(root: pathlib.Path, paths: Sequence[str]) -> Set[str]:
    if not paths:
        return set()
    payload = b"\0".join(_encode_identity(path) for path in paths) + b"\0"
    raw, _ = _run_git(
        root,
        ("check-ignore", "--no-index", "-z", "--stdin"),
        input_bytes=payload,
        allowed_returncodes=(1,),
    )
    return {_decode_path(item) for item in raw.split(b"\0") if item}


def _is_document_candidate(path: str) -> bool:
    pure = pathlib.PurePosixPath(path)
    if len(pure.parts) == 1:
        name = pure.name.casefold()
        return name in {
            "readme",
            "readme.md",
            "readme.markdown",
            "product",
            "product.md",
            "product.markdown",
        }
    return (
        pure.parts[0].casefold() == "docs"
        and pure.suffix.casefold() in MARKDOWN_SUFFIXES
    )


def _normalize_exclude_paths(exclude_paths: Iterable[str]) -> List[str]:
    if isinstance(exclude_paths, (str, bytes)):
        raise ValueError("exclude_paths must be a sequence of repository-relative paths")
    try:
        values = iter(exclude_paths)
    except TypeError as exc:
        raise ValueError(
            "exclude_paths must be a sequence of repository-relative paths"
        ) from exc

    canonical: Set[str] = set()
    supplied_count = 0
    for value in values:
        supplied_count += 1
        if supplied_count > MAX_EXCLUDE_PATHS:
            raise ValueError("exclude_paths must contain at most %d paths" % MAX_EXCLUDE_PATHS)
        if not isinstance(value, str) or not value:
            raise ValueError("each exclude_paths entry must be a non-empty string")
        try:
            encoded_value = value.encode("utf-8")
        except UnicodeEncodeError as exc:
            raise ValueError("exclude_paths contains an invalid path") from exc
        if len(encoded_value) > 1024:
            raise ValueError("exclude_paths entries must not exceed 1024 UTF-8 bytes")
        if SENSITIVE_POLICY_VALUE.search(value):
            raise ValueError("exclude_paths contains a sensitive value")
        if any(unicodedata.category(character) == "Cc" for character in value):
            raise ValueError("exclude_paths entries must not contain NUL or control characters")
        if "\\" in value or any(character in GLOB_CHARACTERS for character in value):
            raise ValueError("exclude_paths entries must not contain backslashes or glob patterns")
        if pathlib.PurePosixPath(value).is_absolute():
            raise ValueError("exclude_paths entries must be repository-relative")

        is_prefix = value.endswith("/")
        plain = value[:-1] if is_prefix else value
        if not plain or any(part in {"", ".", ".."} for part in plain.split("/")):
            raise ValueError(
                "exclude_paths entries must be normalized exact files or directory prefixes"
            )
        canonical.add(value)
    return sorted(canonical)


def _matching_exclude_path(path: str, exclude_paths: Sequence[str]) -> Optional[str]:
    for excluded in exclude_paths:
        if excluded.endswith("/"):
            if path.startswith(excluded):
                return excluded
        elif path == excluded:
            return excluded
    return None


def _redacted_policy_exclusion(path: str) -> str:
    digest = hashlib.sha256(_encode_identity("exclude\0" + path)).hexdigest()[:12]
    return "<redacted-excluded-path:%s>" % digest


def _deny_reason(path: str) -> Optional[str]:
    pure = pathlib.PurePosixPath(path)
    folded_parts = tuple(part.casefold() for part in pure.parts)
    for part in folded_parts:
        if part == ".env" or part.startswith(".env."):
            return "secret-like .env path is excluded"
        stem = pathlib.PurePosixPath(part).stem
        tokens = set(filter(None, re.split(r"[^a-z0-9]+", stem)))
        compact = re.sub(r"[^a-z0-9]+", "", stem)
        if compact in SECRET_NAME_TOKENS or tokens.intersection(SECRET_NAME_TOKENS):
            return "secret-like path is excluded"
        if part in {".netrc", ".npmrc", ".pypirc", "id_ed25519", "id_rsa"}:
            return "secret-like path is excluded"
        if pathlib.PurePosixPath(part).suffix in {".key", ".p12", ".pem", ".pfx"}:
            return "secret-like path is excluded"
    if pure.name.casefold() in INSTRUCTION_NAMES:
        return "agent instruction files are excluded"
    if ".byori" in folded_parts:
        return "generated .byori output is excluded"
    if any(part in RAW_TRANSCRIPT_DIRECTORIES for part in folded_parts[:-1]):
        return "raw transcript directories are excluded"
    return None


def _safe_exclusion_path(path: str, reason: str) -> str:
    if not reason.startswith("secret-like") and not SENSITIVE_PATH_VALUE.search(path):
        return path
    digest = hashlib.sha256(_encode_identity(path)).hexdigest()[:12]
    return "<redacted-secret-path:%s>" % digest


def _within(path: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _stat_signature(value: os.stat_result) -> Tuple[int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _read_document(
    root: pathlib.Path,
    relative_path: str,
    max_file_bytes: int,
    max_total_remaining: int,
) -> Tuple[Optional[bytes], Optional[str]]:
    candidate = root.joinpath(*pathlib.PurePosixPath(relative_path).parts)
    try:
        initial = candidate.lstat()
    except FileNotFoundError:
        return None, "tracked document is deleted from the working tree"
    except OSError:
        return None, "tracked document metadata could not be read"

    if stat.S_ISLNK(initial.st_mode):
        try:
            target = candidate.resolve(strict=True)
        except (OSError, RuntimeError):
            return None, "symlink source is broken or cannot be resolved"
        if not _within(target, root):
            return None, "symlink source escapes the project root"
        return None, "symlink sources are excluded"

    try:
        resolved = candidate.resolve(strict=True)
    except (OSError, RuntimeError):
        return None, "tracked document cannot be resolved"
    if not _within(resolved, root):
        return None, "document path escapes the project root"
    if not stat.S_ISREG(initial.st_mode):
        return None, "special files are excluded"
    if initial.st_size > max_file_bytes:
        return None, "document exceeds max_file_bytes=%d" % max_file_bytes
    if initial.st_size > max_total_remaining:
        return None, "document exceeds remaining max_total_bytes"

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    try:
        descriptor = os.open(str(resolved), flags)
    except OSError:
        return None, "tracked document could not be opened safely"
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            return None, "special files are excluded"
        chunks: List[bytes] = []
        read_limit = min(max_file_bytes, max_total_remaining)
        remaining = read_limit + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
    except OSError:
        return None, "tracked document could not be read safely"
    finally:
        os.close(descriptor)

    content = b"".join(chunks)
    if len(content) > max_file_bytes:
        return None, "document exceeds max_file_bytes=%d" % max_file_bytes
    if len(content) > max_total_remaining:
        return None, "document exceeds remaining max_total_bytes"
    try:
        final = resolved.stat()
    except OSError:
        return None, "document changed during collection"
    if _stat_signature(before) != _stat_signature(after) or _stat_signature(after) != _stat_signature(final):
        return None, "document changed during collection"
    return content, None


def _source_id(kind: str, locator: str) -> str:
    identity = _encode_identity(kind + "\0" + locator)
    return "source:" + hashlib.sha256(identity).hexdigest()[:24]


def _decode_content(raw: bytes) -> Tuple[str, bool]:
    try:
        return raw.decode("utf-8"), False
    except UnicodeDecodeError:
        return raw.decode("utf-8", errors="replace"), True


def _document_source(path: str, content: str) -> Dict[str, object]:
    encoded = content.encode("utf-8")
    return {
        "id": _source_id("document", path),
        "kind": "document",
        "path": path,
        "content": content,
        "digest": hashlib.sha256(encoded).hexdigest(),
        "locator": path,
        "metadata": {},
    }


def _parse_commit(raw: bytes) -> Tuple[str, str, int, bool]:
    headers, separator, message_bytes = raw.partition(b"\n\n")
    if not separator:
        raise SourceError("Git returned a malformed commit object")

    event_time: Optional[int] = None
    for line in headers.splitlines():
        if not line.startswith(b"committer "):
            continue
        match = re.search(br" ([0-9]+) [+-][0-9]{4}$", line)
        if match:
            event_time = int(match.group(1))
    if event_time is None:
        raise SourceError("Git commit metadata is missing its event time")

    # Keep the original message bytes, including trailing newlines.  The only
    # transformation is the documented replacement of invalid UTF-8.
    content, replaced = _decode_content(message_bytes)
    subject = content.splitlines()[0] if content else ""
    return content, subject, event_time, replaced


def _validated_object_id(raw: bytes, description: str) -> str:
    try:
        value = raw.decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise SourceError("Git returned a non-ASCII %s" % description) from exc
    if not OBJECT_ID.fullmatch(value):
        raise SourceError("Git returned an invalid %s" % description)
    return value


def _commit_object_info(
    root: pathlib.Path,
    shas: Sequence[str],
) -> List[Tuple[str, int]]:
    """Read and strictly validate commit object metadata in bounded batches."""

    result: List[Tuple[str, int]] = []
    for start in range(0, len(shas), MAX_CAT_FILE_BATCH_OBJECTS):
        requested = list(shas[start:start + MAX_CAT_FILE_BATCH_OBJECTS])
        payload = b"".join(sha.encode("ascii") + b"\n" for sha in requested)
        raw, _ = _run_git(
            root,
            ("cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"),
            input_bytes=payload,
        )
        lines = raw.splitlines()
        if len(lines) != len(requested):
            raise SourceError("Git returned an unexpected commit metadata count")
        for expected_sha, line in zip(requested, lines):
            fields = line.split(b" ")
            if len(fields) != 3:
                raise SourceError("Git returned malformed commit metadata")
            actual_sha = _validated_object_id(fields[0], "commit object id")
            if actual_sha != expected_sha:
                raise SourceError("Git returned an unexpected commit object id")
            if fields[1] != b"commit":
                raise SourceError("Git returned a non-commit history object")
            if not fields[2] or not fields[2].isdigit():
                raise SourceError("Git returned an invalid commit size")
            object_size = int(fields[2])
            result.append((actual_sha, object_size))
    return result


def _read_commit_objects(
    root: pathlib.Path,
    objects: Sequence[Tuple[str, int]],
) -> List[Tuple[str, bytes]]:
    """Read commit objects in one batch and enforce Git's framing exactly."""

    if not objects or len(objects) > MAX_CAT_FILE_BATCH_OBJECTS:
        raise SourceError("invalid bounded commit batch")
    payload = b"".join(sha.encode("ascii") + b"\n" for sha, _size in objects)
    raw, _ = _run_git(root, ("cat-file", "--batch"), input_bytes=payload)

    result: List[Tuple[str, bytes]] = []
    offset = 0
    for expected_sha, expected_size in objects:
        header_end = raw.find(b"\n", offset)
        if header_end < 0:
            raise SourceError("Git returned truncated commit batch metadata")
        fields = raw[offset:header_end].split(b" ")
        if len(fields) != 3:
            raise SourceError("Git returned malformed commit batch metadata")
        actual_sha = _validated_object_id(fields[0], "commit object id")
        if actual_sha != expected_sha:
            raise SourceError("Git returned an unexpected commit object id")
        if fields[1] != b"commit":
            raise SourceError("Git returned a non-commit history object")
        if not fields[2] or not fields[2].isdigit():
            raise SourceError("Git returned an invalid commit size")
        declared_size = int(fields[2])
        if declared_size != expected_size:
            raise SourceError("Git commit size changed during collection")

        content_start = header_end + 1
        content_end = content_start + declared_size
        if content_end > len(raw):
            raise SourceError("Git returned a truncated commit object")
        if raw[content_end:content_end + 1] != b"\n":
            raise SourceError("Git returned malformed commit object framing")
        result.append((actual_sha, raw[content_start:content_end]))
        offset = content_end + 1
    if offset != len(raw):
        raise SourceError("Git returned unexpected extra commit batch data")
    return result


def _commit_source(
    sha: str,
    content: str,
    subject: str,
    event_time: int,
) -> Dict[str, object]:
    locator = "git:" + sha
    encoded = content.encode("utf-8")
    return {
        "id": _source_id("commit", locator),
        "kind": "commit",
        "path": "",
        "content": content,
        "digest": hashlib.sha256(encoded).hexdigest(),
        "locator": locator,
        "metadata": {
            "commit_sha": sha,
            "subject": subject,
            "event_time": event_time,
        },
    }


def _validate_limit(name: str, value: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError("%s must be a non-negative integer" % name)


def collect_sources(
    root: pathlib.Path,
    *,
    max_commits: int = 100,
    max_files: int = 60,
    max_file_bytes: int = 65536,
    max_total_bytes: int = 1048576,
    exclude_paths: Iterable[str] = (),
) -> dict:
    """Collect a deterministic snapshot of safe local handbook evidence.

    Documents come only from tracked root README/PRODUCT files and tracked
    Markdown under ``docs/``.  Untracked files are intentionally invisible.
    Recent commits contribute their raw commit messages and metadata without any
    attempt to infer active decisions, causes, or resolution state.
    """

    limits: Dict[str, object] = {
        "max_commits": max_commits,
        "max_files": max_files,
        "max_file_bytes": max_file_bytes,
        "max_total_bytes": max_total_bytes,
    }
    for name, value in limits.items():
        _validate_limit(name, value)
    canonical_exclude_paths = _normalize_exclude_paths(exclude_paths)
    limits["exclude_paths"] = canonical_exclude_paths

    project_root, git_dir = _canonical_repository(pathlib.Path(root))
    head = _head(project_root)
    working_state_before = _working_state(project_root)
    checkout_id = hashlib.sha256(_encode_identity(str(git_dir))).hexdigest()
    tracked = _tracked_paths(project_root)
    unmerged = _unmerged_paths(project_root)

    exclusions: List[Dict[str, str]] = []
    matched_exclude_paths: Set[str] = set()
    candidates: List[str] = []
    for path in tracked:
        deny_reason = _deny_reason(path)
        if deny_reason:
            exclusions.append({
                "path": _safe_exclusion_path(path, deny_reason),
                "reason": deny_reason,
            })
        elif _is_document_candidate(path):
            matched_exclude = _matching_exclude_path(path, canonical_exclude_paths)
            if matched_exclude is None:
                candidates.append(path)
            else:
                matched_exclude_paths.add(matched_exclude)

    # Report configured exclusions once per matching rule, not once per file.
    # This keeps diagnostics bounded by MAX_EXCLUDE_PATHS and avoids copying
    # excluded locators into evidence.  The explicit non-secret rules remain
    # visible in policy.exclude_paths for review.
    for excluded in matched_exclude_paths:
        reason = (
            "documents excluded by configured directory prefix"
            if excluded.endswith("/")
            else "document excluded by configured exact path"
        )
        exclusions.append({
            "path": _redacted_policy_exclusion(excluded),
            "reason": reason,
        })

    ignored = _ignored_paths(project_root, candidates)
    document_sources: List[Dict[str, object]] = []
    warnings: List[str] = []
    total_bytes = 0
    max_files_reported = False
    max_total_reported = False

    for path in candidates:
        if path in ignored:
            exclusions.append({"path": path, "reason": "Git-ignored document is excluded"})
            continue
        if path in unmerged:
            exclusions.append({"path": path, "reason": "unmerged document is excluded"})
            continue
        if len(document_sources) >= max_files:
            exclusions.append({"path": path, "reason": "document exceeds max_files selection"})
            if not max_files_reported:
                warnings.append("document selection reached max_files=%d" % max_files)
                max_files_reported = True
            continue

        raw_content, reason = _read_document(
            project_root,
            path,
            max_file_bytes,
            max_total_bytes - total_bytes,
        )
        if reason:
            if reason == "document exceeds remaining max_total_bytes":
                reason = "document exceeds remaining max_total_bytes=%d" % max_total_bytes
                if not max_total_reported:
                    warnings.append("source selection reached max_total_bytes=%d" % max_total_bytes)
                    max_total_reported = True
            exclusions.append({"path": path, "reason": reason})
            warnings.append("document excluded: %s (%s)" % (path, reason))
            continue
        assert raw_content is not None
        if b"\0" in raw_content:
            reason = "binary document content is excluded"
            exclusions.append({"path": path, "reason": reason})
            warnings.append("document excluded: %s (%s)" % (path, reason))
            continue

        content, replaced = _decode_content(raw_content)
        encoded_size = len(content.encode("utf-8"))
        if total_bytes + encoded_size > max_total_bytes:
            reason = "document exceeds remaining max_total_bytes=%d" % max_total_bytes
            exclusions.append({"path": path, "reason": reason})
            if not max_total_reported:
                warnings.append("source selection reached max_total_bytes=%d" % max_total_bytes)
                max_total_reported = True
            continue
        if replaced:
            warnings.append("document contained invalid UTF-8 and replacement characters were used: %s" % path)
        document_sources.append(_document_source(path, content))
        total_bytes += encoded_size

    commit_sources: List[Dict[str, object]] = []
    if head and max_commits:
        raw_shas, _ = _run_git(
            project_root,
            ("rev-list", "--max-count=%d" % max_commits, "HEAD"),
        )
        raw_sha_lines = [line for line in raw_shas.splitlines() if line]
        if len(raw_sha_lines) > max_commits:
            raise SourceError("Git returned too many commit object ids")
        shas = [_validated_object_id(line, "commit object id") for line in raw_sha_lines]
        if len(set(shas)) != len(shas):
            raise SourceError("Git returned duplicate commit object ids")
        if not shas or shas[0] != head:
            raise SourceError("Git returned history for an unexpected HEAD")
        commit_info = _commit_object_info(project_root, shas)
        index = 0
        while index < len(commit_info):
            sha, object_size = commit_info[index]
            locator = "git:" + sha
            remaining = max_total_bytes - total_bytes
            if remaining <= 0:
                exclusions.append({"path": locator, "reason": "commit exceeds remaining max_total_bytes=%d" % max_total_bytes})
                if not max_total_reported:
                    warnings.append("source selection reached max_total_bytes=%d" % max_total_bytes)
                    max_total_reported = True
                index += 1
                continue
            if object_size > remaining + COMMIT_HEADER_ALLOWANCE:
                exclusions.append({"path": locator, "reason": "commit exceeds remaining max_total_bytes=%d" % max_total_bytes})
                if not max_total_reported:
                    warnings.append("source selection reached max_total_bytes=%d" % max_total_bytes)
                    max_total_reported = True
                index += 1
                continue

            # Keep each buffered response within the caller's aggregate bound
            # plus one bounded allowance for commit headers.  A count cap also
            # bounds framing/input overhead for repositories with tiny commits.
            batch: List[Tuple[str, int]] = []
            batch_bytes = 0
            batch_budget = remaining + COMMIT_HEADER_ALLOWANCE
            scan = index
            while scan < len(commit_info) and len(batch) < MAX_CAT_FILE_BATCH_OBJECTS:
                batch_sha, batch_size = commit_info[scan]
                if batch_size > batch_budget or batch_bytes + batch_size > batch_budget:
                    break
                batch.append((batch_sha, batch_size))
                batch_bytes += batch_size
                scan += 1

            for actual_sha, raw_commit in _read_commit_objects(project_root, batch):
                actual_locator = "git:" + actual_sha
                content, subject, event_time, replaced = _parse_commit(raw_commit)
                encoded_size = len(content.encode("utf-8"))
                if total_bytes + encoded_size > max_total_bytes:
                    exclusions.append({"path": actual_locator, "reason": "commit exceeds remaining max_total_bytes=%d" % max_total_bytes})
                    if not max_total_reported:
                        warnings.append("source selection reached max_total_bytes=%d" % max_total_bytes)
                        max_total_reported = True
                    continue
                if replaced:
                    warnings.append("commit contained invalid UTF-8 and replacement characters were used: %s" % actual_locator)
                commit_sources.append(
                    _commit_source(actual_sha, content, subject, event_time)
                )
                total_bytes += encoded_size
            index = scan

    sources = document_sources + commit_sources
    sources.sort(key=lambda item: (0 if item["kind"] == "document" else 1, item["locator"]))
    exclusions.sort(key=lambda item: (item["path"], item["reason"]))
    warnings = sorted(set(warnings))

    head_after = _head(project_root)
    working_state_after = _working_state(project_root)
    if head_after != head or working_state_after != working_state_before:
        raise SourceError("repository sources changed during collection")

    snapshot_state = {
        "schema": 1,
        "checkout_id": checkout_id,
        "head": head,
        "branch": working_state_before["branch"],
        "working_state": working_state_before["fingerprint"],
        "policy": limits,
        "sources": [
            {
                "id": source["id"],
                "kind": source["kind"],
                "locator": source["locator"],
                "digest": source["digest"],
                "metadata": source["metadata"],
            }
            for source in sources
        ],
        "exclusions": exclusions,
    }
    snapshot_bytes = json.dumps(
        snapshot_state,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    return {
        "project_root": str(project_root),
        "checkout_id": checkout_id,
        "head": head,
        "snapshot_digest": hashlib.sha256(snapshot_bytes).hexdigest(),
        "sources": sources,
        "warnings": warnings,
        "exclusions": exclusions,
        "policy": limits,
    }
