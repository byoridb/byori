import XCTest
@testable import ByoriManagerCore

/// tmux is the difference between a session that survives quitting Byori and one
/// that does not, so Settings has to say which of those is true and offer the
/// exact action that changes it. These pin that mapping, including the two states
/// that are easy to conflate: "not installed" and "installed but unusable".
final class TmuxRequirementTests: XCTestCase {
    private var temporaryRoot: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-tmux-requirement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        paths = ManagerPaths(home: temporaryRoot, runtimeRoot: temporaryRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testMissingTmuxOffersAFirstInstall() {
        let status = TmuxStatus(
            availability: .unavailable(.notInstalled),
            install: .homebrew(executablePath: "/opt/homebrew/bin/brew")
        )

        XCTAssertFalse(status.isAvailable)
        XCTAssertTrue(status.canInstall)
        XCTAssertFalse(status.needsUpgrade, "a missing tmux cannot be upgraded")
        XCTAssertEqual(status.actionTitle, "Homebrew로 설치")
        XCTAssertEqual(status.installSubcommand, "install")
        XCTAssertEqual(status.stateLabel, "미설치")
    }

    /// An unsupported tmux needs `brew upgrade`, and describing it as an install
    /// would both read wrong and name the command that refuses to run.
    func testUnsupportedVersionAsksForAnUpgradeAndNamesBothVersions() {
        let status = TmuxStatus(
            availability: .unavailable(.versionTooOld(found: "3.1c", required: "3.2")),
            install: .homebrew(executablePath: "/opt/homebrew/bin/brew")
        )

        XCTAssertTrue(status.needsUpgrade)
        XCTAssertEqual(status.actionTitle, "Homebrew로 업그레이드")
        XCTAssertEqual(status.installSubcommand, "upgrade")
        XCTAssertTrue(status.stateLabel.contains("3.1c"))
        XCTAssertTrue(status.stateLabel.contains("3.2"))
    }

    /// A version Byori could not read is also a tmux that is already on disk, so
    /// the fix is an upgrade rather than an install that brew would refuse.
    func testUnreadableVersionIsTreatedAsAnUpgrade() {
        let status = TmuxStatus(
            availability: .unavailable(.unreadableVersion),
            install: .homebrew(executablePath: "/opt/homebrew/bin/brew")
        )

        XCTAssertTrue(status.needsUpgrade)
        XCTAssertEqual(status.installSubcommand, "upgrade")
    }

    /// A button whose only possible outcome is a failure is worse than none: the
    /// requirement is stated and Homebrew is named instead.
    func testWithoutHomebrewTheRequirementIsStatedRatherThanOffered() {
        let status = TmuxStatus(availability: .unavailable(.notInstalled), install: nil)

        XCTAssertFalse(status.canInstall)
        XCTAssertNil(status.actionTitle)
        XCTAssertTrue(status.detail.contains("Homebrew"))
    }

    func testAvailableTmuxOffersNoActionAndReportsPersistence() {
        let status = TmuxStatus(
            availability: .available(
                executable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
                version: "3.5a"
            ),
            install: .homebrew(executablePath: "/opt/homebrew/bin/brew")
        )

        XCTAssertTrue(status.isAvailable)
        XCTAssertNil(status.actionTitle, "there is nothing left for Byori to do")
        XCTAssertTrue(status.stateLabel.contains("3.5a"))
        XCTAssertFalse(status.detail.isEmpty)
    }

    /// The probe is cached because it spawns a process. Now that Byori installs
    /// tmux itself, a stale cache would report the pre-install version and start
    /// the next session without persistence.
    func testRefreshAvailabilityDropsTheCachedProbe() async throws {
        try makeExecutable(named: "tmux")
        let runner = SequencedRunner(outputs: ["tmux 3.1c", "tmux 3.5a"])
        let service = TmuxSessionService(paths: paths, runner: runner)

        let first = await service.availability()
        XCTAssertEqual(first, .unavailable(.versionTooOld(found: "3.1c", required: "3.2")))

        let cached = await service.availability()
        XCTAssertEqual(cached, first, "a second read must not spawn another process")

        let refreshed = await service.refreshAvailability()
        guard case let .available(_, version) = refreshed else {
            return XCTFail("refresh did not re-read tmux: \(refreshed)")
        }
        XCTAssertEqual(version, "3.5a")
    }

    /// Written into the temporary home's `~/.local/bin`, which `ManagerPaths`
    /// searches first, so the test does not depend on what the machine has.
    private func makeExecutable(named name: String) throws {
        let directory = temporaryRoot.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
}

/// Returns each output once, in order, then repeats the last one.
private actor SequencedRunner: CommandRunning {
    private var outputs: [String]

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func run(_ command: CommandSpec) async -> CommandResult {
        let output = outputs.count > 1 ? outputs.removeFirst() : (outputs.first ?? "")
        return CommandResult(exitCode: 0, output: output)
    }
}
