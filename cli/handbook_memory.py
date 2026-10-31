"""Reviewed, non-destructive capture of observed legacy memory originals.

Two equal observations are not a database snapshot. Missing observations never
delete journal records; only reviewed, adapter-owned records can be updated.
No source command, engine migration, service operation or model is executed.
"""

import contextlib
import copy
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import stat
import time
import urllib.error
import urllib.parse
import urllib.request

import handbook
import handbook_records as journal


ADAPTER = "byoridb-memory-capture-v1"
MAX_RECORDS = 200
MAX_LINKS = 2000
MAX_BYTES = 1024 * 1024
SPACE = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,63}")
TYPES = ("note", "module", "decision", "bug", "incident", "concept", "entity", "task")
STATES = {"decision": {"active", "superseded"}, "bug": {"open", "fixed", "known"},
          "task": {"open", "in_progress", "blocked", "done"}}


class MemoryCaptureError(RuntimeError):
    """Fixed, source/credential-free diagnostics for capture failures."""


def _require(value, message):
    if not value:
        raise MemoryCaptureError(message)


def _encoded(value):
    try:
        journal._validate_json(value)
        raw = json.dumps(value, ensure_ascii=False, sort_keys=True,
                         separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise MemoryCaptureError("memory response is not bounded valid JSON") from None
    _require(len(raw) <= MAX_BYTES, "memory input exceeds the byte limit; select fewer records")
    return raw


def _digest(value):
    return hashlib.sha256(_encoded(value)).hexdigest()


def _private_file(path, *, missing=False, limit=MAX_BYTES):
    try:
        before = path.lstat()
    except FileNotFoundError:
        if missing:
            return None
        raise MemoryCaptureError("installed private runtime configuration is missing") from None
    _require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
             and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600
             and before.st_size <= limit, "configuration must be a bounded private regular file")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as handle:
            opened = os.fstat(handle.fileno())
            _require((opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
                     "configuration changed while opening")
            raw = handle.read(limit + 1)
            after = os.fstat(handle.fileno())
        current = path.lstat()
        _require((after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                 == (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                 and current == after and len(raw) <= limit,
                 "configuration changed while reading")
        return raw
    except OSError:
        raise MemoryCaptureError("private configuration could not be read") from None


def _endpoint(value):
    try:
        parsed = urllib.parse.urlsplit(value)
        host = parsed.hostname
        port = parsed.port
        literal = ipaddress.ip_address(host)
        valid = (parsed.scheme == "http" and literal.is_loopback and port is not None
                 and 1 <= port <= 65535 and parsed.path in {"", "/"}
                 and not parsed.username and not parsed.password
                 and not parsed.query and not parsed.fragment)
    except (TypeError, ValueError):
        valid = False
    _require(valid, "memory capture requires a literal loopback HTTP endpoint with an explicit port")
    host = "[" + str(literal) + "]" if literal.version == 6 else str(literal)
    return "http://%s:%s" % (host, port)


def _space_for_root(root):
    # Do not instantiate ProjectRegistry: its constructor creates ~/.byori.
    import byori
    common = pathlib.Path(os.fsdecode(journal._git(root, ("rev-parse", "--git-common-dir"))).rstrip("\n"))
    common = (common if common.is_absolute() else root / common).resolve(strict=True)
    main = common.parent if common.name == ".git" else common
    roots = [str(root), str(main)]
    registry = byori.default_byori_home() / "projects.json"
    raw = _private_file(registry, missing=True)
    if raw is not None:
        try:
            document = json.loads(raw)
            _require(type(document) is dict and type(document.get("projects")) is list,
                     "project registry is invalid")
            for field in ("projects", "removed_projects"):
                entries = document.get(field, [])
                _require(type(entries) is list, "project registry is invalid")
                for candidate in roots:
                    matches = [item for item in entries if isinstance(item, dict) and item.get("root") == candidate]
                    if matches:
                        spaces = {item.get("space") for item in matches}
                        _require(len(spaces) == 1, "project registry has ambiguous memory spaces")
                        space = next(iter(spaces))
                        _require(isinstance(space, str) and SPACE.fullmatch(space), "project registry memory space is invalid")
                        return space
        except (ValueError, TypeError, UnicodeError):
            raise MemoryCaptureError("project registry is unreadable or invalid") from None
    return byori.memory_space_for_root(main)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise MemoryCaptureError("memory endpoint redirects are not allowed")


class RuntimeMemoryReader:
    """One private local session. Query responses/errors never log raw content."""
    def __init__(self, root):
        import byori
        self.space = _space_for_root(root)
        runtime = byori.default_byoridb_home()
        info = runtime.lstat()
        _require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                 and stat.S_IMODE(info.st_mode) == 0o700,
                 "installed runtime directory must be private and not a symlink")
        raw = _private_file(runtime / "env")
        try:
            values = dict(os.environ)
            for line in raw.decode("utf-8").splitlines():
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    if key.startswith("BYORIDB_"):
                        values[key] = value
        except UnicodeError:
            raise MemoryCaptureError("installed runtime configuration is not UTF-8") from None
        self.endpoint = _endpoint(values.get("BYORIDB_HTTP", "http://127.0.0.1:19669"))
        self._username = values.get("BYORIDB_USER", "root")
        self._password = values.get("BYORIDB_ROOT_PASSWORD") or values.get("BYORIDB_PASSWORD")
        _require(isinstance(self._password, str) and bool(self._password.strip()),
                 "installed memory credential is missing")
        self._session = None
        self._deadline = time.monotonic() + 30
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())

    def _request(self, method, path, payload=None, *, logout=False):
        remaining = self._deadline - time.monotonic()
        _require(logout or remaining > 0, "memory observation exceeded its time limit")
        headers = {"Content-Type": "application/json"}
        if logout:
            headers["X-ByoriDB-Session-Id"] = str(self._session)
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(self.endpoint + path, data=data, headers=headers, method=method)
        try:
            with self._opener.open(request, timeout=2 if logout else min(5, remaining)) as response:
                raw = response.read(MAX_BYTES + 1)
            _require(len(raw) <= MAX_BYTES, "memory response exceeds the byte limit")
            if logout:
                return None
            result = json.loads(raw)
            _require(isinstance(result, dict), "memory response schema is invalid")
            return result
        except urllib.error.HTTPError as exc:
            raise MemoryCaptureError("memory request failed (HTTP %s); no authentication retry was attempted" % exc.code) from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError, UnicodeError):
            raise MemoryCaptureError("local memory request failed; check engine availability and credentials") from None

    def __enter__(self):
        try:
            result = self._request("POST", "/api/v1/session", {"username": self._username, "password": self._password})
            session = result.get("session_id")
            _require(type(session) is int or (type(session) is str and re.fullmatch(r"-?[0-9]{1,20}", session)),
                     "memory session identity is invalid")
            _require(-(2**63) <= int(session) < 2**63, "memory session identity is invalid")
            self._session = session
            self.query("USE " + self.space)
            rows = _rows(self.query("MATCH (n:note) WHERE n.note.name == 'byori:schema-version' RETURN n.note.body AS body LIMIT 2"), 2)
            _require(len(rows) == 1 and rows[0].get("body") == "2",
                     "memory schema is not ready; capture never bootstraps or migrates it")
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def query(self, ngql):
        _require(self._session is not None, "memory session is unavailable")
        _require(ngql.startswith(("MATCH ", "USE ")), "capture supports only fixed read queries")
        return self._request("POST", "/api/v1/query", {"session_id": self._session, "query": ngql, "read_only": True})

    def __exit__(self, *_args):
        if self._session is not None:
            with contextlib.suppress(MemoryCaptureError):
                self._request("DELETE", "/api/v1/session", logout=True)
            self._session = None


def _rows(response, limit):
    _require(isinstance(response, dict) and isinstance(response.get("results"), list)
             and set(response) <= {"results", "row_count", "column_names", "latency_ms"}
             and type(response.get("row_count")) is int
             and response["row_count"] == len(response["results"]), "memory response is partial or malformed")
    _require(len(response["results"]) <= limit, "memory response exceeds the requested limit")
    _require(all(isinstance(item, dict) for item in response["results"]), "memory row schema is invalid")
    _encoded(response)
    return response["results"]


def _vid(value):
    _require(type(value) is int or (type(value) is str and re.fullmatch(r"-?[0-9]{1,20}", value)),
             "memory VID must be a decimal integer, not a floating point value")
    _require(-(2**63) <= int(value) < 2**63, "memory VID exceeds INT64")
    return str(value)


def _selection(selection):
    if selection is None:
        return None
    _require(isinstance(selection, list) and 1 <= len(selection) <= MAX_RECORDS, "selection must contain at most 200 exact records")
    keys = set()
    for item in selection:
        _require(isinstance(item, dict) and set(item) == {"type", "name"}
                 and journal.valid_record_identity(item["type"], item["name"]), "selection record identity is invalid")
        key = item["type"], item["name"]
        _require(key not in keys, "selection contains duplicate identities")
        keys.add(key)
    return [{"type": kind, "name": name} for kind, name in sorted(keys)]


def _node(kind, row):
    required = {"vid", "name", "body", "ts"}
    extra = "kind" if kind == "note" else "state" if kind in STATES else "resolved" if kind == "incident" else None
    if extra:
        required.add(extra)
    _require(required <= set(row) <= required | {"type"}, "memory node fields are missing or unsupported")
    _require(row.get("type", kind) == kind and journal.valid_record_identity(kind, row["name"]), "memory node identity is invalid")
    _require(isinstance(row["body"], str) and type(row["ts"]) is int and -(2**63) <= row["ts"] < 2**63,
             "memory original body or recorded timestamp is invalid")
    value = {**copy.deepcopy(row), "type": kind, "vid": _vid(row["vid"])}
    if kind in STATES:
        _require(isinstance(value["state"], str) and len(value["state"]) <= 64,
                 "memory node lifecycle is invalid")
    if kind == "note":
        _require(isinstance(value["kind"], str) and len(value["kind"]) <= 64, "memory note kind is invalid")
    if kind == "incident":
        _require(type(value["resolved"]) is bool or (isinstance(value["resolved"], str) and len(value["resolved"]) <= 64),
                 "memory incident state is invalid")
    return value


def _observe(client, selection):
    queries = selection if selection is not None else [{"type": kind} for kind in TYPES]
    nodes = []
    for selected in queries:
        kind = selected["type"]
        body = "summary" if kind == "module" else "body"
        columns = ["id(n) AS vid", "n.%s.name AS name" % kind, "n.%s.%s AS body" % (kind, body), "n.%s.ts AS ts" % kind]
        extra = "kind" if kind == "note" else "state" if kind in STATES else "resolved" if kind == "incident" else None
        if extra:
            columns.append("n.%s.%s AS %s" % (kind, extra, extra))
        where = ""
        exact = "name" in selected
        if exact:
            name = selected["name"].replace("\\", "\\\\").replace("'", "\\'")
            where = " WHERE n.%s.name == '%s'" % (kind, name)
        elif kind == "note":
            where = " WHERE n.note.name != 'byori:schema-version'"
        limit = 2 if exact else MAX_RECORDS + 1
        rows = _rows(client.query("MATCH (n:%s)%s RETURN %s ORDER BY vid ASC LIMIT %d" % (kind, where, ", ".join(columns), limit)), limit)
        if exact:
            _require(len(rows) == 1 and rows[0].get("name") == selected["name"], "selected memory record is missing or duplicated")
        _require(len(rows) <= MAX_RECORDS, "memory record limit exceeded; select exact records")
        nodes.extend(_node(kind, row) for row in rows)
        _require(len(nodes) <= MAX_RECORDS, "memory record limit exceeded; select exact records")
        _encoded(nodes)
    identities = [(node["type"], node["name"]) for node in nodes]
    _require(len(identities) == len(set(identities)), "memory canonical identities are duplicated or ambiguous")
    nodes.sort(key=lambda n: (n["type"], n["name"], n["vid"]))
    links = []
    if nodes:
        seeds = ", ".join(str(int(vid)) for vid in sorted({node["vid"] for node in nodes}))
        rows = _rows(client.query("MATCH (a)-[e]->(b) WHERE id(a) IN [%s] OR id(b) IN [%s] "
                                 "RETURN id(a) AS src, id(b) AS dst, type(e) AS edge_type, e.rel.kind AS relation LIMIT %d"
                                 % (seeds, seeds, MAX_LINKS + 1)), MAX_LINKS + 1)
        _require(len(rows) <= MAX_LINKS, "memory link limit exceeded; select fewer records")
        for row in rows:
            _require({"src", "dst", "edge_type", "relation"} <= set(row) <= {"src", "dst", "edge_type", "relation", "ts"}, "memory link fields are missing or unsupported")
            _require(isinstance(row["edge_type"], str) and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", row["edge_type"]), "memory link type is invalid")
            _require(row["relation"] is None or (isinstance(row["relation"], str) and len(row["relation"]) <= 64), "memory link relation is invalid")
            if "ts" in row:
                _require(type(row["ts"]) is int, "memory link timestamp is invalid")
            link = {**copy.deepcopy(row), "src": _vid(row["src"]), "dst": _vid(row["dst"])}
            _require(link["src"] in {n["vid"] for n in nodes} or link["dst"] in {n["vid"] for n in nodes}, "memory link does not touch the selected records")
            links.append(link)
        links = sorted({_digest(link): link for link in links}.values(), key=_digest)
    observation = {"nodes": nodes, "links": links}
    _encoded(observation)
    return observation


def _original_input(record):
    result = {key: copy.deepcopy(record[key]) for key in ("type", "name", "vid", "body", "provenance", "metadata")}
    result["scope"] = record["scope"]["kind"]
    result["state"] = record.get("original_state", record["state"])
    return result


def _merge(identity, current, observation, namespace):
    old = [_original_input(record) for record in current["records"]] if current else []
    merged = {(row["type"], row["name"], row["vid"]): row for row in old}
    old_names = {(row["type"], row["name"]): row["vid"] for row in old}
    incoming, withheld = [], 0
    safe = []
    for node in observation["nodes"]:
        incident = [link for link in observation["links"] if node["vid"] in (link["src"], link["dst"])]
        if handbook._sensitive({"node": node, "links": incident}):
            withheld += 1
        else:
            safe.append(node)
    by_vid = {}
    for node in safe:
        by_vid.setdefault(node["vid"], []).append(node)
    counts = {"new_records": 0, "changed_records": 0, "unchanged_records": 0}
    for node in safe:
        key = node["type"], node["name"], node["vid"]
        _require(old_names.get(key[:2], key[2]) == key[2], "memory identity conflicts with an existing original VID")
        links = [link for link in observation["links"] if node["vid"] in (link["src"], link["dst"])]
        metadata = {"graph_node": node, "graph_links": links}
        if "state" in node:
            metadata["original_state"] = node["state"]
        declarations = {}
        for link in links:
            if link["src"] != node["vid"] or len(by_vid.get(link["src"], [])) != 1 or len(by_vid.get(link["dst"], [])) != 1:
                continue
            target = by_vid[link["dst"]][0]
            relation = link["edge_type"]
            allowed = ((relation == "depends_on" and node["type"] == target["type"] == "module")
                       or (relation == "affects" and node["type"] in {"decision", "bug"} and target["type"] == "module")
                       or (relation == "supersedes" and node["type"] == target["type"] == "decision"))
            if allowed:
                declarations.setdefault(relation, []).append(target["name"])
        if declarations:
            metadata["handbook"] = {key: sorted(set(values)) for key, values in declarations.items()}
        record = {"type": node["type"], "name": node["name"], "vid": node["vid"], "body": node["body"],
                  "scope": "checkout", "state": "unverified", "metadata": metadata,
                  "provenance": {"adapter": ADAPTER, **namespace, "recorded_time": node["ts"],
                                 "scope_assertion": "legacy applicability unverified", "locator": "memory:%s/%s" % (node["type"], node["name"])}}
        previous = merged.get(key)
        if previous:
            _require(previous["provenance"].get("adapter") == ADAPTER
                     and all(previous["provenance"].get(k) == v for k, v in namespace.items())
                     and previous["state"] == "unverified" and previous["scope"] == "checkout",
                     "memory capture conflicts with a manual record or another namespace")
            counts["unchanged_records" if previous == record else "changed_records"] += 1
        else:
            counts["new_records"] += 1
        merged[key] = record
        incoming.append(record)
    records = [merged[key] for key in sorted(merged)]
    _require(len(records) <= MAX_RECORDS, "merged original record limit exceeded; review the journal before capture")
    source = {"kind": ADAPTER, **namespace, "observation_digest": _digest(observation),
              "consistency": "equal bounded observations; not a transactional backup"}
    envelope = {"complete": True, "source": source, "records": records}
    _, normalized = journal._normalize_envelope(envelope, identity)
    # Validate compiler meaning before making the journal a new source revision.
    handbook.compile_handbook(identity["project_root"], accepted_records=normalized, clean_projection=True)
    return envelope, incoming, {**counts, "record_count": len(records),
                               "retained_records": len(old) - counts["changed_records"] - counts["unchanged_records"],
                               "withheld_records": withheld}, normalized


def capture_memory(root, *, selection=None, apply=False, expected_digest=None, client_factory=None):
    """Observe/preview or merge only the freshly rechecked, explicitly reviewed originals."""
    _require(type(apply) is bool, "apply must be a boolean")
    _require((apply and isinstance(expected_digest, str) and re.fullmatch(r"[a-f0-9]{64}", expected_digest))
             or (not apply and expected_digest is None), "apply requires the reviewed expected digest; preview cannot accept one")
    selection = _selection(selection)
    try:
        identity = journal._identity(pathlib.Path(root))
        root = pathlib.Path(identity["project_root"])
        current = journal.load_records(root)
        base = current["revision"] if current else None
        factory = client_factory or RuntimeMemoryReader
        with factory(root) as reader:
            _require(isinstance(reader.space, str) and SPACE.fullmatch(reader.space), "memory space is invalid")
            namespace = {"endpoint": _endpoint(reader.endpoint), "space": reader.space}
            first = _observe(reader, selection)
            second = _observe(reader, selection)
            _require(first == second, "memory observation changed while reading; preview again")
        envelope, incoming, counts, normalized = _merge(identity, current, first, namespace)
        digest = _digest({"identity": identity, "namespace": namespace, "selection": selection,
                          "observation_digest": _digest(first), "base_revision": base})
        result = {"schema_version": 1, "state": "preview", "project_root": str(root),
                  "review_digest": digest, "base_revision": base, **counts, "records": incoming,
                  "source": envelope["source"], "scope": "checkout", "backup": False}
        after = journal.load_records(root)
        _require((after["revision"] if after else None) == base, "original journal revision changed during memory preview")
        if not apply:
            return result
        _require(digest == expected_digest, "reviewed memory digest is stale; preview again")
        if current is not None and current["records"] == normalized:
            return {**result, "state": "imported", "revision": base, "changed": False}
        # Empty/fully withheld observations must not create an authoritative empty journal.
        _require(bool(incoming), "no safe observed records to capture")
        saved = journal.import_records(root, envelope, expected_revision=base)
        return {**result, "state": "imported", "revision": saved["revision"], "changed": True}
    except MemoryCaptureError:
        raise
    except (journal.RecordError, handbook.HandbookError) as exc:
        # These modules deliberately emit fixed, source-free messages.
        raise MemoryCaptureError(str(exc)) from None
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        raise MemoryCaptureError("memory capture could not validate its inputs or local storage") from None
