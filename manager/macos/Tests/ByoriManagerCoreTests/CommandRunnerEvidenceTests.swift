import Foundation
import XCTest
@testable import ByoriManagerCore

final class CommandRunnerEvidenceTests: XCTestCase {
    func testRawNULOutputPreservesWhitespaceAndDefaultStillTrims() async {
        let runner = ProcessCommandRunner()
        let raw = await runner.run(.init(executable: "/usr/bin/printf", arguments: ["  x\\000 \\n"], preserveOutputWhitespace: true))
        XCTAssertEqual(raw.output, "  x\0 \n")
        XCTAssertTrue(raw.outputEncodingValid)
        XCTAssertFalse(raw.outputTruncated)
        let normal = await runner.run(.init(executable: "/usr/bin/printf", arguments: ["  value \\n"]))
        XCTAssertEqual(normal.output, "value")
    }

    func testEnvironmentRemovalPrecedesExplicitScopeOverlay() async {
        let runner = ProcessCommandRunner()
        let removed = await runner.run(.init(executable: "/usr/bin/printenv", arguments: ["PATH"], environmentRemovals: ["PATH"]))
        XCTAssertNotEqual(removed.exitCode, 0)
        XCTAssertEqual(removed.output, "")
        let overlaid = await runner.run(.init(executable: "/usr/bin/printenv", arguments: ["PATH"], environment: ["PATH": "verification-test"], environmentRemovals: ["PATH"]))
        XCTAssertEqual(overlaid.output, "verification-test")
    }

    func testOutputTruncationAndInvalidEncodingAreExplicit() async {
        let runner = ProcessCommandRunner()
        let large = await runner.run(.init(executable: "/usr/bin/head", arguments: ["-c", "300000", "/dev/zero"], preserveOutputWhitespace: true))
        XCTAssertTrue(large.succeeded)
        XCTAssertTrue(large.outputTruncated)
        XCTAssertEqual(large.output.utf8.count, 256 * 1_024)
        let invalid = await runner.run(.init(executable: "/usr/bin/printf", arguments: ["\\377"], preserveOutputWhitespace: true))
        XCTAssertTrue(invalid.succeeded)
        XCTAssertFalse(invalid.outputEncodingValid)
    }

    func testRealProcessCancellationReportsCancelledAndNotSuccess() async {
        let execution = Task { await ProcessCommandRunner().run(.init(executable: "/bin/sleep", arguments: ["20"])) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        execution.cancel()
        let result = await execution.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.timedOut)
    }

    func testVerificationCleanupStopsBackgroundWritersBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byori-verification-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("late-write")
        // The deliberately backgrounded writer ignores TERM. The opt-in
        // cleanup must send KILL while retaining the exited leader's PID.
        let result = await ProcessCommandRunner().run(.init(
            executable: "/bin/sh",
            arguments: ["-c", "(trap '' TERM; /bin/sleep 4; /usr/bin/touch \"$1\") & exit 0", "byori-test", marker.path],
            timeout: 10, terminateProcessGroupOnExit: true
        ))
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.cancelled)
        try await Task.sleep(nanoseconds: 2_300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
