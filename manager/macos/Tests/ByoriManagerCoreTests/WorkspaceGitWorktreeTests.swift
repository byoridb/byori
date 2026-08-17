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

    func testRemovesCleanWorktreeAndKeepsBranchWhenRequested() async throws {
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("byori-wt-\(UUID().uuidString)/feature-one", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        _ = try await git.addWorktree(
            repositoryRoot: root,
            at: destination,
            branch: "feature/one",
            creatingFrom: nil
        )

        let result = try await git.removeWorktree(
            repositoryRoot: root,
            at: destination,
            deletingBranch: false
        )
        let remainingBranches = try await git.branches(at: root)

        XCTAssertEqual(result.branch, "feature/one")
        XCTAssertFalse(result.branchDeleted)
        XCTAssertNil(result.branchDeletionFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(remainingBranches.contains { $0.name == "feature/one" })
    }

    func testRemovesCleanWorktreeAndSafelyDeletesMergedBranch() async throws {
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("byori-wt-\(UUID().uuidString)/feature-one", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        _ = try await git.addWorktree(
            repositoryRoot: root,
            at: destination,
            branch: "feature/one",
            creatingFrom: nil
        )

        let result = try await git.removeWorktree(
            repositoryRoot: root,
            at: destination,
            deletingBranch: true
        )
        let remainingBranches = try await git.branches(at: root)

        XCTAssertEqual(result.branch, "feature/one")
        XCTAssertTrue(result.branchDeleted)
        XCTAssertNil(result.branchDeletionFailure)
        XCTAssertFalse(remainingBranches.contains { $0.name == "feature/one" })
    }

    func testRefusesDirtyWorktreeWithoutDeletingFiles() async throws {
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("byori-wt-\(UUID().uuidString)/feature-one", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        _ = try await git.addWorktree(
            repositoryRoot: root,
            at: destination,
            branch: "feature/one",
            creatingFrom: nil
        )
        let untracked = destination.appendingPathComponent("do-not-delete.txt")
        try Data("important".utf8).write(to: untracked)

        do {
            _ = try await git.removeWorktree(
                repositoryRoot: root,
                at: destination,
                deletingBranch: true
            )
            XCTFail("A dirty worktree must be refused")
        } catch {
            let remainingBranches = try await git.branches(at: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.path))
            XCTAssertTrue(remainingBranches.contains {
                $0.name == "feature/one" && $0.isCheckedOut
            })
        }
    }

    func testUnmergedBranchIsKeptAfterWorktreeRemoval() async throws {
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("byori-wt-\(UUID().uuidString)/feature-one", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        _ = try await git.addWorktree(
            repositoryRoot: root,
            at: destination,
            branch: "feature/one",
            creatingFrom: nil
        )
        try Data("branch-only".utf8).write(to: destination.appendingPathComponent("branch.txt"))
        try run(["-C", destination.path, "add", "."])
        try run(["-C", destination.path, "commit", "-m", "branch work"])

        let result = try await git.removeWorktree(
            repositoryRoot: root,
            at: destination,
            deletingBranch: true
        )
        let remainingBranches = try await git.branches(at: root)

        XCTAssertFalse(result.branchDeleted)
        XCTAssertNotNil(result.branchDeletionFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(remainingBranches.contains { $0.name == "feature/one" })
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

    /// `git worktree add <path> origin/x` succeeds and detaches HEAD, leaving a
    /// checkout whose commits belong to no branch. A caller that named a branch
    /// never meant that, so it is refused before any directory is created.
    func testRefusesARemoteBranchThatWouldDetachHead() async throws {
        let clone = try makeClone()
        let destination = clone.deletingLastPathComponent()
            .appendingPathComponent("wt-remote", isDirectory: true)

        do {
            _ = try await git.addWorktree(
                repositoryRoot: clone,
                at: destination,
                branch: "origin/feature/one",
                creatingFrom: nil
            )
            XCTFail("a remote-tracking branch must not be checked out directly")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("is not a local branch"),
                "the refusal must name the reason, got: \(error)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path),
                "the refusal must come before any directory exists"
            )
            let worktrees = try await git.worktrees(at: clone)
            XCTAssertEqual(worktrees.count, 1, "only the primary checkout remains")
        }
    }

    /// The supported way to work on a colleague's branch: a local branch cut from
    /// the remote ref, which Git also gives an upstream.
    func testCreatesATrackingLocalBranchFromARemoteStartPoint() async throws {
        let clone = try makeClone()
        let destination = clone.deletingLastPathComponent()
            .appendingPathComponent("wt-tracking", isDirectory: true)

        let created = try await git.addWorktree(
            repositoryRoot: clone,
            at: destination,
            branch: "feature/one",
            creatingFrom: "origin/feature/one"
        )

        XCTAssertEqual(created.branch, "feature/one")
        XCTAssertEqual(
            try capture(["-C", clone.path, "rev-parse", "--abbrev-ref", "feature/one@{upstream}"]),
            "origin/feature/one"
        )
    }

    /// A clone of the scratch repository, so `refs/remotes/origin/*` is real Git
    /// state rather than a hand-written ref.
    private func makeClone() throws -> URL {
        let clone = root.deletingLastPathComponent()
            .appendingPathComponent("byori-clone-\(UUID().uuidString)/repo", isDirectory: true)
        addTeardownBlock { [clone] in
            try? FileManager.default.removeItem(at: clone.deletingLastPathComponent())
        }
        try run(["clone", root.path, clone.path])
        return clone
    }

    private func capture(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Branch names become directory names, and they may contain slashes and
/// characters that are awkward or unsafe in a path.
final class WorkspaceWorktreeSlugTests: XCTestCase {
    private func slug(_ branch: String) -> String {
        // Mirrors LiveWorkspaceDataSource.slug, which lives in the app target.
        let mapped = branch.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(scalar)
                : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = collapsed.isEmpty ? "branch" : collapsed
        return String(trimmed.prefix(60))
    }

    func testFlattensPathSeparatorsAndTraversal() {
        XCTAssertEqual(slug("feature/one"), "feature-one")
        XCTAssertEqual(slug("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(slug("release/2026.08"), "release-2026-08")
        XCTAssertEqual(slug("///"), "branch")
        XCTAssertEqual(slug("keeps_underscores-and-dashes"), "keeps_underscores-and-dashes")
        XCTAssertLessThanOrEqual(slug(String(repeating: "a", count: 200)).count, 60)
    }
}
