import Foundation

/// One commit as the history view needs it.
///
/// `parents` is what makes the graph drawable: the lane layout is computed from
/// parent links rather than parsed out of `git log --graph`, whose ASCII art is
/// a rendering, not an interface.
public struct WorkspaceGitCommit: Identifiable, Equatable, Sendable {
    public let sha: String
    public let parents: [String]
    public let authorName: String
    public let authorDate: Date?
    /// Ref names pointing at this commit, already stripped of their prefixes.
    public let refs: [WorkspaceGitRef]
    public let subject: String

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    public init(
        sha: String,
        parents: [String],
        authorName: String,
        authorDate: Date?,
        refs: [WorkspaceGitRef],
        subject: String
    ) {
        self.sha = sha
        self.parents = parents
        self.authorName = authorName
        self.authorDate = authorDate
        self.refs = refs
        self.subject = subject
    }
}

public struct WorkspaceGitRef: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// HEAD attached to a branch, so that branch is the current checkout.
        case head
        /// HEAD sitting directly on a commit. Kept apart from `head` because a
        /// detached HEAD is the one state where checking a branch out here is
        /// the most useful thing on offer, not a no-op.
        case detachedHead
        case localBranch
        case remoteBranch
        case tag
    }

    public let name: String
    public let kind: Kind

    public var id: String { "\(kind)-\(name)" }

    /// Only a local branch is a safe checkout target from a list like this:
    /// checking out a remote-tracking ref or a tag detaches HEAD, which is not
    /// what someone clicking a branch name in a history view is asking for.
    public var isCheckoutable: Bool { kind == .localBranch }

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

// MARK: - Graph layout

/// A commit placed in a lane, plus the lines leaving it toward its parents.
public struct WorkspaceGitGraphRow: Equatable, Sendable {
    public let commit: WorkspaceGitCommit
    public let lane: Int
    /// Lanes occupied by edges passing this row without stopping at it. The view
    /// needs them to draw the vertical lines that run behind a commit.
    public let passingLanes: [Int]
    /// `(from, to)` lane pairs for the edges that leave this commit downward.
    public let outgoing: [WorkspaceGitGraphEdge]

    public init(
        commit: WorkspaceGitCommit,
        lane: Int,
        passingLanes: [Int],
        outgoing: [WorkspaceGitGraphEdge]
    ) {
        self.commit = commit
        self.lane = lane
        self.passingLanes = passingLanes
        self.outgoing = outgoing
    }
}

public struct WorkspaceGitGraphEdge: Equatable, Sendable {
    public let fromLane: Int
    public let toLane: Int

    public init(fromLane: Int, toLane: Int) {
        self.fromLane = fromLane
        self.toLane = toLane
    }
}

public struct WorkspaceGitGraph: Equatable, Sendable {
    public let rows: [WorkspaceGitGraphRow]
    public let laneCount: Int
    /// True when the log stopped at its limit, so the oldest edges dangle.
    public let isTruncated: Bool

    public init(rows: [WorkspaceGitGraphRow], laneCount: Int, isTruncated: Bool) {
        self.rows = rows
        self.laneCount = laneCount
        self.isTruncated = isTruncated
    }

    public static let empty = WorkspaceGitGraph(rows: [], laneCount: 0, isTruncated: false)

    /// Assigns commits to lanes in the order `git log` returned them.
    ///
    /// The rule is the usual one for commit graphs: a lane is reserved for each
    /// commit still waiting to be drawn. When a commit is reached, it takes the
    /// leftmost lane reserved for it, its first parent inherits that lane so a
    /// line of development stays in one column, and any further parents claim
    /// new lanes to the right.
    ///
    /// Reachability is not recomputed here; the caller's order is authoritative.
    /// Anything the log did not include (an unreachable parent, or one past the
    /// limit) simply ends its lane.
    public static func layout(commits: [WorkspaceGitCommit], isTruncated: Bool) -> WorkspaceGitGraph {
        // Lane slots hold the SHA each lane is currently waiting for. A nil slot
        // is free for reuse, which keeps the graph from drifting rightward every
        // time a branch ends.
        var lanes: [String?] = []
        var rows: [WorkspaceGitGraphRow] = []
        var widest = 0

        func firstFreeLane() -> Int {
            if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
            lanes.append(nil)
            return lanes.count - 1
        }

        for commit in commits {
            let lane: Int
            if let reserved = lanes.firstIndex(where: { $0 == commit.sha }) {
                lane = reserved
            } else {
                // A commit nothing points at: a branch tip, or the first commit
                // in a truncated log.
                lane = firstFreeLane()
            }

            // Every other lane still waiting for this same commit is a branch
            // merging back in, and stops here.
            for index in lanes.indices where lanes[index] == commit.sha && index != lane {
                lanes[index] = nil
            }
            lanes[lane] = nil

            var outgoing: [WorkspaceGitGraphEdge] = []
            for (offset, parent) in commit.parents.enumerated() {
                let parentLane: Int
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    // Two children of one parent converge. The parent is pulled
                    // to the leftmost of the converging lanes, because otherwise
                    // a mainline whose parent was first claimed by a side branch
                    // would visibly jog right and stay there.
                    if offset == 0, existing > lane {
                        lanes[existing] = nil
                        lanes[lane] = parent
                        parentLane = lane
                    } else {
                        parentLane = existing
                    }
                } else if offset == 0 {
                    // The first parent continues this commit's own lane, so the
                    // mainline reads as a straight column.
                    lanes[lane] = parent
                    parentLane = lane
                } else {
                    let free = firstFreeLane()
                    lanes[free] = parent
                    parentLane = free
                }
                outgoing.append(WorkspaceGitGraphEdge(fromLane: lane, toLane: parentLane))
            }

            let passing = lanes.indices.filter { lanes[$0] != nil && $0 != lane }
            rows.append(WorkspaceGitGraphRow(
                commit: commit,
                lane: lane,
                passingLanes: passing,
                outgoing: outgoing
            ))
            widest = max(widest, lanes.count)
        }

        return WorkspaceGitGraph(rows: rows, laneCount: max(widest, rows.isEmpty ? 0 : 1), isTruncated: isTruncated)
    }
}

// MARK: - Log parsing

/// Parses the fixed record format Byori asks `git log` for.
///
/// ASCII unit (0x1F) and record (0x1E) separators are used because they cannot
/// appear in a commit subject, author name, or ref name. `-z` is unavailable:
/// it delimits commits with NUL, which would collide with a NUL field
/// separator.
public enum WorkspaceGitLogFormat {
    static let unitSeparator: Character = "\u{1f}"
    static let recordSeparator: Character = "\u{1e}"

    public static let prettyFormat =
        "--pretty=format:%H\u{1f}%P\u{1f}%an\u{1f}%aI\u{1f}%D\u{1f}%s\u{1e}"

    public static func parse(_ output: String) -> [WorkspaceGitCommit] {
        let formatter = ISO8601DateFormatter()
        return output
            .split(separator: recordSeparator, omittingEmptySubsequences: true)
            .compactMap { record in
                // git separates records with 0x1E but still emits a newline
                // between them, which would otherwise land at the front of the
                // next SHA.
                let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let fields = trimmed.split(
                    separator: unitSeparator,
                    maxSplits: 5,
                    omittingEmptySubsequences: false
                ).map(String.init)
                guard fields.count == 6, isHexSHA(fields[0]) else { return nil }
                return WorkspaceGitCommit(
                    sha: fields[0],
                    parents: fields[1].split(separator: " ").map(String.init).filter(isHexSHA),
                    authorName: fields[2],
                    authorDate: formatter.date(from: fields[3]),
                    refs: parseRefs(fields[4]),
                    subject: fields[5]
                )
            }
    }

    /// Parses `%D` as produced with `--decorate=full`, which prints
    /// `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v0.3.0`.
    ///
    /// The full form is required, not a nicety. Short decorations render a local
    /// branch and a remote-tracking branch identically — `feat/x` versus
    /// `origin/feat/x` — and branch names here routinely contain slashes, so
    /// there is no way to tell them apart afterwards. Getting that wrong would
    /// offer a checkout that silently detaches HEAD.
    static func parseRefs(_ value: String) -> [WorkspaceGitRef] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { entry -> [WorkspaceGitRef] in
                if let arrow = entry.range(of: " -> ") {
                    // "HEAD -> refs/heads/main" is two refs at one commit.
                    let head = String(entry[entry.startIndex..<arrow.lowerBound])
                    let target = String(entry[arrow.upperBound...])
                    return [WorkspaceGitRef(name: head, kind: .head)] + classify(target)
                }
                return classify(entry)
            }
    }

    private static func classify(_ entry: String) -> [WorkspaceGitRef] {
        if entry == "HEAD" {
            return [WorkspaceGitRef(name: entry, kind: .detachedHead)]
        }
        let value = entry.hasPrefix("tag: ") ? String(entry.dropFirst(5)) : entry
        if let name = value.dropPrefix("refs/heads/") {
            return [WorkspaceGitRef(name: name, kind: .localBranch)]
        }
        if let name = value.dropPrefix("refs/remotes/") {
            // origin/HEAD is a symbolic pointer at whatever the remote's default
            // branch is. It decorates the same commit as that branch and would
            // just be a duplicate badge.
            guard !name.hasSuffix("/HEAD") else { return [] }
            return [WorkspaceGitRef(name: name, kind: .remoteBranch)]
        }
        if let name = value.dropPrefix("refs/tags/") {
            return [WorkspaceGitRef(name: name, kind: .tag)]
        }
        // An unrecognised namespace (refs/notes, refs/stash, a bare name from an
        // unexpected decoration setting) is shown but never offered as a
        // checkout target.
        return [WorkspaceGitRef(name: value, kind: .tag)]
    }

    static func isHexSHA(_ value: String) -> Bool {
        value.count >= 7 && value.count <= 64 && value.allSatisfy(\.isHexDigit)
    }
}

private extension String {
    /// Nil when the prefix is absent, so a chain of checks reads as a match.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
