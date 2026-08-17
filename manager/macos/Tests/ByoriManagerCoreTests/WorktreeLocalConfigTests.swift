import XCTest
@testable import ByoriManagerCore

final class WorktreeLocalConfigTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-worktree-config-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("primary", isDirectory: true)
        destination = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCarriesLocalConfigThatGitWouldNotProvide() throws {
        try write(".env", in: source, contents: "TOKEN=local")
        try write(".envrc", in: source, contents: "use flake")
        try write(".tool-versions", in: source, contents: "python 3.13.0")

        let carried = WorktreeLocalConfig().carry(from: source, to: destination)

        XCTAssertEqual(carried, [".env", ".envrc", ".tool-versions"])
        XCTAssertEqual(try read(".env", in: destination), "TOKEN=local")
        XCTAssertEqual(try read(".envrc", in: destination), "use flake")
    }

    /// A `.env` is usually 0600. Landing it at 0644 in the new worktree would
    /// quietly widen access to a credential.
    func testCopyKeepsRestrictivePermissions() throws {
        try write(".env", in: source, contents: "TOKEN=local")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: source.appendingPathComponent(".env").path
        )

        WorktreeLocalConfig().carry(from: source, to: destination)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent(".env").path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testNestedCandidateCreatesItsDirectory() throws {
        let nested = source.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(".claude/settings.local.json", in: source, contents: "{}")

        let carried = WorktreeLocalConfig().carry(from: source, to: destination)

        XCTAssertEqual(carried, [".claude/settings.local.json"])
        XCTAssertEqual(try read(".claude/settings.local.json", in: destination), "{}")
    }

    func testNeverOverwritesWhatTheWorktreeAlreadyHas() throws {
        try write(".env", in: source, contents: "TOKEN=primary")
        try write(".env", in: destination, contents: "TOKEN=worktree")

        let carried = WorktreeLocalConfig().carry(from: source, to: destination)

        XCTAssertTrue(carried.isEmpty)
        XCTAssertEqual(try read(".env", in: destination), "TOKEN=worktree")
    }

    /// The allowlist exists so that creating a worktree never turns into copying
    /// a dependency directory or a build cache.
    func testIgnoresDirectoriesAndUnlistedPaths() throws {
        let modules = source.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try write("node_modules/index.js", in: source, contents: "// large")
        try write("secrets.txt", in: source, contents: "not on the list")
        let envDirectory = source.appendingPathComponent(".env.local", isDirectory: true)
        try FileManager.default.createDirectory(at: envDirectory, withIntermediateDirectories: true)

        let carried = WorktreeLocalConfig().carry(from: source, to: destination)

        XCTAssertTrue(carried.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("node_modules").path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent(".env.local").path)
        )
    }

    func testSkipsAFileOverTheSizeLimit() throws {
        let oversized = String(repeating: "x", count: WorktreeLocalConfig.byteLimit + 1)
        try write(".env", in: source, contents: oversized)

        XCTAssertTrue(WorktreeLocalConfig().plan(from: source, to: destination).isEmpty)
    }

    func testSkipsSymlinks() throws {
        try write("real-env", in: source, contents: "TOKEN=local")
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent(".env"),
            withDestinationURL: source.appendingPathComponent("real-env")
        )

        XCTAssertTrue(WorktreeLocalConfig().plan(from: source, to: destination).isEmpty)
    }

    private func write(_ relativePath: String, in directory: URL, contents: String) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(relativePath))
    }

    private func read(_ relativePath: String, in directory: URL) throws -> String {
        String(decoding: try Data(contentsOf: directory.appendingPathComponent(relativePath)), as: UTF8.self)
    }
}
