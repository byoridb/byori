#!/usr/bin/env python3
"""Copy selected memories out of the legacy shared space into a project space.

Sessions that ran before memory was scoped per project all wrote into one
`claude_memory` space, so it holds several unrelated projects side by side. That
data is not lost, only unreachable from a project space — and it cannot be moved
automatically, because deciding which rows belong to which project is a judgement
call. This script makes the judgement explicit: name what to copy, see it, then
apply it.

    # what would move (dry run)
    scripts/migrate-legacy-memory.py --name-prefix module:naraeclaw

    # move it, into the space resolved for the current project
    scripts/migrate-legacy-memory.py --name-prefix module:naraeclaw --apply

The source is never modified: rows are copied, not moved, so a wrong selection
costs nothing but a `memory_delete` in the destination. Copying the same rows
twice is idempotent — a memory's VID is derived from its name — but it does
append a bitemporal version, so the second run shows up in history.

The destination must already exist with the current schema: start an agent
session in the project once and its MCP server bootstraps it.
"""
import argparse
import importlib.util
import os
import pathlib
import sys
import time
import uuid

BYORIDB_HOME = pathlib.Path(os.environ.get("BYORIDB_HOME", "~/.byoridb")).expanduser()
LEGACY_SHARED_SPACE = "claude_memory"
# The MCP server bounds a single read at 500 rows; the legacy space is small
# enough that one page per type is the whole of it, and a cap keeps a runaway
# read from turning into an unbounded copy.
READ_LIMIT = 500


def fail(message):
    print("error: %s" % message, file=sys.stderr)
    raise SystemExit(1)


def load_env(path):
    """Load BYORIDB_* values from the installed runtime env file."""
    if not path.exists():
        return
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        fail("could not read %s: %s" % (path, exc))
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key.startswith("BYORIDB_") and key not in os.environ:
            os.environ[key] = value.strip()


def load_mcp():
    """Import the installed MCP server as a library.

    Its space resolution decides the default destination, and reusing its VID
    hashing and escaping is the only way for a copy to land on the same nodes the
    server would address.
    """
    candidates = [
        BYORIDB_HOME / "byoridb_mcp.py",
        pathlib.Path(__file__).resolve().parents[1] / "mcp" / "byoridb_mcp.py",
    ]
    source = next((path for path in candidates if path.is_file()), None)
    if source is None:
        fail("ByoriDB MCP runtime not found; looked in %s" % ", ".join(map(str, candidates)))
    spec = importlib.util.spec_from_file_location(
        "byoridb_mcp_for_migration_%s" % uuid.uuid4().hex, source
    )
    if spec is None or spec.loader is None:
        fail("could not load %s" % source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def selected(node, prefixes, names, take_all):
    if take_all:
        return True
    name = node.get("name", "")
    return name in names or any(name.startswith(prefix) for prefix in prefixes)


def insert_vertex_statement(mcp, node):
    """Recreate `node` in the pinned space, timestamps included.

    Deliberately not `tool_remember`/`tool_wiki_upsert`: those stamp the write
    time, and a migrated memory that claims to be new loses the recency ordering
    that makes recall useful.
    """
    esc = mcp._esc
    vid = int(node["vid"])
    name = esc(node["name"])
    body = esc(node.get("body", ""))
    try:
        ts = int(node.get("ts") or 0)
    except (TypeError, ValueError):
        ts = 0
    node_type = node["type"]
    if node_type == "note":
        kind = esc(node.get("kind") or "note")
        return (
            "INSERT VERTEX note(kind, name, body, ts) VALUES "
            "%d:('%s', '%s', '%s', %d)" % (vid, kind, name, body, ts)
        )
    if node_type == "module":
        return (
            "INSERT VERTEX module(name, summary, ts) VALUES "
            "%d:('%s', '%s', %d)" % (vid, name, body, ts)
        )
    if node_type in mcp.WIKI_STATES:
        state = node.get("state") or mcp.DEFAULT_WIKI_STATES[node_type]
        return (
            "INSERT VERTEX %s(name, body, state, ts) VALUES "
            "%d:('%s', '%s', '%s', %d)" % (node_type, vid, name, body, esc(state), ts)
        )
    if node_type == "incident":
        resolved = "true" if node.get("resolved") else "false"
        return (
            "INSERT VERTEX incident(name, body, resolved, ts) VALUES "
            "%d:('%s', '%s', '%s', %d)" % (vid, name, body, resolved, ts)
        )
    return (
        "INSERT VERTEX %s(name, body, ts) VALUES "
        "%d:('%s', '%s', %d)" % (node_type, vid, name, body, ts)
    )


def insert_edge_statement(edge, types_by_vid):
    """Recreate one edge, choosing the same edge tag the MCP server would.

    `relates_to` between two notes is the legacy `rel(kind)` edge; everything
    else is a typed edge carrying `ts`. Mirrors `tool_link`.
    """
    source_vid = int(edge["source_vid"])
    target_vid = int(edge["target_vid"])
    relation = edge["relation"]
    legacy = (
        relation == "relates_to"
        and types_by_vid.get(edge["source_vid"]) == "note"
        and types_by_vid.get(edge["target_vid"]) == "note"
    )
    if legacy:
        return (
            "INSERT EDGE rel(kind) VALUES "
            "%d->%d:('relates_to')" % (source_vid, target_vid)
        )
    # A typed edge carries the time it was written, and reading an edge back does
    # not report it, so the copy is stamped now — the same value `tool_link` would
    # write. Node timestamps, which recall orders by, are preserved exactly.
    return (
        "INSERT EDGE %s(ts) VALUES %d->%d:(%d)"
        % (relation, source_vid, target_vid, int(time.time() * 1000))
    )


def main():
    parser = argparse.ArgumentParser(
        description="Copy memories from the legacy shared space into a project space.",
    )
    parser.add_argument(
        "--from",
        dest="source",
        default=LEGACY_SHARED_SPACE,
        help="source space (default: %s)" % LEGACY_SHARED_SPACE,
    )
    parser.add_argument(
        "--to",
        dest="destination",
        default=None,
        help="destination space (default: the space resolved for this project)",
    )
    parser.add_argument(
        "--name-prefix",
        action="append",
        default=[],
        metavar="PREFIX",
        help="copy memories whose name starts with PREFIX (repeatable)",
    )
    parser.add_argument(
        "--name",
        action="append",
        default=[],
        metavar="NAME",
        help="copy exactly this memory name (repeatable)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="copy every memory in the source space",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform the copy; without it nothing is written",
    )
    args = parser.parse_args()

    if not args.name_prefix and not args.name and not args.all:
        fail("nothing selected; pass --name-prefix, --name, or --all")

    load_env(BYORIDB_HOME / "env")
    mcp = load_mcp()
    source = args.source
    destination = args.destination or mcp.SPACE
    for space in (source, destination):
        try:
            mcp._validate_space_name(space)
        except ValueError as exc:
            fail(str(exc))
    if source == destination:
        fail("source and destination are the same space (%s)" % source)

    mcp._login()
    # The module re-pins `SPACE` when it has to re-authenticate mid-query, so the
    # space being read has to be the module's idea of the current one — otherwise a
    # dropped session would silently continue the read against the destination.
    mcp.SPACE = source
    try:
        mcp._raw_query("USE %s" % source)
    except Exception as exc:  # noqa: BLE001 - report the space, not a traceback
        fail("could not read source space %s: %s" % (source, exc))

    nodes = []
    for node_type in mcp.NODE_TYPES:
        for node in mcp._query_nodes(node_type, limit=READ_LIMIT):
            if selected(node, args.name_prefix, set(args.name), args.all):
                nodes.append(node)
    if not nodes:
        print("no memories in %s matched the selection" % source)
        return 0
    types_by_vid = {node["vid"]: node["type"] for node in nodes}
    touching = mcp._read_edges([node["vid"] for node in nodes])
    edges = [
        edge
        for edge in touching
        if edge["source_vid"] in types_by_vid and edge["target_vid"] in types_by_vid
    ]

    print("%s -> %s" % (source, destination))
    for node in sorted(nodes, key=lambda item: (item["type"], item["name"])):
        print("  [%s] %s" % (node["type"], node["name"]))
    names_by_vid = {node["vid"]: node["name"] for node in nodes}
    for edge in edges:
        print(
            "  relation: %s --%s--> %s"
            % (
                names_by_vid.get(edge["source_vid"], edge["source_vid"]),
                edge["relation"],
                names_by_vid.get(edge["target_vid"], edge["target_vid"]),
            )
        )
    print("%d memories, %d relations" % (len(nodes), len(edges)))
    # Relations whose other end was not selected are dropped rather than
    # dragging in a memory the caller did not ask for. Say so; a silently
    # thinner graph reads as data loss.
    dropped = len(touching) - len(edges)
    if dropped:
        print("%d relations to unselected memories are not copied" % dropped)

    if not args.apply:
        print("dry run; nothing was written. Re-run with --apply.")
        return 0

    mcp.SPACE = destination
    try:
        mcp._raw_query("USE %s" % destination)
    except Exception as exc:  # noqa: BLE001
        fail(
            "could not open destination space %s (%s); start an agent session in "
            "the project once so its MCP server creates it" % (destination, exc)
        )
    version = mcp._schema_version()
    if version != mcp.SCHEMA_VERSION:
        fail(
            "destination schema is v%s, expected v%s; start an agent session in the "
            "project once to migrate it" % (version, mcp.SCHEMA_VERSION)
        )

    for node in nodes:
        mcp._raw_query(insert_vertex_statement(mcp, node))
    for edge in edges:
        mcp._raw_query(insert_edge_statement(edge, types_by_vid))
    print(
        "copied %d memories and %d relations into %s (%s is unchanged)"
        % (len(nodes), len(edges), destination, source)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
