#!/usr/bin/env python3
"""Private, append-only journal for caller-supplied accepted record snapshots.

Nothing in this module reads ByoriDB, calls a model, or discovers records.  The
caller must supply and attest a complete snapshot explicitly.  Generated
handbook generations are disposable; these original bodies are not.
"""

import contextlib
import fcntl
import hashlib
import importlib
import json
import math
import os
import pathlib
import re
import stat
import subprocess
import sys
import threading
import unicodedata
import uuid
from typing import Dict, List, Optional, Sequence, Tuple


SCHEMA_VERSION = 1
MAX_RECORDS = 10_000
MAX_SNAPSHOT_BYTES = 16 * 1024 * 1024
MAX_POINTER_BYTES = 64 * 1024
MAX_HISTORY_REVISIONS = 1_000
MAX_HISTORY_BYTES = 64 * 1024 * 1024
CANONICAL_NAME = re.compile(r"^[a-z][a-z0-9_]*:[A-Za-z0-9][A-Za-z0-9._-]*$")
NODE_TYPES = frozenset({"note", "module", "decision", "bug", "incident", "concept", "entity", "task"})
TYPED_NODE_TYPES = NODE_TYPES - {"note"}
SCHEMA_VERSION_NAME = "byori:schema-version"
VID = re.compile(r"^-?[0-9]{1,32}$")
REVISION = re.compile(r"^[0-9a-f]{64}$")
VERIFICATION_STATES = frozenset({
    "conflicted",
    "inferred",
    "supported",
    "superseded",
    "unverified",
})
RECORD_FIELDS = frozenset({
    "body",
    "metadata",
    "name",
    "provenance",
    "scope",
    "state",
    "type",
    "vid",
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

_THREAD_LOCKS: Dict[str, threading.Lock] = {}
_THREAD_LOCKS_GUARD = threading.Lock()


class RecordError(RuntimeError):
    """A record snapshot or its private journal cannot be trusted."""


class RecordConflict(RecordError):
    """The active revision differs from the caller's expected revision."""


def valid_record_identity(node_type, name):
    """Keep legacy printable note names verbatim; typed identities stay canonical."""
    if not isinstance(node_type, str) or node_type not in NODE_TYPES:
        return False
    if not isinstance(name, str) or not 1 <= len(name) <= 256:
        return False
    if any(unicodedata.category(char) in {"Cc", "Cf", "Cs", "Zl", "Zp"} for char in name):
        return False
    if node_type == "note":
        return name != SCHEMA_VERSION_NAME
    return CANONICAL_NAME.fullmatch(name) is not None and name.startswith(node_type + ":")


def _git_environment() -> Dict[str, str]:
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
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
    })
    return environment


def _git(root: pathlib.Path, arguments: Sequence[str]) -> bytes:
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
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            env=_git_environment(),
        )
    except subprocess.TimeoutExpired as exc:
        raise RecordError("Git identity lookup timed out") from exc
    except OSError as exc:
        raise RecordError("Git identity lookup could not run") from exc
    if result.returncode != 0 or result.stderr:
        raise RecordError("Git identity lookup failed")
    return result.stdout


def _decode_path(value: bytes) -> str:
    return value.decode("utf-8", errors="surrogateescape")


def _identity(root: pathlib.Path) -> Dict[str, str]:
    try:
        requested = pathlib.Path(root).resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise RecordError("project root cannot be resolved") from exc
    if not requested.is_dir():
        raise RecordError("project root is not a directory")

    try:
        top = pathlib.Path(
            _decode_path(_git(requested, ("rev-parse", "--show-toplevel")).rstrip(b"\n"))
        ).resolve(strict=True)
        git_dir = pathlib.Path(
            _decode_path(_git(top, ("rev-parse", "--absolute-git-dir")).rstrip(b"\n"))
        ).resolve(strict=True)
        common_value = pathlib.Path(
            _decode_path(_git(top, ("rev-parse", "--git-common-dir")).rstrip(b"\n"))
        )
        if not common_value.is_absolute():
            common_value = top / common_value
        common_dir = common_value.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise RecordError("Git returned an invalid project identity") from exc
    if not top.is_dir() or not git_dir.is_dir() or not common_dir.is_dir():
        raise RecordError("Git project identity is not directory-backed")

    def digest(path: pathlib.Path) -> str:
        return hashlib.sha256(str(path).encode("utf-8", errors="surrogatepass")).hexdigest()

    return {
        "project_root": str(top),
        "project_id": digest(common_dir),
        "checkout_id": digest(git_dir),
    }


def _protect_journal_outputs(root: pathlib.Path) -> None:
    """Use the compiler's local-exclude guard without a top-level cycle."""

    module_directory = str(pathlib.Path(__file__).resolve().parent)
    inserted = not sys.path or sys.path[0] != module_directory
    if inserted:
        sys.path.insert(0, module_directory)
    try:
        module = importlib.import_module("handbook")
        module_path = pathlib.Path(module.__file__).resolve()
        if module_path != pathlib.Path(__file__).resolve().with_name("handbook.py"):
            raise RecordError("local handbook output guard could not be resolved")
        module.protect_outputs(root)
    except RecordError:
        raise
    except Exception as exc:
        raise RecordError("record journal output could not be protected from Git") from exc
    finally:
        if inserted:
            with contextlib.suppress(ValueError):
                sys.path.remove(module_directory)


def _validate_json(value, depth: int = 0) -> None:
    if depth > 32:
        raise RecordError("record provenance exceeds the nesting limit")
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            raise RecordError("record provenance contains a non-finite number")
        return
    if isinstance(value, list):
        for item in value:
            _validate_json(item, depth + 1)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise RecordError("record provenance keys must be strings")
            _validate_json(item, depth + 1)
        return
    raise RecordError("record provenance contains a non-JSON value")


def _json_bytes(value) -> bytes:
    _validate_json(value)
    try:
        return json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, UnicodeError, ValueError) as exc:
        raise RecordError("record snapshot is not canonical JSON") from exc


def _canonical_copy(value):
    return json.loads(_json_bytes(value).decode("utf-8"))


def _digest(value) -> str:
    return hashlib.sha256(_json_bytes(value)).hexdigest()


def _normalize_envelope(envelope, identity: Dict[str, str]) -> Tuple[dict, List[dict]]:
    if not isinstance(envelope, dict) or set(envelope) != {"complete", "source", "records"}:
        raise RecordError(
            "records must be an explicit complete snapshot with complete, source, and records"
        )
    if envelope["complete"] is not True:
        raise RecordError("record import requires complete=true")
    if not isinstance(envelope["source"], dict) or not envelope["source"]:
        raise RecordError("record import requires non-empty source provenance")
    source = _canonical_copy(envelope["source"])
    records = envelope["records"]
    if not isinstance(records, list):
        raise RecordError("record snapshot records must be a list")
    if len(records) > MAX_RECORDS:
        raise RecordError("record snapshot exceeds the record-count safety bound")
    if len(_json_bytes(envelope)) > MAX_SNAPSHOT_BYTES:
        raise RecordError("record snapshot exceeds the byte safety bound")

    normalized: List[dict] = []
    identities = set()
    for record in records:
        if not isinstance(record, dict) or not set(record).issubset(RECORD_FIELDS):
            raise RecordError("record fields are invalid or would be silently discarded")
        if not {"type", "name", "vid", "body", "scope", "provenance"}.issubset(record):
            raise RecordError("each record requires type, name, vid, body, scope, and provenance")
        node_type = record["type"]
        name = record["name"]
        vid = record["vid"]
        body = record["body"]
        scope_kind = record["scope"]
        provenance = record["provenance"]
        metadata = record.get("metadata", {})
        state = record.get("state", "unverified")
        if node_type not in NODE_TYPES:
            raise RecordError("record type is unsupported")
        if not valid_record_identity(node_type, name):
            raise RecordError("record names must be canonical identities")
        if node_type in TYPED_NODE_TYPES and not name.startswith(node_type + ":"):
            raise RecordError("typed record name prefix must match its type")
        if node_type == "note" and name == SCHEMA_VERSION_NAME:
            raise RecordError("the graph schema marker is not an accepted record")
        if not isinstance(vid, str) or not VID.fullmatch(vid):
            raise RecordError("record vid must be a preserved decimal string")
        graph_identity = (node_type, name, vid)
        if graph_identity in identities:
            raise RecordError("exact graph record identities must be unique")
        identities.add(graph_identity)
        if not isinstance(body, str):
            raise RecordError("record bodies must be strings")
        if scope_kind not in {"project", "checkout"}:
            raise RecordError("record scope must be project or checkout")
        if not isinstance(provenance, dict) or not provenance:
            raise RecordError("record provenance must be a non-empty object")
        if not isinstance(metadata, dict):
            raise RecordError("record metadata must be an object")
        if not isinstance(state, str):
            raise RecordError("record state must be a string")
        provenance = _canonical_copy(provenance)
        metadata = _canonical_copy(metadata)

        scope = {
            "kind": scope_kind,
            "project_id": identity["project_id"],
        }
        scope_identity = identity["project_id"]
        if scope_kind == "checkout":
            scope["checkout_id"] = identity["checkout_id"]
            scope_identity = identity["checkout_id"]
        record_id = "record:" + hashlib.sha256(
            (
                scope_kind + "\0" + scope_identity + "\0"
                + node_type + "\0" + name + "\0" + vid
            ).encode("utf-8")
        ).hexdigest()[:24]
        normalized_record = {
            "id": record_id,
            "type": node_type,
            "name": name,
            "vid": vid,
            "body": body,
            "body_digest": hashlib.sha256(body.encode("utf-8")).hexdigest(),
            "scope": scope,
            "provenance": provenance,
            "metadata": metadata,
            "state": state if state in VERIFICATION_STATES else "unverified",
        }
        if state not in VERIFICATION_STATES:
            normalized_record["original_state"] = state
        normalized.append(normalized_record)
    normalized.sort(
        key=lambda item: (
            item["scope"]["kind"], item["type"], item["name"], item["vid"], item["id"]
        )
    )
    return source, normalized


def _open_directory(
    parent_fd: int,
    name: str,
    create: bool,
    *,
    private: bool = False,
) -> Optional[int]:
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent_fd)
        except FileExistsError:
            pass
        except OSError as exc:
            raise RecordError("record journal directory could not be created safely") from exc
    flags = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise RecordError("record journal directory is unsafe or unreadable") from exc
    directory_stat = os.fstat(descriptor)
    if not stat.S_ISDIR(directory_stat.st_mode):
        os.close(descriptor)
        raise RecordError("record journal path is not a directory")
    if private and directory_stat.st_mode & 0o077:
        os.close(descriptor)
        raise RecordError("record journal directory is not private")
    return descriptor


@contextlib.contextmanager
def _journal(identity: Dict[str, str], create: bool):
    flags = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        root_fd = os.open(identity["project_root"], flags)
    except OSError as exc:
        raise RecordError("project root cannot be opened safely") from exc
    descriptors = [root_fd]
    try:
        byori_fd = _open_directory(root_fd, ".byori", create)
        if byori_fd is None:
            yield None
            return
        descriptors.append(byori_fd)
        records_fd = _open_directory(byori_fd, "records", create, private=True)
        if records_fd is None:
            yield None
            return
        descriptors.append(records_fd)
        snapshots_fd = _open_directory(records_fd, "snapshots", create, private=True)
        if snapshots_fd is None:
            if _read_file(records_fd, "active.json", MAX_POINTER_BYTES) is not None:
                raise RecordError("active record journal is missing its snapshots directory")
            yield None
            return
        descriptors.append(snapshots_fd)
        yield records_fd, snapshots_fd
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _read_file(directory_fd: int, name: str, limit: int) -> Optional[bytes]:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    try:
        descriptor = os.open(name, flags, dir_fd=directory_fd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise RecordError("record journal file is unsafe or unreadable") from exc
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_mode & 0o077
            or before.st_nlink != 1
            or before.st_size > limit
        ):
            raise RecordError("record journal file violates its safety bound")
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    content = b"".join(chunks)
    if len(content) > limit:
        raise RecordError("record journal file violates its safety bound")
    if (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    ) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    ):
        raise RecordError("record journal changed while being read")
    return content


def _parse_json(raw: bytes, label: str):
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise RecordError("record journal %s is invalid" % label) from exc


def _validate_loaded_record(record: dict, identity: Dict[str, str]) -> None:
    required = {
        "id", "type", "name", "vid", "body", "body_digest", "scope", "provenance",
        "metadata", "state",
    }
    if not isinstance(record, dict):
        raise RecordError("stored record schema is invalid")
    record_fields = set(record)
    if record_fields != required and record_fields != required | {"original_state"}:
        raise RecordError("stored record schema is invalid")
    if record["type"] not in NODE_TYPES:
        raise RecordError("stored record type is invalid")
    if not valid_record_identity(record["type"], record["name"]):
        raise RecordError("stored record identity is invalid")
    if record["type"] in TYPED_NODE_TYPES and not record["name"].startswith(record["type"] + ":"):
        raise RecordError("stored typed identity is inconsistent")
    if record["type"] == "note" and record["name"] == SCHEMA_VERSION_NAME:
        raise RecordError("stored schema marker is not an accepted record")
    if not isinstance(record["vid"], str) or not VID.fullmatch(record["vid"]):
        raise RecordError("stored record vid is invalid")
    if not isinstance(record["body"], str):
        raise RecordError("stored record body is invalid")
    if hashlib.sha256(record["body"].encode("utf-8")).hexdigest() != record["body_digest"]:
        raise RecordError("stored record body digest does not match")
    if record["state"] not in VERIFICATION_STATES:
        raise RecordError("stored record verification state is invalid")
    if not isinstance(record["provenance"], dict) or not record["provenance"]:
        raise RecordError("stored record provenance is invalid")
    if not isinstance(record["metadata"], dict):
        raise RecordError("stored record metadata is invalid")
    if "original_state" in record:
        if (
            record["state"] != "unverified"
            or not isinstance(record["original_state"], str)
            or record["original_state"] in VERIFICATION_STATES
        ):
            raise RecordError("stored original record state is invalid")
    scope = record["scope"]
    if not isinstance(scope, dict) or scope.get("project_id") != identity["project_id"]:
        raise RecordError("stored record belongs to another project")
    if scope.get("kind") == "project" and set(scope) == {"kind", "project_id"}:
        scope_identity = identity["project_id"]
    elif (
        scope.get("kind") == "checkout"
        and set(scope) == {"kind", "project_id", "checkout_id"}
        and scope.get("checkout_id") == identity["checkout_id"]
    ):
        scope_identity = identity["checkout_id"]
    else:
        raise RecordError("stored record checkout scope does not match")
    expected_id = "record:" + hashlib.sha256(
        (
            scope["kind"] + "\0" + scope_identity + "\0" + record["type"]
            + "\0" + record["name"] + "\0" + record["vid"]
        ).encode("utf-8")
    ).hexdigest()[:24]
    if record["id"] != expected_id:
        raise RecordError("stored record ID does not match its scope")
    _validate_json(record["provenance"])
    _validate_json(record["metadata"])


def _validate_snapshot(snapshot, identity: Dict[str, str]) -> dict:
    fields = {
        "schema_version", "revision", "parent_revision", "sequence", "complete",
        "project_root", "project_id", "checkout_id", "source", "records",
        "records_digest",
    }
    if not isinstance(snapshot, dict) or set(snapshot) != fields:
        raise RecordError("stored record snapshot schema is invalid")
    if snapshot["schema_version"] != SCHEMA_VERSION or snapshot["complete"] is not True:
        raise RecordError("stored record snapshot version is unsupported")
    for field in ("project_root", "project_id", "checkout_id"):
        if snapshot[field] != identity[field]:
            raise RecordError("stored record snapshot belongs to another project scope")
    if not isinstance(snapshot["sequence"], int) or isinstance(snapshot["sequence"], bool) or snapshot["sequence"] < 1:
        raise RecordError("stored record sequence is invalid")
    parent = snapshot["parent_revision"]
    if parent is not None and (not isinstance(parent, str) or not REVISION.fullmatch(parent)):
        raise RecordError("stored parent revision is invalid")
    if not isinstance(snapshot["source"], dict) or not snapshot["source"]:
        raise RecordError("stored source provenance is invalid")
    if not isinstance(snapshot["records"], list) or len(snapshot["records"]) > MAX_RECORDS:
        raise RecordError("stored records violate the count bound")
    seen = set()
    for record in snapshot["records"]:
        _validate_loaded_record(record, identity)
        graph_identity = (record["type"], record["name"], record["vid"])
        if graph_identity in seen:
            raise RecordError("stored exact graph identities are duplicated")
        seen.add(graph_identity)
    if _digest(snapshot["records"]) != snapshot["records_digest"]:
        raise RecordError("stored record-set digest does not match")
    revision = snapshot["revision"]
    if not isinstance(revision, str) or not REVISION.fullmatch(revision):
        raise RecordError("stored record revision is invalid")
    payload = dict(snapshot)
    payload.pop("revision")
    if _digest(payload) != revision:
        raise RecordError("stored record snapshot digest does not match")
    if len(_json_bytes(snapshot)) > MAX_SNAPSHOT_BYTES:
        raise RecordError("stored record snapshot violates the byte bound")
    return snapshot


def _load_active(
    identity: Dict[str, str],
    records_fd: int,
    snapshots_fd: int,
) -> Tuple[Optional[dict], int, int]:
    raw_pointer = _read_file(records_fd, "active.json", MAX_POINTER_BYTES)
    if raw_pointer is None:
        try:
            snapshot_entries = os.listdir(snapshots_fd)
        except OSError as exc:
            raise RecordError("record snapshot directory cannot be inspected") from exc
        if snapshot_entries:
            raise RecordError("record journal has preserved snapshots but no active pointer")
        return None, 0, 0
    pointer = _parse_json(raw_pointer, "active pointer")
    pointer_fields = {"schema_version", "revision", "project_id", "checkout_id"}
    if not isinstance(pointer, dict) or set(pointer) != pointer_fields:
        raise RecordError("record journal active pointer is invalid")
    if pointer["schema_version"] != SCHEMA_VERSION:
        raise RecordError("record journal active pointer version is unsupported")
    if pointer["project_id"] != identity["project_id"] or pointer["checkout_id"] != identity["checkout_id"]:
        raise RecordError("record journal active pointer belongs to another project scope")
    revision = pointer["revision"]
    if not isinstance(revision, str) or not REVISION.fullmatch(revision):
        raise RecordError("record journal active revision is invalid")
    raw_snapshot = _read_file(snapshots_fd, revision + ".json", MAX_SNAPSHOT_BYTES)
    if raw_snapshot is None:
        raise RecordError("record journal active snapshot is missing")
    snapshot = _validate_snapshot(_parse_json(raw_snapshot, "snapshot"), identity)
    if snapshot["revision"] != revision:
        raise RecordError("record journal pointer and snapshot disagree")
    history_revisions, history_bytes = _validate_history(
        snapshot,
        identity,
        snapshots_fd,
        len(raw_snapshot),
    )
    return snapshot, history_revisions, history_bytes


def _validate_history(
    active: dict,
    identity: Dict[str, str],
    snapshots_fd: int,
    active_bytes: int,
) -> Tuple[int, int]:
    current = active
    seen = {current["revision"]}
    total_bytes = active_bytes
    while current["parent_revision"] is not None:
        if len(seen) >= MAX_HISTORY_REVISIONS:
            raise RecordError("record revision history exceeds its safety bound")
        parent_revision = current["parent_revision"]
        if parent_revision in seen:
            raise RecordError("record revision history contains a cycle")
        raw_parent = _read_file(
            snapshots_fd,
            parent_revision + ".json",
            MAX_SNAPSHOT_BYTES,
        )
        if raw_parent is None:
            raise RecordError("record revision history is missing a parent snapshot")
        total_bytes += len(raw_parent)
        if total_bytes > MAX_HISTORY_BYTES:
            raise RecordError("record revision history exceeds its byte safety bound")
        parent = _validate_snapshot(_parse_json(raw_parent, "parent snapshot"), identity)
        if parent["revision"] != parent_revision:
            raise RecordError("record parent filename and revision disagree")
        if parent["sequence"] != current["sequence"] - 1:
            raise RecordError("record revision sequence is discontinuous")
        seen.add(parent_revision)
        current = parent
    if current["sequence"] != 1:
        raise RecordError("record revision history has no initial snapshot")
    return len(seen), total_bytes


def _recover_initial_candidate(
    identity: Dict[str, str],
    records_fd: int,
    snapshots_fd: int,
    candidate: dict,
    candidate_bytes: bytes,
) -> Optional[dict]:
    """Activate only the exact sole snapshot left by an interrupted first import."""

    if candidate["parent_revision"] is not None or candidate["sequence"] != 1:
        return None
    if _read_file(records_fd, "active.json", MAX_POINTER_BYTES) is not None:
        return None
    expected_name = candidate["revision"] + ".json"
    try:
        entries = os.listdir(snapshots_fd)
    except OSError as exc:
        raise RecordError("record snapshot directory cannot be inspected") from exc
    if entries != [expected_name]:
        return None
    preserved = _read_file(snapshots_fd, expected_name, MAX_SNAPSHOT_BYTES)
    if preserved != candidate_bytes:
        return None
    stored = _validate_snapshot(_parse_json(preserved, "recovery snapshot"), identity)
    if stored != candidate:
        return None
    if 1 > MAX_HISTORY_REVISIONS or len(preserved) > MAX_HISTORY_BYTES:
        raise RecordError("record revision history exceeds its safety bound")
    pointer = {
        "schema_version": SCHEMA_VERSION,
        "revision": candidate["revision"],
        "project_id": identity["project_id"],
        "checkout_id": identity["checkout_id"],
    }
    _atomic_write(records_fd, "active.json", _json_bytes(pointer))
    return stored


def _write_all(descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise RecordError("record journal write did not make progress")
        offset += written


def _write_immutable(directory_fd: int, name: str, data: bytes) -> None:
    temporary = ".%s.%s.tmp" % (name, uuid.uuid4().hex)
    temporary_exists = True
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
        _write_all(descriptor, data)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        try:
            os.link(
                temporary,
                name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
                follow_symlinks=False,
            )
        except FileExistsError:
            existing = _read_file(directory_fd, name, MAX_SNAPSHOT_BYTES)
            if existing != data:
                raise RecordError("content-addressed record snapshot conflicts on disk")
        os.unlink(temporary, dir_fd=directory_fd)
        temporary_exists = False
        os.fsync(directory_fd)
        installed = _read_file(directory_fd, name, MAX_SNAPSHOT_BYTES)
        if installed != data:
            raise RecordError("installed record snapshot failed verification")
    except RecordError:
        raise
    except OSError as exc:
        raise RecordError("record snapshot could not be installed safely") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_exists:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=directory_fd)
        with contextlib.suppress(OSError):
            os.fsync(directory_fd)


def _atomic_write(directory_fd: int, name: str, data: bytes) -> None:
    temporary = ".%s.%s.tmp" % (name, uuid.uuid4().hex)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
        _write_all(descriptor, data)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
    except OSError as exc:
        raise RecordError("record journal pointer could not be activated atomically") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=directory_fd)


def _thread_lock(project_root: str) -> threading.Lock:
    with _THREAD_LOCKS_GUARD:
        return _THREAD_LOCKS.setdefault(project_root, threading.Lock())


def load_records(root: pathlib.Path) -> Optional[dict]:
    """Load and verify the active original-record snapshot, or return ``None``.

    ``None`` only means no active journal exists.  Unsafe, corrupt, incomplete,
    or wrongly scoped storage raises :class:`RecordError` instead of becoming an
    authoritative empty snapshot.
    """

    identity = _identity(pathlib.Path(root))
    with _journal(identity, create=False) as journal:
        if journal is None:
            return None
        records_fd, snapshots_fd = journal
        snapshot, _, _ = _load_active(identity, records_fd, snapshots_fd)
        return snapshot


def import_records(
    root: pathlib.Path,
    records,
    expected_revision: Optional[str] = None,
) -> dict:
    """Append and activate one explicitly complete accepted-record snapshot.

    ``expected_revision=None`` is create-only.  Updating an existing journal
    requires its current revision, making stale thread/process writers fail with
    :class:`RecordConflict` instead of silently dropping records.
    """

    if expected_revision is not None and (
        not isinstance(expected_revision, str) or not REVISION.fullmatch(expected_revision)
    ):
        raise RecordError("expected_revision must be None or a SHA-256 revision")
    identity = _identity(pathlib.Path(root))
    source, normalized = _normalize_envelope(records, identity)
    _protect_journal_outputs(pathlib.Path(identity["project_root"]))
    lock = _thread_lock(identity["project_root"])
    with lock, _journal(identity, create=True) as journal:
        assert journal is not None
        records_fd, snapshots_fd = journal
        lock_flags = os.O_RDWR
        if hasattr(os, "O_CLOEXEC"):
            lock_flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            lock_flags |= os.O_NOFOLLOW
        if hasattr(os, "O_NONBLOCK"):
            lock_flags |= os.O_NONBLOCK
        try:
            lock_fd = os.open(
                "lock",
                lock_flags | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=records_fd,
            )
        except FileExistsError:
            try:
                lock_fd = os.open("lock", lock_flags, 0o600, dir_fd=records_fd)
            except OSError as exc:
                raise RecordError("record journal lock is unsafe or unavailable") from exc
        except OSError as exc:
            raise RecordError("record journal lock is unsafe or unavailable") from exc
        try:
            if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
                raise RecordError("record journal lock is not a regular file")
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            try:
                current, history_revisions, history_bytes = _load_active(
                    identity,
                    records_fd,
                    snapshots_fd,
                )
            except RecordError:
                if expected_revision is not None:
                    raise
                initial_payload = {
                    "schema_version": SCHEMA_VERSION,
                    "parent_revision": None,
                    "sequence": 1,
                    "complete": True,
                    "project_root": identity["project_root"],
                    "project_id": identity["project_id"],
                    "checkout_id": identity["checkout_id"],
                    "source": source,
                    "records": normalized,
                    "records_digest": _digest(normalized),
                }
                initial_revision = _digest(initial_payload)
                initial_candidate = dict(initial_payload, revision=initial_revision)
                initial_bytes = _json_bytes(initial_candidate)
                recovered = _recover_initial_candidate(
                    identity,
                    records_fd,
                    snapshots_fd,
                    initial_candidate,
                    initial_bytes,
                )
                if recovered is not None:
                    return recovered
                raise
            current_revision = current["revision"] if current is not None else None
            if current_revision != expected_revision:
                raise RecordConflict("active record revision changed; reload before importing")
            if (
                current is not None
                and current["source"] == source
                and current["records"] == normalized
            ):
                return current

            payload = {
                "schema_version": SCHEMA_VERSION,
                "parent_revision": current_revision,
                "sequence": 1 if current is None else current["sequence"] + 1,
                "complete": True,
                "project_root": identity["project_root"],
                "project_id": identity["project_id"],
                "checkout_id": identity["checkout_id"],
                "source": source,
                "records": normalized,
                "records_digest": _digest(normalized),
            }
            revision = _digest(payload)
            snapshot = dict(payload, revision=revision)
            snapshot_bytes = _json_bytes(snapshot)
            if len(snapshot_bytes) > MAX_SNAPSHOT_BYTES:
                raise RecordError("record snapshot exceeds the byte safety bound")
            if history_revisions + 1 > MAX_HISTORY_REVISIONS:
                raise RecordError("record revision history exceeds its safety bound")
            if history_bytes + len(snapshot_bytes) > MAX_HISTORY_BYTES:
                raise RecordError("record revision history exceeds its byte safety bound")
            _write_immutable(snapshots_fd, revision + ".json", snapshot_bytes)
            pointer = {
                "schema_version": SCHEMA_VERSION,
                "revision": revision,
                "project_id": identity["project_id"],
                "checkout_id": identity["checkout_id"],
            }
            _atomic_write(records_fd, "active.json", _json_bytes(pointer))
            return snapshot
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
