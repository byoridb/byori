import Foundation
import XCTest
@testable import ByoriManagerCore

final class ManagerServiceIntegrationInventoryTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-mcp-probe-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        paths = ManagerPaths(home: root.appendingPathComponent("home"), runtimeRoot: root)
        for name in ["claude", "codex", "agy"] {
            let executable = paths.home.appendingPathComponent(".local/bin/\(name)")
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHealthyByoriProbeSurvivesGlobalListTimeoutAndRunsOnce() async throws {
        let runner = MCPProbeFixtureRunner(
            list: CommandResult(exitCode: 15, output: "Checking MCP server health...", timedOut: true),
            get: managedGet()
        )
        let result = try await inventory(runner)
        XCTAssertEqual(result.mcpState, .unavailable)
        XCTAssertEqual(result.byoriMCPProbe, ByoriMCPProbe(registrationConfirmed: true, status: .connected))
        XCTAssertEqual(result.mcpServers, [MCPServerSummary(
            agent: .claude, name: "byoridb", status: .connected, management: .byoriManaged
        )])
        let commands = await runner.commands.filter { URL(fileURLWithPath: $0.executable).lastPathComponent == "claude" }
        XCTAssertEqual(commands.filter { $0.arguments == ["mcp", "get", "byoridb"] }.count, 1)
        XCTAssertEqual(commands.filter { $0.arguments == ["mcp", "list"] }.count, 1)
        XCTAssertTrue(commands.allSatisfy { $0.workingDirectory == paths.home.path })
    }

    func testNewFailedProbeDoesNotReusePreviousHealthyRefresh() async throws {
        let runner = MCPProbeFixtureRunner(
            list: CommandResult(exitCode: 0, output: "byoridb: /fixture - ✓ Connected"),
            get: managedGet()
        )
        let service = ManagerService(paths: paths, runner: runner)
        let firstInventories = await service.integrationInventories()
        let first = try XCTUnwrap(firstInventories.first { $0.kind == .claude })
        XCTAssertEqual(first.byoriMCPProbe?.status, .connected)
        await runner.setGet(CommandResult(exitCode: 1, output: "Status: ✓ Connected"))
        let secondInventories = await service.integrationInventories()
        let second = try XCTUnwrap(secondInventories.first { $0.kind == .claude })
        XCTAssertEqual(second.byoriMCPProbe, ByoriMCPProbe(registrationConfirmed: false, status: .unknown))
        XCTAssertEqual(second.mcpServers.first?.management, .unmanaged)
    }

    func testTimeoutKeepsOnlyExplicitPartialRowsWithoutDiagnosticsOrSecrets() async throws {
        let runner = MCPProbeFixtureRunner(
            list: CommandResult(exitCode: 15, output: """
            Checking MCP server health...
            Error: bad configuration
            Status: Connected
            incomplete: /bin/connected-server --token secret
            healthy: /bin/server --token secret - ✓ Connected
            auth: https://example.invalid/secret - Needs authentication
            Error: command failed - ✓ Connected
            """, timedOut: true),
            get: managedGet()
        )
        let result = try await inventory(runner)
        XCTAssertEqual(result.mcpState, .unavailable)
        XCTAssertEqual(result.mcpServers.map(\.name), ["auth", "byoridb", "healthy"])
        XCTAssertEqual(result.mcpServers.first?.status, .authenticationRequired)
        XCTAssertFalse(String(describing: result).contains("secret"))
    }

    func testFailedListRetainsCloudOwnershipInPartialSection() async throws {
        let runner = MCPProbeFixtureRunner(
            list: CommandResult(exitCode: 1, output: """
            Claude.ai connectors:
            calendar: https://example.invalid/private - ✓ Connected
            User servers:
            local: /fixture - ✗ Failed to connect
            """),
            get: CommandResult(exitCode: 1, output: "not registered")
        )
        let result = try await inventory(runner)
        XCTAssertEqual(result.mcpState, .unavailable)
        XCTAssertEqual(result.mcpServers.first { $0.name == "calendar" }?.management, .claudeCloudReadOnly)
        XCTAssertEqual(result.mcpServers.first { $0.name == "local" }?.management, .unmanaged)
    }

    func testTruncatedOutputCannotClaimCompleteInventoryOrAcceptCutFirstRow() async throws {
        let runner = MCPProbeFixtureRunner(
            list: CommandResult(exitCode: 0, output: "cut: /fixture - ✓ Connected\nwhole: /fixture - ✓ Connected", outputTruncated: true),
            get: managedGet()
        )
        let result = try await inventory(runner)
        XCTAssertEqual(result.mcpState, .unavailable)
        XCTAssertEqual(result.mcpServers.map(\.name), ["byoridb", "whole"])
    }

    func testCancelledOrMalformedListDoesNotRetainRows() async throws {
        for list in [
            CommandResult(exitCode: 0, output: "external: /fixture - ✓ Connected", cancelled: true),
            CommandResult(exitCode: 0, output: "external: /fixture - ✓ Connected", outputEncodingValid: false),
        ] {
            let result = try await inventory(MCPProbeFixtureRunner(list: list, get: managedGet()))
            XCTAssertEqual(result.mcpState, .unavailable)
            XCTAssertEqual(result.mcpServers.map(\.name), ["byoridb"])
        }
    }

    func testRegistrationWithoutExplicitStatusDoesNotClaimConnection() async throws {
        let result = try await inventory(MCPProbeFixtureRunner(
            list: CommandResult(exitCode: 0, output: "byoridb: /fixture - ✓ Connected"),
            get: managedGet(statusLine: "Args: --status=connected --healthy")
        ))
        XCTAssertEqual(result.byoriMCPProbe, ByoriMCPProbe(registrationConfirmed: true, status: .unknown))
        XCTAssertEqual(result.mcpServers.first?.status, .unknown)
    }

    func testDifferentCommandOrScopeDoesNotBecomeManagedDespiteConnectedStatus() async throws {
        for get in [
            managedGet(command: paths.mcpRunner.path + ".old"),
            managedGet(scope: "Project config"),
            managedGet(scope: "User config backup"),
        ] {
            let result = try await inventory(MCPProbeFixtureRunner(
                list: CommandResult(exitCode: 0, output: "byoridb: /fixture - ✓ Connected"), get: get
            ))
            XCTAssertEqual(result.byoriMCPProbe, ByoriMCPProbe(registrationConfirmed: false, status: .unknown))
            XCTAssertEqual(result.mcpServers.first?.management, .unmanaged)
        }
    }

    func testTruncatedCancelledOrMalformedGetCannotVerifyRegistration() async throws {
        let output = managedGet().output
        for get in [
            CommandResult(exitCode: 0, output: output, outputTruncated: true),
            CommandResult(exitCode: 0, output: output, cancelled: true),
            CommandResult(exitCode: 0, output: output, outputEncodingValid: false),
        ] {
            let result = try await inventory(MCPProbeFixtureRunner(
                list: CommandResult(exitCode: 0, output: ""), get: get
            ))
            XCTAssertEqual(result.byoriMCPProbe, ByoriMCPProbe(registrationConfirmed: false, status: .unknown))
            XCTAssertTrue(result.mcpServers.isEmpty)
        }
    }

    func testCodexRegistrationDoesNotInventHealthOrOverwriteDisabledListState() async throws {
        for (list, expected) in [
            (CommandResult(exitCode: 1, output: "failed"), MCPServerStatus.configured),
            (CommandResult(exitCode: 0, output: "[{\"name\":\"byoridb\",\"enabled\":false}]"), .disabled),
        ] {
            let runner = MCPProbeFixtureRunner(list: list, get: managedGet(), provider: "codex")
            let inventories = await ManagerService(paths: paths, runner: runner).integrationInventories()
            let result = try XCTUnwrap(inventories.first { $0.kind == .codex })
            XCTAssertEqual(result.byoriMCPProbe, ByoriMCPProbe(registrationConfirmed: true, status: expected))
            XCTAssertEqual(result.mcpServers.first?.status, expected)
        }
    }

    private func managedGet(
        statusLine: String = "Status: ✓ Connected",
        command: String? = nil,
        scope: String = "User config (available in all your projects)"
    ) -> CommandResult {
        CommandResult(exitCode: 0, output: """
        byoridb:
          Scope: \(scope)
          \(statusLine)
          Type: stdio
          Command: \(command ?? paths.mcpRunner.path)
          Args: --token fixture-secret
        """)
    }

    private func inventory(_ runner: MCPProbeFixtureRunner) async throws -> AgentIntegrationInventory {
        let inventories = await ManagerService(paths: paths, runner: runner).integrationInventories()
        return try XCTUnwrap(inventories.first { $0.kind == .claude })
    }
}

private actor MCPProbeFixtureRunner: CommandRunning {
    private let list: CommandResult
    private var get: CommandResult
    private let provider: String
    private(set) var commands: [CommandSpec] = []

    init(list: CommandResult, get: CommandResult, provider: String = "claude") {
        self.list = list
        self.get = get
        self.provider = provider
    }

    func setGet(_ result: CommandResult) { get = result }

    func run(_ command: CommandSpec) async -> CommandResult {
        commands.append(command)
        guard URL(fileURLWithPath: command.executable).lastPathComponent == provider else {
            return CommandResult(exitCode: 1, output: "fixture: not configured")
        }
        if Array(command.arguments.prefix(2)) == ["mcp", "list"] { return list }
        if command.arguments == ["mcp", "get", "byoridb"] { return get }
        return CommandResult(exitCode: 99, output: "fixture: unexpected command")
    }
}
