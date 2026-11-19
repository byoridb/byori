import XCTest
@testable import ByoriManagerCore

/// The rollback after a failed install is what left the engine down in #58:
/// "Bootstrap failed: 5: Input/output error". launchd answers a bootstrap with
/// that error both for a job that is still loaded and for a disabled one, so the
/// app now loads the job the way install.sh does and says what launchd saw when
/// it cannot.
final class ManagerServiceLaunchdTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-launchd-\(UUID().uuidString)", isDirectory: true)
        paths = ManagerPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("runtime", isDirectory: true),
            byoriHome: root.appendingPathComponent("byoridb", isDirectory: true),
            httpPort: 1,
            serviceLabel: "test.byori.launchd.\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: paths.serverBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: paths.serverBinary)
        try FileManager.default.createDirectory(
            at: paths.launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("<plist/>".utf8).write(to: paths.launchAgent)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func failInstall(with launchd: FakeLaunchd) async throws -> Error {
        do {
            _ = try await ManagerService(paths: paths, runner: launchd).installOrUpdateByori(engineTag: "v0.4.2")
        } catch {
            return error
        }
        XCTFail("the install was set up to fail")
        throw ManagerError.prerequisite("unreachable")
    }

    /// The incident's shape: the job is still going away when the rollback
    /// loads it again. Bootstrapping then would fail with error 5.
    func testRollbackWaitsForTheJobToLeaveBeforeLoadingItAgain() async throws {
        let launchd = FakeLaunchd(loaded: true, lingerAfterBootout: 2)

        let error = try await failInstall(with: launchd)

        if case ManagerError.rollbackFailed = error { XCTFail("the rollback itself failed: \(error)") }
        let loaded = await launchd.loaded
        XCTAssertTrue(loaded, "the previous engine's job must be loaded again")
        let verbs = await launchd.lifecycleVerbs
        XCTAssertEqual(verbs, ["bootout", "enable", "bootstrap"])
    }

    /// The old uninstall's `unload -w` left the label disabled, which the app's
    /// bare bootstrap could not get past.
    func testRollbackLoadsAJobThatWasLeftDisabled() async throws {
        let launchd = FakeLaunchd(loaded: true, disabledAfterBootout: true)

        _ = try await failInstall(with: launchd)

        let loaded = await launchd.loaded
        XCTAssertTrue(loaded)
    }

    func testABootstrapRefusedForALoadedJobRestartsIt() async throws {
        let launchd = FakeLaunchd(loaded: true, bootoutIsIgnored: true)

        _ = try await failInstall(with: launchd)

        let verbs = await launchd.lifecycleVerbs
        XCTAssertEqual(verbs.suffix(3), ["enable", "bootstrap", "kickstart"])
    }

    func testARollbackThatCannotLoadTheJobSaysWhatLaunchdSaw() async throws {
        let launchd = FakeLaunchd(loaded: true, refusesBootstrap: true)

        let error = try await failInstall(with: launchd)

        let message = error.localizedDescription
        XCTAssertTrue(message.contains("자동 롤백도 실패했습니다"), message)
        XCTAssertTrue(message.contains("Bootstrap failed: 5"), message)
        XCTAssertTrue(message.contains("is not loaded"), message)
    }
}

/// launchd as measured on macOS 27, plus an install command that fails.
private actor FakeLaunchd: CommandRunning {
    private(set) var loaded: Bool
    private var disabled = false
    private var linger = 0
    private let lingerAfterBootout: Int
    private let disabledAfterBootout: Bool
    private let bootoutIsIgnored: Bool
    private let refusesBootstrap: Bool
    private(set) var lifecycleVerbs: [String] = []

    init(
        loaded: Bool,
        lingerAfterBootout: Int = 0,
        disabledAfterBootout: Bool = false,
        bootoutIsIgnored: Bool = false,
        refusesBootstrap: Bool = false
    ) {
        self.loaded = loaded
        self.lingerAfterBootout = lingerAfterBootout
        self.disabledAfterBootout = disabledAfterBootout
        self.bootoutIsIgnored = bootoutIsIgnored
        self.refusesBootstrap = refusesBootstrap
    }

    func run(_ command: CommandSpec) async -> CommandResult {
        if command.executable == "/bin/bash" {
            return CommandResult(exitCode: 1, output: "error: server did not become healthy")
        }
        guard command.executable == "/bin/launchctl", let verb = command.arguments.first else {
            return CommandResult(exitCode: 1, output: "")
        }
        switch verb {
        case "print":
            if linger > 0 {
                linger -= 1
                if linger == 0 { loaded = false }
            }
            return loaded
                ? CommandResult(exitCode: 0, output: "\tstate = running\n\tlast exit code = (never exited)")
                : CommandResult(exitCode: 113, output: "Could not find service")
        case "bootout":
            lifecycleVerbs.append(verb)
            if bootoutIsIgnored { return CommandResult(exitCode: 0, output: "") }
            if disabledAfterBootout { disabled = true }
            if lingerAfterBootout > 0 { linger = lingerAfterBootout } else { loaded = false }
            return CommandResult(exitCode: 0, output: "")
        case "enable":
            lifecycleVerbs.append(verb)
            disabled = false
            return CommandResult(exitCode: 0, output: "")
        case "bootstrap":
            lifecycleVerbs.append(verb)
            if loaded || disabled || refusesBootstrap {
                return CommandResult(exitCode: 5, output: "Bootstrap failed: 5: Input/output error")
            }
            loaded = true
            return CommandResult(exitCode: 0, output: "")
        case "kickstart":
            lifecycleVerbs.append(verb)
            return CommandResult(exitCode: loaded ? 0 : 113, output: "")
        default:
            return CommandResult(exitCode: 1, output: "")
        }
    }
}
