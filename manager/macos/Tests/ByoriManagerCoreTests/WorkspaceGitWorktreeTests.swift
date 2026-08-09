import XCTest
@testable import ByoriManagerCore

/// Exercises real `git` against a scratch repository. Worktree creation is the
/// one workspace mutation that touches the user's repository, so the contract is
/// verified against Git itself rather than a stub.
final class WorkspaceGitWorktreeTests: XCTestCase {
    private var root: URL!
    private let git = WorkspaceGitService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try run(["init", "--initial-branch=main", root.path])
        try run(["-C", root.path, "config", "user.email", "test@example.invalid"])
        try run(["-C", root.path, "config", "user.name", "Byori Test"])
        try Data("hello".utf8).write(to: root.appendingPathComponent("README.md"))
        try run(["-C", root.path, "add", "."])
        try run(["-C", root.path, "commit", "-m", "initial"])
        try run(["-C", root.path, "branch", "feature/one"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func testListsLocalBranchesAndMarksTheOneAlreadyCheckedOut() async throws {
        let branches = try await git.branches(at: root)
        let names = branches.map(\.name).sorted()
        XCTAssertEqual(names, ["feature/one", "main"])

        let main = try XCTUnwrap(branches.first { $0.name == "main" })
        XCTAssertTrue(main.isCheckedOut, "the primary worktree holds main")
        XCTAssertFalse(main.isRemote)

        let feature = try XCTUnwrap(branches.first { $0.name == "feature/one" })
        XCTAssertFalse(feature.isCheckedOut, "no worktree holds it yet")
    }

    func testAddsAWorktreeForAnExistingBranch() async throws {
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("byori-wt-\(UUID().uuidString)/feature-one", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let created = try await git.addWorktree(
            repositoryRoot: root,
            at: destination,
            branch: "feature/one",
            creatingFrom: nil
        )
        XCTAssertEqual(created.branch, "feature/one")
        XCTAssertFalse(created.isPrimary)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("README.md").path
        ))

        // Git now reports it as taken, which is what stops a second attempt.
        let branches = try await git.branches(at: root)
        let reused = try XCTUnwrap(branches.first { $0.name == "feature/one" })
        XCTAssertTrue(reused.isCheckedOut)
    }

    func testCreatesANewBranchFromAStartPoint() async throws {
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("byori-wt-\(UUID().uuidString)/fresh", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let created = try await git.addWorktree(
            repositoryRoot: root,
            at: destination,
            branch: "feature/fresh",
            creatingFrom: "main"
        )
        XCTAssertEqual(created.branch, "feature/fresh")
        let after = try await git.branches(at: root)
        XCTAssertTrue(after.contains { $0.name == "feature/fresh" })
    }

    func testRefusesToOverwriteAnExistingDirectory() async throws {
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("byori-wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: destination.appendingPathComponent("existing.txt"))
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            _ = try await git.addWorktree(
                repositoryRoot: root,
                at: destination,
                branch: "feature/one",
                creatingFrom: nil
            )
            XCTFail("expected the occupied destination to be refused")
        } catch {
            XCTAssertEqual(
                try? Data(contentsOf: destination.appendingPathComponent("existing.txt")),
                Data("keep me".utf8),
                "the existing directory must be left alone"
            )
        }
    }

    func testRejectsBranchNamesThatWouldBeReadAsOptions() {
        XCTAssertThrowsError(try WorkspaceGitService.validateBranchName("--force"))
        XCTAssertThrowsError(try WorkspaceGitService.validateBranchName(""))
        XCTAssertThrowsError(try WorkspaceGitService.validateBranchName("with\nnewline"))
        XCTAssertThrowsError(try WorkspaceGitService.validateBranchName(" leading"))
        XCTAssertThrowsError(try WorkspaceGitService.validateStartPoint("-x"))
        XCTAssertNoThrow(try WorkspaceGitService.validateBranchName("feature/one"))
    }
}
