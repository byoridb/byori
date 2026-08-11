import XCTest
@testable import ByoriManagerCore

/// These pin the exact tmux command lines Byori runs. Getting one wrong does
/// not fail loudly at build time — it starts a session that silently dies with
/// the app, or attaches to the wrong thing.
final class TmuxSessionPlanTests: XCTestCase {
    private var temporaryRoot: URL!
    private var workingDirectory: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-tmux-tests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = temporaryRoot.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        paths = ManagerPaths(home: temporaryRoot, runtimeRoot: temporaryRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    /// `-A` is what makes a relaunch reattach instead of failing on a name that
    /// already exists, and the CLI must arrive after `--` as separate argv
    /// entries so tmux does not hand the words to a shell.
    func testAttachOrCreatePassesTheCLIAfterASeparator() throws {
        let descriptor = try makeDescriptor(arguments: ["--session-id", "abc"])
        let plan = TmuxSupport.attachOrCreate(
            descriptor,
            tmux: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
            configFile: URL(fileURLWithPath: "/conf/tmux.conf")
        )

        XCTAssertEqual(plan.executable.path, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(plan.sessionName, TmuxSupport.sessionName(for: descriptor.id))

        let separator = try XCTUnwrap(plan.arguments.firstIndex(of: "--"))
        XCTAssertEqual(
            Array(plan.arguments[(separator + 1)...]),
            [descriptor.executable.path, "--session-id", "abc"]
        )

        let head = Array(plan.arguments[..<separator])
        XCTAssertEqual(head.prefix(3), ["-f", "/conf/tmux.conf", "new-session"])
        XCTAssertTrue(head.contains("-A"), "without -A a relaunch cannot reattach")
        XCTAssertEqual(value(after: "-s", in: head), plan.sessionName)
        XCTAssertEqual(
            value(after: "-c", in: head),
            descriptor.workingDirectory.resolvingSymlinksInPath().path
        )
    }

    /// The tmux *server* may already be running from an earlier session, so it
    /// cannot inherit this launch's environment. `-e` is the only way the
    /// variables reach the CLI.
    func testEveryEnvironmentEntryIsPassedWithItsOwnFlag() throws {
        let descriptor = try makeDescriptor(
            environmentOverrides: ["BYORIDB_MEMORY_SPACE": "demo", "EXTRA": "value"]
        )
        let plan = TmuxSupport.attachOrCreate(
            descriptor,
            tmux: URL(fileURLWithPath: "/bin/tmux"),
            configFile: URL(fileURLWithPath: "/conf/tmux.conf")
        )
        let separator = try XCTUnwrap(plan.arguments.firstIndex(of: "--"))
        let head = Array(plan.arguments[..<separator])

        var passed: [String] = []
        for (index, argument) in head.enumerated() where argument == "-e" {
            passed.append(head[index + 1])
        }
        XCTAssertTrue(passed.contains("BYORIDB_MEMORY_SPACE=demo"))
        XCTAssertTrue(passed.contains("EXTRA=value"))
        XCTAssertEqual(passed.count, descriptor.environmentArray.count)
    }

    func testSessionNamesRoundTripAndAreNamespaced() {
        let id = UUID()
        let name = TmuxSupport.sessionName(for: id)

        XCTAssertTrue(name.hasPrefix("byori-"))
        XCTAssertEqual(TmuxSupport.sessionID(fromSessionName: name), id)
        XCTAssertNil(TmuxSupport.sessionID(fromSessionName: "work"))
        XCTAssertNil(TmuxSupport.sessionID(fromSessionName: "byori-not-a-uuid"))
    }

    /// A user's own tmux sessions share the server. Reattaching to one, or
    /// reporting it as a Byori session, would be worse than missing one.
    func testOnlyByoriSessionsAreRecognisedInAListing() {
        let mine = UUID()
        let output = """
        work
        byori-\(mine.uuidString.lowercased())
        byori-garbage
        \("")
        scratch
        """

        XCTAssertEqual(TmuxSupport.liveSessionIDs(fromListOutput: output), [mine])
        XCTAssertTrue(
            TmuxSupport.liveSessionIDs(fromListOutput: "no server running on /tmp/tmux-501/default")
                .isEmpty
        )
        XCTAssertTrue(TmuxSupport.liveSessionIDs(fromListOutput: "").isEmpty)
    }

    func testKillAndListCommandsCarryTheByoriConfig() {
        let config = URL(fileURLWithPath: "/conf/tmux.conf")
        XCTAssertEqual(
            TmuxSupport.killSessionArguments(configFile: config, sessionName: "byori-x"),
            ["-f", "/conf/tmux.conf", "kill-session", "-t", "byori-x"]
        )
        XCTAssertEqual(
            TmuxSupport.listSessionsArguments(configFile: config),
            ["-f", "/conf/tmux.conf", "list-sessions", "-F", "#{session_name}"]
        )
    }

    func testVersionParsingAcceptsTheShapesTmuxActuallyPrints() {
        // Verified against a real `tmux -V` on 3.7b.
        XCTAssertEqual(TmuxSupport.version(fromVersionOutput: "tmux 3.7b\n"), "3.7b")
        XCTAssertEqual(TmuxSupport.version(fromVersionOutput: "tmux 3.5a\n"), "3.5a")
        XCTAssertEqual(TmuxSupport.version(fromVersionOutput: "tmux next-3.6"), "next-3.6")
        XCTAssertNil(TmuxSupport.version(fromVersionOutput: "command not found"))
        XCTAssertNil(TmuxSupport.version(fromVersionOutput: "tmux "))
    }

    /// A patch suffix is not a number, so a naive string compare would read
    /// "3.2a" as older than "3.2" and refuse a version that works.
    func testVersionComparisonHandlesPatchLettersAndPrereleases() {
        XCTAssertTrue(TmuxSupport.isAtLeast("3.2"))
        XCTAssertTrue(TmuxSupport.isAtLeast("3.2a"))
        XCTAssertTrue(TmuxSupport.isAtLeast("3.5a"))
        XCTAssertTrue(TmuxSupport.isAtLeast("3.7b"))
        XCTAssertTrue(TmuxSupport.isAtLeast("next-3.6"))
        XCTAssertTrue(TmuxSupport.isAtLeast("10.0"))

        XCTAssertFalse(TmuxSupport.isAtLeast("3.1c"))
        XCTAssertFalse(TmuxSupport.isAtLeast("2.9"))
        // Unparsable must refuse rather than assume new enough: guessing wrong
        // means passing -e to a tmux that drops it, and the CLI starts without
        // the environment Byori promised it.
        XCTAssertFalse(TmuxSupport.isAtLeast("unknown"))
        XCTAssertFalse(TmuxSupport.isAtLeast(""))
    }

    /// The config is what keeps tmux invisible: a prefix key would swallow a
    /// chord from the CLI, and destroy-unattached would defeat the whole point.
    func testConfigurationKeepsTmuxOutOfTheWay() {
        let contents = TmuxConfiguration.fileContents

        XCTAssertTrue(contents.contains("set -g prefix None"))
        XCTAssertTrue(contents.contains("unbind C-b"))
        XCTAssertTrue(contents.contains("set -g destroy-unattached off"))
        XCTAssertTrue(contents.contains("set -g status off"))
        XCTAssertTrue(contents.contains("set -sg escape-time 0"))
    }

    func testConfigurationIsWrittenToAByoriOwnedPath() async throws {
        let service = TmuxSessionService(paths: paths)
        let file = try await service.prepareConfiguration()

        XCTAssertEqual(file, paths.tmuxConfig)
        XCTAssertTrue(file.path.hasSuffix("/.byori-manager/tmux.conf"))
        XCTAssertFalse(
            file.path.hasSuffix("/.tmux.conf"),
            "Byori must not write the user's own tmux config"
        )
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            TmuxConfiguration.fileContents
        )

        // Rewriting is idempotent, so a launch does not churn the file.
        let again = try await service.prepareConfiguration()
        XCTAssertEqual(
            try String(contentsOf: again, encoding: .utf8),
            TmuxConfiguration.fileContents
        )
    }

    /// Unusable tmux has to degrade quietly at every entry point: a session must
    /// still start, it just will not outlive the app.
    ///
    /// Driven through a stubbed runner rather than the machine's real tmux, so
    /// the result does not depend on whether the developer happens to have it
    /// installed — the bug this guards against is a *broken* command being
    /// built, which only shows up when tmux is present but unusable.
    func testUnusableTmuxDegradesInsteadOfFailing() async throws {
        let descriptor = try makeDescriptor()

        for stub in [
            CommandResult(exitCode: 127, output: ""),
            CommandResult(exitCode: 0, output: "not tmux at all"),
            CommandResult(exitCode: 0, output: "tmux 2.9"),
        ] {
            let service = TmuxSessionService(
                paths: paths,
                runner: StubRunner(result: stub),
                fileManager: .default
            )

            let availability = await service.availability()
            XCTAssertFalse(availability.isAvailable, "\(stub.output) was treated as usable")
            let plan = await service.launchPlan(for: descriptor)
            XCTAssertNil(plan, "unusable tmux must mean no plan, not a broken command")
            let live = await service.liveSessionIDs()
            XCTAssertTrue(live.isEmpty)
            let killed = await service.killSession(id: descriptor.id)
            XCTAssertFalse(killed)
        }
    }

    /// The version gate has to let a usable tmux through, or the backend is
    /// dead code that silently never engages.
    func testUsableTmuxProducesAPlan() async throws {
        let service = TmuxSessionService(
            paths: paths,
            runner: StubRunner(result: CommandResult(exitCode: 0, output: "tmux 3.7b")),
            fileManager: .default
        )
        // Resolved from PATH, so this only runs where tmux is actually present.
        try XCTSkipIf(
            paths.executable(named: "tmux") == nil,
            "tmux is not installed on this machine"
        )

        let availability = await service.availability()
        XCTAssertTrue(availability.isAvailable)
        let plan = await service.launchPlan(for: try makeDescriptor())
        XCTAssertEqual(plan?.executable, paths.executable(named: "tmux"))
    }

    private func makeDescriptor(
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:]
    ) throws -> TerminalLaunchDescriptor {
        let executable = temporaryRoot.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let factory = TerminalLaunchDescriptorFactory(paths: paths, environment: [:])
        return try factory.customAgent(
            CustomAgentProvider(
                id: "custom-tool",
                displayName: "Tool",
                executablePath: executable.path,
                defaultArguments: arguments
            ),
            workingDirectory: workingDirectory,
            environmentOverrides: environmentOverrides
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[index + 1]
    }
}

private struct StubRunner: CommandRunning {
    let result: CommandResult

    func run(_ command: CommandSpec) async -> CommandResult { result }
}
