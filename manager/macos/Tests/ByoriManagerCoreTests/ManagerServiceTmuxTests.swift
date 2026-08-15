import XCTest
@testable import ByoriManagerCore

/// The tmux install is the one Settings action that runs a package manager on the
/// user's behalf, so what it executes and what it accepts as done are pinned
/// here. A command that exits zero without producing a tmux Byori will use has
/// not finished the job, and reporting it as success would leave sessions dying
/// with the app while Settings claimed otherwise.
final class ManagerServiceTmuxTests: XCTestCase {
    private var temporaryRoot: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-service-tmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        paths = ManagerPaths(home: temporaryRoot, runtimeRoot: temporaryRoot)
        // Both live in the temporary home's `~/.local/bin`, which ManagerPaths
        // searches first, so the machine's own tmux and brew cannot decide the
        // outcome of these tests.
        try makeExecutable(named: "tmux")
        try makeExecutable(named: "brew")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    /// An unsupported tmux is already installed, so brew has to be asked to
    /// upgrade it. `brew install` would refuse and be reported as a failure.
    func testUnsupportedVersionRunsBrewUpgradeAndVerifiesTheResult() async throws {
        let runner = ScriptedRunner(tmuxVersions: ["tmux 3.1c", "tmux 3.5a"])
        let service = ManagerService(paths: paths, runner: runner)

        let result = try await service.installTmux()

        XCTAssertTrue(result.summary.contains("3.5a"), result.summary)
        let brewCommands = await runner.brewCommands()
        let brew = try XCTUnwrap(brewCommands.first)
        XCTAssertEqual(brew.arguments, ["upgrade", "tmux"])
        XCTAssertEqual(
            brew.environment["HOMEBREW_NO_AUTO_UPDATE"],
            "1",
            "a tmux install must not turn into a formula index update"
        )
    }

    /// brew exiting zero is not the commit boundary: the boundary is a tmux that
    /// Byori's own probe accepts.
    func testSucceedingCommandWithAnUnusableTmuxIsAFailure() async throws {
        let runner = ScriptedRunner(tmuxVersions: ["tmux 3.1c"])
        let service = ManagerService(paths: paths, runner: runner)

        do {
            _ = try await service.installTmux()
            XCTFail("an unusable tmux must not be reported as installed")
        } catch let error as ManagerError {
            guard case let .verificationFailed(message) = error else {
                return XCTFail("expected a verification failure, got \(error)")
            }
            XCTAssertTrue(message.contains("3.1c"), message)
        }
    }

    /// Nothing to do is its own outcome. Running brew anyway would either fail or
    /// spend minutes reinstalling a working tmux.
    func testUsableTmuxRunsNoPackageManagerCommand() async throws {
        let runner = ScriptedRunner(tmuxVersions: ["tmux 3.5a"])
        let service = ManagerService(paths: paths, runner: runner)

        let result = try await service.installTmux()

        XCTAssertTrue(result.summary.contains("이미"), result.summary)
        let brewCommands = await runner.brewCommands()
        XCTAssertTrue(brewCommands.isEmpty, "brew was run for a tmux that already works")
    }

    private func makeExecutable(named name: String) throws {
        let directory = temporaryRoot.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
}

/// Answers `tmux -V` from a script and records every brew invocation.
private actor ScriptedRunner: CommandRunning {
    private var tmuxVersions: [String]
    private var brewInvocations: [CommandSpec] = []

    init(tmuxVersions: [String]) {
        self.tmuxVersions = tmuxVersions
    }

    func brewCommands() -> [CommandSpec] { brewInvocations }

    func run(_ command: CommandSpec) async -> CommandResult {
        if command.executable.hasSuffix("/tmux") {
            let version = tmuxVersions.count > 1
                ? tmuxVersions.removeFirst()
                : (tmuxVersions.first ?? "")
            return CommandResult(exitCode: 0, output: version)
        }
        if command.executable.hasSuffix("/brew") {
            brewInvocations.append(command)
            return CommandResult(exitCode: 0, output: "==> Upgrading tmux")
        }
        return CommandResult(exitCode: 0, output: "")
    }
}
