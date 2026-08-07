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

    func testGitWorktreeListParsesPrimaryLinkedDetachedAndFlags() async throws {
        let primary = temporaryRoot.appendingPathComponent("repo with spaces", isDirectory: true)
        let linked = temporaryRoot.appendingPathComponent("linked feature", isDirectory: true)
        let detached = temporaryRoot.appendingPathComponent("detached", isDirectory: true)
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
