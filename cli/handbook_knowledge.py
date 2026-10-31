"""Pure projection of explicit, unverified checkpoint declarations.

Callers supply an already scoped, sensitive-filtered snapshot. No body, lifecycle,
recency, or lexical similarity is inspected to infer truth or relationships.
Lists are sorted and deduplicated, but their strings (especially conditions) are
preserved verbatim. Paths are declarations, not filesystem paths to resolve.
Paths and conditions reject Unicode Cc/Cf (including newline/tab), surrogates,
and line/paragraph separators Zl/Zp; valid Unicode is never normalized or stripped.
Module paths are literal, nonempty POSIX-relative declarations: no empty/dot/
parent segments, backslashes, colons, glob/bracing characters (*?[]{}), or
surrounding whitespace. No existence, symlink, expansion, or containment lookup
is performed. The projection contract does not authorize arbitrary globs.

Field matrix: module_paths and depends_on belong only to modules; conditions to
decisions, bugs, incidents, and tasks; affects to decisions and bugs; conflicts_with
and supersedes to decisions. depends_on/affects target modules; the other two
relations target decisions. Module cycles are allowed; supersession cycles are not.
Self-conflicts are malformed declarations, not real conflict pairs, and refused.
"""

import re
import unicodedata


FIELDS = ("module_paths", "conditions", "depends_on", "affects", "conflicts_with", "supersedes")
NODE_TYPES = frozenset({"note", "module", "decision", "bug", "incident", "concept", "entity", "task"})
CANONICAL_NAME = re.compile(r"[a-z][a-z0-9_]*:[A-Za-z0-9][A-Za-z0-9._-]*")
FIELD_TYPES = {
    "module_paths": frozenset({"module"}),
    "conditions": frozenset({"decision", "bug", "incident", "task"}),
    "depends_on": frozenset({"module"}),
    "affects": frozenset({"decision", "bug"}),
    "conflicts_with": frozenset({"decision"}),
    "supersedes": frozenset({"decision"}),
}
TARGET_TYPES = {"depends_on": "module", "affects": "module",
                "conflicts_with": "decision", "supersedes": "decision"}


class KnowledgeError(ValueError):
    """An explicit declaration cannot be safely projected (no source values)."""


def _canonical(value):
    return (isinstance(value, str) and len(value) <= 256
            and CANONICAL_NAME.fullmatch(value) is not None)


def _record_name(node_type, value):
    if node_type != "note":
        return _canonical(value)
    # Keep this pure projection module independently loadable. Shared identity
    # vectors test agreement with the original journal's legacy-name boundary.
    return (isinstance(value, str) and 1 <= len(value) <= 256
            and value != "byori:schema-version"
            and not any(unicodedata.category(char) in {"Cc", "Cf", "Cs", "Zl", "Zp"} for char in value))


def _normalize(field, values):
    if not isinstance(values, list) or len(values) > 16:
        raise KnowledgeError("handbook fields must be lists of at most 16 entries")
    for value in values:
        if not isinstance(value, str) or not value.strip():
            raise KnowledgeError("handbook entries must be nonempty strings")
        if field in TARGET_TYPES:
            if not _canonical(value):
                raise KnowledgeError("handbook relation targets must be bounded canonical names")
        else:
            try:
                size = len(value.encode("utf-8"))
            except UnicodeError:
                raise KnowledgeError("handbook strings must be valid UTF-8") from None
            if size > 1024:
                raise KnowledgeError("handbook paths and conditions exceed the byte bound")
            if any(unicodedata.category(char) in {"Cc", "Cf", "Zl", "Zp"} for char in value):
                raise KnowledgeError("handbook paths and conditions contain forbidden Unicode characters")
            if field == "module_paths":
                if (value != value.strip() or any(char in value for char in "\\:*?[]{}")
                        or any(part in {"", ".", ".."} for part in value.split("/"))):
                    raise KnowledgeError("module declarations require safe literal relative paths")
    return sorted(set(values))


def _reject_supersession_cycles(relationships):
    # Only this relation is acyclic. Do not impose policy on module components.
    edges = {}
    for link in relationships:
        if link["relation"] == "supersedes":
            edges.setdefault(link["source"], []).append(link["target"])
    visiting, visited = set(), set()

    def visit(source_id):
        if source_id in visiting:
            raise KnowledgeError("explicit supersession declarations contain a cycle")
        if source_id in visited:
            return
        visiting.add(source_id)
        for target_id in edges.get(source_id, ()):
            visit(target_id)
        visiting.remove(source_id)
        visited.add(source_id)

    for source_id in sorted(edges):
        visit(source_id)


def annotate_sources(sources):
    """Return declarations, explicit source-ID links, warnings, and coverage.

    At most 200 checkpoint sources are accepted, including undeclared records.
    Typed records without handbook metadata still resolve targets and count toward
    declared_modules (module-typed originals, with or without module_paths).
    conditional_records counts nonempty conditions; conflict_pairs counts unique
    unordered declared pairs; supersession_links counts unique directed links.
    Checkpoints with no metadata have no declarations or resolvable identity.
    Unrelated record metadata and non-checkpoint declarations are not projected.
    This function neither mutates inputs nor shares mutable output with them.
    """
    if not isinstance(sources, (list, tuple)):
        raise KnowledgeError("knowledge sources must be a snapshot sequence")
    checkpoints, source_ids = [], set()
    for source in sources:
        if not isinstance(source, dict):
            raise KnowledgeError("knowledge sources must be source dictionaries")
        source_id = source.get("id")
        if not isinstance(source_id, str) or not source_id or source_id in source_ids:
            raise KnowledgeError("knowledge source IDs must be nonempty and unique")
        source_ids.add(source_id)
        if source.get("kind") == "checkpoint":
            checkpoints.append(source)
            if len(checkpoints) > 200:
                raise KnowledgeError("knowledge snapshot exceeds 200 checkpoint sources")

    declarations, identities, types = {}, {}, {}
    for source in checkpoints:
        if "metadata" not in source:
            continue
        metadata = source["metadata"]
        if not isinstance(metadata, dict):
            raise KnowledgeError("checkpoint metadata must be an object")
        name, node_type = metadata.get("name"), metadata.get("type")
        if not isinstance(node_type, str) or node_type not in NODE_TYPES or not _record_name(node_type, name):
            raise KnowledgeError("checkpoint metadata requires a canonical name and supported type")
        if node_type != "note" and not name.startswith(node_type + ":"):
            raise KnowledgeError("typed checkpoint prefix must match its type")
        source_id = source["id"]
        types[source_id] = node_type
        identities.setdefault(name, []).append(source_id)
        handbook = metadata.get("handbook", {})
        if not isinstance(handbook, dict) or not set(handbook).issubset(FIELDS):
            raise KnowledgeError("handbook declarations must be an object with only supported fields")
        declaration = {field: [] for field in FIELDS}
        for field, values in handbook.items():
            if node_type not in FIELD_TYPES[field]:
                raise KnowledgeError("handbook field is not permitted for this checkpoint type")
            declaration[field] = _normalize(field, values)
        declarations[source_id] = declaration

    relationships = []
    for source_id in sorted(declarations):
        for relation, target_type in TARGET_TYPES.items():
            for target_name in declarations[source_id][relation]:
                candidates = identities.get(target_name, ())
                if len(candidates) != 1:
                    raise KnowledgeError("explicit relation target is missing or ambiguous in this snapshot")
                target_id = candidates[0]
                if types[target_id] != target_type:
                    raise KnowledgeError("explicit relation target has an unsupported checkpoint type")
                if relation == "conflicts_with" and source_id == target_id:
                    raise KnowledgeError("explicit conflict declarations must link distinct sources")
                relationships.append({"source": source_id, "relation": relation, "target": target_id})
    relationships.sort(key=lambda link: (link["source"], link["relation"], link["target"]))
    _reject_supersession_cycles(relationships)
    conflict_pairs = {tuple(sorted((link["source"], link["target"])))
                      for link in relationships if link["relation"] == "conflicts_with"}
    coverage = {
        "declared_modules": sum(node_type == "module" for node_type in types.values()),
        "conditional_records": sum(bool(item["conditions"]) for item in declarations.values()),
        "conflict_pairs": len(conflict_pairs),
        "supersession_links": sum(link["relation"] == "supersedes" for link in relationships),
    }
    warnings = []
    if not coverage["declared_modules"]:
        warnings.append("Declared module coverage is unknown; absence is not proof of no modules.")
    if not coverage["conflict_pairs"]:
        warnings.append("Declared conflict coverage is unknown; absence is not proof of agreement.")
    return {"declarations": {key: declarations[key] for key in sorted(declarations)},
            "relationships": relationships, "warnings": warnings, "coverage": coverage}
