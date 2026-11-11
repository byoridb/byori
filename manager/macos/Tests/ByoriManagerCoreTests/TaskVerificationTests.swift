import Foundation
import XCTest
@testable import ByoriManagerCore

final class TaskVerificationTests: XCTestCase {
    func testPassRequiresMatchingInputsAndUnchangedCommandDefinition() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let fingerprinter = VerificationTestFingerprint()
        let runner = VerificationTestRunner(result: .init(exitCode: 0, output: "  tests passed\n"))
        let service = fixture.service(runner: runner, fingerprinter: fingerprinter)
        let command = VerificationCommand(id: "tests", name: "Tests", executable: "/usr/bin/true", arguments: ["literal;argument"])
        try await service.saveProfile(projectID: fixture.scope.projectID, commands: [command])
        let ticket = try await service.prepareRun(scope: fixture.scope, commandID: command.id)
        let receipt = try await service.executeRun(ticket)
        XCTAssertEqual(receipt.output, "  tests passed\n")
        let passed = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(passed.requiredAssessment.state, .passed)
        let calls = await runner.commands
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments, ["literal;argument"])
        XCTAssertEqual(calls[0].workingDirectory, fixture.scope.root.path)
        XCTAssertEqual(calls[0].environment["BYORI_TASK_ID"], fixture.scope.taskID)
        XCTAssertTrue(calls[0].environmentRemovals.contains("BYORIDB_PASSWORD"))
        XCTAssertTrue(calls[0].preserveOutputWhitespace)
        XCTAssertTrue(calls[0].terminateProcessGroupOnExit)

        await fingerprinter.setDigest("edited-at-same-HEAD")
        let staleCode = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(staleCode.requiredAssessment.state, .stale)
        await fingerprinter.setDigest("original")
        var changed = command
        changed.arguments = ["different"]
        try await service.saveProfile(projectID: fixture.scope.projectID, commands: [changed])
        let staleCommand = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(staleCommand.requiredAssessment.state, .stale)
    }

    func testChangedDuringCommandAndIncompleteFingerprintNeverPass() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let changing = VerificationSequenceFingerprint(digests: ["before", "after", "after"])
        let service = fixture.service(fingerprinter: changing)
        let command = try await fixture.configure(service)
        let ticket = try await service.prepareRun(scope: fixture.scope, commandID: command.id)
        _ = try await service.executeRun(ticket)
        let changed = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(changed.requiredAssessment.state, .stale)

        let incomplete = VerificationTestFingerprint(complete: false)
        let reloaded = fixture.service(fingerprinter: incomplete)
        let next = try await reloaded.prepareRun(scope: fixture.scope, commandID: command.id)
        _ = try await reloaded.executeRun(next)
        let snapshot = try await reloaded.snapshot(scope: fixture.scope)
        XCTAssertEqual(snapshot.requiredAssessment.state, .unverified)
        XCTAssertFalse(snapshot.requiredAssessment.canComplete)
    }

    func testNoRequiredCommandsAndNeverRunAreNotPassing() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let service = fixture.service()
        let empty = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(empty.requiredAssessment.state, .notConfigured)
        let command = try await fixture.configure(service)
        let pending = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(pending.requiredAssessment.state, .notRun)
        var optional = command; optional.required = false
        try await service.saveProfile(projectID: fixture.scope.projectID, commands: [optional])
        let noRequired = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(noRequired.requiredAssessment.state, .notConfigured)
    }

    func testFailureTimeoutAndCancellationRemainDistinct() async throws {
        for (result, outcome, state) in [
            (CommandResult(exitCode: 2, output: "failure"), VerificationOutcome.failed, VerificationState.failed),
            (CommandResult(exitCode: 0, output: "timeout", timedOut: true), .timedOut, .timedOut),
            (CommandResult(exitCode: 0, output: "cancel", cancelled: true), .cancelled, .cancelled),
        ] {
            let fixture = try await VerificationFixture.make()
            defer { fixture.remove() }
            let service = fixture.service(runner: VerificationTestRunner(result: result))
            let command = try await fixture.configure(service)
            let ticket = try await service.prepareRun(scope: fixture.scope, commandID: command.id)
            let receipt = try await service.executeRun(ticket)
            XCTAssertEqual(receipt.outcome, outcome)
            let snapshot = try await service.snapshot(scope: fixture.scope)
            XCTAssertEqual(snapshot.requiredAssessment.state, state)
        }
    }

    func testReservationBlocksConcurrentCheckoutAndProfileEditAndReloadInterruptsPending() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let service = fixture.service()
        let command = try await fixture.configure(service)
        _ = try await service.prepareRun(scope: fixture.scope, commandID: command.id)
        let running = await service.isRunning(taskID: fixture.scope.taskID, root: fixture.scope.root)
        XCTAssertTrue(running)
        do { _ = try await service.prepareRun(scope: fixture.scope, commandID: command.id); XCTFail("Second run must be rejected") }
        catch VerificationError.running {}
        do { try await service.saveProfile(projectID: fixture.scope.projectID, commands: []); XCTFail("Active profile must be stable") }
        catch VerificationError.running {}
        let reloaded = fixture.service()
        let snapshot = try await reloaded.snapshot(scope: fixture.scope)
        XCTAssertEqual(snapshot.requiredAssessment.state, .interrupted)
        XCTAssertNil(snapshot.receipts.first?.finishedAt)
    }

    func testTaskCancellationFinalizesReceiptAndReleasesReservation() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let runner = VerificationCancellationRunner()
        let service = fixture.service(runner: runner)
        let command = try await fixture.configure(service)
        let ticket = try await service.prepareRun(scope: fixture.scope, commandID: command.id)
        let execution = Task { try await service.executeRun(ticket) }
        await runner.waitUntilStarted()
        execution.cancel()
        let receipt = try await execution.value
        XCTAssertEqual(receipt.outcome, .cancelled)
        XCTAssertNotNil(receipt.finishedAt)
        let running = await service.isRunning()
        XCTAssertFalse(running)
        let snapshot = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(snapshot.requiredAssessment.state, .cancelled)
        do { _ = try await service.executeRun(ticket); XCTFail("Ticket must be single use") }
        catch VerificationError.invalidTicket {}
    }

    func testScopeValidationArchiveAndLateWriteNeverResurrectTask() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let artifacts = TaskArtifactStore(home: fixture.home)
        let bytes = Data("artifact".utf8)
        try artifacts.write(scope: fixture.scope, name: "workflow.json", data: bytes, byteLimit: 100)
        let wrong = VerificationScope(projectID: "wrong", checkoutID: fixture.scope.checkoutID,
                                      taskID: fixture.scope.taskID, root: fixture.scope.root)
        XCTAssertThrowsError(try artifacts.read(scope: wrong, name: "workflow.json", byteLimit: 100))
        _ = try await fixture.tasks.archiveTask(id: fixture.scope.taskID)
        XCTAssertThrowsError(try artifacts.write(scope: fixture.scope, name: "workflow.json", data: bytes, byteLimit: 100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("tasks/\(fixture.scope.taskID)").path))
        XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent("archived-tasks/\(fixture.scope.taskID)/workflow.json")), bytes)
    }

    func testReceiptHistoryOutputAndPermissionsAreBounded() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let service = fixture.service(runner: VerificationTestRunner(result: .init(exitCode: 0, output: String(repeating: "x", count: 70_000))))
        let command = try await fixture.configure(service)
        for _ in 0..<32 {
            let ticket = try await service.prepareRun(scope: fixture.scope, commandID: command.id)
            _ = try await service.executeRun(ticket)
        }
        let snapshot = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(snapshot.receipts.count, 30)
        XCTAssertTrue(snapshot.receipts.allSatisfy { $0.output.utf8.count == 65_536 && $0.outputTruncated })
        let receiptPath = fixture.home.appendingPathComponent("tasks/\(fixture.scope.taskID)/verification.json").path
        let profilePath = fixture.home.appendingPathComponent("verification-profiles/\(fixture.scope.projectID).json").path
        for path in [receiptPath, profilePath] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let directory = try FileManager.default.attributesOfItem(atPath: fixture.home.appendingPathComponent("verification-profiles").path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testCorruptAndSymlinkedArtifactsFailClosed() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let service = fixture.service()
        _ = try await fixture.configure(service)
        let receiptURL = fixture.home.appendingPathComponent("tasks/\(fixture.scope.taskID)/verification.json")
        try Data("{broken".utf8).write(to: receiptURL)
        do { _ = try await service.snapshot(scope: fixture.scope); XCTFail("Corrupt history must be visible") }
        catch VerificationError.persistence {}
        try FileManager.default.removeItem(at: receiptURL)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: receiptURL, withDestinationURL: outside)
        let artifacts = TaskArtifactStore(home: fixture.home)
        XCTAssertThrowsError(try artifacts.read(scope: fixture.scope, name: "verification.json", byteLimit: 100))
        XCTAssertThrowsError(try artifacts.write(scope: fixture.scope, name: "verification.json", data: Data(), byteLimit: 100))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
    }

    func testMultibyteOutputTruncatesAtValidUTF8Boundary() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let service = fixture.service(runner: VerificationTestRunner(result: .init(exitCode: 0, output: String(repeating: "가", count: 24_000))))
        let command = try await fixture.configure(service)
        let ticket = try await service.prepareRun(scope: fixture.scope, commandID: command.id)
        let receipt = try await service.executeRun(ticket)
        XCTAssertTrue(receipt.outputTruncated)
        XCTAssertEqual(receipt.output.utf8.count, 65_535)
        XCTAssertFalse(receipt.output.contains("�"))
        let loaded = try await service.snapshot(scope: fixture.scope)
        XCTAssertEqual(loaded.receipts.first?.output, receipt.output)
    }

    func testInvalidProfilesCannotBeSaved() async throws {
        let fixture = try await VerificationFixture.make()
        defer { fixture.remove() }
        let service = fixture.service()
        let command = VerificationCommand(name: "Tests", executable: "/usr/bin/true")
        for timeout in [0, 1_801, Double.infinity, Double.nan] {
            var invalid = command; invalid.timeout = timeout
            XCTAssertThrowsError(try invalid.validate())
        }
        XCTAssertThrowsError(try VerificationProfile(commands: [command, command]).validate())
        var invalid = command; invalid.arguments = ["bad\0argument"]
        do { try await service.saveProfile(projectID: fixture.scope.projectID, commands: [invalid]); XCTFail("NUL argv is invalid") }
        catch {}
        let profile = try await service.profile(projectID: fixture.scope.projectID)
        XCTAssertTrue(profile.commands.isEmpty)
    }
}

private struct VerificationFixture {
    let root: URL
    let home: URL
    let scope: VerificationScope
    let tasks: WorkspaceTaskStore
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byori-verification-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent(".byori")
        let tasks = WorkspaceTaskStore(home: home, idGenerator: { "task-test" })
        let task = try await tasks.createTask(projectID: "project-test", checkout: .init(kind: .sourceTree, id: "source-test"), title: "Verification")
        return Self(root: root, home: home, scope: .init(projectID: task.projectID, checkoutID: task.checkout.id, taskID: task.id, root: root), tasks: tasks)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func service(runner: any CommandRunning = VerificationTestRunner(result: .init(exitCode: 0, output: "")),
                 fingerprinter: any VerificationFingerprinting = VerificationTestFingerprint()) -> TaskVerificationService {
        TaskVerificationService(home: home, paths: .init(home: root, runtimeRoot: root, serviceLabel: "com.byori.test.verification.\(UUID().uuidString)"), runner: runner, fingerprinter: fingerprinter)
    }
    func configure(_ service: TaskVerificationService) async throws -> VerificationCommand {
        let command = VerificationCommand(id: "tests", name: "Tests", executable: "/usr/bin/true")
        try await service.saveProfile(projectID: scope.projectID, commands: [command])
        return command
    }
}

private actor VerificationTestRunner: CommandRunning {
    let result: CommandResult
    private(set) var commands: [CommandSpec] = []
    init(result: CommandResult) { self.result = result }
    func run(_ command: CommandSpec) async -> CommandResult { commands.append(command); return result }
}

private actor VerificationTestFingerprint: VerificationFingerprinting {
    private var digest = "original"
    private let complete: Bool
    init(complete: Bool = true) { self.complete = complete }
    func setDigest(_ digest: String) { self.digest = digest }
    func capture(root: URL) async -> VerificationFingerprint {
        .init(root: root.path, revision: "HEAD", digest: digest, complete: complete)
    }
}

private actor VerificationSequenceFingerprint: VerificationFingerprinting {
    private var digests: [String]
    init(digests: [String]) { self.digests = digests }
    func capture(root: URL) async -> VerificationFingerprint {
        let digest = digests.count > 1 ? digests.removeFirst() : digests[0]
        return .init(root: root.path, revision: "HEAD", digest: digest, complete: true)
    }
}

private actor VerificationCancellationRunner: CommandRunning {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func run(_ command: CommandSpec) async -> CommandResult {
        started = true
        waiters.forEach { $0.resume() }; waiters = []
        do { try await Task.sleep(nanoseconds: 60_000_000_000) }
        catch { return .init(exitCode: 0, output: "", cancelled: true) }
        return .init(exitCode: 1, output: "Test command should have been cancelled")
    }
}
