import Darwin
import XCTest
@testable import ByoriManagerCore

/// Temporary homes and a recording runner only. No launchctl or engine runs.
final class ManagerServiceRuntimeRecoveryTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let originals = [
        "bin/byoridb-server": "engine-old", "bin/byori": "cli-old",
        "byoridb_mcp.py": "mcp-old", "env": "fixture-secret-old", "engine.json": "manifest-old",
    ]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("byori-recovery-\(UUID())")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("fixture installer".utf8).write(to: runtime.appendingPathComponent("install.sh"))
        let bin = root.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bin.appendingPathComponent("python3"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent("python3").path)
        paths = ManagerPaths(home: root, runtimeRoot: runtime)
        try FileManager.default.createDirectory(at: paths.byoriHome.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.byoriHome.path)
        for (name, content) in originals { try Data(content.utf8).write(to: paths.byoriHome.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: paths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist-old".utf8).write(to: paths.launchAgent)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSafeFailedInstallRestoresManifestAndAllRuntimeBytesTogether() async throws {
        let runner = RecoveryRunner(paths: paths)
        await expectInstallFailure(ManagerService(paths: paths, runner: runner))
        for (name, content) in originals {
            XCTAssertEqual(try String(contentsOf: paths.byoriHome.appendingPathComponent(name)), content)
        }
        XCTAssertEqual(try String(contentsOf: paths.launchAgent), "plist-old")
        let commands = await runner.commands()
        let install = try XCTUnwrap(commands.first { $0.executable == "/bin/bash" })
        XCTAssertNotNil(install.runtimeLeaseFileDescriptor)
        XCTAssertEqual(install.environment["BYORI_RUNTIME_LEASE_FD"], "9")
        XCTAssertTrue(install.arguments.contains("--no-hooks"))
        let stopped = try XCTUnwrap(commands.first { $0.arguments.first == "bootout" })
        XCTAssertNotNil(stopped.runtimeLeaseFileDescriptor)
        try RuntimeMutationLease.acquire(home: paths.byoriHome).release()
    }

    func testExistingDataRefusesOldEngineRollbackWithoutDeletingAnyRuntimeBytes() async throws {
        try makeData()
        let runner = RecoveryRunner(paths: paths)
        let message = await expectInstallFailure(ManagerService(paths: paths, runner: runner))
        XCTAssertTrue(message.contains("데이터"), message)
        XCTAssertEqual(try String(contentsOf: paths.serverBinary), "engine-new")
        XCTAssertEqual(try String(contentsOf: paths.engineManifest), "manifest-new")
        XCTAssertEqual(try String(contentsOf: paths.byoriHome.appendingPathComponent("data/original")), "data-original")
        let commands = await runner.commands()
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: paths.backups.path).isEmpty)
        try RuntimeMutationLease.acquire(home: paths.byoriHome).release()
    }

    func testSameEngineAssetsCanRestoreWithoutTouchingExistingData() async throws {
        try makeData()
        let runner = RecoveryRunner(paths: paths, changeEngine: false)
        await expectInstallFailure(ManagerService(paths: paths, runner: runner))
        XCTAssertEqual(try String(contentsOf: paths.serverBinary), "engine-old")
        XCTAssertEqual(try String(contentsOf: paths.engineManifest), "manifest-old")
        XCTAssertEqual(try String(contentsOf: paths.byoriHome.appendingPathComponent("data/original")), "data-original")
    }

    func testMissingSnapshotFailsBeforeDeletingLiveFiles() async throws {
        let runner = RecoveryRunner(paths: paths, damage: .missing)
        await expectInstallFailure(ManagerService(paths: paths, runner: runner))
        XCTAssertEqual(try String(contentsOf: paths.serverBinary), "engine-new")
        XCTAssertEqual(try String(contentsOf: paths.engineManifest), "manifest-new")
        let commands = await runner.commands()
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" })
    }

    func testChangedSnapshotFailsBeforeDeletingLiveFiles() async throws {
        let runner = RecoveryRunner(paths: paths, damage: .changed)
        await expectInstallFailure(ManagerService(paths: paths, runner: runner))
        XCTAssertEqual(try String(contentsOf: paths.serverBinary), "engine-new")
        XCTAssertEqual(try String(contentsOf: paths.byoriHome.appendingPathComponent("env")), "env-new")
        let commands = await runner.commands()
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" })
    }

    func testBusyLeaseBlocksInstallAndAllServiceMutationsBeforeRunnerCommands() async throws {
        let lease = try RuntimeMutationLease.acquire(home: paths.byoriHome)
        defer { lease.release() }
        let runner = RecoveryRunner(paths: paths)
        let service = ManagerService(paths: paths, runner: runner)
        for operation in 0..<4 {
            do {
                switch operation {
                case 0: _ = try await service.installOrUpdateByori()
                case 1: _ = try await service.startService()
                case 2: _ = try await service.stopService()
                default: _ = try await service.restartService()
                }
                XCTFail("A held lease must reject every mutation")
            } catch { XCTAssertEqual(error as? RuntimeMutationLeaseError, .busy) }
        }
        let commands = await runner.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testActorReentrancyAndCancellationCannotReleaseLeaseBeforeRollbackFinishes() async throws {
        let runner = RecoveryRunner(paths: paths, gateInstall: true, gateRollback: true)
        let service = ManagerService(paths: paths, runner: runner)
        let operation = Task { () -> String in
            do { _ = try await service.installOrUpdateByori(); return "unexpected success" }
            catch { return error.localizedDescription }
        }
        try await waitFor(runner, phase: "install")
        do { _ = try await service.stopService(); XCTFail("reentrant writer acquired lease") }
        catch { XCTAssertEqual(error as? RuntimeMutationLeaseError, .busy) }
        operation.cancel()
        await runner.releaseInstall()
        try await waitFor(runner, phase: "rollback")
        XCTAssertThrowsError(try RuntimeMutationLease.acquire(home: paths.byoriHome)) { error in
            XCTAssertEqual(error as? RuntimeMutationLeaseError, .busy)
        }
        await runner.releaseRollback()
        let failure = await operation.value
        XCTAssertNotEqual(failure, "unexpected success")
        XCTAssertEqual(try String(contentsOf: paths.engineManifest), "manifest-old")
        try RuntimeMutationLease.acquire(home: paths.byoriHome).release()
    }

    func testRuntimeSymlinksAreRejectedBeforeInstallerExecution() async throws {
        let env = paths.byoriHome.appendingPathComponent("env")
        try FileManager.default.removeItem(at: env)
        let outside = root.appendingPathComponent("unrelated")
        try Data("unrelated".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: env, withDestinationURL: outside)
        let runner = RecoveryRunner(paths: paths)
        await expectInstallFailure(ManagerService(paths: paths, runner: runner))
        let commands = await runner.commands()
        XCTAssertFalse(commands.contains { $0.executable == "/bin/bash" })
        XCTAssertEqual(try String(contentsOf: outside), "unrelated")
    }

    func testDataWrittenDuringStopPreventsEngineRollback() async throws {
        let runner = RecoveryRunner(paths: paths, gateRollback: true)
        let service = ManagerService(paths: paths, runner: runner)
        let operation = Task { try? await service.installOrUpdateByori() }
        try await waitFor(runner, phase: "rollback")
        try makeData()
        await runner.releaseRollback()
        _ = await operation.value
        XCTAssertEqual(try String(contentsOf: paths.serverBinary), "engine-new")
        XCTAssertEqual(try String(contentsOf: paths.engineManifest), "manifest-new")
    }

    func testOccupiedEnginePortPreventsAllRuntimeReplacement() async throws {
        let runner = RecoveryRunner(paths: paths, occupiedPort: true)
        await expectInstallFailure(ManagerService(paths: paths, runner: runner))
        XCTAssertEqual(try String(contentsOf: paths.serverBinary), "engine-new")
        XCTAssertEqual(try String(contentsOf: paths.engineManifest), "manifest-new")
    }

    func testUnknownInitialServiceStateAbortsBeforeInstallerAndSnapshot() async throws {
        let runner = RecoveryRunner(paths: paths, unknownInitialState: true)
        let message = await expectInstallFailure(ManagerService(paths: paths, runner: runner))
        XCTAssertTrue(message.contains("설치 전 상태"), message)
        let commands = await runner.commands()
        XCTAssertFalse(commands.contains { $0.executable == "/bin/bash" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backups.path))
        XCTAssertEqual(try String(contentsOf: paths.serverBinary), "engine-old")
        try RuntimeMutationLease.acquire(home: paths.byoriHome).release()
    }

    private func makeData() throws {
        let data = paths.byoriHome.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("data-original".utf8).write(to: data.appendingPathComponent("original"))
    }

    @discardableResult private func expectInstallFailure(_ service: ManagerService) async -> String {
        do { _ = try await service.installOrUpdateByori(); XCTFail("expected failure"); return "" }
        catch { return error.localizedDescription }
    }

    private func waitFor(_ runner: RecoveryRunner, phase: String) async throws {
        for _ in 0..<500 {
            if await runner.phase() == phase { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        await runner.releaseInstall()
        await runner.releaseRollback()
        XCTFail("runner did not enter \(phase)")
        throw CancellationError()
    }
}

private actor RecoveryRunner: CommandRunning {
    enum Damage: Sendable { case missing, changed }
    let paths: ManagerPaths
    let changeEngine: Bool
    let damage: Damage?
    let gateInstall: Bool
    let gateRollback: Bool
    let occupiedPort: Bool
    let unknownInitialState: Bool
    var history: [CommandSpec] = []
    var currentPhase = ""
    var installGate: CheckedContinuation<Void, Never>?
    var rollbackGate: CheckedContinuation<Void, Never>?

    init(paths: ManagerPaths, changeEngine: Bool = true, damage: Damage? = nil,
         gateInstall: Bool = false, gateRollback: Bool = false, occupiedPort: Bool = false,
         unknownInitialState: Bool = false) {
        self.paths = paths; self.changeEngine = changeEngine; self.damage = damage
        self.gateInstall = gateInstall; self.gateRollback = gateRollback
        self.occupiedPort = occupiedPort
        self.unknownInitialState = unknownInitialState
    }

    func run(_ command: CommandSpec) async -> CommandResult {
        history.append(command)
        if unknownInitialState, command.arguments.first == "print" {
            return CommandResult(exitCode: 1, output: "probe failed", timedOut: true)
        }
        if command.executable == "/bin/bash" {
            currentPhase = "install"
            if gateInstall { await withCheckedContinuation { installGate = $0 } }
            do {
                if changeEngine { try Data("engine-new".utf8).write(to: paths.serverBinary) }
                for (name, content) in ["bin/byori": "cli-new", "env": "env-new", "engine.json": "manifest-new", "byoridb_mcp.py": "mcp-new"] {
                    try Data(content.utf8).write(to: paths.byoriHome.appendingPathComponent(name))
                }
                try Data("plist-new".utf8).write(to: paths.launchAgent)
                if let damage {
                    let snapshot = try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil).first!
                    let saved = snapshot.appendingPathComponent("env")
                    switch damage {
                    case .missing: try FileManager.default.removeItem(at: saved)
                    case .changed: try Data("corrupted".utf8).write(to: saved)
                    }
                }
            } catch { return CommandResult(exitCode: 98, output: "fixture setup failed") }
            return CommandResult(exitCode: 1, output: "synthetic install failure")
        }
        if command.arguments.first == "bootout" {
            currentPhase = "rollback"
            if gateRollback { await withCheckedContinuation { rollbackGate = $0 } }
            return CommandResult(exitCode: 0, output: "")
        }
        if command.executable == "/usr/sbin/lsof" {
            return CommandResult(exitCode: occupiedPort ? 0 : 1, output: occupiedPort ? "p1234" : "")
        }
        return CommandResult(exitCode: 113, output: "not loaded")
    }

    func commands() -> [CommandSpec] { history }
    func phase() -> String { currentPhase }
    func releaseInstall() { installGate?.resume(); installGate = nil }
    func releaseRollback() { rollbackGate?.resume(); rollbackGate = nil }
}
