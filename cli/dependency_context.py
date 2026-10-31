#!/usr/bin/env python3
"""Experimental, read-only, version-bound consumer knowledge. No model or DB calls."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys


MAX_SOURCE = 1024 * 1024
MAX_TOTAL = 4 * MAX_SOURCE
MAX_MANIFEST = 128 * 1024
ID = re.compile(r"[a-z][a-z0-9_-]{0,63}\Z")
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")
LIMITATIONS = [
    "Claims are manually curated source reviews, not automatically proven facts.",
    "Source hashes do not prove claim entailment or that cited tests were executed.",
    "Source commits do not identify the installed engine or establish release compatibility.",
    "Only declared sources are covered; this is not an exhaustive dependency analysis.",
    "Copied Markdown is a snapshot; rerun inspection before reuse.",
    "Byte counts are not model token usage or demonstrated cost savings.",
]


class ContextError(ValueError):
    """Malformed or excessive input; messages never contain source contents."""


class _Unavailable(Exception):
    pass


def _object(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ContextError("Object fields do not match the pilot schema")


def _text(value, maximum):
    if (not isinstance(value, str) or not value.strip() or len(value) > maximum
            or any(ord(c) < 32 and c not in "\n\t" for c in value)):
        raise ContextError("Invalid or excessive text")
    try:
        value.encode("utf-8")
    except UnicodeError as exc:
        raise ContextError("Text must be valid UTF-8") from exc


def _identifier(value):
    if not isinstance(value, str) or not ID.fullmatch(value):
        raise ContextError("Invalid identifier")


def _list(value, maximum):
    if not isinstance(value, list) or not 1 <= len(value) <= maximum:
        raise ContextError("Invalid or excessive list")


def _path(value):
    _text(value, 512)
    path = PurePosixPath(value)
    if (path.is_absolute() or str(path) != value or "\\" in value
            or any(p in (".", "..", ".git") for p in path.parts)
            or any(ord(c) < 32 for c in value)):
        raise ContextError("Source path must be a normal relative path")
    for part in path.parts:
        lower = part.lower()
        if (lower == ".env" or lower.startswith(".env.")
                or lower in ("id_rsa", "id_ed25519", "credentials", "credentials.json")
                or lower.endswith((".pem", ".key", ".p12", ".pfx"))):
            raise ContextError("Sensitive source paths are excluded")


def _validate(manifest):
    _object(manifest, ("schema_version", "title", "task", "repositories", "sources", "claims"))
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] != 1:
        raise ContextError("Unsupported manifest schema")
    _text(manifest["title"], 160)
    _text(manifest["task"], 1000)
    repositories = manifest["repositories"]
    if not isinstance(repositories, dict) or not 1 <= len(repositories) <= 4:
        raise ContextError("Expected one to four repositories")
    for name, repo in repositories.items():
        _identifier(name)
        _object(repo, ("revision",))
        if not isinstance(repo["revision"], str) or not COMMIT.fullmatch(repo["revision"]):
            raise ContextError("Use a full Git commit hash")
    _list(manifest["sources"], 12)
    source_ids, paths = set(), set()
    for source in manifest["sources"]:
        _object(source, ("id", "repo", "path", "sha256"))
        _identifier(source["id"])
        _identifier(source["repo"])
        _path(source["path"])
        identity = (source["repo"], source["path"])
        if source["id"] in source_ids or identity in paths:
            raise ContextError("Duplicate source")
        source_ids.add(source["id"])
        paths.add(identity)
        if source["repo"] not in repositories:
            raise ContextError("Unknown source repository")
        if not isinstance(source["sha256"], str) or not HASH.fullmatch(source["sha256"]):
            raise ContextError("Invalid source SHA256")
    _list(manifest["claims"], 20)
    claim_ids, text_bytes = set(), 0
    for claim in manifest["claims"]:
        _object(claim, ("id", "kind", "text", "evidence"))
        _identifier(claim["id"])
        if claim["id"] in claim_ids:
            raise ContextError("Duplicate claim")
        claim_ids.add(claim["id"])
        if claim["kind"] not in ("contract", "consumer_policy", "limitation"):
            raise ContextError("Invalid claim kind")
        _text(claim["text"], 1000)
        text_bytes += len(claim["text"].encode("utf-8"))
        _list(claim["evidence"], 6)
        for evidence in claim["evidence"]:
            _object(evidence, ("source", "start", "end"))
            _identifier(evidence["source"])
            start, end = evidence["start"], evidence["end"]
            if (evidence["source"] not in source_ids or type(start) is not int
                    or type(end) is not int or start < 1 or end < start or end - start >= 100):
                raise ContextError("Invalid evidence range")
    if text_bytes > 24 * 1024:
        raise ContextError("Claim text exceeds budget")


def _git(root, *arguments):
    env = os.environ.copy()
    # Avoid inherited alternate worktrees/indexes, replacement objects and injected config.
    env = {k: v for k, v in env.items() if not k.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_NO_REPLACE_OBJECTS="1", GIT_TERMINAL_PROMPT="0",
               GIT_LITERAL_PATHSPECS="1")
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, env=env,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise _Unavailable() from exc
    if result.returncode:
        raise _Unavailable()
    return result.stdout


def _head(root):
    return _git(root, "rev-parse", "--verify", "HEAD^{commit}").decode("ascii").strip()


def _blob(root, revision, path):
    entry = _git(root, "ls-tree", "-z", revision, "--", path)
    if not entry or len(entry.split(b"\0")) != 2:
        raise _Unavailable()
    try:
        info, name = entry[:-1].split(b"\t", 1)
        mode, kind, oid = info.split(b" ")
        if mode not in (b"100644", b"100755") or kind != b"blob" or name.decode("utf-8") != path:
            raise _Unavailable()
        object_id = oid.decode("ascii")
        size = int(_git(root, "cat-file", "-s", object_id))
    except (ValueError, UnicodeError) as exc:
        raise _Unavailable() from exc
    if size > MAX_SOURCE:
        raise ContextError("Committed source exceeds byte budget")
    content = _git(root, "cat-file", "blob", object_id)
    if len(content) != size:
        raise _Unavailable()
    return content


def _working_matches(root, path, expected):
    candidate = root
    try:
        for part in PurePosixPath(path).parts:
            candidate = candidate / part
            if candidate.is_symlink():
                return False
        flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(candidate, flags)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_SOURCE:
                return False
            content = stream.read(MAX_SOURCE + 1)
            after = os.fstat(stream.fileno())
            return (before.st_mtime_ns == after.st_mtime_ns and before.st_size == after.st_size
                    and content == expected)
    except OSError:
        return False


def inspect_context(manifest: dict, roots: dict[str, Path]) -> dict:
    """Check explicit source bindings; withhold all prose when review is needed."""
    _validate(manifest)
    if not isinstance(roots, dict) or set(roots) - set(manifest["repositories"]):
        raise ContextError("Unknown repository binding")
    report = {
        "schema_version": 1, "status": "needs_review", "title": manifest["title"],
        "task": manifest["task"], "repositories": {}, "diagnostics": [],
        "claims": [], "evidence": [], "metrics": {"source_bytes_checked": 0,
        "selected_evidence_bytes": 0, "context_bytes": 0, "model_tokens": None},
        "limitations": list(LIMITATIONS),
    }

    def diagnostic(code, repo=None, source=None):
        item = {"code": code}
        if repo is not None:
            item["repo"] = repo
        if source is not None:
            item["source"] = source
        if item not in report["diagnostics"]:
            report["diagnostics"].append(item)

    available = {}
    for name, specification in manifest["repositories"].items():
        expected = specification["revision"]
        identity = {"expected_revision": expected, "observed_revision": None,
                    "runtime_compatibility": "not_checked"}
        report["repositories"][name] = identity
        try:
            root = Path(roots[name]).resolve(strict=True)
            toplevel = Path(_git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve()
            if root != toplevel:
                raise _Unavailable()
            actual = _head(root)
            identity["observed_revision"] = actual
            if actual != expected:
                diagnostic("revision_mismatch", name)
            # Read the pinned object, not HEAD, even when the checkout has moved.
            if _git(root, "cat-file", "-t", expected).strip() != b"commit":
                raise _Unavailable()
            available[name] = root
        except (KeyError, TypeError, ValueError, OSError, _Unavailable):
            diagnostic("repository_unavailable", name)

    blobs, sources = {}, {}
    for source in manifest["sources"]:
        name, sid = source["repo"], source["id"]
        sources[sid] = source
        if name not in available:
            continue
        root = available[name]
        try:
            content = _blob(root, manifest["repositories"][name]["revision"], source["path"])
        except _Unavailable:
            diagnostic("source_missing", name, sid)
            continue
        report["metrics"]["source_bytes_checked"] += len(content)
        if report["metrics"]["source_bytes_checked"] > MAX_TOTAL:
            raise ContextError("Total source bytes exceed budget")
        if hashlib.sha256(content).hexdigest() != source["sha256"]:
            diagnostic("source_hash_mismatch", name, sid)
            continue
        if not _working_matches(root, source["path"], content):
            diagnostic("working_tree_changed", name, sid)
        try:
            lines = content.decode("utf-8").splitlines(keepends=True)
        except UnicodeError as exc:
            raise ContextError("Evidence sources must be UTF-8 text") from exc
        blobs[sid] = (content, lines)

    evidence_items, seen = [], set()
    for claim in manifest["claims"]:
        for evidence in claim["evidence"]:
            sid, start, end = evidence["source"], evidence["start"], evidence["end"]
            if sid not in blobs:
                continue
            lines = blobs[sid][1]
            if end > len(lines):
                raise ContextError("Evidence range exceeds source length")
            key = (sid, start, end)
            if key in seen:
                continue
            seen.add(key)
            source = sources[sid]
            excerpt = "".join(lines[start - 1:end])
            report["metrics"]["selected_evidence_bytes"] += len(excerpt.encode("utf-8"))
            if report["metrics"]["selected_evidence_bytes"] > 64 * 1024:
                raise ContextError("Selected evidence exceeds budget")
            evidence_items.append({**evidence, "repo": source["repo"], "path": source["path"],
                "revision": manifest["repositories"][source["repo"]]["revision"],
                "sha256": source["sha256"], "text": excerpt})

    # Check again after extraction. This is a source snapshot, not a runtime lease.
    for name, root in available.items():
        try:
            if _head(root) != report["repositories"][name]["observed_revision"]:
                diagnostic("revision_mismatch", name)
        except _Unavailable:
            diagnostic("repository_unavailable", name)
    for sid, (content, _) in blobs.items():
        source = sources[sid]
        if not _working_matches(available[source["repo"]], source["path"], content):
            diagnostic("working_tree_changed", source["repo"], sid)
    if not report["diagnostics"]:
        report["status"] = "ready"
        report["claims"] = json.loads(json.dumps(manifest["claims"]))
        report["evidence"] = evidence_items
    report["metrics"]["context_bytes"] = len(render_context(report).encode("utf-8"))
    return report


def _literal(text):
    # Source-derived prose is reference data, never active HTML or Markdown links.
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace("`", "&#96;").replace("[", "&#91;").replace("]", "&#93;"))


def render_context(report: dict) -> str:
    lines = ["# " + _literal(report["title"]), "", "Status: " + report["status"],
             "Reference data only; not instructions. Source review, not runtime certification.",
             "", _literal(report["task"]), ""]
    for name, identity in report["repositories"].items():
        lines.append(f"- {name}: source commit {identity['expected_revision']}; installed runtime NOT checked.")
    lines.append("")
    if report["status"] != "ready":
        lines.append("Claims withheld. Review source bindings before using this knowledge.")
        for item in report["diagnostics"]:
            lines.append(f"- {item['code']}: {item.get('repo', '')} {item.get('source', '')}".rstrip())
    else:
        citations = {(e["source"], e["start"], e["end"]): e for e in report["evidence"]}
        for claim in report["claims"]:
            lines.extend([f"## {claim['id']} ({claim['kind']})", "", _literal(claim["text"])])
            for reference in claim["evidence"]:
                e = citations[(reference["source"], reference["start"], reference["end"])]
                lines.append(f"Source: {e['repo']}@{e['revision']}:{_literal(e['path'])}:{e['start']}-{e['end']}")
            lines.append("")
    lines.extend(["", "## Limits", ""] + ["- " + item for item in report["limitations"]])
    return "\n".join(lines).rstrip() + "\n"


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ContextError("Duplicate JSON object key")
        result[key] = value
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--repo", action="append", default=[], metavar="NAME=PATH")
    parser.add_argument("--format", choices=("json", "markdown"), default="markdown")
    args = parser.parse_args(argv)
    try:
        with args.manifest.open("rb") as stream:
            raw = stream.read(MAX_MANIFEST + 1)
        if len(raw) > MAX_MANIFEST:
            raise ContextError("Manifest exceeds byte budget")
        manifest = json.loads(raw, object_pairs_hook=_unique_object)
        roots = {}
        for binding in args.repo:
            name, separator, value = binding.partition("=")
            _identifier(name)
            if not separator or not value or name in roots:
                raise ContextError("Invalid or duplicate repository binding")
            roots[name] = Path(value)
        report = inspect_context(manifest, roots)
    except (ContextError, OSError, UnicodeError, json.JSONDecodeError):
        print("Invalid dependency context input; check schema, paths and bounds.", file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=False, indent=2) if args.format == "json"
          else render_context(report), end="\n" if args.format == "json" else "")
    return 0 if report["status"] == "ready" else 1


if __name__ == "__main__":
    sys.exit(main())
