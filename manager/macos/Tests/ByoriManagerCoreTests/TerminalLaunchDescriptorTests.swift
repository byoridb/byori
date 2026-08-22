import XCTest
@testable import ByoriManagerCore

final class TerminalLaunchDescriptorTests: XCTestCase {
    private var temporaryRoot: URL!
    private var workingDirectory: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-terminal-tests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = temporaryRoot.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        paths = ManagerPaths(home: temporaryRoot, runtimeRoot: temporaryRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testClaudeDescriptorUsesInteractiveCLIWithoutShellParsing() throws {
        let executable = try makeExecutable(named: "claude")
        let sessionID = UUID(uuidString: "AD8EFCF7-985E-45E1-9C3E-97AD899E9D01")!
        let factory = TerminalLaunchDescriptorFactory(
            paths: paths,
            environment: ["CUSTOM": "preserved"]
        )

        let descriptor = try factory.codingAgent(
            .claude,
            model: "claude-sonnet-4-5",
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            executableOverride: executable
        )

        XCTAssertEqual(descriptor.target, .codingAgent(.claude))
        XCTAssertEqual(descriptor.model, "claude-sonnet-4-5")
        XCTAssertEqual(descriptor.executable, executable.resolvingSymlinksInPath())
        XCTAssertEqual(
            descriptor.arguments,
            [
                "--model", "claude-sonnet-4-5",
                "--session-id", sessionID.uuidString.lowercased(),
            ]
        )
        XCTAssertFalse(descriptor.arguments.contains("--print"))
        XCTAssertEqual(descriptor.environment["CUSTOM"], "preserved")
        XCTAssertEqual(descriptor.environment["TERM"], "xterm-256color")
        XCTAssertEqual(descriptor.environment["COLORTERM"], "truecolor")
    }

    func testCodexDescriptorUsesInteractiveTUIAndFixedWorkingDirectory() throws {
        let executable = try makeExecutable(named: "codex")
        let factory = TerminalLaunchDescriptorFactory(paths: paths, environment: [:])

        let descriptor = try factory.codingAgent(
            .codex,
            model: "gpt-5.4",
            workingDirectory: workingDirectory,
            executableOverride: executable
        )

        XCTAssertEqual(descriptor.target, .codingAgent(.codex))
        XCTAssertEqual(
            descriptor.arguments,
            ["--model", "gpt-5.4", "--cd", workingDirectory.resolvingSymlinksInPath().path]
        )
        XCTAssertFalse(descriptor.arguments.contains("exec"))
        XCTAssertFalse(descriptor.arguments.contains("--json"))
    }

    func testInteractiveTerminalRemovesInheritedColorSuppression() throws {
        let executable = try makeExecutable(named: "claude")
        let factory = TerminalLaunchDescriptorFactory(
            paths: paths,
            environment: [
                "NO_COLOR": "1",
                "NO_COLOUR": "1",
                "NODE_DISABLE_COLORS": "1",
                "FORCE_COLOR": "0",
                "CLICOLOR": "0",
                "CLICOLOR_FORCE": "0",
                "TERM": "dumb",
            ]
        )

        let descriptor = try factory.codingAgent(
            .claude,
            workingDirectory: workingDirectory,
            executableOverride: executable
        )

        XCTAssertNil(descriptor.environment["NO_COLOR"])
        XCTAssertNil(descriptor.environment["NO_COLOUR"])
        XCTAssertNil(descriptor.environment["NODE_DISABLE_COLORS"])
        XCTAssertNil(descriptor.environment["FORCE_COLOR"])
        XCTAssertNil(descriptor.environment["CLICOLOR_FORCE"])
        XCTAssertEqual(descriptor.environment["TERM"], "xterm-256color")
        XCTAssertEqual(descriptor.environment["COLORTERM"], "truecolor")
        XCTAssertEqual(descriptor.environment["CLICOLOR"], "1")
    }

    func testClaudeGatewayCanReplaceOnlyItsManagedInheritedEnvironment() throws {
        let executable = try makeExecutable(named: "claude")
        let factory = TerminalLaunchDescriptorFactory(
            paths: paths,
            environment: [
                "ANTHROPIC_AUTH_TOKEN": "old-token",
                "ANTHROPIC_API_KEY": "old-api-key",
                "ANTHROPIC_MODEL": "old-model",
                "API_TIMEOUT_MS": "user-timeout",
                "UNRELATED": "preserved",
            ]
        )
        let configuration = ClaudeGatewayConfiguration(
            isEnabled: true,
            baseURL: "https://gateway.example.com",
            model: "new-model"
        )

        let descriptor = try factory.codingAgent(
            .claude,
            workingDirectory: workingDirectory,
            executableOverride: executable,
            environmentOverrides: [
                "ANTHROPIC_BASE_URL": "https://gateway.example.com",
                "ANTHROPIC_AUTH_TOKEN": "new-token",
                "ANTHROPIC_MODEL": "new-model",
            ],
            environmentRemovals: configuration.environmentKeysToReplace
        )

        XCTAssertEqual(descriptor.environment["ANTHROPIC_AUTH_TOKEN"], "new-token")
        XCTAssertNil(descriptor.environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(descriptor.environment["ANTHROPIC_MODEL"], "new-model")
        XCTAssertEqual(descriptor.environment["API_TIMEOUT_MS"], "user-timeout")
        XCTAssertEqual(descriptor.environment["UNRELATED"], "preserved")
    }

    func testCLIModelDefaultIsRecordedWithoutPassingSyntheticModelArgument() throws {
        let executable = try makeExecutable(named: "codex")
        let factory = TerminalLaunchDescriptorFactory(paths: paths, environment: [:])

        let descriptor = try factory.codingAgent(
            .codex,
            model: nil,
            workingDirectory: workingDirectory,
            executableOverride: executable
        )

        XCTAssertEqual(descriptor.modelSelection, .cliDefault)
        XCTAssertNil(descriptor.model)
        XCTAssertEqual(
            descriptor.arguments,
            ["--cd", workingDirectory.resolvingSymlinksInPath().path]
        )
        XCTAssertFalse(descriptor.arguments.contains("default"))
        XCTAssertFalse(descriptor.arguments.contains("--model"))
    }

    func testMissingCodingCLINeverFallsBackToShell() throws {
        let factory = TerminalLaunchDescriptorFactory(
            paths: paths,
            environment: [:],
            fileManager: .default,
            executableResolver: { _ in nil }
        )

        XCTAssertThrowsError(
            try factory.codingAgent(
                .claude,
                model: "sonnet",
                workingDirectory: workingDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? TerminalLaunchDescriptorError,
                .missingExecutable("claude")
            )
        }
    }

    func testSystemShellIsItsOwnTargetAndCarriesNoModel() throws {
        let shell = try makeExecutable(named: "demo-zsh")
        let factory = TerminalLaunchDescriptorFactory(paths: paths, environment: [:])

        let descriptor = try factory.systemShell(
            workingDirectory: workingDirectory,
            executable: shell
        )

        XCTAssertEqual(descriptor.target, .systemShell)
        XCTAssertNil(descriptor.model)
        XCTAssertEqual(descriptor.arguments, ["-l"])
        XCTAssertEqual(descriptor.executable.lastPathComponent, "demo-zsh")
    }

    /// A terminal opened from Byori should behave like the terminal the user
    /// already has — same prompt, same aliases — so it runs their own shell.
    func testSystemShellDefaultsToTheUsersShell() throws {
        let shell = try makeExecutable(named: "fish")
        let factory = TerminalLaunchDescriptorFactory(
            paths: paths,
            environment: ["SHELL": shell.path]
        )

        let descriptor = try factory.systemShell(workingDirectory: workingDirectory)

        XCTAssertEqual(descriptor.executable.resolvingSymlinksInPath().path,
                       shell.resolvingSymlinksInPath().path)
    }

    /// `SHELL` naming a shell that is gone must not refuse a session the user
    /// asked for; the macOS default takes over.
    func testSystemShellFallsBackWhenTheConfiguredShellIsUnusable() throws {
        for value in ["/nonexistent/fish", "fish", ""] {
            let factory = TerminalLaunchDescriptorFactory(
                paths: paths,
                environment: ["SHELL": value]
            )

            let descriptor = try factory.systemShell(workingDirectory: workingDirectory)

            XCTAssertEqual(descriptor.executable.path, "/bin/zsh", "SHELL=\(value)")
        }
    }

    func testRejectsUnsafeModelAndEnvironment() throws {
        let executable = try makeExecutable(named: "codex")
        let factory = TerminalLaunchDescriptorFactory(paths: paths, environment: [:])

        XCTAssertThrowsError(
            try factory.codingAgent(
                .codex,
                model: "gpt-5; open /tmp/unsafe",
                workingDirectory: workingDirectory,
                executableOverride: executable
            )
        ) { error in
            XCTAssertEqual(error as? TerminalLaunchDescriptorError, .invalidModel)
        }

        XCTAssertThrowsError(
            try factory.codingAgent(
                .codex,
                model: "gpt-5.4",
                workingDirectory: workingDirectory,
                executableOverride: executable,
                environmentOverrides: ["INVALID=KEY": "value"]
            )
        ) { error in
            XCTAssertEqual(
                error as? TerminalLaunchDescriptorError,
                .invalidEnvironmentKey("INVALID=KEY")
            )
        }
    }

    private func makeExecutable(named name: String) throws -> URL {
        let executable = temporaryRoot.appendingPathComponent("bin/\(name)")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }
}
