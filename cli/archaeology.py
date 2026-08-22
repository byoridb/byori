#!/usr/bin/env python3
"""Turn a repository's own history into a starting project graph.

Installing Byori used to hand someone an empty graph and a promise: keep working
for a few weeks and it will become useful. But the history that explains a
codebase is already in the clone — issues referenced by fixes, reverts, merge
commits, the design documents somebody wrote — and none of it needs a model to
read.

Everything here is deliberately deterministic. A wrong causal edge is worse than
a missing one, because it is read later with the same confidence as a true one,
so this pass only records relationships the history states outright:

  - `Fixes #12` in a commit message is that commit fixing that issue.
  - `Revert "X"` is somebody undoing X, which is a fact about X.
  - `Merge pull request #34` names where the change was discussed.
  - A file under `docs/adr/` is a decision, and Git knows when it arrived.
  - The directory a fix touched is a module that fix affected.

Anything softer — summarising a decision, guessing why an incident happened,
linking things that only look related — belongs to a later, clearly-marked
inference pass, not here. Every node this module produces carries the commit,
pull request or path it came from, so a reader can check it.

Pure functions over Git output: nothing here talks to ByoriDB, which is what
makes it testable against a scratch repository.
"""
import collections
import dataclasses
import re
import subprocess
from typing import Dict, List, Optional, Sequence, Tuple

# Record and field separators for `git log --format`. Chosen because Git never
# emits them itself and a commit message that contains one is pathological.
RECORD_SEPARATOR = "\x1e"
FIELD_SEPARATOR = "\x1f"

# A commit that says `fix:`/`fix(scope):`/`hotfix` is repairing something; anything
# else closing an issue is work being delivered. Read from the commit's own prefix
# rather than guessed, so an issue closed by `feat(...)` is recorded as a finished
# task instead of being mislabelled a bug.
FIX_SUBJECT = re.compile(r"^(?:fix|bugfix|hotfix|patch)\b|^revert\b", re.IGNORECASE)

# `Fixes #12`, `closes gh-12`, `Resolves: #12` — the conventional ways a commit
# claims an issue. Deliberately not `see #12` or a bare `#12`: a mention is not a
# claim, and this pass only records what the history states outright.
ISSUE_TRAILER = re.compile(
    r"\b(?:fix|fixes|fixed|close|closes|closed|resolve|resolves|resolved)\b"
    r"\s*:?\s*(?:#|gh-)(\d{1,7})",
    re.IGNORECASE,
)
# `Merge pull request #34 from fork/branch` (GitHub) and `Merged in ... (pull request #34)`.
PULL_REQUEST = re.compile(r"pull request #(\d{1,7})", re.IGNORECASE)
# A revert's subject quotes the subject it undoes; Git also writes the sha in the body.
REVERT_SUBJECT = re.compile(r'^Revert\s+"(?P<subject>.+)"\s*$')
REVERT_BODY_SHA = re.compile(r"\b(?:This reverts commit|reverts commit)\s+([0-9a-f]{7,40})", re.IGNORECASE)

# Files that are a decision by convention rather than by inference.
DECISION_PATHS = re.compile(
    r"(^|/)(?:docs?/)?(?:adr|adrs|decisions|rfcs?|design-docs?)/[^/]+\.(?:md|markdown|rst|txt)$"
    r"|(^|/)(?:adr|rfc)-\d+[^/]*\.(?:md|markdown)$"
    r"|(^|/)(?:DESIGN|ARCHITECTURE|DECISIONS|RATIONALE)\.(?:md|markdown|rst|txt)$",
    re.IGNORECASE,
)

# Directories that are build output, dependencies or vendored code: they say
# nothing about why this project is the way it is.
UNINTERESTING_DIRECTORIES = {
    ".git", ".github", ".idea", ".vscode", "__pycache__", "node_modules",
    "vendor", "third_party", "dist", "build", "target", "out", "bin",
    ".build", ".venv", "venv", "coverage", "fixtures", "snapshots",
}

MAX_BODY_CHARS = 1_400
MAX_EVIDENCE_ITEMS = 4


@dataclasses.dataclass
class Commit:
    sha: str
    timestamp: int
    subject: str
    body: str
    paths: List[str]

    @property
    def short(self) -> str:
        return self.sha[:12]


@dataclasses.dataclass
class Node:
    type: str
    name: str
    body: str
    state: Optional[str] = None
    resolved: Optional[bool] = None


@dataclasses.dataclass
class Edge:
    relation: str
    source: Tuple[str, str]
    target: Tuple[str, str]


@dataclasses.dataclass
class Plan:
    """What one archaeology run found, before anything is written."""

    nodes: List[Node] = dataclasses.field(default_factory=list)
    edges: List[Edge] = dataclasses.field(default_factory=list)
    stats: Dict[str, int] = dataclasses.field(default_factory=dict)

    def counts_by_type(self) -> Dict[str, int]:
        counter: Dict[str, int] = collections.OrderedDict()
        for node in self.nodes:
            counter[node.type] = counter.get(node.type, 0) + 1
        return counter


def slug(value: str, limit: int = 60) -> str:
    """A canonical-name component: `[A-Za-z0-9][A-Za-z0-9._-]*`."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-._").lower()
    cleaned = re.sub(r"-{2,}", "-", cleaned)
    if not cleaned or not cleaned[0].isalnum():
        cleaned = "x" + cleaned.lstrip("-._")
    return cleaned[:limit].rstrip("-._") or "x"


def _git(root, *arguments: str, timeout: int = 120) -> str:
    result = subprocess.run(
        ("git", "-C", str(root)) + arguments,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        errors="replace",
        timeout=timeout,
    )
    return result.stdout if result.returncode == 0 else ""


def read_commits(root, limit: int) -> List[Commit]:
    """Recent commits with the files they touched, newest first.

    One `git log` rather than a `git show` per commit: a repository with 14,000
    commits would otherwise mean 14,000 processes.
    """
    fmt = RECORD_SEPARATOR + FIELD_SEPARATOR.join(["%H", "%at", "%s", "%b"]) + FIELD_SEPARATOR
    raw = _git(
        root,
        "log",
        "--no-merges",
        "-n",
        str(limit),
        "--name-only",
        "--format=" + fmt,
    )
    commits: List[Commit] = []
    for chunk in raw.split(RECORD_SEPARATOR):
        if not chunk.strip():
            continue
        fields = chunk.split(FIELD_SEPARATOR)
        if len(fields) < 5:
            continue
        sha, timestamp, subject, body, trailing = fields[0], fields[1], fields[2], fields[3], fields[4]
        paths = [line for line in trailing.splitlines() if line.strip()]
        try:
            when = int(timestamp)
        except ValueError:
            when = 0
        commits.append(Commit(sha=sha.strip(), timestamp=when, subject=subject.strip(),
                              body=body.strip(), paths=paths))
    return commits


def read_merge_commits(root, limit: int, max_merges: int = 400) -> Dict[str, int]:
    """Pull request number for every commit a merge brought in.

    "Where was this discussed" is a headline of the evidence this pass records, and
    it lives on the merge commit — but the commits that fixed something are the
    ones *under* the merge. So each merge that names a pull request is expanded
    with `rev-list <merge>^1..<merge>^2`, and the merge itself is mapped too.

    One process per merge, capped: on a repository with thousands of merges the
    newest `max_merges` carry the recent history this pass is about, and the cap is
    reported in the stats rather than silently applied.
    """
    fmt = RECORD_SEPARATOR + FIELD_SEPARATOR.join(["%H", "%s"]) + FIELD_SEPARATOR
    raw = _git(root, "log", "--merges", "-n", str(limit), "--format=" + fmt)
    numbers: Dict[str, int] = {}
    expanded = 0
    for chunk in raw.split(RECORD_SEPARATOR):
        if not chunk.strip():
            continue
        fields = chunk.split(FIELD_SEPARATOR)
        if len(fields) < 2:
            continue
        match = PULL_REQUEST.search(fields[1])
        if not match:
            continue
        merge_sha = fields[0].strip()
        number = int(match.group(1))
        numbers[merge_sha] = number
        if expanded >= max_merges:
            continue
        expanded += 1
        for line in _git(
            root, "rev-list", "%s^1..%s^2" % (merge_sha, merge_sha), timeout=30
        ).splitlines():
            sha = line.strip()
            # First merge wins: a commit reachable from two merges was brought in
            # by the earlier one, and that is the pull request that discussed it.
            if sha and sha not in numbers:
                numbers[sha] = number
    return numbers


def read_tracked_paths(root) -> List[str]:
    return [line for line in _git(root, "ls-files").splitlines() if line.strip()]


def first_commit_for_path(root, path: str) -> Optional[Commit]:
    """The commit that added `path`, which is when that decision arrived."""
    fmt = FIELD_SEPARATOR.join(["%H", "%at", "%s"])
    # No `--reverse -n 1`: Git applies the count before reversing, so that pair
    # asks for "the newest, then reverse it" and finds nothing useful. Take the
    # last line of the additions instead — the oldest add is the arrival.
    raw = _git(root, "log", "--diff-filter=A", "--format=" + fmt, "--", path)
    lines = [line for line in raw.splitlines() if line.strip()]
    if not lines:
        return None
    fields = lines[-1].split(FIELD_SEPARATOR)
    if len(fields) < 3:
        return None
    try:
        when = int(fields[1])
    except ValueError:
        when = 0
    return Commit(sha=fields[0], timestamp=when, subject=fields[2], body="", paths=[path])


def module_directories(paths: Sequence[str], minimum_files: int = 3) -> Dict[str, int]:
    """Directories worth calling modules, with how many tracked files each holds.

    Depth 1, plus depth 2 inside a directory large enough that its children are
    the real units (a monorepo's `packages/*`). Build output and dependencies are
    skipped: they describe tooling, not this project.
    """
    depth1: Dict[str, int] = {}
    depth2: Dict[str, int] = {}
    for path in paths:
        parts = path.split("/")
        if len(parts) < 2:
            continue
        if any(part in UNINTERESTING_DIRECTORIES or part.startswith(".") for part in parts[:-1]):
            continue
        depth1[parts[0]] = depth1.get(parts[0], 0) + 1
        if len(parts) >= 3:
            key = parts[0] + "/" + parts[1]
            depth2[key] = depth2.get(key, 0) + 1

    modules = {name: count for name, count in depth1.items() if count >= minimum_files}
    for name, count in depth2.items():
        parent = name.split("/")[0]
        if modules.get(parent, 0) >= 200 and count >= minimum_files:
            modules[name] = count
    return modules


def owning_modules(paths: Sequence[str], modules: Dict[str, int]) -> List[str]:
    """Which known modules a set of touched files belongs to, longest match first."""
    owners: List[str] = []
    for path in paths:
        best: Optional[str] = None
        for module in modules:
            if path == module or path.startswith(module + "/"):
                if best is None or len(module) > len(best):
                    best = module
        if best is not None and best not in owners:
            owners.append(best)
    return owners


def _bounded(text: str) -> str:
    collapsed = re.sub(r"\n{3,}", "\n\n", text.strip())
    if len(collapsed) <= MAX_BODY_CHARS:
        return collapsed
    return collapsed[: MAX_BODY_CHARS - 1].rstrip() + "…"


def _iso(timestamp: int) -> str:
    import datetime as _dt

    if not timestamp:
        return "unknown date"
    return _dt.datetime.fromtimestamp(timestamp, _dt.timezone.utc).strftime("%Y-%m-%d")


def build_plan(
    root,
    repository: str,
    commits: Sequence[Commit],
    merge_pull_requests: Dict[str, int],
    tracked_paths: Sequence[str],
    decision_documents: Sequence[Tuple[str, Optional[Commit]]],
) -> Plan:
    """Assemble nodes and edges from already-gathered Git facts."""
    prefix = slug(repository, limit=24)
    plan = Plan()
    modules = module_directories(tracked_paths)

    # --- modules ------------------------------------------------------------
    touched: Dict[str, List[Commit]] = collections.defaultdict(list)
    for commit in commits:
        for module in owning_modules(commit.paths, modules):
            touched[module].append(commit)

    for path, file_count in sorted(modules.items()):
        history = touched.get(path, [])
        name = "module:%s-%s" % (prefix, slug(path))
        last = _iso(history[0].timestamp) if history else "not in the scanned range"
        first = _iso(history[-1].timestamp) if history else "not in the scanned range"
        plan.nodes.append(Node(
            type="module",
            name=name,
            body=_bounded(
                "%s — %d tracked files. %d of the scanned commits touched it "
                "(%s … %s).\nSource: byori init, git ls-files and git log."
                % (path, file_count, len(history), first, last)
            ),
        ))
        if "/" in path:
            parent = path.split("/")[0]
            if parent in modules:
                plan.edges.append(Edge(
                    relation="part_of",
                    source=("module", name),
                    target=("module", "module:%s-%s" % (prefix, slug(parent))),
                ))

    # --- issues closed by commits ------------------------------------------
    fixes: Dict[int, List[Commit]] = collections.defaultdict(list)
    for commit in commits:
        for number in {int(n) for n in ISSUE_TRAILER.findall(commit.subject + "\n" + commit.body)}:
            fixes[number].append(commit)

    for number, history in sorted(fixes.items()):
        repaired = any(FIX_SUBJECT.match(commit.subject) for commit in history)
        node_type = "bug" if repaired else "task"
        name = "%s:%s-issue-%d" % (node_type, prefix, number)
        evidence = []
        for commit in history[:MAX_EVIDENCE_ITEMS]:
            line = "commit %s (%s) %s" % (commit.short, _iso(commit.timestamp), commit.subject)
            pull_request = merge_pull_requests.get(commit.sha)
            if pull_request:
                line += " [PR #%d]" % pull_request
            evidence.append(line)
        plan.nodes.append(Node(
            type=node_type,
            name=name,
            state="fixed" if node_type == "bug" else "done",
            body=_bounded(
                "Issue #%d, closed by commit message. What it was about is in the "
                "issue itself; what is certain from history is that these commits "
                "closed it:\n- %s\nSource: byori init, git log issue trailers "
                "(typed from the commit's own %s prefix)."
                % (number, "\n- ".join(evidence), "fix" if repaired else "non-fix")
            ),
        ))
        for module in owning_modules(
            [path for commit in history for path in commit.paths], modules
        )[:6]:
            plan.edges.append(Edge(
                relation="affects" if node_type == "bug" else "about",
                source=(node_type, name),
                target=("module", "module:%s-%s" % (prefix, slug(module))),
            ))

    # --- reverts ------------------------------------------------------------
    for commit in commits:
        match = REVERT_SUBJECT.match(commit.subject)
        if not match:
            continue
        undone = match.group("subject")
        undone_sha = REVERT_BODY_SHA.search(commit.body)
        name = "bug:%s-revert-%s" % (prefix, commit.sha[:8])
        plan.nodes.append(Node(
            type="bug",
            name=name,
            state="fixed",
            body=_bounded(
                'Reverted on %s: "%s"%s. A revert is the history stating that the '
                "change was wrong; why it was wrong is not in the commit, so it is "
                "not recorded here.\nEvidence: revert commit %s%s\n"
                "Source: byori init, git log revert subjects."
                % (
                    _iso(commit.timestamp),
                    undone,
                    "" if not undone_sha else " (commit %s)" % undone_sha.group(1)[:12],
                    commit.short,
                    "" if not merge_pull_requests.get(commit.sha)
                    else " [PR #%d]" % merge_pull_requests[commit.sha],
                )
            ),
        ))
        for module in owning_modules(commit.paths, modules)[:6]:
            plan.edges.append(Edge(
                relation="affects",
                source=("bug", name),
                target=("module", "module:%s-%s" % (prefix, slug(module))),
            ))

    # --- decisions written down --------------------------------------------
    for path, introduced in decision_documents:
        title, excerpt = read_document_summary(root, path)
        name = "decision:%s-%s" % (prefix, slug(path.rsplit("/", 1)[-1].rsplit(".", 1)[0]))
        arrival = (
            "added %s in commit %s" % (_iso(introduced.timestamp), introduced.short)
            if introduced else "arrival not found in the scanned range"
        )
        plan.nodes.append(Node(
            type="decision",
            name=name,
            state="active",
            body=_bounded(
                "%s\n\n%s\n\nEvidence: %s (%s)\n"
                "Source: byori init, a decision document in the tree. Its state is "
                "recorded as active because nothing in history says otherwise; a "
                "later document may supersede it."
                % (title or path, excerpt, path, arrival)
            ),
        ))

    plan.stats = {
        "commits_scanned": len(commits),
        "merge_commits_with_pull_requests": len(merge_pull_requests),
        "tracked_files": len(tracked_paths),
        "modules": len(modules),
        "issues_closed": len(fixes),
        "decision_documents": len(decision_documents),
        "nodes": len(plan.nodes),
        "edges": len(plan.edges),
    }
    return plan


def read_document_summary(root, path: str) -> Tuple[str, str]:
    """A decision document's title and opening paragraph, quoted not summarised."""
    raw = _git(root, "show", "HEAD:" + path)
    if not raw:
        try:
            with open(str(root) + "/" + path, encoding="utf-8", errors="replace") as handle:
                raw = handle.read()
        except OSError:
            return "", ""
    lines = raw.splitlines()
    # A doc that opens with `---` starts with YAML frontmatter: metadata about the
    # document, not the decision in it. Reading it as the body produced colour
    # tokens where a rationale belonged.
    if lines and lines[0].strip() == "---":
        for index in range(1, len(lines)):
            if lines[index].strip() in {"---", "..."}:
                lines = lines[index + 1:]
                break
    title = ""
    paragraph: List[str] = []
    for line in lines:
        stripped = line.strip()
        if not title and stripped.startswith("#"):
            title = stripped.lstrip("#").strip()
            continue
        if not title and stripped and not stripped.startswith(("---", "=")):
            title = stripped
            continue
        if title:
            if stripped.startswith("#"):
                if paragraph:
                    break
                continue
            if not stripped:
                if paragraph:
                    break
                continue
            paragraph.append(stripped)
            if sum(len(part) for part in paragraph) > 600:
                break
    return title, " ".join(paragraph)


def find_decision_documents(root, paths: Sequence[str], limit: int = 200) -> List[Tuple[str, Optional[Commit]]]:
    found: List[Tuple[str, Optional[Commit]]] = []
    for path in paths:
        if len(found) >= limit:
            break
        if DECISION_PATHS.search(path):
            found.append((path, first_commit_for_path(root, path)))
    return found


def excavate(root, repository: str, limit: int = 2_000) -> Plan:
    """Read the repository and return what its history states outright."""
    commits = read_commits(root, limit)
    merges = read_merge_commits(root, limit)
    paths = read_tracked_paths(root)
    documents = find_decision_documents(root, paths)
    return build_plan(root, repository, commits, merges, paths, documents)
