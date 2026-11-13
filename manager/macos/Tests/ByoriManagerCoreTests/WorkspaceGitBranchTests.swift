import XCTest
@testable import ByoriManagerCore

/// Branch creation changes the user's current checkout, so refusal and success
/// are checked against real Git, including branch pointers and file contents.
final class WorkspaceGitBranchTests: XCTestCase {
    private var root: URL!
    private let git = WorkspaceGitService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try run(["init", "--initial-branch=main"])
        try run(["config", "user.email", "test@example.invalid"])
        try run(["config", "user.name", "Byori Test"])
        try Data("initial".utf8).write(to: root.appendingPathComponent("README.md"))
        try run(["add", "."])
        try run(["commit", "-m", "initial"])
        try run(["branch", "base"])
        try Data("main work".utf8).write(to: root.appendingPathComponent("README.md"))
        try run(["commit", "-am", "advance main"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreatesAndChecksOutBranchFromTheRequestedCommit() async throws {
        let originalMain = try run(["rev-parse", "main"])
        let base = try run(["rev-parse", "base"])

        try await git.createBranch(at: root, name: "byori/fix-parser", startPoint: "base")

        XCTAssertEqual(try run(["branch", "--show-current"]), "byori/fix-parser")
        XCTAssertEqual(try run(["rev-parse", "HEAD"]), base)
        XCTAssertEqual(try run(["rev-parse", "main"]), originalMain)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("README.md")), "initial")
        let worktrees = try await git.worktrees(at: root)
        XCTAssertEqual(worktrees.count, 1, "a branch in this checkout does not create a worktree")
        let status = try await git.status(at: root, maxChanges: 1)
        XCTAssertTrue(status.isClean)
    }

    func testRefusesTrackedChangesWithoutCreatingBranchOrMovingHead() async throws {
        let file = root.appendingPathComponent("README.md")
        try Data("keep my changes".utf8).write(to: file)

        await assertRefused(name: "byori/dirty", startPoint: "base")

        XCTAssertEqual(try String(contentsOf: file), "keep my changes")
        XCTAssertEqual(try run(["branch", "--show-current"]), "main")
        XCTAssertFalse(try run(["branch", "--list", "byori/dirty"]).contains("byori/dirty"))
    }

    func testRefusesUntrackedFilesWithoutTouchingThem() async throws {
        let file = root.appendingPathComponent("unfinished.txt")
        try Data("unsaved work".utf8).write(to: file)

        await assertRefused(name: "byori/untracked", startPoint: "base")

        XCTAssertEqual(try String(contentsOf: file), "unsaved work")
        XCTAssertEqual(try run(["branch", "--show-current"]), "main")
        XCTAssertEqual(try run(["branch", "--list", "byori/untracked"]), "")
    }

    func testRefusesExistingBranchWithoutResettingItsRevision() async throws {
        let originalBase = try run(["rev-parse", "base"])
        let originalHead = try run(["rev-parse", "HEAD"])

        await assertRefused(name: "base", startPoint: "main")

        XCTAssertEqual(try run(["rev-parse", "base"]), originalBase)
        XCTAssertEqual(try run(["rev-parse", "HEAD"]), originalHead)
        XCTAssertEqual(try run(["branch", "--show-current"]), "main")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("README.md")), "main work")
    }

    func testRefusesInvalidOrExpansionBranchNamesWithoutChangingRepository() async throws {
        let originalRefs = try run(["show-ref"])
        for name in ["", "-f", "feature..bad", "feature bad", "@{-1}", "feature\nother", "x.lock"] {
            await assertRefused(name: name, startPoint: "main")
            XCTAssertEqual(try run(["show-ref"]), originalRefs, name)
            XCTAssertEqual(try run(["branch", "--show-current"]), "main", name)
        }
    }

    func testRefusesMissingOrOptionStartPointWithoutLeavingBranch() async throws {
        let originalRefs = try run(["show-ref"])
        for startPoint in ["missing-branch", "--detach", "", "main\nother"] {
            await assertRefused(name: "byori/new", startPoint: startPoint)
            XCTAssertEqual(try run(["show-ref"]), originalRefs, startPoint)
            XCTAssertEqual(try run(["branch", "--show-current"]), "main", startPoint)
        }
    }

    private func assertRefused(name: String, startPoint: String) async {
        do {
            try await git.createBranch(at: root, name: name, startPoint: startPoint)
            XCTFail("Expected branch creation to be refused: \(name) from \(startPoint)")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ByoriGitBranchTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(text)",
            ])
        }
        return text
    }
}
