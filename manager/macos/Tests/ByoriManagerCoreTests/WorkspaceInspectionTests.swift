import XCTest
@testable import ByoriManagerCore

final class WorkspaceInspectionTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-inspection-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testFileTreeIsMetadataOnlySkipsHiddenAndBoundsEntries() async throws {
        let directory = temporaryRoot.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("a private body that must not appear".utf8)
            .write(to: temporaryRoot.appendingPathComponent("a.txt"))
        try Data("nested".utf8).write(to: directory.appendingPathComponent("b.txt"))
        try Data("hidden".utf8).write(to: temporaryRoot.appendingPathComponent(".secret"))
        try FileManager.default.createSymbolicLink(
            at: temporaryRoot.appendingPathComponent("b-outside-link"),
            withDestinationURL: directory
        )

        let service = LocalWorkspaceFileTreeService()
        let tree = try await service.tree(
            at: temporaryRoot,
            options: WorkspaceFileTreeOptions(maxEntries: 3, maxDepth: 4)
        )

        XCTAssertEqual(tree.nodes.count, 3)
        XCTAssertTrue(tree.isTruncated)
        XCTAssertFalse(tree.nodes.contains(where: { $0.name == ".secret" }))
        XCTAssertEqual(tree.nodes.first(where: { $0.name == "b-outside-link" })?.kind, .symbolicLink)
        XCTAssertFalse(tree.nodes.map(\.relativePath).joined().contains("private body"))
    }

    func testFileTreeDepthLimitIsReportedAsTruncation() async throws {
        let directory = temporaryRoot.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: directory.appendingPathComponent("b.txt"))

        let tree = try await LocalWorkspaceFileTreeService().tree(
            at: temporaryRoot,
            options: WorkspaceFileTreeOptions(maxEntries: 100, maxDepth: 0)
        )
        XCTAssertEqual(tree.nodes.map(\.relativePath), ["dir"])
        XCTAssertTrue(tree.isTruncated)
    }

    func testGitStatusUsesArgumentArrayAndBoundsChanges() async throws {
        let repositoryRoot = temporaryRoot.appendingPathComponent("repo with spaces", isDirectory: true)
        let runner = StubCommandRunner { command in
            XCTAssertEqual(command.executable, "/test/bin/git")
            XCTAssertTrue(command.arguments.contains(repositoryRoot.path))
            if command.arguments.contains("--show-toplevel") {
                return CommandResult(exitCode: 0, output: repositoryRoot.path)
            }
            if command.arguments.contains("symbolic-ref") {
                return CommandResult(exitCode: 0, output: "feature/workspace")
            }
            if command.arguments.contains("--verify") {
                return CommandResult(exitCode: 0, output: String(repeating: "a", count: 40))
            }
            if command.arguments.contains("status") {
                return CommandResult(
                    exitCode: 0,
                    output: " M Sources/A.swift\n?? Sources/B.swift\nA  Sources/C.swift"
                )
            }
            return CommandResult(exitCode: 1, output: "unexpected")
        }
        let service = WorkspaceGitService(runner: runner, gitExecutable: "/test/bin/git")

        let status = try await service.status(at: repositoryRoot, maxChanges: 2)

        XCTAssertEqual(status.repositoryRoot, repositoryRoot.path)
        XCTAssertEqual(status.branch, "feature/workspace")
        XCTAssertEqual(status.headRevision, String(repeating: "a", count: 40))
        XCTAssertEqual(status.changes, [
            WorkspaceGitChange(status: " M", path: "Sources/A.swift"),
            WorkspaceGitChange(status: "??", path: "Sources/B.swift"),
        ])
        XCTAssertTrue(status.isTruncated)
        XCTAssertFalse(status.isClean)
    }

    func testInitializeRepositoryUsesArgumentArrayAndReturnsVerifiedRoot() async throws {
        let directory = temporaryRoot.appendingPathComponent("new project; safe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let runner = StubCommandRunner { command in
            XCTAssertEqual(command.executable, "/test/bin/git")
            XCTAssertEqual(command.workingDirectory, directory.path)
            if command.arguments.contains("init") {
                XCTAssertEqual(command.arguments, ["-C", directory.path, "init", "-b", "main"])
                return CommandResult(exitCode: 0, output: "Initialized empty Git repository")
            }
            // The path carries a `;` on purpose: every argument stays a separate
            // element, including the ones the root commit adds.
            if command.arguments.contains("GIT_AUTHOR_IDENT") {
                XCTAssertEqual(command.arguments, ["-C", directory.path, "var", "GIT_AUTHOR_IDENT"])
                return CommandResult(exitCode: 0, output: "Someone <someone@example.invalid> 0 +0000")
            }
            if command.arguments.contains("commit") {
                XCTAssertEqual(command.arguments, [
                    "-C", directory.path, "commit", "--allow-empty", "-m", "Initial commit",
                ])
                return CommandResult(exitCode: 0, output: "[main (root-commit) abc1234] Initial commit")
            }
            XCTAssertEqual(command.arguments, ["-C", directory.path, "rev-parse", "--show-toplevel"])
            return CommandResult(exitCode: 0, output: directory.path)
        }
        let service = WorkspaceGitService(runner: runner, gitExecutable: "/test/bin/git")

        let root = try await service.initializeRepository(at: directory)

        XCTAssertEqual(root.path, directory.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testInitializeRepositoryRequiresExistingDirectoryBeforeRunningGit() async throws {
        let missing = temporaryRoot.appendingPathComponent("missing", isDirectory: true)
        let runner = StubCommandRunner { _ in
            XCTFail("git must not run for a missing directory")
            return CommandResult(exitCode: 1, output: "unexpected")
        }
        let service = WorkspaceGitService(runner: runner, gitExecutable: "/test/bin/git")

        do {
            _ = try await service.initializeRepository(at: missing)
            XCTFail("Expected a missing-directory error")
        } catch let error as WorkspaceError {
            guard case let .notGitRepository(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains(missing.path))
        }
    }

    /// A new project has to be workable the moment it is registered, and an unborn
    /// `main` is not: nothing lists it, nothing can start from it, and no second
    /// checkout can be cut. So initialization commits once.
    func testInitializeRealRepositoryCreatesABornMainBranch() async throws {
        let directory = temporaryRoot.appendingPathComponent("real-new-project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let service = WorkspaceGitService()

        let root = try await service.initializeRepository(at: directory)
        let status = try await service.status(at: root)
        let worktrees = try await service.worktrees(at: root)
        let branches = try await service.branches(at: root)

        XCTAssertEqual(root.path, directory.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(status.branch, "main")
        XCTAssertNotNil(status.headRevision, "an unborn branch is what this has to avoid")
        XCTAssertTrue(status.isClean, "the root commit is empty, so nothing is left uncommitted")
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees.first?.branch, "main")
        XCTAssertTrue(worktrees.first?.isPrimary == true)
        XCTAssertEqual(branches.map(\.name), ["main"], "main must be a ref, not just HEAD's name")
        XCTAssertTrue(branches.first?.isCheckedOut == true)
    }

    /// The failure this exists to prevent, end to end: cutting a worktree is
    /// impossible from an unborn HEAD, which is what a second concurrent session
    /// needs on a project Byori just created.
    func testANewRepositoryCanImmediatelyTakeAWorktree() async throws {
        let directory = temporaryRoot.appendingPathComponent("worktree-ready", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let service = WorkspaceGitService()
        let root = try await service.initializeRepository(at: directory)

        let created = try await service.addWorktree(
            repositoryRoot: root,
            at: temporaryRoot.appendingPathComponent("second-checkout", isDirectory: true),
            branch: "byori/first-task",
            creatingFrom: "main"
        )

        XCTAssertEqual(created.branch, "byori/first-task")
    }

    /// A machine with no configured Git identity would otherwise fail here, leaving
    /// exactly the unborn repository this is meant to avoid.
    func testTheRootCommitFallsBackToByorisIdentityOnlyWhenGitHasNone() async throws {
        for hasIdentity in [true, false] {
            let commands = CommandLog()
            let runner = StubCommandRunner { command in
                if command.arguments.contains("--show-toplevel") {
                    return CommandResult(exitCode: 0, output: "/tmp/project")
                }
                _ = commands.record(command.arguments)
                if command.arguments.contains("GIT_AUTHOR_IDENT") {
                    return hasIdentity
                        ? CommandResult(exitCode: 0, output: "Someone <someone@example.invalid> 0 +0000")
                        : CommandResult(exitCode: 128, output: "unable to auto-detect email address")
                }
                return CommandResult(exitCode: 0, output: "")
            }
            let service = WorkspaceGitService(runner: runner, gitExecutable: "/test/bin/git")

            _ = try await service.initializeRepository(at: temporaryRoot)

            let commit = try XCTUnwrap(commands.recorded.first { $0.contains("commit") })
            XCTAssertTrue(commit.contains("--allow-empty"), "\(commit)")
            XCTAssertEqual(
                commit.contains("user.name=Byori"),
                !hasIdentity,
                "a configured identity must be preferred: \(commit)"
            )
        }
    }

    func testGitWorktreeListParsesPrimaryLinkedDetachedAndFlags() async throws {
        let primary = temporaryRoot.appendingPathComponent("repo with spaces", isDirectory: true)
        let linked = temporaryRoot.appendingPathComponent("linked feature", isDirectory: true)
        let detached = temporaryRoot.appendingPathComponent("detached", isDirectory: true)
        // Every listed checkout exists, so nothing is pruned and the listing is
        // the only worktree command issued.
        for directory in [primary, linked, detached] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let runner = StubCommandRunner { command in
            XCTAssertEqual(command.executable, "/test/bin/git")
            if command.arguments.contains("--show-toplevel") {
                return CommandResult(exitCode: 0, output: primary.path)
            }
            XCTAssertEqual(command.arguments, [
                "-C", primary.path, "worktree", "list", "--porcelain", "-z",
            ])
            return CommandResult(exitCode: 0, output:
                "worktree \(primary.path)\0"
                    + "HEAD \(String(repeating: "a", count: 40))\0"
                    + "branch refs/heads/main\0\0"
                    + "worktree \(linked.path)\0"
                    + "HEAD \(String(repeating: "b", count: 40))\0"
                    + "branch refs/heads/feature/workspace\0"
                    + "locked review\0\0"
                    + "worktree \(detached.path)\0"
                    + "HEAD \(String(repeating: "c", count: 40))\0"
                    + "detached\0prunable stale metadata\0\0"
            )
        }
        let service = WorkspaceGitService(runner: runner, gitExecutable: "/test/bin/git")

        let worktrees = try await service.worktrees(at: primary)

        XCTAssertEqual(worktrees, [
            WorkspaceGitWorktreeSnapshot(
                path: primary.path,
                branch: "main",
                headRevision: String(repeating: "a", count: 40),
                isPrimary: true
            ),
            WorkspaceGitWorktreeSnapshot(
                path: linked.path,
                branch: "feature/workspace",
                headRevision: String(repeating: "b", count: 40),
                isPrimary: false,
                isLocked: true
            ),
            WorkspaceGitWorktreeSnapshot(
                path: detached.path,
                branch: nil,
                headRevision: String(repeating: "c", count: 40),
                isPrimary: false,
                isPrunable: true
            ),
        ])
    }

    /// A worktree directory the user deleted leaves a registration that keeps
    /// holding its branch, so the next checkout of that branch fails. Listing
    /// clears those first — but only when something is actually missing, so an
    /// ordinary refresh still costs one git process.
    func testWorktreeListingPrunesRegistrationsWhoseDirectoryIsGone() async throws {
        let primary = temporaryRoot.appendingPathComponent("primary", isDirectory: true)
        let missing = temporaryRoot.appendingPathComponent("deleted-by-hand", isDirectory: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)

        let commands = CommandLog()
        let runner = StubCommandRunner { command in
            if command.arguments.contains("--show-toplevel") {
                return CommandResult(exitCode: 0, output: primary.path)
            }
            let attempt = commands.record(command.arguments)
            if command.arguments.contains("prune") {
                return CommandResult(exitCode: 0, output: "")
            }
            // First listing still reports the deleted checkout; after the prune
            // git no longer knows about it.
            let stale = "worktree \(missing.path)\0"
                + "HEAD \(String(repeating: "b", count: 40))\0"
                + "branch refs/heads/gone\0\0"
            return CommandResult(exitCode: 0, output:
                "worktree \(primary.path)\0"
                    + "HEAD \(String(repeating: "a", count: 40))\0"
                    + "branch refs/heads/main\0\0"
                    + (attempt == 1 ? stale : "")
            )
        }
        let service = WorkspaceGitService(runner: runner, gitExecutable: "/test/bin/git")

        let worktrees = try await service.worktrees(at: primary)

        XCTAssertEqual(worktrees.map(\.path), [primary.path])
        XCTAssertEqual(commands.recorded.count, 3, "list, prune, list")
        XCTAssertTrue(commands.recorded[1].contains("prune"))
    }
}

/// Counts worktree commands across concurrent-safe stub invocations.
private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []

    @discardableResult
    func record(_ arguments: [String]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        commands.append(arguments)
        return commands.filter { !$0.contains("prune") }.count
    }

    var recorded: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}

private struct StubCommandRunner: CommandRunning {
    let handler: @Sendable (CommandSpec) -> CommandResult

    init(handler: @escaping @Sendable (CommandSpec) -> CommandResult) {
        self.handler = handler
    }

    func run(_ command: CommandSpec) async -> CommandResult {
        handler(command)
    }
}
