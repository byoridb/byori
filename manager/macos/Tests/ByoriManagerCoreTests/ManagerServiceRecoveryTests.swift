import Foundation
import XCTest
@testable import ByoriManagerCore

final class ManagerServiceRecoveryTests: XCTestCase {
    func testManagedUnresponsiveServiceRestartsOnceAndVerifies() async throws {
        let fixture = try RecoveryServiceFixture()
        defer { fixture.remove() }
        let runner = RecoveryServiceRunner(paths: fixture.paths, state: .unresponsive)
        let service = fixture.service(runner: runner, graph: RecoveryServiceGraph())
        let before = await service.runtimeRecoveryStatus()
        XCTAssertEqual(before.diagnosis, .unresponsive)
        _ = try await service.recoverRuntime(automatic: true)
        let after = await service.runtimeRecoveryStatus()
        XCTAssertEqual(after.lastAttempt?.action, .restart)
        XCTAssertEqual(after.lastAttempt?.outcome, .verified)
        let mutations = await runner.mutations
        XCTAssertEqual(mutations, [["kickstart", fixture.paths.serviceLabel]])
    }

    func testExplicitStopIsRememberedByANewServiceInstance() async throws {
        let fixture = try RecoveryServiceFixture()
        defer { fixture.remove() }
        let runner = RecoveryServiceRunner(paths: fixture.paths, state: .running)
        let graph = RecoveryServiceGraph()
        _ = try await fixture.service(runner: runner, graph: graph).stopService()
        let restartedApp = fixture.service(runner: runner, graph: graph)
        let report = await restartedApp.runtimeRecoveryStatus()
        XCTAssertEqual(report.diagnosis, .stopped)
        XCTAssertTrue(report.userStopped)
        XCTAssertFalse(report.canRecoverAutomatically)
        do { _ = try await restartedApp.recoverRuntime(automatic: true); XCTFail("must honor the persisted stop") }
        catch RuntimeRecoveryError.userStopped {}
        let mutations = await runner.mutations
        XCTAssertEqual(mutations, [["bootout", fixture.paths.serviceLabel]])
    }

    func testStoppedOwnedConfigurationStartsOnceAndVerifiesAuthenticatedGraph() async throws {
        let fixture = try RecoveryServiceFixture()
        defer { fixture.remove() }
        let runner = RecoveryServiceRunner(paths: fixture.paths, state: .stopped)
        let graph = RecoveryServiceGraph()
        let service = fixture.service(runner: runner, graph: graph)
        let before = await service.runtimeRecoveryStatus()
        XCTAssertEqual(before.diagnosis, .stopped)
        _ = try await service.recoverRuntime()
        let after = await service.runtimeRecoveryStatus()
        XCTAssertEqual(after.diagnosis, .healthy)
        XCTAssertEqual(after.lastAttempt?.outcome, .verified)
        let mutations = await runner.mutations
        XCTAssertEqual(mutations, [["bootstrap", fixture.paths.launchAgent.path]])
        let verifications = await graph.verifications
        XCTAssertGreaterThan(verifications, 0)
        let unexpected = await runner.unexpectedCommands
        XCTAssertTrue(unexpected.isEmpty)
    }

    func testForeignListenerNeverReceivesCredentialsOrAServiceMutation() async throws {
        let fixture = try RecoveryServiceFixture()
        defer { fixture.remove() }
        let runner = RecoveryServiceRunner(paths: fixture.paths, state: .foreign)
        let graph = RecoveryServiceGraph()
        let service = fixture.service(runner: runner, graph: graph)
        let status = await service.runtimeRecoveryStatus()
        XCTAssertEqual(status.diagnosis, .foreignListener)
        do { _ = try await service.recoverRuntime(); XCTFail("foreign listener must be refused") }
        catch RuntimeRecoveryError.refused(.foreignListener) {}
        let verifications = await graph.verifications
        let mutations = await runner.mutations
        XCTAssertEqual(verifications, 0)
        XCTAssertTrue(mutations.isEmpty)
    }

    func testBadCredentialIsDiagnosedWithoutRestartingManagedService() async throws {
        let fixture = try RecoveryServiceFixture()
        defer { fixture.remove() }
        let runner = RecoveryServiceRunner(paths: fixture.paths, state: .running)
        let graph = RecoveryServiceGraph(error: .authenticationFailed)
        let service = fixture.service(runner: runner, graph: graph)
        let status = await service.runtimeRecoveryStatus()
        XCTAssertEqual(status.diagnosis, .authenticationFailed)
        do { _ = try await service.recoverRuntime(); XCTFail("bad credentials must be refused") }
        catch RuntimeRecoveryError.refused(.authenticationFailed) {}
        let mutations = await runner.mutations
        XCTAssertTrue(mutations.isEmpty)
    }

    func testLowDiskRefusesRecoveryBeforeCommandsOrAuthentication() async throws {
        let fixture = try RecoveryServiceFixture()
        defer { fixture.remove() }
        let runner = RecoveryServiceRunner(paths: fixture.paths, state: .stopped)
        let graph = RecoveryServiceGraph()
        let service = fixture.service(runner: runner, graph: graph, freeBytes: 0)
        let status = await service.runtimeRecoveryStatus()
        XCTAssertEqual(status.diagnosis, .diskLow)
        do { _ = try await service.recoverRuntime(); XCTFail("low disk must be refused") }
        catch RuntimeRecoveryError.refused(.diskLow) {}
        let commandCount = await runner.commandCount
        let verifications = await graph.verifications
        XCTAssertEqual(commandCount, 0)
        XCTAssertEqual(verifications, 0)
    }

    func testInspectionFailureDoesNotGetMisclassifiedAsStopped() async throws {
        let fixture = try RecoveryServiceFixture()
        defer { fixture.remove() }
        let runner = RecoveryServiceRunner(paths: fixture.paths, state: .probeFailure)
        let service = fixture.service(runner: runner, graph: RecoveryServiceGraph())
        let status = await service.runtimeRecoveryStatus()
        XCTAssertEqual(status.diagnosis, .inspectionFailed)
        do { _ = try await service.recoverRuntime(); XCTFail("unknown service identity must refuse") }
        catch RuntimeRecoveryError.refused(.inspectionFailed) {}
        let mutations = await runner.mutations
        XCTAssertTrue(mutations.isEmpty)
    }

    func testServiceChangeBetweenDiagnosisAndActionIsRefused() async throws {
        let fixture = try RecoveryServiceFixture()
        defer { fixture.remove() }
        let runner = RecoveryServiceRunner(paths: fixture.paths, state: .stoppedThenForeign)
        let graph = RecoveryServiceGraph()
        let service = fixture.service(runner: runner, graph: graph)
        do { _ = try await service.recoverRuntime(); XCTFail("new listener must be refused") }
        catch RuntimeRecoveryError.refused(.foreignListener) {}
        let mutations = await runner.mutations
        let verifications = await graph.verifications
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertEqual(verifications, 0)
    }

    func testUnverifiedMutationIsRecordedAsFailureRatherThanSuccess() async throws {
        let fixture = try RecoveryServiceFixture()
        defer { fixture.remove() }
        let runner = RecoveryServiceRunner(paths: fixture.paths, state: .stopped)
        let service = fixture.service(runner: runner, graph: RecoveryServiceGraph(error: .authenticationFailed))
        do { _ = try await service.recoverRuntime(); XCTFail("zero exit code is not verified recovery") }
        catch RuntimeRecoveryError.verificationFailed(.authenticationFailed) {}
        let status = await service.runtimeRecoveryStatus()
        XCTAssertEqual(status.lastAttempt?.outcome, .failed)
        XCTAssertEqual(status.lastAttempt?.diagnosis, .authenticationFailed)
        XCTAssertEqual(status.attemptsUsed, 1)
    }
}

private struct RecoveryServiceFixture {
    let root: URL
    let paths: ManagerPaths
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("byori-recovery-service-\(UUID())")
        paths = ManagerPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"),
                             httpPort: 49_991, graphPort: 49_992, serviceLabel: "test.byori.recovery.\(UUID())")
        let fm = FileManager.default
        try fm.createDirectory(at: paths.serverBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in [paths.serverBinary, paths.byoriHome.appendingPathComponent("bin/run-server.sh")] {
            try Data("#!/bin/sh\nexit 97\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try Data("BYORIDB_ROOT_PASSWORD=fake-not-a-real-secret\n".utf8)
            .write(to: paths.byoriHome.appendingPathComponent("env"))
        try fm.createDirectory(at: paths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": paths.serviceLabel,
            "ProgramArguments": ["/bin/sh", paths.byoriHome.appendingPathComponent("bin/run-server.sh").path],
            "WorkingDirectory": paths.byoriHome.path,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: paths.launchAgent)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func service(runner: RecoveryServiceRunner, graph: RecoveryServiceGraph, freeBytes: Int64 = 1_000_000_000) -> ManagerService {
        ManagerService(paths: paths, runner: runner, graphProvider: graph, recoveryDiskFreeBytes: { _ in freeBytes })
    }
}

/// No process runner fallback, ever. Unknown commands are test failures.
private actor RecoveryServiceRunner: CommandRunning {
    enum State { case stopped, running, unresponsive, foreign, probeFailure, stoppedThenForeign }
    let paths: ManagerPaths
    var state: State
    var mutations: [[String]] = []
    var unexpectedCommands: [String] = []
    var commandCount = 0
    private var printCount = 0
    init(paths: ManagerPaths, state: State) { self.paths = paths; self.state = state }
    func run(_ command: CommandSpec) async -> CommandResult {
        commandCount += 1
        let arguments = command.arguments
        if command.executable == "/bin/launchctl", arguments.count == 2,
           arguments[0] == "print", arguments[1] == "gui/\(getuid())/\(paths.serviceLabel)" {
            printCount += 1
            if state == .stoppedThenForeign && printCount > 1 { state = .foreign }
            if state == .probeFailure { return CommandResult(exitCode: 5, output: "Permission denied") }
            if state == .stopped || state == .stoppedThenForeign {
                return CommandResult(exitCode: 113, output: "Could not find service \(paths.serviceLabel)")
            }
            return CommandResult(exitCode: 0, output: "pid = 12345\narguments = {\n/bin/sh\n\(paths.byoriHome.path)/bin/run-server.sh\n}")
        }
        if command.executable == "/usr/sbin/lsof",
           arguments == ["-nP", "-iTCP:\(paths.httpPort)", "-sTCP:LISTEN", "-Fp"] {
            switch state {
            case .stopped, .stoppedThenForeign, .unresponsive: return CommandResult(exitCode: 1, output: "")
            case .foreign: return CommandResult(exitCode: 0, output: "p99999\n")
            default: return CommandResult(exitCode: 0, output: "p12345\n")
            }
        }
        if command.executable == "/usr/sbin/lsof",
           arguments == ["-nP", "-a", "-p", "12345", "-iTCP:\(paths.httpPort)", "-sTCP:LISTEN", "-Fp"] {
            return CommandResult(exitCode: 0, output: "p12345\n")
        }
        if command.executable == "/bin/launchctl", arguments.count == 3,
           arguments[0] == "bootstrap", arguments[1] == "gui/\(getuid())", arguments[2] == paths.launchAgent.path {
            mutations.append(["bootstrap", arguments[2]])
            state = .running
            return CommandResult(exitCode: 0, output: "")
        }
        if command.executable == "/bin/launchctl",
           arguments == ["kickstart", "-k", "gui/\(getuid())/\(paths.serviceLabel)"] {
            mutations.append(["kickstart", paths.serviceLabel])
            state = .running
            return CommandResult(exitCode: 0, output: "")
        }
        if command.executable == "/bin/launchctl",
           arguments == ["bootout", "gui/\(getuid())/\(paths.serviceLabel)"] {
            mutations.append(["bootout", paths.serviceLabel])
            state = .stopped
            return CommandResult(exitCode: 0, output: "")
        }
        unexpectedCommands.append(command.executable + " " + arguments.joined(separator: " "))
        XCTFail("Unexpected fake runner command: \(command.executable)")
        return CommandResult(exitCode: 99, output: "unexpected fake command")
    }
}

private actor RecoveryServiceGraph: KnowledgeGraphProviding {
    let error: KnowledgeGraphClientError?
    var verifications = 0
    init(error: KnowledgeGraphClientError? = nil) { self.error = error }
    func verifyConnection(paths: ManagerPaths) async throws {
        verifications += 1
        if let error { throw error }
    }
    func loadGraph(paths: ManagerPaths, nodeLimit: Int, space: String) async throws -> KnowledgeGraphSnapshot {
        XCTFail("recovery must not pick an arbitrary project space")
        throw KnowledgeGraphClientError.queryFailed
    }
    func loadBodies(paths: ManagerPaths, requests: [KnowledgeBodyRequest], space: String) async throws -> [Int64: String] {
        XCTFail("recovery must not load project memory")
        throw KnowledgeGraphClientError.queryFailed
    }
}
