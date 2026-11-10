"""Snapshot-scoped code intelligence on the existing ByoriDB query transport.

The Rust indexer owns parsing; this module validates its interchange format and
publishes immutable graph snapshots. An active pointer is written only after all
records and edges succeed. Old snapshots remain available for recovery; they are
not included in ordinary queries. No source execution or model inference occurs.
"""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import time


LANGUAGES = ("python", "swift", "javascript", "typescript", "rust")
MAX_LIMIT = 100
MAX_BATCH_BYTES = 64 * 1024
MAX_KEY = 8192
MIGRATION = (
    "CREATE TAG IF NOT EXISTS code_index(checkout STRING, root STRING, snapshot STRING, revision STRING, summary STRING, ts INT64)",
    "CREATE TAG IF NOT EXISTS code_snapshot(checkout STRING, snapshot STRING, digest STRING, summary STRING, ts INT64)",
    "CREATE TAG IF NOT EXISTS code_file(checkout STRING, snapshot STRING, key STRING, path STRING, language STRING, content_hash STRING)",
    "CREATE TAG IF NOT EXISTS code_symbol(checkout STRING, snapshot STRING, key STRING, name STRING, qualified STRING, kind STRING, path STRING, line INT64, end_line INT64, language STRING)",
    "CREATE TAG IF NOT EXISTS code_reference(checkout STRING, snapshot STRING, key STRING, source_key STRING, target_key STRING, kind STRING, name STRING, path STRING, line INT64, resolution STRING)",
    "CREATE EDGE IF NOT EXISTS code_defines(ts INT64)",
    "CREATE EDGE IF NOT EXISTS code_calls(ts INT64)",
    "CREATE EDGE IF NOT EXISTS code_imports(ts INT64)",
)


def _string(value, name, maximum=MAX_KEY, empty=False):
    if not isinstance(value, str) or (not empty and not value):
        raise ValueError("%s must be %sa string" % (name, "" if empty else "a non-empty "))
    if len(value) > maximum or "\x00" in value:
        raise ValueError("%s is too long or contains NUL" % name)
    return value


def _integer(value, name, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ValueError("%s must be an integer in %s..%s" % (name, low, high))
    return value


def _hex(value, name, length):
    if not isinstance(value, str) or not re.fullmatch("[0-9a-f]{%d}" % length, value):
        raise ValueError("%s must be %d lowercase hexadecimal characters" % (name, length))
    return value


def _path(value, name="file"):
    _string(value, name, 4096)
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or value != path.as_posix() or any(p in (".", "..") for p in path.parts):
        raise ValueError("%s must be a normalized repository-relative path" % name)
    return value


def _object(value, name):
    if not isinstance(value, dict):
        raise ValueError("%s must be an object" % name)
    return value


def _array(value, name, limit):
    if not isinstance(value, list) or len(value) > limit:
        raise ValueError("%s must be an array with at most %d entries" % (name, limit))
    return value


def _args(args, allowed):
    _object(args, "arguments")
    if set(args) - set(allowed):
        raise ValueError("unsupported fields: %s" % ", ".join(sorted(set(args) - set(allowed))))


def _literal(value):
    if type(value) is int:
        return str(value)
    # Control characters cannot introduce query tokens. Escape carriage returns,
    # tabs and backslashes as well as the quote/newline used by memory tools.
    value = str(value).replace("\\", "\\\\").replace("'", "\\'")
    return "'" + value.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "'"


def _digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                     separators=(",", ":")).encode()).hexdigest()


def _clip_utf8(value, size):
    return value.encode("utf-8")[:size].decode("utf-8", errors="ignore")


def _key_chunks(keys):
    """Bound escaped UTF-8 WHERE clauses, including adversarial long IDs."""
    chunk, size = [], 0
    for key in keys:
        cost = len(_literal(key).encode()) + 48
        if chunk and size + cost > MAX_BATCH_BYTES // 2:
            yield chunk
            chunk, size = [], 0
        chunk.append(key)
        size += cost
    if chunk:
        yield chunk


def _vid(value):
    return int.from_bytes(hashlib.sha256(value.encode()).digest()[:8], "big") & 0x7FFF_FFFF_FFFF_FFFF


def checkout_for_root(root):
    return hashlib.sha256(str(root).encode()).hexdigest()[:16]


def default_checkout():
    start = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()
    try:
        result = subprocess.run(["git", "-C", str(start), "rev-parse", "--show-toplevel"],
                                capture_output=True, text=True, timeout=10, check=False)
        if result.returncode == 0:
            start = pathlib.Path(result.stdout.strip()).resolve()
    except (OSError, subprocess.SubprocessError):
        pass
    return checkout_for_root(start)


def validate_payload(payload):
    """Validate the whole input before starting any graph writes."""
    _object(payload, "index")
    if type(payload.get("format_version")) is not int or payload["format_version"] != 1:
        raise ValueError("unsupported index format_version (expected 1)")
    root = _string(payload.get("root"), "root", 4096)
    if not pathlib.Path(root).is_absolute() or str(pathlib.Path(root).resolve()) != root:
        raise ValueError("root must be a canonical absolute checkout path")
    checkout = _hex(payload.get("checkout_id"), "checkout_id", 16)
    if checkout != checkout_for_root(root):
        raise ValueError("checkout_id does not match root")
    snapshot = _hex(payload.get("snapshot_id"), "snapshot_id", 64)
    revision = _string(payload.get("revision", ""), "revision", 128, empty=True)
    files = _array(payload.get("files"), "files", 100_000)
    symbols = _array(payload.get("symbols"), "symbols", 1_000_000)
    references = _array(payload.get("references"), "references", 3_000_000)
    diagnostics = _array(payload.get("diagnostics", []), "diagnostics", 100_000)
    by_path, by_id, vids = {}, {}, {}

    def register(key, record):
        _string(key, "id")
        if key in by_id:
            raise ValueError("duplicate code id: %s" % key)
        vid = _vid("code:%s:%s:%s" % (checkout, snapshot, key))
        if vid in vids:
            raise ValueError("code VID collision")
        by_id[key], vids[vid] = record, key

    for file in files:
        _object(file, "file")
        path = _path(file.get("path"))
        if file.get("id") != "file:" + path or path in by_path:
            raise ValueError("file id must be unique and equal file:<path>")
        if file.get("language") not in LANGUAGES:
            raise ValueError("unsupported language: %s" % file.get("language"))
        _hex(file.get("hash"), "file hash", 64)
        by_path[path] = file
        register(file["id"], file)
    for symbol in symbols:
        _object(symbol, "symbol")
        if _path(symbol.get("file")) not in by_path:
            raise ValueError("symbol references a missing file")
        for field in ("name", "qualified_name", "kind"):
            _string(symbol.get(field), "symbol " + field, 4096)
        start = _integer(symbol.get("start_line"), "start_line", 1, 2**31 - 1)
        _integer(symbol.get("end_line"), "end_line", start, 2**31 - 1)
        register(symbol.get("id"), symbol)
    for ref in references:
        _object(ref, "reference")
        source_key = _string(ref.get("source"), "reference source")
        if source_key not in by_id or _path(ref.get("file")) not in by_path:
            raise ValueError("reference source or file is missing")
        source = by_id[ref["source"]]
        if source.get("file", source.get("path")) != ref["file"]:
            raise ValueError("reference evidence must belong to its source file")
        if ref.get("kind") not in ("calls", "imports"):
            raise ValueError("reference kind must be calls or imports")
        _string(ref.get("name"), "reference name", 4096)
        _integer(ref.get("line"), "reference line", 1, 2**31 - 1)
        if ref.get("resolution") == "resolved":
            if _string(ref.get("target"), "reference target") not in by_id:
                raise ValueError("resolved reference target is missing")
        elif ref.get("resolution") != "unresolved" or ref.get("target") is not None:
            raise ValueError("unresolved reference target must be null")
    for diagnostic in diagnostics:
        _object(diagnostic, "diagnostic")
        _path(diagnostic.get("file"))
        _string(diagnostic.get("message"), "diagnostic message", 8192)
    # Reserve metadata/reference IDs too: a hash collision must fail before it
    # can overwrite a different record. Repeated identical references share one
    # evidence record, just as repeated calls share one structural edge.
    for identity in ("code-active:" + checkout, "code-snapshot:%s:%s" % (checkout, snapshot)):
        candidate = _vid(identity)
        if candidate in vids:
            raise ValueError("code VID collision")
        vids[candidate] = identity
    for ref in references:
        identity = "code-ref:%s:%s:%s" % (checkout, snapshot, _digest(ref))
        candidate = _vid(identity)
        if candidate in vids and vids[candidate] != identity:
            raise ValueError("code VID collision")
        vids[candidate] = identity
    # Runtime counters (cache hits and elapsed time) do not change snapshot content.
    content = {k: payload.get(k, []) for k in
               ("files", "symbols", "references", "diagnostics")}
    return checkout, snapshot, revision, by_path, by_id, _digest(content)


class CodeGraph:
    def __init__(self, query, ensure_ready, checkout=default_checkout):
        self.query = query
        self.ensure_ready = ensure_ready
        self.checkout = checkout

    def _rows(self, query):
        return self.query(query, read_only=True).get("results") or []

    def _select(self, tag, fields, where, limit, offset=0):
        projection = ", ".join("n.%s.%s AS %s" % (tag, field, alias)
                               for field, alias in fields)
        return self._rows("MATCH (n:%s) WHERE %s RETURN %s ORDER BY %s ASC LIMIT %d OFFSET %d"
                          % (tag, where, projection, fields[0][1], limit, offset))

    def _active(self, checkout):
        rows = self._select("code_index", [(x, x) for x in
                            ("checkout", "root", "snapshot", "revision", "summary", "ts")],
                            "n.code_index.checkout == " + _literal(checkout), 2)
        if len(rows) > 1:
            raise RuntimeError("ambiguous active code index for checkout")
        if not rows:
            return None
        row = dict(rows[0])
        summary = json.loads(row.pop("summary"))
        row.update(summary)
        row["checkout_id"] = row.pop("checkout")
        row["snapshot_id"] = row.pop("snapshot")
        row["indexed_at"] = row.pop("ts")
        row["working_tree_verified"] = False
        row["freshness"] = "not_checked"
        return row

    def _context(self, args):
        checkout = _hex(args["checkout_id"] if "checkout_id" in args else self.checkout(),
                        "checkout_id", 16)
        self.ensure_ready()
        active = self._active(checkout)
        if active is None:
            return checkout, None
        return checkout, active

    @staticmethod
    def _scope(tag, active):
        return "n.%s.checkout == %s AND n.%s.snapshot == %s" % (
            tag, _literal(active["checkout_id"]), tag, _literal(active["snapshot_id"]))

    def _insert(self, tag, fields, rows):
        prefix = "INSERT VERTEX %s(%s) VALUES " % (tag, ", ".join(fields))
        batch, size = [], len(prefix.encode())
        for vid, values in rows:
            row = "%d:(%s)" % (vid, ", ".join(_literal(v) for v in values))
            row_size = len(row.encode()) + 2
            if row_size + len(prefix.encode()) > MAX_BATCH_BYTES:
                raise ValueError("code record exceeds maximum query batch size")
            if batch and size + row_size > MAX_BATCH_BYTES:
                self.query(prefix + ", ".join(batch))
                batch, size = [], len(prefix.encode())
            batch.append(row)
            size += row_size
        if batch:
            self.query(prefix + ", ".join(batch))

    def _edges(self, kind, edges, timestamp):
        prefix = "INSERT EDGE code_%s(ts) VALUES " % kind
        batch, size = [], len(prefix)
        for source, target in sorted(set(edges)):
            row = "%d->%d:(%d)" % (source, target, timestamp)
            if batch and size + len(row) + 2 > MAX_BATCH_BYTES:
                self.query(prefix + ", ".join(batch))
                batch, size = [], len(prefix)
            batch.append(row)
            size += len(row) + 2
        if batch:
            self.query(prefix + ", ".join(batch))

    def store(self, payload):
        checkout, snapshot, revision, by_path, by_id, digest = validate_payload(payload)
        self.ensure_ready()
        previous = self._active(checkout)
        if previous and previous["snapshot_id"] == snapshot:
            if previous["digest"] != digest:
                raise ValueError("snapshot_id reused with different content")
            if previous["revision"] == revision:
                return {"ok": True, "unchanged": True, "index": previous}
            # A commit may leave all indexed files unchanged. Rebind the proven
            # content to that revision without rewriting any code records.
            summary = {k: v for k, v in previous.items() if k not in (
                "revision", "root", "checkout_id", "snapshot_id", "indexed_at",
                "working_tree_verified", "freshness")}
            self._insert("code_index", ("checkout", "root", "snapshot", "revision", "summary", "ts"), [
                (_vid("code-active:" + checkout), (checkout, payload["root"], snapshot, revision,
                 json.dumps(summary, ensure_ascii=False, separators=(",", ":")), int(time.time() * 1000)))])
            return {"ok": True, "unchanged": True, "index": self._active(checkout)}
        scope = "n.code_snapshot.checkout == %s AND n.code_snapshot.snapshot == %s" % (
            _literal(checkout), _literal(snapshot))
        existing = self._select("code_snapshot", [("digest", "digest")], scope, 2)
        if existing and (len(existing) != 1 or existing[0]["digest"] != digest):
            raise ValueError("snapshot_id reused with different content")
        now = int(time.time() * 1000)
        refs = payload["references"]
        diagnostics = payload.get("diagnostics", [])
        displayed_diagnostics = [{"file": _clip_utf8(d["file"], 256),
                                  "message": _clip_utf8(d["message"], 1024)}
                                 for d in diagnostics[:20]]
        summary = {
            "digest": digest, "files": len(payload["files"]), "symbols": len(payload["symbols"]),
            "resolved_references": sum(r["resolution"] == "resolved" for r in refs),
            "unresolved_references": sum(r["resolution"] == "unresolved" for r in refs),
            "diagnostics": displayed_diagnostics, "diagnostics_count": len(diagnostics),
            "diagnostics_truncated": displayed_diagnostics != diagnostics,
            "languages": sorted({f["language"] for f in payload["files"]}),
            "language_stats": {
                language: {
                    "files": sum(f["language"] == language for f in payload["files"]),
                    "symbols": sum(by_path[s["file"]]["language"] == language for s in payload["symbols"]),
                } for language in sorted({f["language"] for f in payload["files"]})
            },
        }
        packed = json.dumps(summary, ensure_ascii=False, separators=(",", ":"))
        # Escaping can expand a message several times (JSON inside an nGQL
        # literal). Bound its actual encoded query size, not character count.
        while len(_literal(packed).encode()) > MAX_BATCH_BYTES // 2 and summary["diagnostics"]:
            summary["diagnostics"].pop()
            summary["diagnostics_truncated"] = True
            packed = json.dumps(summary, ensure_ascii=False, separators=(",", ":"))
        # A staging header pins the content digest even when a later write fails.
        self._insert("code_snapshot", ("checkout", "snapshot", "digest", "summary", "ts"), [
            (_vid("code-snapshot:%s:%s" % (checkout, snapshot)),
             (checkout, snapshot, digest, packed, now))])

        def vid(key):
            return _vid("code:%s:%s:%s" % (checkout, snapshot, key))

        self._insert("code_file", ("checkout", "snapshot", "key", "path", "language", "content_hash"),
                     ((vid(f["id"]), (checkout, snapshot, f["id"], f["path"], f["language"], f["hash"]))
                      for f in payload["files"]))
        self._insert("code_symbol", ("checkout", "snapshot", "key", "name", "qualified", "kind",
                                     "path", "line", "end_line", "language"),
                     ((vid(s["id"]), (checkout, snapshot, s["id"], s["name"], s["qualified_name"],
                                      s["kind"], s["file"], s["start_line"], s["end_line"],
                                      by_path[s["file"]]["language"])) for s in payload["symbols"]))
        self._insert("code_reference", ("checkout", "snapshot", "key", "source_key", "target_key",
                                        "kind", "name", "path", "line", "resolution"),
                     ((_vid("code-ref:%s:%s:%s" % (checkout, snapshot, _digest(r))),
                       (checkout, snapshot, _digest(r), r["source"], r["target"] or "", r["kind"],
                        r["name"], r["file"], r["line"], r["resolution"])) for r in refs))
        self._edges("defines", ((vid(by_path[s["file"]]["id"]), vid(s["id"]))
                                for s in payload["symbols"]), now)
        for kind in ("calls", "imports"):
            self._edges(kind, ((vid(r["source"]), vid(r["target"])) for r in refs
                               if r["kind"] == kind and r["resolution"] == "resolved"), now)
        # Commit point. Readers keep the previous complete snapshot on any failure
        # above, and use this one on their next call. Callers serialize writers.
        self._insert("code_index", ("checkout", "root", "snapshot", "revision", "summary", "ts"), [
            (_vid("code-active:" + checkout),
             (checkout, payload["root"], snapshot, revision, packed, now))])
        return {"ok": True, "unchanged": False, "index": self._active(checkout)}

    def status(self, args):
        _args(args, ("checkout_id",))
        checkout, active = self._context(args)
        return {"indexed": active is not None, "checkout_id": checkout, "index": active,
                "hint": "Run byori index in this checkout to refresh source analysis."}

    def files(self, args):
        """Page repository files, including files with no indexed definitions."""
        _args(args, ("checkout_id", "query", "language", "limit", "offset"))
        limit = _integer(args.get("limit", 30), "limit", 1, MAX_LIMIT)
        offset = _integer(args.get("offset", 0), "offset", 0, 100_000)
        filters = []
        if "query" in args:
            filters.append("n.code_file.path CONTAINS " +
                           _literal(_string(args["query"], "query", 1024, empty=True)))
        if "language" in args:
            if args["language"] not in LANGUAGES:
                raise ValueError("unsupported language")
            filters.append("n.code_file.language == " + _literal(args["language"]))
        checkout, active = self._context(args)
        rows = []
        if active:
            rows = self._select("code_file", [("key", "id"), ("path", "path"),
                ("language", "language"), ("content_hash", "content_hash")],
                " AND ".join([self._scope("code_file", active)] + filters), limit + 1, offset)
        return {"checkout_id": checkout, "index": active, "files": rows[:limit],
                "truncated": len(rows) > limit, "next_offset": offset + limit if len(rows) > limit else None}

    def _symbols_for_keys(self, active, keys):
        """Bounded relation labels from the exact snapshot, without N+1 reads."""
        found = []
        for chunk in _key_chunks(sorted(set(key for key in keys if key and not key.startswith("file:")))):
            where = self._scope("code_symbol", active) + " AND (" + " OR ".join(
                "n.code_symbol.key == " + _literal(key) for key in chunk) + ")"
            found.extend(self._select("code_symbol", [("key", "id"), ("name", "name"),
                ("qualified", "qualified_name"), ("kind", "kind"), ("path", "file"),
                ("line", "start_line"), ("end_line", "end_line"), ("language", "language")],
                where, len(chunk)))
        return found

    def search(self, args):
        _args(args, ("checkout_id", "query", "file", "language", "symbol_id", "limit", "offset"))
        limit = _integer(args.get("limit", 30), "limit", 1, MAX_LIMIT)
        offset = _integer(args.get("offset", 0), "offset", 0, 100_000)
        filters = []
        if "query" in args:
            query = _literal(_string(args["query"], "query", 1024, empty=True))
            filters.append("(n.code_symbol.name CONTAINS %s OR n.code_symbol.qualified CONTAINS %s)" % (query, query))
        if "file" in args:
            filters.append("n.code_symbol.path == " + _literal(_path(args["file"])))
        if "language" in args:
            if args["language"] not in LANGUAGES:
                raise ValueError("unsupported language")
            filters.append("n.code_symbol.language == " + _literal(args["language"]))
        if "symbol_id" in args:
            filters.append("n.code_symbol.key == " + _literal(_string(args["symbol_id"], "symbol_id")))
        checkout, active = self._context(args)
        rows = []
        if active:
            where = " AND ".join([self._scope("code_symbol", active)] + filters)
            rows = self._select("code_symbol", [("key", "id"), ("name", "name"),
                ("qualified", "qualified_name"), ("kind", "kind"), ("path", "file"),
                ("line", "start_line"), ("end_line", "end_line"), ("language", "language")],
                where, limit + 1, offset)
            hashes = self._file_hashes(active, {row["file"] for row in rows[:limit]})
            for row in rows[:limit]:
                row["content_hash"] = hashes.get(row["file"])
        return {"checkout_id": checkout, "index": active, "symbols": rows[:limit],
                "truncated": len(rows) > limit, "next_offset": offset + limit if len(rows) > limit else None}

    def _file_hashes(self, active, paths):
        result = {}
        for chunk in _key_chunks(sorted(paths)):
            where = self._scope("code_file", active) + " AND (" + " OR ".join(
                "n.code_file.path == " + _literal(path) for path in chunk) + ")"
            rows = self._select("code_file", [("path", "path"), ("content_hash", "content_hash")],
                                where, len(chunk))
            result.update((row["path"], row["content_hash"]) for row in rows)
        return result

    def _references(self, active, keys, direction, kind, limit):
        # A frontier may contain long qualified IDs. Bound the query text as well
        # as row counts; an arbitrarily long OR expression exceeds engine limits.
        found = {}
        for chunk in _key_chunks(keys):
            for row in self._reference_chunk(active, chunk, direction, kind, limit):
                found[row["id"]] = row
        return [found[key] for key in sorted(found)[:limit]]

    def _reference_chunk(self, active, keys, direction, kind, limit):
        field = "source_key" if direction == "outgoing" else "target_key"
        where = [self._scope("code_reference", active), "(" + " OR ".join(
            "n.code_reference.%s == %s" % (field, _literal(key)) for key in keys) + ")"]
        if kind:
            where.append("n.code_reference.kind == " + _literal(kind))
        if direction == "incoming":
            where.append("n.code_reference.resolution == 'resolved'")
        rows = self._select("code_reference", [("key", "id"), ("source_key", "source"),
            ("target_key", "target"), ("kind", "kind"), ("name", "name"), ("path", "file"),
            ("line", "line"), ("resolution", "resolution")], " AND ".join(where), limit)
        for row in rows:
            if row.get("target") == "":
                row["target"] = None
        return rows

    def relations(self, args):
        _args(args, ("checkout_id", "symbol_id", "kind", "direction", "limit"))
        key = _string(args.get("symbol_id"), "symbol_id")
        limit = _integer(args.get("limit", 30), "limit", 1, MAX_LIMIT)
        direction = args.get("direction", "outgoing")
        kind = args.get("kind", "calls")
        if direction not in ("incoming", "outgoing") or kind not in ("calls", "imports"):
            raise ValueError("invalid relation kind or direction")
        checkout, active = self._context(args)
        rows = self._references(active, [key], direction, kind, limit + 1) if active else []
        return {"checkout_id": checkout, "index": active, "relations": rows[:limit],
                "symbols": self._symbols_for_keys(active, [key] + [k for r in rows[:limit]
                    for k in (r["source"], r["target"])]) if active else [],
                "truncated": len(rows) > limit, "direction": direction, "kind": kind}

    def impact(self, args):
        _args(args, ("checkout_id", "symbol_id", "depth", "limit"))
        seed = _string(args.get("symbol_id"), "symbol_id")
        depth = _integer(args.get("depth", 3), "depth", 1, 5)
        limit = _integer(args.get("limit", 50), "limit", 1, MAX_LIMIT)
        checkout, active = self._context(args)
        seen, frontier, impacted, evidence = {seed}, [seed], [], []
        truncated = False
        if active:
            for distance in range(1, depth + 1):
                next_frontier = []
                # At most limit+1 references at each hop: cycles/fanout cannot
                # create an unbounded traversal or hide a cut behind 'complete'.
                rows = self._references(active, frontier, "incoming", None, limit + 1)
                if len(rows) > limit:
                    truncated = True
                for ref in rows[:limit]:
                    evidence.append(ref)
                    key = ref["source"]
                    if key in seen:
                        continue
                    if len(impacted) >= limit:
                        truncated = True
                        break
                    seen.add(key)
                    impacted.append({"id": key, "distance": distance})
                    next_frontier.append(key)
                frontier = next_frontier
                if not frontier or len(impacted) >= limit:
                    if frontier:
                        truncated = True
                    break
            if frontier:
                # Reaching max depth is a bounded answer, not an assertion that
                # no additional callers exist beyond it.
                truncated = True
        return {"checkout_id": checkout, "index": active, "seed": seed, "impacted": impacted,
                "symbols": self._symbols_for_keys(active, [seed] + [item["id"] for item in impacted]) if active else [],
                "relations": evidence, "depth": depth, "truncated": truncated,
                "coverage": "Resolved static calls/imports only; dynamic references are excluded."}


def tool_definitions(graph):
    checkout = {"type": "string", "pattern": "^[0-9a-f]{16}$", "minLength": 16, "maxLength": 16,
                "description": "Defaults to the current Git checkout; linked worktrees have separate indexes."}
    key = {"type": "string", "minLength": 1, "maxLength": MAX_KEY}
    limit = {"type": "integer", "minimum": 1, "maximum": MAX_LIMIT}

    def tool(handler, description, properties, required=()):
        return {"handler": handler, "description": description, "inputSchema": {
            "type": "object", "properties": dict({"checkout_id": checkout}, **properties),
            "required": list(required), "additionalProperties": False}}

    return {
        "code_status": tool(graph.status, "Inspect the indexed source snapshot, languages, diagnostics and unresolved references for this checkout. Indexing is performed by byori index; freshness is not assumed.", {}),
        "code_search": tool(graph.search, "Find indexed Python, Swift, JS/TS and Rust symbols with source locations. Results belong to one immutable checkout snapshot; verify current source before editing.", {
            "query": {"type": "string", "maxLength": 1024}, "file": {"type": "string", "minLength": 1, "maxLength": 4096},
            "language": {"type": "string", "enum": list(LANGUAGES)}, "symbol_id": key,
            "limit": limit, "offset": {"type": "integer", "minimum": 0, "maximum": 100_000}}),
        "code_relations": tool(graph.relations, "Read callers/callees or imports/dependents. Pass a symbol id from code_search or file:<relative path>. Outgoing results include explicitly unresolved references.", {
            "symbol_id": key, "kind": {"type": "string", "enum": ["calls", "imports"]},
            "direction": {"type": "string", "enum": ["incoming", "outgoing"]}, "limit": limit}, ("symbol_id",)),
        "code_impact": tool(graph.impact, "Traverse resolved incoming calls/imports to find potentially affected code. Bounded depth and result limits are reported; this is static evidence, not complete runtime/test coverage.", {
            "symbol_id": key, "depth": {"type": "integer", "minimum": 1, "maximum": 5}, "limit": limit}, ("symbol_id",)),
    }
