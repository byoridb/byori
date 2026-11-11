import Darwin
import Foundation
import XCTest
@testable import ByoriManagerCore

final class VerificationFingerprintTests: XCTestCase {
    func testContentEditsAtSameHEADAndPorcelainChangeFingerprint() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        let printer = GitVerificationFingerprinter()
        try fixture.write("fixture.txt", "first dirty input")
        let first = await printer.capture(root: fixture.root)
        let status = try await fixture.git(["status", "--porcelain=v1", "-z"])
        try fixture.write("fixture.txt", "other dirty input")
        let second = await printer.capture(root: fixture.root)
        let nextStatus = try await fixture.git(["status", "--porcelain=v1", "-z"])
        XCTAssertTrue(first.complete, first.reason ?? "")
        XCTAssertTrue(second.complete, second.reason ?? "")
        XCTAssertEqual(first.revision, second.revision)
        XCTAssertEqual(status, nextStatus)
        XCTAssertNotEqual(first.digest, second.digest)
        XCTAssertFalse(first.matches(second))
    }

    func testAdditionDeletionAndIndexOnlyChangeAreIncluded() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        let printer = GitVerificationFingerprinter()
        let original = await printer.capture(root: fixture.root)
        try fixture.write("document.pdf", "all formats count, including binary and configuration")
        let added = await printer.capture(root: fixture.root)
        _ = try await fixture.git(["add", "--", "document.pdf"])
        let staged = await printer.capture(root: fixture.root)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("fixture.txt"))
        let deleted = await printer.capture(root: fixture.root)
        XCTAssertTrue([original, added, staged, deleted].allSatisfy(\.complete))
        XCTAssertEqual(original.revision, deleted.revision)
        XCTAssertNotEqual(original.digest, added.digest)
        XCTAssertNotEqual(added.digest, staged.digest, "Index metadata changed with identical working tree bytes")
        XCTAssertNotEqual(staged.digest, deleted.digest)
    }

    func testExactWhitespaceAndNewlinePathsAreIncluded() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        try fixture.write(" leading.txt", "alpha")
        try fixture.write("line\nbreak.txt", "beta")
        try fixture.write("trailing.txt ", "gamma")
        _ = try await fixture.git(["add", "--", " leading.txt", "line\nbreak.txt"])
        let printer = GitVerificationFingerprinter()
        let before = await printer.capture(root: fixture.root)
        try fixture.write("line\nbreak.txt", "zeta")
        let after = await printer.capture(root: fixture.root)
        XCTAssertTrue(before.complete, before.reason ?? "")
        XCTAssertTrue(after.complete, after.reason ?? "")
        XCTAssertEqual(before.files, 4)
        XCTAssertNotEqual(before.digest, after.digest)
    }

    func testIgnoredFilesAreOutsideDeclaredCoverage() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        try fixture.write(".gitignore", "dependencies/\n")
        try fixture.write("dependencies/cache.bin", "old cache")
        let printer = GitVerificationFingerprinter()
        let before = await printer.capture(root: fixture.root)
        try fixture.write("dependencies/cache.bin", "new cache of different size")
        try fixture.write("dependencies/another.bin", "another ignored input")
        let after = await printer.capture(root: fixture.root)
        XCTAssertTrue(before.complete, before.reason ?? "")
        XCTAssertTrue(after.complete, after.reason ?? "")
        XCTAssertTrue(before.matches(after))
        XCTAssertTrue(after.coverage.contains("Ignored files"))
    }

    func testFileByteAndTimeCapsFailClosed() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        let cases: [(VerificationFingerprintLimits, String)] = [
            (.init(maxFiles: 0), "file_limit"),
            (.init(maxBytes: 1), "byte_limit"),
            (.init(maxFileBytes: 1), "file_byte_limit"),
            (.init(maxOutputBytes: 1), "inventory_limit"),
            (.init(maxDuration: 0), "time_limit"),
        ]
        for (limits, reason) in cases {
            let result = await GitVerificationFingerprinter(limits: limits).capture(root: fixture.root)
            XCTAssertFalse(result.complete)
            XCTAssertNil(result.digest)
            XCTAssertEqual(result.reason, reason)
            XCTAssertFalse(result.matches(result))
        }
    }

    func testTruncationEncodingTimeoutAndCancellationFailClosed() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        let cases: [(CommandResult, String)] = [
            (.init(exitCode: 0, output: "", outputTruncated: true), "inventory_limit"),
            (.init(exitCode: 0, output: "", outputEncodingValid: false), "invalid_path_encoding"),
            (.init(exitCode: 0, output: "", timedOut: true), "time_limit"),
            (.init(exitCode: 0, output: "", cancelled: true), "cancelled"),
        ]
        for (commandResult, reason) in cases {
            let printer = GitVerificationFingerprinter(runner: FingerprintResultRunner(result: commandResult))
            let result = await printer.capture(root: fixture.root)
            XCTAssertFalse(result.complete)
            XCTAssertNil(result.digest)
            XCTAssertEqual(result.reason, reason)
        }
    }

    func testSymlinkEscapeAndSpecialFileAreUnverified() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = fixture.root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let result = await GitVerificationFingerprinter().capture(root: fixture.root)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.reason, "symlink")
        XCTAssertNil(result.digest)
        try FileManager.default.removeItem(at: link)
        // Git does not list untracked FIFOs. A tracked regular file replaced by
        // one must still be rejected without waiting for a writer.
        let tracked = fixture.root.appendingPathComponent("fixture.txt")
        try FileManager.default.removeItem(at: tracked)
        XCTAssertEqual(tracked.path.withCString { mkfifo($0, 0o600) }, 0)
        let special = await GitVerificationFingerprinter().capture(root: fixture.root)
        XCTAssertFalse(special.complete)
        XCTAssertEqual(special.reason, "unsupported_file")
    }

    func testTrackedParentSymlinkCannotEscapeRootDescriptor() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        try fixture.write("nested/file.txt", "local input")
        _ = try await fixture.git(["add", "--", "nested/file.txt"])
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("nested"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("nested"),
            withDestinationURL: fixture.root.deletingLastPathComponent()
        )
        let result = await GitVerificationFingerprinter().capture(root: fixture.root)
        XCTAssertFalse(result.complete)
        XCTAssertNil(result.digest)
    }

    func testSubmoduleIndexEntryIsUnverified() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        let head = try await fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await fixture.git(["update-index", "--add", "--cacheinfo", "160000,\(head),submodule"])
        let result = await GitVerificationFingerprinter().capture(root: fixture.root)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.reason, "submodule")
        XCTAssertNil(result.digest)
    }

    func testWrongRootAndMissingHEADAreUnverified() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        try fixture.write("nested/file.txt", "input")
        let wrong = await GitVerificationFingerprinter().capture(root: fixture.root.appendingPathComponent("nested"))
        XCTAssertFalse(wrong.complete)
        XCTAssertEqual(wrong.reason, "not_git_root")
        let empty = try await FingerprintFixture.create(commit: false)
        defer { empty.remove() }
        let unborn = await GitVerificationFingerprinter().capture(root: empty.root)
        XCTAssertFalse(unborn.complete)
        XCTAssertEqual(unborn.reason, "unverified_head")
    }

    func testFileEditDuringReinventoryInvalidatesObservation() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        let runner = FingerprintMutatingRunner(root: fixture.root)
        let result = await GitVerificationFingerprinter(runner: runner).capture(root: fixture.root)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.reason, "changed_during_scan")
        XCTAssertNil(result.digest)
    }

    func testFileEditDuringFinalRootQueryInvalidatesObservation() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        let runner = FingerprintMutatingRunner(root: fixture.root, trigger: "--show-toplevel")
        let result = await GitVerificationFingerprinter(runner: runner).capture(root: fixture.root)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.reason, "changed_during_scan")
        XCTAssertNil(result.digest)
    }

    func testGitCommandsDisableHooksAndRemoveOverrides() async throws {
        let fixture = try await FingerprintFixture.create()
        defer { fixture.remove() }
        let runner = FingerprintRecordingRunner()
        let result = await GitVerificationFingerprinter(runner: runner).capture(root: fixture.root)
        XCTAssertTrue(result.complete, result.reason ?? "")
        let commands = await runner.commands
        XCTAssertFalse(commands.isEmpty)
        for command in commands {
            XCTAssertEqual(command.executable, "/usr/bin/git")
            XCTAssertTrue(command.arguments.contains("core.fsmonitor=false"))
            XCTAssertTrue(command.environmentRemovals.contains("GIT_INDEX_FILE"))
            XCTAssertTrue(command.environmentRemovals.contains("BYORIDB_PASSWORD"))
            XCTAssertTrue(command.preserveOutputWhitespace)
            XCTAssertLessThanOrEqual(command.timeout, 5)
        }
    }

    func testMatchingIgnoresCheckTimeButRequiresCompleteIdentity() {
        let first = VerificationFingerprint(root: "/project", revision: "head", digest: "digest", complete: true, checkedAt: .distantPast)
        let second = VerificationFingerprint(root: "/project", revision: "head", digest: "digest", complete: true, checkedAt: .distantFuture)
        XCTAssertTrue(first.matches(second))
        XCTAssertFalse(first.matches(.init(root: "/other", revision: "head", digest: "digest", complete: true)))
        XCTAssertFalse(first.matches(.init(root: "/project", revision: "head", digest: "digest", complete: false)))
        let incomplete = VerificationFingerprint(root: "/project", complete: false)
        XCTAssertFalse(incomplete.matches(incomplete))
    }
}

private struct FingerprintFixture {
    let root: URL

    static func create(commit: Bool = true) async throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-fingerprint-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Self(root: root)
        do {
            _ = try await fixture.git(["init", "-b", "main"])
            try fixture.write("fixture.txt", "initial input")
            if commit {
                _ = try await fixture.git(["add", "--", "fixture.txt"])
                _ = try await fixture.git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--no-gpg-sign", "-m", "fixture"])
            }
            return fixture
        } catch { fixture.remove(); throw error }
    }

    func write(_ path: String, _ contents: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    func git(_ arguments: [String]) async throws -> String {
        let result = await ProcessCommandRunner().run(CommandSpec(
            executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", root.path] + arguments,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            workingDirectory: root.path, preserveOutputWhitespace: true,
            environmentRemovals: Set(ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("GIT_") })
        ))
        guard result.succeeded else { throw NSError(domain: "FingerprintFixture", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: result.output]) }
        return result.output
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct FingerprintResultRunner: CommandRunning {
    let result: CommandResult
    func run(_ command: CommandSpec) async -> CommandResult { result }
}

private actor FingerprintMutatingRunner: CommandRunning {
    let root: URL
    let trigger: String
    private var inventoryCalls = 0
    init(root: URL, trigger: String = "--stage") { self.root = root; self.trigger = trigger }
    func run(_ command: CommandSpec) async -> CommandResult {
        if command.arguments.contains(trigger) {
            inventoryCalls += 1
            if inventoryCalls == 2 {
                try? Data("changed during the observation".utf8).write(to: root.appendingPathComponent("fixture.txt"))
            }
        }
        return await ProcessCommandRunner().run(command)
    }
}

private actor FingerprintRecordingRunner: CommandRunning {
    private(set) var commands: [CommandSpec] = []
    func run(_ command: CommandSpec) async -> CommandResult {
        commands.append(command)
        return await ProcessCommandRunner().run(command)
    }
}
