import Foundation

public enum WorkspaceFileKind: String, Codable, Sendable {
    case directory
    case file
    case symbolicLink = "symbolic_link"
    case other
}

public struct WorkspaceFileNode: Identifiable, Equatable, Sendable {
    public var id: String { relativePath }

    public let name: String
    public let relativePath: String
    public let depth: Int
    public let kind: WorkspaceFileKind
    public let byteSize: Int?

    public init(
        name: String,
        relativePath: String,
        depth: Int,
        kind: WorkspaceFileKind,
        byteSize: Int? = nil
    ) {
        self.name = name
        self.relativePath = relativePath
        self.depth = depth
        self.kind = kind
        self.byteSize = byteSize
    }
}

public struct WorkspaceFileTreeOptions: Equatable, Sendable {
    public let maxEntries: Int
    public let maxDepth: Int
    public let includeHidden: Bool

    public init(maxEntries: Int = 500, maxDepth: Int = 6, includeHidden: Bool = false) {
        self.maxEntries = min(max(maxEntries, 1), 2_000)
        self.maxDepth = min(max(maxDepth, 0), 12)
        self.includeHidden = includeHidden
    }
}

public struct WorkspaceFileTreeSnapshot: Equatable, Sendable {
    public let rootPath: String
    public let nodes: [WorkspaceFileNode]
    public let isTruncated: Bool

    public init(rootPath: String, nodes: [WorkspaceFileNode], isTruncated: Bool) {
        self.rootPath = rootPath
        self.nodes = nodes
        self.isTruncated = isTruncated
    }
}

public protocol WorkspaceFileTreeProviding: Sendable {
    func tree(
        at root: URL,
        options: WorkspaceFileTreeOptions
    ) async throws -> WorkspaceFileTreeSnapshot
}

/// Enumerates names and resource metadata only. It never opens regular-file bodies
/// and never follows symbolic links while walking descendants.
public struct LocalWorkspaceFileTreeService: WorkspaceFileTreeProviding, Sendable {
    public init() {}

    public func tree(
        at root: URL,
        options: WorkspaceFileTreeOptions = WorkspaceFileTreeOptions()
    ) async throws -> WorkspaceFileTreeSnapshot {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        return try await Task.detached(priority: .utility) {
            try Self.readTree(at: root, options: options)
        }.value
    }

    private static func readTree(
        at root: URL,
        options: WorkspaceFileTreeOptions
    ) throws -> WorkspaceFileTreeSnapshot {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceError.inspection("tree root is not a directory: \(bounded(root.path, limit: 2_048))")
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var nodes: [WorkspaceFileNode] = []
        var isTruncated = false

        func walk(directory: URL, relativeDirectory: String, childDepth: Int) throws {
            guard !isTruncated else { return }
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: []
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                throw WorkspaceError.inspection(
                    "cannot enumerate \(bounded(relativeDirectory.isEmpty ? "." : relativeDirectory, limit: 2_048)): "
                        + bounded(error.localizedDescription, limit: 1_024)
                )
            }

            for child in children {
                if !options.includeHidden && child.lastPathComponent.hasPrefix(".") {
                    continue
                }
                guard nodes.count < options.maxEntries else {
                    isTruncated = true
                    return
                }

                let values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: resourceKeys)
                } catch {
                    throw WorkspaceError.inspection(
                        "cannot inspect \(bounded(child.lastPathComponent, limit: 512)): "
                            + bounded(error.localizedDescription, limit: 1_024)
                    )
                }
                let relativePath = relativeDirectory.isEmpty
                    ? child.lastPathComponent
                    : relativeDirectory + "/" + child.lastPathComponent
                let kind: WorkspaceFileKind
                if values.isSymbolicLink == true {
                    kind = .symbolicLink
                } else if values.isDirectory == true {
                    kind = .directory
                } else if values.isRegularFile == true {
                    kind = .file
                } else {
                    kind = .other
                }
                nodes.append(WorkspaceFileNode(
                    name: child.lastPathComponent,
                    relativePath: relativePath,
                    depth: childDepth,
                    kind: kind,
                    byteSize: kind == .file ? values.fileSize : nil
                ))

                guard kind == .directory else { continue }
                if childDepth < options.maxDepth {
                    try walk(
                        directory: child,
                        relativeDirectory: relativePath,
                        childDepth: childDepth + 1
                    )
                } else {
                    // The depth limit is itself a truncation boundary. We avoid a
                    // second directory read merely to determine whether it is empty.
                    isTruncated = true
                }
                if isTruncated { return }
            }
        }

        try walk(directory: root, relativeDirectory: "", childDepth: 0)
        return WorkspaceFileTreeSnapshot(
            rootPath: root.path,
            nodes: nodes,
            isTruncated: isTruncated
        )
    }
}

public struct WorkspaceGitChange: Identifiable, Equatable, Sendable {
    public var id: String { status + "\u{0}" + path }

    public let status: String
    public let path: String

    public init(status: String, path: String) {
        self.status = status
        self.path = path
    }
}

public struct WorkspaceGitStatusSnapshot: Equatable, Sendable {
    public let repositoryRoot: String
    public let branch: String
    public let headRevision: String?
    public let changes: [WorkspaceGitChange]
    public let isTruncated: Bool

    public var isClean: Bool { changes.isEmpty && !isTruncated }

    public init(
        repositoryRoot: String,
        branch: String,
        headRevision: String?,
        changes: [WorkspaceGitChange],
        isTruncated: Bool
    ) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.headRevision = headRevision
        self.changes = changes
        self.isTruncated = isTruncated
    }
}

/// One checkout reported by `git worktree list --porcelain`. The first record
/// is Git's primary worktree; every later record is a linked worktree. Dirty
/// state stays in `WorkspaceGitStatusSnapshot` so callers can inspect each
/// checkout independently without conflating repository-wide metadata.
public struct WorkspaceGitWorktreeSnapshot: Equatable, Sendable {
    public let path: String
    public let branch: String?
    public let headRevision: String?
    public let isPrimary: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(
        path: String,
        branch: String?,
        headRevision: String?,
        isPrimary: Bool,
        isLocked: Bool = false,
        isPrunable: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.headRevision = headRevision
        self.isPrimary = isPrimary
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// A branch the user can start work on. Remote-tracking branches are offered
/// too, because wanting to work on a colleague's branch is the ordinary reason
/// to open a second checkout.
public struct WorkspaceGitBranch: Identifiable, Equatable, Sendable {
    public let name: String
    public let isRemote: Bool
    /// Already checked out somewhere, so Git will refuse a second worktree for it.
    public let isCheckedOut: Bool

    public var id: String { isRemote ? "remote:\(name)" : "local:\(name)" }

    public init(name: String, isRemote: Bool, isCheckedOut: Bool) {
        self.name = name
        self.isRemote = isRemote
        self.isCheckedOut = isCheckedOut
    }
}

public protocol WorkspaceGitInspecting: Sendable {
    func repositoryRoot(at path: URL) async throws -> URL
    func originRemote(at repositoryRoot: URL) async throws -> String?
    func worktrees(at path: URL) async throws -> [WorkspaceGitWorktreeSnapshot]
    func status(at path: URL, maxChanges: Int) async throws -> WorkspaceGitStatusSnapshot
    func branches(at path: URL) async throws -> [WorkspaceGitBranch]
    func log(at path: URL, limit: Int) async throws -> (commits: [WorkspaceGitCommit], isTruncated: Bool)
    func checkout(at path: URL, ref: String) async throws
    func addWorktree(
        repositoryRoot: URL,
        at destination: URL,
        branch: String,
        creatingFrom startPoint: String?
    ) async throws -> WorkspaceGitWorktreeSnapshot
    func removeWorktree(
        repositoryRoot: URL,
        at worktree: URL,
        deletingBranch: Bool
    ) async throws -> WorkspaceGitWorktreeRemovalResult
}

public struct WorkspaceGitWorktreeRemovalResult: Equatable, Sendable {
    public let branch: String?
    public let branchDeleted: Bool
    public let branchDeletionFailure: String?

    public init(
        branch: String?,
        branchDeleted: Bool,
        branchDeletionFailure: String? = nil
    ) {
        self.branch = branch
        self.branchDeleted = branchDeleted
        self.branchDeletionFailure = branchDeletionFailure
    }
}

/// Project registration only inspects; branch listing and worktree creation are
/// for the workspace UI. Defaulting them here keeps inspection-only conformers
/// from having to implement what they never call.
extension WorkspaceGitInspecting {
    public func branches(at path: URL) async throws -> [WorkspaceGitBranch] {
        throw WorkspaceError.gitCommandFailed("Branch listing is not available here.")
    }

    public func addWorktree(
        repositoryRoot: URL,
        at destination: URL,
        branch: String,
        creatingFrom startPoint: String?
    ) async throws -> WorkspaceGitWorktreeSnapshot {
        throw WorkspaceError.gitCommandFailed("Worktree creation is not available here.")
    }

    public func removeWorktree(
        repositoryRoot: URL,
        at worktree: URL,
        deletingBranch: Bool
    ) async throws -> WorkspaceGitWorktreeRemovalResult {
        throw WorkspaceError.gitCommandFailed("Worktree removal is not available here.")
    }

    public func log(
        at path: URL,
        limit: Int
    ) async throws -> (commits: [WorkspaceGitCommit], isTruncated: Bool) {
        throw WorkspaceError.gitCommandFailed("History is not available here.")
    }

    public func checkout(at path: URL, ref: String) async throws {
        throw WorkspaceError.gitCommandFailed("Checkout is not available here.")
    }
}

public struct WorkspaceGitService: WorkspaceGitInspecting, Sendable {
    private static let commandOutputLimit = 256 * 1_024
    private static let worktreeLimit = 2_000
    private static let branchLimit = 5_000
    private static let logLimit = 2_000
    private let runner: any CommandRunning
    private let gitExecutable: String

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        gitExecutable: String = "/usr/bin/git"
    ) {
        self.runner = runner
        self.gitExecutable = gitExecutable
    }

    public func repositoryRoot(at path: URL) async throws -> URL {
        let candidate = path.standardizedFileURL
        let result = await git(
            ["-C", candidate.path, "rev-parse", "--show-toplevel"],
            workingDirectory: candidate.path
        )
        guard result.succeeded else {
            throw WorkspaceError.notGitRepository(candidate.path)
        }
        let value = result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !value.isEmpty, value.utf8.count <= 4_096, value.hasPrefix("/") else {
            throw WorkspaceError.gitCommandFailed("git returned an invalid repository root")
        }
        return URL(fileURLWithPath: value, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    /// Initializes a local repository without invoking a shell. Callers create
    /// and approve the directory first; this method only adds Git metadata and
    /// deliberately does not configure a remote or create a commit.
    public func initializeRepository(at directory: URL) async throws -> URL {
        let candidate = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceError.notGitRepository("Project folder does not exist: \(candidate.path)")
        }

        let result = await git(
            ["-C", candidate.path, "init", "-b", "main"],
            workingDirectory: candidate.path
        )
        guard result.succeeded else {
            let message = bounded(result.output, limit: 2_048)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceError.gitCommandFailed(
                message.isEmpty ? "git init failed for \(candidate.path)" : message
            )
        }
        return try await repositoryRoot(at: candidate)
    }

    public func originRemote(at repositoryRoot: URL) async throws -> String? {
        let result = await git(
            ["-C", repositoryRoot.path, "config", "--get", "remote.origin.url"],
            workingDirectory: repositoryRoot.path
        )
        guard result.succeeded else { return nil }
        let remote = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { return nil }
        guard remote.utf8.count <= 4_096, !remote.contains("\n"), !remote.contains("\r") else {
            throw WorkspaceError.gitCommandFailed("origin remote is not a bounded single-line value")
        }
        return remote
    }

    /// Lists worktrees, first clearing registrations whose directory is gone.
    ///
    /// A deleted worktree directory leaves its administrative entry behind, and
    /// that entry keeps holding the branch: the next checkout of it fails with
    /// "branch is already checked out", and the listing shows a checkout that
    /// does not exist. `git worktree prune` is the documented cleanup for exactly
    /// that, and it only removes bookkeeping for directories that are already
    /// missing — so it runs here rather than waiting for a user to know the
    /// command. Only when something is actually missing, to keep an ordinary
    /// refresh from spawning a second git process.
    public func worktrees(at path: URL) async throws -> [WorkspaceGitWorktreeSnapshot] {
        let root = try await repositoryRoot(at: path)
        let listed = try await listWorktrees(root: root)
        let hasMissingCheckout = listed.contains { snapshot in
            !FileManager.default.fileExists(atPath: snapshot.path)
        }
        guard hasMissingCheckout else { return listed }
        let pruned = await git(
            ["-C", root.path, "worktree", "prune"],
            workingDirectory: root.path
        )
        guard pruned.succeeded else { return listed }
        return try await listWorktrees(root: root)
    }

    private func listWorktrees(root: URL) async throws -> [WorkspaceGitWorktreeSnapshot] {
        let result = await git(
            ["-C", root.path, "worktree", "list", "--porcelain", "-z"],
            workingDirectory: root.path
        )
        guard result.succeeded else {
            throw WorkspaceError.gitCommandFailed(bounded(result.output, limit: 2_048))
        }
        let output = utf8Prefix(result.output, byteLimit: Self.commandOutputLimit)
        guard !output.wasTruncated else {
            throw WorkspaceError.gitCommandFailed("worktree list output exceeded the inspection limit")
        }
        return try Self.parseWorktrees(output.value)
    }

    public func status(
        at path: URL,
        maxChanges: Int = 500
    ) async throws -> WorkspaceGitStatusSnapshot {
        let limit = min(max(maxChanges, 1), 1_000)
        let root = try await repositoryRoot(at: path)

        let branchResult = await git(
            ["-C", root.path, "symbolic-ref", "--quiet", "--short", "HEAD"],
            workingDirectory: root.path
        )
        let headResult = await git(
            ["-C", root.path, "rev-parse", "--verify", "HEAD"],
            workingDirectory: root.path
        )
        let branch: String
        if branchResult.succeeded, !branchResult.output.isEmpty {
            branch = bounded(branchResult.output, limit: 512)
        } else if headResult.succeeded {
            branch = "detached@" + String(headResult.output.prefix(12))
        } else {
            branch = "unborn"
        }
        let headRevision = headResult.succeeded && !headResult.output.isEmpty
            ? bounded(headResult.output, limit: 128)
            : nil

        let statusResult = await git(
            [
                "-C", root.path,
                "-c", "core.quotepath=true",
                "status", "--porcelain=v1", "--untracked-files=normal",
            ],
            workingDirectory: root.path
        )
        guard statusResult.succeeded else {
            throw WorkspaceError.gitCommandFailed(bounded(statusResult.output, limit: 2_048))
        }

        let boundedStatus = utf8Prefix(statusResult.output, byteLimit: Self.commandOutputLimit)
        var isTruncated = boundedStatus.wasTruncated
        let lines = boundedStatus.value.split(whereSeparator: \.isNewline)
        if lines.count > limit { isTruncated = true }
        var changes: [WorkspaceGitChange] = []
        for line in lines.prefix(limit) {
            guard line.utf8.count >= 3 else { continue }
            let status = String(line.prefix(2))
            let rawPath = String(line.dropFirst(3))
            let path = bounded(rawPath, limit: 2_048)
            if path != rawPath { isTruncated = true }
            changes.append(WorkspaceGitChange(status: status, path: path))
        }

        return WorkspaceGitStatusSnapshot(
            repositoryRoot: root.path,
            branch: branch,
            headRevision: headRevision,
            changes: changes,
            isTruncated: isTruncated
        )
    }

    public func branches(at path: URL) async throws -> [WorkspaceGitBranch] {
        let root = try await repositoryRoot(at: path)
        // %(worktreepath) is empty unless the branch is checked out somewhere,
        // which is exactly what makes a second worktree impossible.
        let result = await git(
            [
                "-C", root.path, "for-each-ref",
                "--format=%(refname)%00%(worktreepath)",
                "--count=\(Self.branchLimit)",
                "refs/heads", "refs/remotes",
            ],
            workingDirectory: root.path
        )
        guard result.succeeded else {
            throw WorkspaceError.gitCommandFailed("git could not list branches")
        }
        guard result.output.utf8.count <= Self.commandOutputLimit else {
            throw WorkspaceError.gitCommandFailed("git returned an unbounded branch list")
        }

        var branches: [WorkspaceGitBranch] = []
        var seen = Set<String>()
        for line in result.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard let reference = fields.first.map(String.init), !reference.isEmpty else { continue }
            let worktreePath = fields.count > 1 ? String(fields[1]) : ""

            let name: String
            let isRemote: Bool
            if reference.hasPrefix("refs/heads/") {
                name = String(reference.dropFirst("refs/heads/".count))
                isRemote = false
            } else if reference.hasPrefix("refs/remotes/") {
                name = String(reference.dropFirst("refs/remotes/".count))
                isRemote = true
            } else {
                continue
            }
            // origin/HEAD is a symbolic pointer, not somewhere to start work.
            guard !name.isEmpty, !name.hasSuffix("/HEAD"), seen.insert(reference).inserted else {
                continue
            }
            branches.append(WorkspaceGitBranch(
                name: name,
                isRemote: isRemote,
                isCheckedOut: !worktreePath.isEmpty
            ))
        }
        return branches
    }

    /// Reads recent history for the graph. The walk is bounded by `limit`; the
    /// caller is told when it stopped early so the view can say the oldest edges
    /// are cut off rather than drawing them as roots.
    public func log(at path: URL, limit: Int) async throws -> (commits: [WorkspaceGitCommit], isTruncated: Bool) {
        let limit = min(max(limit, 1), Self.logLimit)
        let root = try await repositoryRoot(at: path)
        let result = await git(
            [
                "-C", root.path, "log",
                // One extra record answers "was there more?" without a second
                // walk; it is dropped before returning.
                "--max-count=\(limit + 1)",
                "--decorate=full",
                "--date-order",
                WorkspaceGitLogFormat.prettyFormat,
                "--all",
            ],
            workingDirectory: root.path
        )
        guard result.succeeded else {
            // An empty repository has no HEAD to walk, and that is not a failure.
            if result.output.contains("does not have any commits") {
                return ([], false)
            }
            throw WorkspaceError.gitCommandFailed(bounded(result.output, limit: 2_048))
        }
        let output = utf8Prefix(result.output, byteLimit: Self.commandOutputLimit)
        var commits = WorkspaceGitLogFormat.parse(output.value)
        let hasMore = commits.count > limit || output.wasTruncated
        if commits.count > limit {
            commits.removeLast(commits.count - limit)
        }
        return (commits, hasMore)
    }

    /// Switches the checkout to `ref`.
    ///
    /// Refusing on a dirty tree is deliberate even though Git would allow a
    /// checkout that does not conflict: this runs against source trees an agent
    /// may be writing, and "it only carried some of your changes across" is not
    /// a state worth landing a user in from a one-click button.
    public func checkout(at path: URL, ref: String) async throws {
        try Self.validateStartPoint(ref)
        let status = try await status(at: path, maxChanges: 1)
        guard status.isClean else {
            throw WorkspaceError.checkoutRefused(
                "This source tree has uncommitted changes. Commit or stash them first."
            )
        }
        let result = await git(
            // `--` closes the argument list so a ref that looks like a path
            // cannot be reinterpreted as a pathspec checkout, which would
            // overwrite files instead of switching branches.
            ["-C", path.standardizedFileURL.path, "checkout", ref, "--"],
            workingDirectory: path.standardizedFileURL.path
        )
        guard result.succeeded else {
            throw WorkspaceError.checkoutRefused(bounded(result.output, limit: 2_048))
        }
    }

    public func addWorktree(
        repositoryRoot: URL,
        at destination: URL,
        branch: String,
        creatingFrom startPoint: String?
    ) async throws -> WorkspaceGitWorktreeSnapshot {
        try Self.validateBranchName(branch)
        if let startPoint {
            try Self.validateStartPoint(startPoint)
        } else {
            // Without a start point this checks a branch out as it is, and
            // `git worktree add <path> <commit-ish>` accepts far more than a
            // branch: a remote-tracking ref, a tag, or a bare revision all
            // resolve, and Git then detaches HEAD. That leaves a checkout whose
            // commits belong to no branch, which is never what a caller asking
            // for `branch` meant. Only a local branch can be checked out, so
            // anything else is refused here instead of being discovered later
            // as a directory sitting on a detached HEAD.
            try await requireLocalBranch(branch, in: repositoryRoot)
        }
        let target = destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw WorkspaceError.gitCommandFailed("\(target.path) already exists")
        }

        var arguments = ["-C", repositoryRoot.path, "worktree", "add"]
        if let startPoint {
            arguments += ["-b", branch, target.path, startPoint]
        } else {
            arguments += [target.path, branch]
        }
        // Creating a checkout can pull in a large tree, so it gets its own
        // budget rather than the short inspection timeout.
        let result = await runner.run(CommandSpec(
            executable: gitExecutable,
            arguments: arguments,
            environment: ["LC_ALL": "C", "LANG": "C"],
            workingDirectory: repositoryRoot.path,
            timeout: 300
        ))
        guard result.succeeded else {
            throw WorkspaceError.gitCommandFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Report what Git actually recorded rather than what was requested.
        let created = try await worktrees(at: repositoryRoot).first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == target.path
        }
        guard let created else {
            throw WorkspaceError.gitCommandFailed("git did not register the new worktree")
        }
        return created
    }

    /// Fails unless `refs/heads/<branch>` exists, naming the remedy for the case
    /// this is reached with: a remote-tracking branch, which needs a local branch
    /// started from it rather than a direct checkout.
    private func requireLocalBranch(_ branch: String, in repositoryRoot: URL) async throws {
        let result = await git(
            [
                "-C", repositoryRoot.path,
                "show-ref", "--verify", "--quiet", "refs/heads/\(branch)",
            ],
            workingDirectory: repositoryRoot.path
        )
        guard result.succeeded else {
            throw WorkspaceError.gitCommandFailed(
                "\(branch) is not a local branch. Create a local branch from it instead."
            )
        }
    }

    /// Removes one exact non-primary worktree after re-checking that Git still
    /// knows it and that its working tree is clean. Branch deletion is a
    /// separate, conservative step: `-d` refuses an unmerged branch and that
    /// refusal is returned without pretending the already removed worktree
    /// still exists.
    public func removeWorktree(
        repositoryRoot: URL,
        at worktree: URL,
        deletingBranch: Bool
    ) async throws -> WorkspaceGitWorktreeRemovalResult {
        let root = try await self.repositoryRoot(at: repositoryRoot)
        let target = worktree.resolvingSymlinksInPath().standardizedFileURL
        guard target.path != root.path else {
            throw WorkspaceError.gitCommandFailed("The primary worktree cannot be deleted.")
        }

        let registered = try await worktrees(at: root)
        guard let snapshot = registered.first(where: {
            URL(fileURLWithPath: $0.path, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path == target.path
        }), !snapshot.isPrimary else {
            throw WorkspaceError.gitCommandFailed(
                "The selected folder is no longer a removable Git worktree. Refresh and try again."
            )
        }
        if deletingBranch, let branch = snapshot.branch {
            try Self.validateBranchName(branch)
        }

        let currentStatus = try await status(at: target, maxChanges: 1)
        guard currentStatus.isClean else {
            throw WorkspaceError.gitCommandFailed(
                "This worktree has uncommitted or untracked changes. Commit or stash them first."
            )
        }

        let removal = await runner.run(CommandSpec(
            executable: gitExecutable,
            arguments: ["-C", root.path, "worktree", "remove", target.path],
            environment: ["LC_ALL": "C", "LANG": "C"],
            workingDirectory: root.path,
            timeout: 300
        ))
        guard removal.succeeded else {
            let message = bounded(removal.output, limit: 2_048)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceError.gitCommandFailed(
                message.isEmpty ? "Git could not remove the selected worktree." : message
            )
        }

        guard deletingBranch else {
            return WorkspaceGitWorktreeRemovalResult(
                branch: snapshot.branch,
                branchDeleted: false
            )
        }
        guard let branch = snapshot.branch else {
            return WorkspaceGitWorktreeRemovalResult(
                branch: nil,
                branchDeleted: false,
                branchDeletionFailure:
                    "The worktree was deleted, but it was detached and had no local branch to delete."
            )
        }

        let branchRemoval = await git(
            ["-C", root.path, "branch", "-d", "--", branch],
            workingDirectory: root.path
        )
        guard branchRemoval.succeeded else {
            let detail = bounded(branchRemoval.output, limit: 2_048)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return WorkspaceGitWorktreeRemovalResult(
                branch: branch,
                branchDeleted: false,
                branchDeletionFailure: detail.isEmpty
                    ? "The worktree was deleted, but Git kept the branch because it could not verify a safe deletion."
                    : "The worktree was deleted, but Git kept branch \(branch): \(detail)"
            )
        }
        return WorkspaceGitWorktreeRemovalResult(branch: branch, branchDeleted: true)
    }

    /// Delegates the rules to Git itself; a hand-rolled pattern would drift from
    /// what `git worktree add` will actually accept.
    static func validateBranchName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 255,
              !name.hasPrefix("-"),
              !name.contains("\n"), !name.contains("\r"), !name.contains("\0"),
              name.trimmingCharacters(in: .whitespaces) == name else {
            throw WorkspaceError.gitCommandFailed("Branch name is not usable: \(name)")
        }
    }

    static func validateStartPoint(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 255,
              !value.hasPrefix("-"),
              !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw WorkspaceError.gitCommandFailed("Start point is not usable: \(value)")
        }
    }

    private func git(_ arguments: [String], workingDirectory: String) async -> CommandResult {
        await runner.run(CommandSpec(
            executable: gitExecutable,
            arguments: arguments,
            environment: ["LC_ALL": "C", "LANG": "C"],
            workingDirectory: workingDirectory,
            timeout: 15
        ))
    }

    private static func parseWorktrees(_ output: String) throws -> [WorkspaceGitWorktreeSnapshot] {
        struct Record {
            var path: String?
            var branch: String?
            var headRevision: String?
            var isLocked = false
            var isPrunable = false
        }

        var records: [Record] = []
        var record = Record()
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        if let first = fields.first, !first.isEmpty, !first.hasPrefix("worktree ") {
            throw WorkspaceError.gitCommandFailed("git returned an incomplete worktree list")
        }

        func appendRecord() throws {
            guard let rawPath = record.path else { return }
            guard records.count < worktreeLimit else {
                throw WorkspaceError.gitCommandFailed("worktree count exceeded the inspection limit")
            }
            guard !rawPath.isEmpty, rawPath.utf8.count <= 4_096, rawPath.hasPrefix("/") else {
                throw WorkspaceError.gitCommandFailed("git returned an invalid worktree path")
            }
            let path = URL(fileURLWithPath: rawPath, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            records.append(Record(
                path: path,
                branch: record.branch,
                headRevision: record.headRevision,
                isLocked: record.isLocked,
                isPrunable: record.isPrunable
            ))
        }

        for field in fields {
            if field.isEmpty {
                try appendRecord()
                record = Record()
                continue
            }
            if field.hasPrefix("worktree ") {
                if record.path != nil {
                    try appendRecord()
                    record = Record()
                }
                record.path = String(field.dropFirst("worktree ".count))
            } else if field.hasPrefix("HEAD ") {
                let revision = String(field.dropFirst("HEAD ".count))
                guard !revision.isEmpty, revision.utf8.count <= 128 else {
                    throw WorkspaceError.gitCommandFailed("git returned an invalid worktree revision")
                }
                record.headRevision = revision
            } else if field.hasPrefix("branch ") {
                let reference = String(field.dropFirst("branch ".count))
                guard !reference.isEmpty, reference.utf8.count <= 1_024 else {
                    throw WorkspaceError.gitCommandFailed("git returned an invalid worktree branch")
                }
                record.branch = reference.hasPrefix("refs/heads/")
                    ? String(reference.dropFirst("refs/heads/".count))
                    : reference
            } else if field == "locked" || field.hasPrefix("locked ") {
                record.isLocked = true
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                record.isPrunable = true
            }
        }
        if record.path != nil {
            try appendRecord()
        }

        var seenPaths = Set<String>()
        var snapshots: [WorkspaceGitWorktreeSnapshot] = []
        snapshots.reserveCapacity(records.count)
        for record in records {
            guard let path = record.path else { continue }
            guard seenPaths.insert(path).inserted else {
                throw WorkspaceError.gitCommandFailed("git returned a duplicate worktree path")
            }
            snapshots.append(WorkspaceGitWorktreeSnapshot(
                path: path,
                branch: record.branch,
                headRevision: record.headRevision,
                isPrimary: snapshots.isEmpty,
                isLocked: record.isLocked,
                isPrunable: record.isPrunable
            ))
        }
        return snapshots
    }
}

private func bounded(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(limit))
}

private func utf8Prefix(_ value: String, byteLimit: Int) -> (value: String, wasTruncated: Bool) {
    let bytes = Array(value.utf8)
    guard bytes.count > byteLimit else { return (value, false) }
    return (String(decoding: bytes.prefix(byteLimit), as: UTF8.self), true)
}
