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
    r"(^|/)(?:docs?/)?(?:adr|adrs|[a-z-]*decisions?|rfcs?|design-docs?)/[^/]+\.(?:md|markdown|rst|txt)$"
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
# How far a merged branch is followed before the walk gives up and says so.
MAX_BRANCH_WALK = 2_000
# Section names an ADR template hands out. A document whose first heading is one of
# these has not told you its subject yet.
ADR_SECTION_HEADINGS = frozenset({
    "context", "background", "decision", "status", "consequences", "consequence",
    "alternatives", "alternatives considered", "problem", "problem statement",
    "summary", "abstract", "motivation", "rationale", "options",
})


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


class ArchaeologyError(RuntimeError):
    """A Git command this pass depends on did not run."""


def _git(root, *arguments: str, timeout: int = 600, required: bool = True) -> str:
    """Run one Git command.

    `required` commands raise when Git fails. They used to return an empty string,
    which turned a partial clone whose fetch failed into "analyzed 0 commits"
    printed as though nothing had gone wrong — a false fact, reported confidently,
    which is the failure mode this whole project exists to avoid. Optional lookups
    (a document's arrival, say) may legitimately find nothing and stay quiet.
    """
    try:
        result = subprocess.run(
            ("git", "-C", str(root)) + arguments,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        if required:
            raise ArchaeologyError(
                "git %s timed out after %ds in %s"
                % (" ".join(arguments[:2]), timeout, root)
            )
        return ""
    except OSError as exc:
        if required:
            raise ArchaeologyError("git could not run: %s" % exc)
        return ""
    if result.returncode != 0:
        if required:
            detail = (result.stderr or "").strip().splitlines()
            raise ArchaeologyError(
                "git %s failed in %s: %s"
                % (" ".join(arguments[:2]), root, detail[-1] if detail else "exit %d" % result.returncode)
            )
        return ""
    return result.stdout


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


def read_merge_commits(root, limit: int) -> Tuple[Dict[str, int], Dict[str, int]]:
    """Pull request number for every commit a merge brought in, in one pass.

    "Where was this discussed" is a headline of the evidence this records, and it
    lives on the merge commit — but the commit that fixed something is the one
    *under* the merge. The first version expanded each merge with its own
    `rev-list`, which meant a cap, and the cap quietly left 329 of 350 nodes in a
    real repository with no pull request attached.

    So the graph is read once (`%H %P`) and walked here: the mainline is HEAD's
    first-parent chain, and each merge's second parent is followed away from it
    until the walk leaves the branch. Deterministic, no extra processes, and the
    walk is bounded per merge — a branch that is longer than that is reported in the
    stats rather than silently truncated.
    """
    raw = _git(root, "log", "-n", str(limit * 3), "--format=%H %P")
    parents: Dict[str, List[str]] = {}
    order: List[str] = []
    for line in raw.splitlines():
        pieces = line.split()
        if not pieces:
            continue
        parents[pieces[0]] = pieces[1:]
        order.append(pieces[0])
    if not order:
        return {}, {"merges_with_pull_requests": 0, "branches_truncated": 0}

    mainline = set()
    cursor: Optional[str] = order[0]
    while cursor and cursor not in mainline:
        mainline.add(cursor)
        chain = parents.get(cursor) or []
        cursor = chain[0] if chain else None

    subjects = _merge_subjects(root, limit)
    numbers: Dict[str, int] = {}
    truncated = 0
    merges = 0
    for sha, subject in subjects.items():
        match = PULL_REQUEST.search(subject)
        if not match:
            continue
        merges += 1
        number = int(match.group(1))
        numbers.setdefault(sha, number)
        chain = parents.get(sha) or []
        if len(chain) < 2:
            continue
        # Walk the merged branch away from the mainline. `visited` keeps a branch
        # that merged another branch from being walked twice.
        frontier = [chain[1]]
        visited = set()
        while frontier:
            if len(visited) >= MAX_BRANCH_WALK:
                truncated += 1
                break
            current = frontier.pop()
            if current in visited or current in mainline:
                continue
            visited.add(current)
            numbers.setdefault(current, number)
            frontier.extend(parents.get(current) or [])
    return numbers, {
        "merges_with_pull_requests": merges,
        "branches_truncated": truncated,
    }


def _merge_subjects(root, limit: int) -> Dict[str, str]:
    fmt = RECORD_SEPARATOR + FIELD_SEPARATOR.join(["%H", "%s"]) + FIELD_SEPARATOR
    raw = _git(root, "log", "--merges", "-n", str(limit), "--format=" + fmt)
    subjects: Dict[str, str] = {}
    for chunk in raw.split(RECORD_SEPARATOR):
        if not chunk.strip():
            continue
        fields = chunk.split(FIELD_SEPARATOR)
        if len(fields) >= 2:
            subjects[fields[0].strip()] = fields[1]
    return subjects


def read_tracked_paths(root) -> List[str]:
    return [line for line in _git(root, "ls-files").splitlines() if line.strip()]


def first_commit_for_path(root, path: str) -> Optional[Commit]:
    """The commit that added `path`, which is when that decision arrived."""
    fmt = FIELD_SEPARATOR.join(["%H", "%at", "%s"])
    # No `--reverse -n 1`: Git applies the count before reversing, so that pair
    # asks for "the newest, then reverse it" and finds nothing useful. Take the
    # last line of the additions instead — the oldest add is the arrival.
    raw = _git(root, "log", "--diff-filter=A", "--format=" + fmt, "--", path, required=False)
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
    max_modules: int = 60,
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

    # A monorepo has hundreds of directories; recording all of them buries the
    # handful that the history actually moves through. Keep the busiest, and say how
    # many were left out — a silent cut would read as "this project has 60 modules".
    ranked_modules = sorted(
        modules.items(),
        key=lambda item: (-len(touched.get(item[0], [])), -item[1], item[0]),
    )
    kept = dict(ranked_modules[:max_modules])
    plan.stats["modules_below_the_cut"] = max(len(modules) - len(kept), 0)

    for path, file_count in sorted(kept.items()):
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

    modules = kept

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
        filename = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
        # Many ADRs open with `## Context` and keep their title in the filename, so
        # a boilerplate section name is not the decision's name.
        if not title or title.strip().lower().rstrip(":") in ADR_SECTION_HEADINGS:
            title = filename.replace("-", " ").replace("_", " ").strip()
        name = "decision:%s-%s" % (prefix, slug(filename))
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

    below_the_cut = plan.stats.get("modules_below_the_cut", 0)
    plan.stats = {
        "commits_scanned": len(commits),
        "modules_below_the_cut": below_the_cut,
        "commits_with_a_pull_request": len(merge_pull_requests),
        "tracked_files": len(tracked_paths),
        "modules": len(kept),
        "issues_closed": len(fixes),
        "decision_documents": len(decision_documents),
        "nodes": len(plan.nodes),
        "edges": len(plan.edges),
    }
    return plan


def read_document_summary(root, path: str) -> Tuple[str, str]:
    """A decision document's title and opening paragraph, quoted not summarised."""
    raw = _git(root, "show", "HEAD:" + path, required=False)
    if not raw:
        try:
            with open(str(root) + "/" + path, encoding="utf-8", errors="replace") as handle:
                raw = handle.read()
        except OSError:
            return "", ""
    # An ADR template's instructions live in HTML comments, and a document written
    # on that template keeps them. They are guidance for the author, not the
    # decision, so they are removed before anything is quoted.
    raw = re.sub(r"<!--.*?-->", "", raw, flags=re.DOTALL)
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


# `adr000-template.md`, `0000-template.md`, `template.md`: the form an ADR is
# written on, not a decision anybody made.
TEMPLATE_DOCUMENT = re.compile(r"(^|/|-|_)(?:template|example|skeleton)s?\.[a-z]+$|0+-?template", re.IGNORECASE)


def find_decision_documents(root, paths: Sequence[str], limit: int = 200) -> List[Tuple[str, Optional[Commit]]]:
    found: List[Tuple[str, Optional[Commit]]] = []
    for path in paths:
        if len(found) >= limit:
            break
        if TEMPLATE_DOCUMENT.search(path):
            continue
        if DECISION_PATHS.search(path):
            found.append((path, first_commit_for_path(root, path)))
    return found


def excavate(root, repository: str, limit: int = 2_000, max_modules: int = 60) -> Plan:
    """Read the repository and return what its history states outright."""
    commits = read_commits(root, limit)
    if not commits:
        raise ArchaeologyError(
            "no commits were read from %s — an empty or unborn repository, or a "
            "history this pass could not walk" % root
        )
    merges, merge_stats = read_merge_commits(root, limit)
    paths = read_tracked_paths(root)
    documents = find_decision_documents(root, paths)
    plan = build_plan(
        root, repository, commits, merges, paths, documents, max_modules=max_modules
    )
    plan.stats.update(merge_stats)
    return plan
