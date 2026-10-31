"""Deterministic, source-preserving project handbook compilation.

This module never runs a model or source-provided command. Extracts are attributed
reference material, not newly inferred policy. Publication has one activation
point: replacement of handbook.md after an immutable generation is durable.
"""

import contextlib
import fcntl
import hashlib
import json
import marshal
import os
import pathlib
import re
import stat
import subprocess
import sys
import time
import uuid
from collections import deque
from urllib.parse import quote

from handbook_sources import SourceError, collect_sources
from handbook_projection import MEMO, PROJECTION_VERSION, ProjectionMemo, _encoded as _projection_encoded
from handbook_projection_cache import ProjectionCache
from handbook_records import valid_record_identity


SCHEMA_VERSION = 1
COMPILER_VERSION = "1.3.0"
MAX_STORED_BYTES = 4 * 1024 * 1024
GENERATION = re.compile(r"^<!-- byori-handbook:v1 generation=([a-f0-9]{64}) -->$")
EVIDENCE_DIGEST = re.compile(r"^<!-- evidence-sha256:([a-f0-9]{64}) -->$")
_AUTO_RECORDS = object()
SENSITIVE = re.compile(
    r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|"
    r"\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16})\b|"
    r"(?im:^\s*(?:export\s+)?[\w-]*(?:password|secret|api[_-]?key|access[_-]?token)"
    r"[\w-]*\s*[:=]\s*[\"']?[^\s\"']{8,})"
)


class HandbookError(RuntimeError):
    """A bounded, user-facing compiler/publication failure."""


class HandbookBusy(HandbookError):
    """Another cooperative writer still holds a required lock."""


class HandbookCancelled(HandbookError):
    """An operation was cancelled at a safe boundary."""


def _check_cancel(cancelled):
    if cancelled is not None and cancelled():
        raise HandbookCancelled("handbook operation cancelled")


def _acquire_lock(handle, timeout=2.0, cancelled=None):
    if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or not 0 <= timeout <= 30:
        raise HandbookError("lock timeout must be between 0 and 30 seconds")
    deadline = time.monotonic() + timeout
    while True:
        _check_cancel(cancelled)
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise HandbookBusy("another handbook writer is busy; retry shortly")
            time.sleep(min(0.025, max(0, deadline - time.monotonic())))


def _json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _sensitive(value, depth=0):
    """Inspect strings before JSON quoting can disguise assignment boundaries."""
    if depth > 16:
        return True
    if isinstance(value, str):
        return bool(SENSITIVE.search(value))
    if isinstance(value, dict):
        return any(_sensitive(key, depth + 1) or _sensitive(item, depth + 1)
                   or _sensitive(str(key) + "=" + str(item), depth + 1)
                   for key, item in value.items())
    if isinstance(value, (list, tuple)):
        return any(_sensitive(item, depth + 1) for item in value)
    return False


def _read(fd, name, limit=MAX_STORED_BYTES):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        handle = os.open(name, flags, dir_fd=fd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise HandbookError("unsafe or unreadable handbook storage") from exc
    with os.fdopen(handle, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise HandbookError("handbook storage is not a bounded regular file")
        data = source.read(limit + 1)
    if len(data) > limit:
        raise HandbookError("handbook storage exceeds the read limit")
    try:
        return data.decode("utf-8")
    except UnicodeError as exc:
        raise HandbookError("handbook storage is not UTF-8") from exc


@contextlib.contextmanager
def _directory(parent_fd, name, create=False):
    if create:
        with contextlib.suppress(FileExistsError):
            os.mkdir(name, mode=0o700, dir_fd=parent_fd)
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        yield fd
    finally:
        os.close(fd)


@contextlib.contextmanager
def _storage(root, create=False):
    root_fd = os.open(str(root), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with _directory(root_fd, ".byori", create) as fd:
            yield fd
    finally:
        os.close(root_fd)


def _atomic(fd, name, text):
    temporary = ".%s.%s.tmp" % (name, uuid.uuid4().hex)
    handle = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=fd)
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=fd)


def _open_lock(parent_fd, name):
    """Create once, then open the same persistent lock inode.

    On macOS simultaneous O_CREAT|O_NOFOLLOW opens of an absent file can
    return ENOENT to the losing creator. Exclusive creation gives an explicit
    EEXIST handoff instead. Cooperative writers never unlink these lock files.
    """
    flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        return os.open(name, flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent_fd)
    except FileExistsError:
        return os.open(name, flags, dir_fd=parent_fd)


def protect_outputs(root, *, lock_timeout=2.0, cancelled=None):
    """Keep local evidence/config backups out of ordinary `git add .`.

    This updates only Git's local exclude file, never tracked .gitignore or the
    index. A pre-existing tracked output tree needs explicit user remediation.
    """
    root = pathlib.Path(root).resolve(strict=True)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("GIT_")}
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    def git(*args):
        result = subprocess.run(["git", "--no-pager", "-c", "core.hooksPath=/dev/null",
                                 "-c", "core.fsmonitor=false", "-C", str(root), *args],
                                capture_output=True, timeout=30, env=environment)
        if result.returncode:
            raise HandbookError("cannot verify local Git output exclusion")
        return result.stdout
    if git("ls-files", "-z", "--", ".byori"):
        raise HandbookError(".byori outputs are already tracked; untrack them explicitly before building or connecting")
    path = pathlib.Path(os.fsdecode(git("rev-parse", "--git-path", "info/exclude").rstrip(b"\n")))
    if not path.is_absolute():
        path = root / path
    parent = path.parent
    # Git owns this directory. Refuse symlinks rather than following a hostile exclude.
    if parent.is_symlink() or path.is_symlink():
        raise HandbookError("Git exclude path must not be a symlink")
    if not parent.exists():
        parent.mkdir(mode=0o700)
    fd = os.open(str(parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        lock = _open_lock(fd, "byori-exclude.lock")
        try:
            if not stat.S_ISREG(os.fstat(lock).st_mode):
                raise HandbookError("Git exclude lock is not a regular file")
            _acquire_lock(lock, lock_timeout, cancelled)
            original = _read(fd, "exclude", 1024 * 1024)
            text = original or ""
            if "/.byori/" not in text.splitlines():
                addition = ("" if not text or text.endswith("\n") else "\n") + "# Byori local generated evidence and connection backups\n/.byori/\n"
                if _read(fd, "exclude", 1024 * 1024) != original:
                    raise HandbookError("Git exclude changed concurrently; retry")
                _atomic(fd, "exclude", text + addition)
        finally:
            os.close(lock)
    finally:
        os.close(fd)
    ignored = subprocess.run(
        ["git", "-c", "core.fsmonitor=false", "-C", str(root),
         "check-ignore", "--no-index", "-q", "--", ".byori/handbook.md"],
        capture_output=True, timeout=30, env=environment,
    )
    if ignored.returncode != 0:
        raise HandbookError("repository ignore rules override .byori protection; review them before building")


def _markdown_lines(content):
    """Yield original lines and whether they are outside Markdown code blocks.

    A fence closes only with the same marker, at least the opening length and
    whitespace after it. This is deliberately not a semantic Markdown parser;
    it only prevents example headings/status lines from becoming policy labels.
    """
    fence = None
    for line in content.splitlines():
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence is not None:
            if (marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1]
                    and not marker[2].strip()):
                fence = None
            yield line, False
        elif marker and (marker[1][0] != "`" or "`" not in marker[2]):
            fence = (marker[1][0], len(marker[1]))
            yield line, False
        else:
            yield line, not line.startswith(("    ", "\t"))


def _sections(content):
    """Keep complete heading sections; don't cut a condition mid-paragraph."""
    current = []
    for line, outside_code in _markdown_lines(content):
        if outside_code and re.match(r"^#{1,6}\s", line) and current:
            block = "\n".join(current).strip()
            if block:
                yield block
            current = []
        current.append(line)
    block = "\n".join(current).strip()
    if block:
        yield block


def _category(source):
    path = source.get("path", "").lower()
    if source["kind"] == "commit":
        return "Recorded changes"
    if source["kind"] == "checkpoint":
        record_type = source.get("metadata", {}).get("type")
        if record_type == "module":
            return "Declared modules — verify applicability"
        if record_type == "decision":
            return "Recorded decisions — verify applicability"
        if record_type in {"bug", "incident"}:
            return "Recorded pitfalls — verify applicability"
        return "Durable records — verify applicability"
    if "adr" in path or "decision" in path:
        return "Decision documents — verify applicability"
    if pathlib.PurePosixPath(path).name.lower() in {"readme.md", "product.md"}:
        return "Project overview"
    return "Project documentation"


def _source_rank(source):
    categories = ["Project overview", "Declared modules — verify applicability",
                  "Recorded decisions — verify applicability", "Recorded pitfalls — verify applicability",
                  "Durable records — verify applicability",
                  "Decision documents — verify applicability", "Project documentation",
                  "Recorded changes"]
    return (categories.index(_category(source)), source["locator"], source["id"])


def _project_source(value):
    """One trusted per-source projection; no storage or global budget decisions."""
    source = value["source"]
    states = _declared_lifecycle(source)
    claims = []
    for index, block in enumerate(_sections(source["content"])):
        if not any(line.strip() and not line.startswith("#") for line in block.splitlines()):
            continue
        claims.append({"id": "excerpt:" + _digest(source["id"] + "\0" + str(index) + "\0" + block)[:24],
                       "source_id": source["id"], "body": block, "kind": "attributed_excerpt",
                       "state": "unverified", "source_declared_states": states,
                       "support": "verbatim_source_excerpt", "source_digest": source["digest"]})
    return {"claims": claims, "declarations": value["declarations"],
            "category": _category(source), "states": states}


def _quote_data(text):
    return "\n".join("> " + line.replace("<", "&lt;").replace(">", "&gt;") for line in text.splitlines())


def _render_claim(source, unit, claim, relations, names):
    qualification = ""
    states = unit["states"]
    if states:
        qualification = "Source-declared lifecycle: `%s` — not verified current policy.\n\n" % ", ".join(states)
        if set(states) & {"proposed", "draft", "superseded", "deprecated", "rejected", "withdrawn"}:
            qualification += "Contains a non-current or unaccepted label; do not adopt it as an active rule.\n\n"
    declaration = unit["declarations"]
    for key, label in (("conditions", "Source-declared conditions (retain these qualifications)"),
                       ("module_paths", "Source-declared module paths (not verified behavior)")):
        if declaration.get(key):
            qualification += label + ":\n\n" + _quote_data("\n".join(declaration[key])) + "\n\n"
    for relation in relations:
        if relation["source"] == source["id"]:
            label = relation["relation"]
            other = relation["target"]
        elif relation["target"] == source["id"] and relation["relation"] in {"conflicts_with", "supersedes"}:
            label = "conflict declared by" if relation["relation"] == "conflicts_with" else "superseded according to"
            other = relation["source"]
        else:
            continue
        qualification += "Source-declared %s: `%s` (`%s`); verify applicability.\n\n" % (label, names[other], other)
    path = source.get("path")
    locator = ("[%s](../%s)" % (source["id"], quote(path, safe="/")) if path
               else "`%s` (%s)" % (source["id"], _locator_text(source["locator"])))
    return ("## %s\n\n" % unit["category"] + qualification + _quote_data(claim["body"])
            + "\n\nSource: " + locator + " · `" + claim["id"] + "`\n\n")


def _locator_text(value):
    # Opaque legacy note names are data, not Markdown links or HTML.
    for char, escaped in (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
                          ("`", "&#96;"), ("[", "&#91;"), ("]", "&#93;"),
                          ("\\", "&#92;")):
        value = value.replace(char, escaped)
    return value


def _record_omission(omissions, reason, source_ids, sections):
    """Aggregate counts by source component, never repeat metadata per section."""
    ids = tuple(sorted(set(source_ids)))
    key = (reason, ids)
    if key not in omissions:
        omissions[key] = {"reason": reason, "source_ids": list(ids), "sections": 0}
    omissions[key]["sections"] += sections


def _selection_groups(sources, units, relationships, omissions):
    """Round-robin categories and sources, preserving related decision components."""
    by_id = {source["id"]: source for source in sources}
    components = {key: {key} for key in by_id}
    for edge in relationships:
        if edge["relation"] not in {"conflicts_with", "supersedes"}:
            continue
        combined = components[edge["source"]] | components[edge["target"]]
        for key in combined:
            components[key] = combined
    queues = {}
    seen = set()
    for source in sorted(sources, key=_source_rank):
        key = source["id"]
        if key in seen:
            continue
        component = components[key]
        seen.update(component)
        rank = _source_rank(source)[0]
        if len(component) > 1:
            if any(not units[member]["claims"] for member in component):
                # A title-only/empty counterpart cannot be represented by an
                # invented excerpt. Keep the originals/edges in evidence and
                # withhold every member instead of implying a one-sided rule.
                _record_omission(omissions, "related_source_has_no_complete_excerpt", component,
                                 sum(len(units[member]["claims"]) for member in component))
                continue
            groups = [[(member, claim) for member in sorted(component, key=lambda item: _source_rank(by_id[item]))
                       for claim in units[member]["claims"]]]
        else:
            groups = [[(key, claim)] for claim in units[key]["claims"]]
        queues.setdefault(rank, deque()).append(iter(groups))
    while queues:
        exhausted_categories = []
        for rank in sorted(queues):
            found = False
            while queues[rank]:
                source_queue = queues[rank].popleft()
                group = next(source_queue, None)
                if group is not None:
                    queues[rank].append(source_queue)
                    if group:
                        yield group
                        found = True
                        break
            if not found:
                exhausted_categories.append(rank)
        for rank in exhausted_categories:
            del queues[rank]


def _render_group(group, by_id, units, relationships, names, limit):
    parts = []
    used = 0
    for key, claim in group:
        rendered = _render_claim(by_id[key], units[key], claim, relationships, names)
        used += len(rendered)
        if used > limit:
            return None
        parts.append(rendered)
    return "".join(parts)


def _declared_lifecycle(source):
    """Expose a source's own labels without promoting them to verified policy."""
    known = {"proposed", "draft", "accepted", "active", "superseded", "deprecated",
             "rejected", "withdrawn", "open", "fixed", "known", "in_progress", "blocked", "done"}
    states = set()
    metadata = source.get("metadata", {})
    metadata_state = metadata.get("original_state", metadata.get("state"))
    if isinstance(metadata_state, str) and metadata_state in known:
        states.add(metadata_state)
    for line, outside_code in _markdown_lines(source["content"]):
        if not outside_code:
            continue
        match = re.fullmatch(r"\s*(?:\*\*)?(?:status|state)(?:\*\*)?\s*:\s*(?:\*\*)?([a-z_-]+)(?:\*\*)?\s*", line, re.IGNORECASE)
        if match and match.group(1).lower() in known:
            states.add(match.group(1).lower())
    return sorted(states)


# Fingerprint the loaded projection implementation, not mutable source files
# reread later. A running old process must not sign its old units as new code
# merely because an installer replaced files on disk. Never deserialize code.
_PROJECTION_IMPLEMENTATION = hashlib.sha256(marshal.dumps((
    (sys.implementation.cache_tag, sys.version.split()[0]),
    tuple(function.__code__ for function in (
        _project_source, _markdown_lines, _sections, _category, _declared_lifecycle,
        _digest, ProjectionMemo.project, _projection_encoded,
    )),
))).hexdigest()


def _projection_scope(snapshot):
    return (snapshot["project_root"], snapshot["checkout_id"], COMPILER_VERSION,
            PROJECTION_VERSION, _PROJECTION_IMPLEMENTATION)


def _projection_observation(target, phase, statistics):
    """Aggregate actual invocations across build/verification passes, not artifacts."""
    if target is None:
        return
    if not target:
        target.update(mode=statistics["mode"], projected_sources=0, reused_sources=0,
                      removed_sources=0, affected_sources=0, passes=[])
    for key in ("projected_sources", "reused_sources", "removed_sources", "affected_sources"):
        target[key] += statistics[key]
    target["passes"].append({"phase": phase, **statistics})


def _persist_projection(snapshot, *, clean=False, cancelled=None):
    if clean or (cancelled is not None and cancelled()):
        return False
    try:
        scope = _projection_scope(snapshot)
        return MEMO.persist(scope, ProjectionCache(snapshot["project_root"], scope))
    except (OSError, ValueError, TypeError, RuntimeError, RecursionError):
        # Publication has already succeeded. Optional cache persistence must not
        # turn it into a reported failed build or weaken its verification.
        return False


def _resolved_records(root, supplied):
    if supplied is not _AUTO_RECORDS:
        return supplied
    try:
        (pathlib.Path(root) / ".byori" / "records").lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise HandbookError("original-record journal is unavailable") from exc
    try:
        import handbook_records
        snapshot = handbook_records.load_records(pathlib.Path(root))
    except ImportError as exc:
        raise HandbookError("original-record journal runtime is not installed") from exc
    except handbook_records.RecordError as exc:
        raise HandbookError(str(exc)) from exc
    if snapshot is None:
        return None
    records = []
    for original in snapshot["records"]:
        record = dict(original, revision=snapshot["revision"])
        scope = original["scope"]
        record["project_id"] = scope["project_id"]
        if scope["kind"] == "checkout":
            record["checkout_id"] = scope["checkout_id"]
        records.append(record)
    return records


def compile_handbook(root, *, accepted_records=_AUTO_RECORDS, max_chars=12000,
                     clean_projection=False, projection_stats=None, **source_limits):
    """Preview without filesystem writes or engine/model requests.

    accepted_records is a caller-owned authoritative snapshot, NOT a graph backup.
    Preserve original records before passing them here; generations are derived.
    """
    if isinstance(max_chars, bool) or not 2048 <= max_chars <= 64000:
        raise HandbookError("max_chars must be between 2048 and 64000")
    if not isinstance(clean_projection, bool) or (projection_stats is not None and not isinstance(projection_stats, dict)):
        raise HandbookError("invalid projection diagnostics request")
    try:
        snapshot = collect_sources(pathlib.Path(root), **source_limits)
    except SourceError as exc:
        raise HandbookError(str(exc)) from exc
    supplied = _resolved_records(snapshot["project_root"], accepted_records)
    records = [] if supplied is None else supplied
    if not isinstance(records, list) or len(records) > 200 or len(_json(records).encode("utf-8")) > 1048576:
        raise HandbookError("accepted records must be a bounded list (at most 200)")
    sources = list(snapshot["sources"])
    seen = set()
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("name"), str) or not isinstance(record.get("body"), str):
            raise HandbookError("each accepted record needs a name and original body")
        name = record["name"]
        known_types = {"note", "module", "decision", "bug", "incident", "concept", "entity", "task"}
        prefix = name.split(":", 1)[0]
        record_type = record.get("type", prefix if prefix in known_types else "note")
        vid = record.get("vid", "")
        if not valid_record_identity(record_type, name):
            raise HandbookError("accepted record identities must use valid canonical names and types")
        if record_type != "note" and prefix != record_type:
            raise HandbookError("typed accepted record prefix must match its type")
        if not isinstance(vid, str) or (vid and not re.fullmatch(r"-?[0-9]{1,32}", vid)):
            raise HandbookError("accepted record VID must remain a decimal string")
        record_key = (record_type, name, vid)
        if record_key in seen:
            raise HandbookError("accepted record identities must be unique canonical names")
        seen.add(record_key)
        scope = record.get("checkout_id")
        if scope and scope != snapshot["checkout_id"]:
            raise HandbookError("accepted record belongs to another checkout")
        metadata_fields = {"name", "type", "vid", "state", "resolved", "source_event_time",
                           "recorded_time", "last_verified", "checkout_id", "project_id", "revision",
                           "provenance", "scope", "original_state", "id"}
        metadata = {key: value for key, value in record.items() if key in metadata_fields}
        metadata.update(type=record_type, name=name)
        if "metadata" in record:
            if not isinstance(record["metadata"], dict):
                raise HandbookError("accepted record metadata must be an object")
            if "handbook" in record["metadata"]:
                metadata["handbook"] = record["metadata"]["handbook"]
            if "original_state" in record["metadata"]:
                metadata.setdefault("original_state", record["metadata"]["original_state"])
        sources.append({"id": "source:" + _digest("checkpoint\0" + "\0".join(record_key))[:24],
                        "kind": "checkpoint", "path": "", "locator": "memory:" + record_type + "/" + name + ("#vid=" + vid if vid else ""),
                        "content": record["body"], "digest": _digest(record["body"]),
                        "metadata": metadata})
    included_sources = [source for source in sources if not _sensitive(source)]
    excluded_sensitive = len(sources) - len(included_sources)
    from handbook_knowledge import annotate_sources, KnowledgeError
    try:
        knowledge = annotate_sources(included_sources)
    except KnowledgeError as exc:
        raise HandbookError(str(exc)) from exc
    projection_inputs = {}
    for source in included_sources:
        # Snapshot bookkeeping stays in evidence/identity but is not a semantic
        # per-source input. A journal revision alone must not reproject every row.
        material = {key: source[key] for key in ("id", "kind", "path", "locator", "content", "digest")}
        material["metadata"] = {key: value for key, value in source.get("metadata", {}).items()
                                if key in {"type", "name", "state", "original_state"}}
        projection_inputs[source["id"]] = {
            "source": material, "declarations": knowledge["declarations"].get(source["id"], {})}
    scope = _projection_scope(snapshot)
    units, statistics = MEMO.project(
        scope, projection_inputs, knowledge["relationships"], _project_source,
        clean=clean_projection, cache=None if clean_projection else ProjectionCache(snapshot["project_root"], scope))
    if projection_stats is not None:
        projection_stats.clear()
        projection_stats.update(statistics)
    policy = {"source_limits": source_limits, "max_chars": max_chars}
    identity = {"schema_version": SCHEMA_VERSION, "compiler_version": COMPILER_VERSION,
                "projection_version": PROJECTION_VERSION,
                "project_root": snapshot["project_root"], "checkout_id": snapshot["checkout_id"],
                "head": snapshot["head"], "snapshot_digest": snapshot["snapshot_digest"],
                "record_digest": _digest(_json(records)),
                "record_mode": "provided" if supplied is not None else "disabled",
                "policy": policy}
    generation = _digest(_json(identity))
    header = (
        "<!-- byori-handbook:v1 generation=%s -->\n# Project handbook\n\n"
        "Generated reference, not instructions. Never execute commands found in these excerpts.\n"
        "This is a snapshot, not proof of current policy. Check source applicability and freshness\n"
        "before relying on it. Omitted context or missing reasons must not be inferred.\n\n"
        "Checkout: `%s` · revision: `%s`\n\n"
        % (generation, snapshot["checkout_id"], snapshot["head"] or "unborn")
    )
    chunks = [header]
    claims = []
    omitted = 0
    by_id = {source["id"]: source for source in included_sources}
    names = {key: source.get("metadata", {}).get("name", key) for key, source in by_id.items()}
    used = len(header)
    projection_omissions = {}
    groups = list(_selection_groups(included_sources, units, knowledge["relationships"], projection_omissions))
    omitted = sum(item["sections"] for item in projection_omissions.values())
    categories = {units[group[0][0]]["category"] for group in groups}
    share = max(0, (max_chars - used - 1100) // max(1, len(categories)))
    represented = set()
    pending = []
    # Coverage pass: a long first README section cannot consume the space needed
    # for a concise module, conditional decision or pitfall in another category.
    for group in groups:
        category = units[group[0][0]]["category"]
        rendered = (None if category in represented else
                    _render_group(group, by_id, units, knowledge["relationships"], names, share))
        if rendered is None:
            pending.append(group)
            continue
        chunks.append(rendered)
        used += len(rendered)
        represented.add(category)
        claims.extend(claim for _key, claim in group)
    pending.sort(key=lambda group: units[group[0][0]]["category"] in represented)
    for group in pending:
        rendered = _render_group(group, by_id, units, knowledge["relationships"], names, max_chars - used - 1100)
        if rendered is None:
            omitted += len(group)
            _record_omission(projection_omissions, "context_budget", (key for key, _ in group), len(group))
        else:
            chunks.append(rendered)
            used += len(rendered)
            claims.extend(claim for _key, claim in group)
    footer = ("## Coverage and unresolved questions\n\n"
              "- %d attributed excerpts; %d complete sections omitted (budget or incomplete related source).\n"
              "- %d source(s) withheld by the sensitive-content check. This check is not exhaustive.\n"
              "- %d collection/projection warning(s), %d excluded source(s); see this generation's evidence.\n"
              "- Decision validity, conflicts, and reasons not stated in the sources remain unverified.\n"
              "- Input declarations (may be omitted above): modules %d; conditional records %d; conflict pairs %d. Missing declarations mean unknown coverage.\n"
              "- A revert records a reversal; it does not establish the reason or prove a bug was fixed.\n"
              "- Use `byori handbook status` to check this checkout; read detailed evidence only when needed.\n"
              % (len(claims), omitted, excluded_sensitive, len(snapshot["warnings"]) + len(knowledge["warnings"]), len(snapshot["exclusions"]),
                 knowledge["coverage"]["declared_modules"], knowledge["coverage"]["conditional_records"],
                 knowledge["coverage"]["conflict_pairs"]))
    handbook = "".join(chunks) + footer
    if len(handbook) > max_chars:
        raise HandbookError("handbook exceeds its declared context budget")
    evidence = {**identity, "generation": generation, "sources": included_sources,
                "claims": claims, "relationships": [
                    {"source": c["id"], "relation": "derived_from", "target": c["source_id"]}
                    for c in claims] + knowledge["relationships"],
                "source_declarations": knowledge["declarations"], "knowledge_coverage": knowledge["coverage"],
                "projection_omissions": [projection_omissions[key] for key in sorted(projection_omissions)],
                "warnings": snapshot["warnings"] + knowledge["warnings"],
                "exclusions": snapshot["exclusions"], "omitted_sections": omitted,
                "sensitive_sources_withheld": excluded_sensitive}
    handbook = handbook.replace("\n", "\n<!-- evidence-sha256:%s -->\n" % _digest(_json(evidence)), 1)
    if len(handbook) > max_chars:
        raise HandbookError("handbook exceeds its declared context budget")
    evidence["handbook_digest"] = _digest(handbook)
    if len(_json(evidence).encode("utf-8")) > MAX_STORED_BYTES:
        raise HandbookError("generation evidence exceeds storage budget")
    return {"schema_version": SCHEMA_VERSION, "generation": generation,
            "project_root": snapshot["project_root"], "handbook": handbook,
            "evidence": evidence, "published": False}


def _active(fd):
    text = _read(fd, "handbook.md", 256000)
    if text is None:
        return None, None
    match = GENERATION.fullmatch(text.splitlines()[0] if text else "")
    if not match:
        raise HandbookError("handbook.md is not compiler-owned; preserve it as a source before building")
    generation = match.group(1)
    try:
        with _directory(fd, "generations") as generations:
            with _directory(generations, generation) as generation_fd:
                raw = _read(generation_fd, "evidence.json")
                expected = _read(generation_fd, "handbook.md", 256000)
        evidence = json.loads(raw or "null")
    except (ValueError, OSError) as exc:
        raise HandbookError("active handbook generation is missing or invalid") from exc
    if not isinstance(evidence, dict) or evidence.get("generation") != generation or expected != text or evidence.get("handbook_digest") != _digest(text):
        raise HandbookError("handbook was modified or its generation is incomplete; refusing to overwrite")
    lines = text.splitlines()
    proof = EVIDENCE_DIGEST.fullmatch(lines[1] if len(lines) > 1 else "")
    material = {key: value for key, value in evidence.items() if key != "handbook_digest"}
    if not proof or proof.group(1) != _digest(_json(material)):
        raise HandbookError("generation evidence was modified or is incomplete")
    if evidence.get("schema_version") != SCHEMA_VERSION or not isinstance(evidence.get("policy"), dict):
        raise HandbookError("unsupported or malformed generation evidence")
    return text, evidence


def publish_handbook(build, *, accepted_records=_AUTO_RECORDS, lock_timeout=2.0, cancelled=None,
                     clean_projection=False, projection_stats=None):
    root = pathlib.Path(build["project_root"])
    evidence = build["evidence"]
    if not isinstance(clean_projection, bool) or (projection_stats is not None and not isinstance(projection_stats, dict)):
        raise HandbookError("invalid projection diagnostics request")
    if evidence.get("generation") != build["generation"] or evidence.get("handbook_digest") != _digest(build["handbook"]):
        raise HandbookError("invalid build artifact")
    try:
        _check_cancel(cancelled)
        protect_outputs(root, lock_timeout=lock_timeout, cancelled=cancelled)
        with _storage(root, True) as fd:
            lock = _open_lock(fd, "compiler.lock")
            try:
                if not stat.S_ISREG(os.fstat(lock).st_mode):
                    raise HandbookError("compiler lock is not a regular file")
                _acquire_lock(lock, lock_timeout, cancelled)
                previous, previous_evidence = _active(fd)
                if previous_evidence and previous_evidence.get("record_mode") == "provided" and _resolved_records(root, accepted_records) is None:
                    raise HandbookError("accepted records are unavailable; refusing to drop them from a rebuild")
                # Recompile the exact snapshot under the writer lock before activation.
                statistics = {}
                current = compile_handbook(root, accepted_records=accepted_records,
                                           **evidence["policy"]["source_limits"],
                                           max_chars=evidence["policy"]["max_chars"],
                                           clean_projection=clean_projection, projection_stats=statistics)
                _projection_observation(projection_stats, "locked_revalidation", statistics)
                if current["generation"] != build["generation"] or current["handbook"] != build["handbook"] or current["evidence"] != evidence:
                    raise HandbookError("sources changed since preview; rebuild before publishing")
                if previous == build["handbook"]:
                    _check_cancel(cancelled)
                    saved = _persist_projection(evidence, clean=clean_projection, cancelled=cancelled)
                    if projection_stats is not None:
                        projection_stats["cache_saved"] = saved
                    return {**build, "published": True, "changed": False}
                with _directory(fd, "generations", True) as generations:
                    with _directory(generations, build["generation"], True) as generation_fd:
                        existing = _read(generation_fd, "evidence.json")
                        serialized = _json(evidence) + "\n"
                        if existing is not None and existing != serialized:
                            raise HandbookError("generation identity collision or edited evidence")
                        prior_text = _read(generation_fd, "handbook.md", 256000)
                        if prior_text is not None and prior_text != build["handbook"]:
                            raise HandbookError("generation contents were edited")
                        if existing is None:
                            _atomic(generation_fd, "evidence.json", serialized)
                        if prior_text is None:
                            _atomic(generation_fd, "handbook.md", build["handbook"])
                        if _read(generation_fd, "evidence.json") != serialized or _read(generation_fd, "handbook.md", 256000) != build["handbook"]:
                            raise HandbookError("staged generation changed before activation")
                    os.fsync(generations)
                now, _ = _active(fd)
                if now != previous:
                    raise HandbookError("handbook changed during publication; refusing to overwrite")
                # Revalidate sources again after evidence I/O, before the only activation write.
                statistics = {}
                latest = compile_handbook(root, accepted_records=accepted_records,
                                          **evidence["policy"]["source_limits"],
                                          max_chars=evidence["policy"]["max_chars"],
                                          clean_projection=clean_projection, projection_stats=statistics)
                _projection_observation(projection_stats, "activation_revalidation", statistics)
                if latest["generation"] != build["generation"]:
                    raise HandbookError("sources changed during publication; rebuild before publishing")
                _check_cancel(cancelled)
                _atomic(fd, "handbook.md", build["handbook"])
                saved = _persist_projection(evidence, clean=clean_projection, cancelled=cancelled)
                if projection_stats is not None:
                    projection_stats["cache_saved"] = saved
                return {**build, "published": True, "changed": True}
            finally:
                os.close(lock)
    except HandbookError:
        raise
    except OSError as exc:
        raise HandbookError("cannot safely publish handbook storage") from exc


def _refresh_policy_matches(root, policy):
    try:
        (pathlib.Path(root) / ".byori" / "refresh.json").lstat()
    except FileNotFoundError:
        return True
    try:
        import handbook_refresh
    except ImportError as exc:
        raise HandbookError("refresh policy runtime is not installed") from exc
    return handbook_refresh.output_policy_matches(root, policy)


def handbook_status(root, *, accepted_records=_AUTO_RECORDS):
    try:
        snapshot = collect_sources(pathlib.Path(root), max_commits=0, max_files=0)
        root = pathlib.Path(snapshot["project_root"])
        with _storage(root) as fd:
            text, evidence = _active(fd)
        if text is None:
            return {"state": "missing", "reason": "No published handbook", "generation": None}
        if evidence["checkout_id"] != snapshot["checkout_id"]:
            return {"state": "unavailable", "reason": "Handbook belongs to another checkout", "generation": evidence["generation"]}
        if not _refresh_policy_matches(root, evidence["policy"]):
            return {"state": "stale", "reason": "Selected source policy changed", "generation": evidence["generation"]}
        supplied = _resolved_records(root, accepted_records)
        if evidence.get("record_mode") == "provided" and supplied is None:
            return {"state": "unavailable", "reason": "Accepted records were not supplied; refusing unverified output", "generation": evidence["generation"]}
        if evidence["record_digest"] != _digest(_json([] if supplied is None else supplied)):
            return {"state": "stale", "reason": "Accepted records changed or were not supplied", "generation": evidence["generation"]}
        current = compile_handbook(root, accepted_records=accepted_records,
                                   max_chars=evidence["policy"]["max_chars"],
                                   **evidence["policy"]["source_limits"])
        if current["generation"] == evidence["generation"] and (current["handbook"] != text or current["evidence"] != evidence):
            return {"state": "unavailable", "generation": evidence["generation"],
                    "reason": "Published artifact differs from deterministic source compilation"}
        state = "current" if current["generation"] == evidence["generation"] else "stale"
        return {"state": state, "generation": evidence["generation"],
                "current_generation": current["generation"],
                "handbook_digest": evidence["handbook_digest"],
                "reason": "Selected source snapshot matches" if state == "current" else "Selected sources or policy changed",
                "path": str(root / ".byori" / "handbook.md"), "claim_count": len(evidence["claims"]),
                "warnings": evidence["warnings"], "excluded_sources": len(evidence["exclusions"]),
                "sensitive_sources_withheld": evidence["sensitive_sources_withheld"],
                "omitted_sections": evidence["omitted_sections"]}
    except FileNotFoundError:
        return {"state": "missing", "generation": None, "reason": "No published handbook"}
    except (HandbookError, SourceError, OSError, ValueError, KeyError, TypeError) as exc:
        return {"state": "unavailable", "generation": None, "reason": str(exc) if isinstance(exc, (HandbookError, SourceError)) else "Handbook storage cannot be verified"}


def read_handbook(root, *, accepted_records=_AUTO_RECORDS):
    status = handbook_status(root, accepted_records=accepted_records)
    if status["state"] != "current":
        return {**status, "handbook": None}
    try:
        with _storage(pathlib.Path(status["path"]).parent.parent) as fd:
            text, evidence = _active(fd)
    except OSError as exc:
        raise HandbookError("handbook storage changed while reading; retry") from exc
    if text is None or evidence is None or evidence["generation"] != status["generation"] or _digest(text) != status["handbook_digest"]:
        raise HandbookError("handbook changed while reading; retry")
    if not _refresh_policy_matches(pathlib.Path(status["path"]).parent.parent, evidence["policy"]):
        return {**status, "state": "stale", "reason": "Selected source policy changed while reading", "handbook": None}
    return {**status, "handbook": text}


def read_evidence(root, expected_generation, *, source_id=None, accepted_records=_AUTO_RECORDS):
    """Follow evidence only within the currently verified requested generation."""
    if not isinstance(expected_generation, str) or not re.fullmatch(r"[a-f0-9]{64}", expected_generation):
        raise HandbookError("expected generation must be a 64-character lowercase hex ID")
    if source_id is not None and (not isinstance(source_id, str) or not re.fullmatch(r"source:[a-f0-9]{24}", source_id)):
        raise HandbookError("source ID must be a generated source:<24 hex> identifier")
    status = read_handbook(root, accepted_records=accepted_records)
    result = {key: value for key, value in status.items() if key != "handbook"}
    if status["state"] != "current":
        return {**result, "evidence": None}
    if status["generation"] != expected_generation:
        return {**result, "state": "unavailable", "evidence": None,
                "reason": "Requested evidence generation is not current"}
    try:
        with _storage(pathlib.Path(status["path"]).parent.parent) as fd:
            text, evidence = _active(fd)
    except OSError as exc:
        raise HandbookError("evidence storage changed while reading; retry") from exc
    if text is None or evidence is None or evidence["generation"] != expected_generation or _digest(text) != status["handbook_digest"]:
        raise HandbookError("evidence generation changed while reading; retry")
    if not _refresh_policy_matches(pathlib.Path(status["path"]).parent.parent, evidence["policy"]):
        return {**result, "state": "stale", "reason": "Selected source policy changed while reading", "evidence": None}
    if source_id is None:
        selected = {"sources": [
            {key: source[key] for key in ("id", "kind", "locator", "digest")}
            for source in evidence["sources"]], "relationships": evidence["relationships"],
            "exclusions": evidence["exclusions"]}
    else:
        source = next((item for item in evidence["sources"] if item["id"] == source_id), None)
        if source is None:
            return {**result, "state": "unavailable", "evidence": None,
                    "reason": "Source is not available in the requested generation"}
        selected = {"source": source, "claims": [item for item in evidence["claims"] if item["source_id"] == source_id]}
    return {**result, "evidence": selected}
