import Foundation
import XCTest
@testable import ByoriManagerCore

final class IntegrationInventoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-inventory-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClaudeParserDropsSecretBearingDetailsAndFindsCloudConnectors() throws {
        let parsed = MCPInventoryParser.claudeServers(fromText: """
        Checking MCP server health...
        \u{001B}[32mlocal-tools:\u{001B}[0m /bin/error-handler --header Authorization:Bearer-super-secret - ✓ Connected
        failing-server: /bin/server --token another-secret - ✗ Failed
        claude.ai Google Calendar: https://example.invalid/private - Needs authentication
        """)

        XCTAssertEqual(parsed.map(\.name), ["failing-server", "Google Calendar", "local-tools"])
        XCTAssertEqual(parsed.first(where: { $0.name == "local-tools" })?.status, .connected)
        XCTAssertEqual(parsed.first(where: { $0.name == "failing-server" })?.status, .unavailable)
        let cloud = try XCTUnwrap(parsed.first(where: { $0.name == "Google Calendar" }))
        XCTAssertEqual(cloud.status, .authenticationRequired)
        XCTAssertTrue(cloud.isClaudeCloud)
        XCTAssertFalse(parsed.map(\.name).joined().contains("secret"))
        XCTAssertEqual(Mirror(reflecting: cloud).children.count, 3)
    }

    func testCodexParserKeepsOnlyNameEnabledAndCoarseStatus() throws {
        let parsed = try XCTUnwrap(MCPInventoryParser.codexServers(fromJSON: """
        [
          {
            "name": "github",
            "enabled": true,
            "transport": {
              "command": "/bin/server",
              "args": ["--token", "super-secret"],
              "env": {"API_TOKEN": "super-secret"}
            }
          },
          {"name": "disabled-one", "enabled": false, "headers": {"Authorization": "secret"}}
        ]
        """))

        XCTAssertEqual(parsed.map(\.name), ["disabled-one", "github"])
        XCTAssertEqual(parsed.first(where: { $0.name == "github" })?.status, .configured)
        XCTAssertEqual(parsed.first(where: { $0.name == "disabled-one" })?.status, .disabled)
        XCTAssertFalse(parsed.map(\.name).joined().contains("secret"))
        XCTAssertTrue(parsed.allSatisfy { Mirror(reflecting: $0).children.count == 3 })
    }

    func testSkillScannerIsDirectBoundedAndSymlinkSafe() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let claudeSkills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        let direct = claudeSkills.appendingPathComponent("direct", isDirectory: true)
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: direct.appendingPathComponent("SKILL.md"))

        let nested = claudeSkills.appendingPathComponent("container/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("SKILL.md"))

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(
            at: claudeSkills.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: outside
        )

        let scanner = UserSkillScanner(home: home)
        let result = scanner.scan(.claude)
        XCTAssertEqual(result.skills.map(\.name), ["direct"])
        XCTAssertFalse(result.wasTruncated)
        XCTAssertEqual(try scanner.validatedDirectory(for: XCTUnwrap(result.skills.first)), direct)

        let forged = UserSkillSummary(
            agent: .claude,
            name: "outside",
            directoryPath: outside.path,
            skillFilePath: outside.appendingPathComponent("SKILL.md").path,
            origin: .claudeUser,
            isByoriManaged: false
        )
        XCTAssertThrowsError(try scanner.validatedDirectory(for: forged))
    }

    func testArbitrarySkillRemovalBacksUpWholeDirectory() async throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let directory = home.appendingPathComponent(".agents/skills/custom", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: directory.appendingPathComponent("SKILL.md"))
        try Data("helper".utf8).write(to: directory.appendingPathComponent("helper.txt"))
        let skill = try XCTUnwrap(UserSkillScanner(home: home).scan(.codex).skills.first)

        let service = ManagerService(paths: ManagerPaths(home: home, runtimeRoot: runtime))
        _ = try await service.removeUserSkill(skill)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let backups = try FileManager.default.contentsOfDirectory(
            at: service.paths.backups,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backups[0].appendingPathComponent("helper.txt").path
        ))
    }

    func testDisconnectNeverTreatsFailedRemoveAndFailedProbeAsSuccess() async throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let paths = ManagerPaths(home: home, runtimeRoot: root)
        let claude = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(
            at: claude.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        try Data("original-config".utf8).write(to: paths.claudeConfig)

        let service = ManagerService(paths: paths, runner: FailedRemoveRunner())
        do {
            _ = try await service.disconnectMCP(.claude)
            XCTFail("failed remove was reported as success")
        } catch let error as ManagerError {
            guard case .commandFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: paths.claudeConfig), "original-config")
    }
}

private actor FailedRemoveRunner: CommandRunning {
    func run(_ command: CommandSpec) async -> CommandResult {
        if Array(command.arguments.prefix(2)) == ["mcp", "remove"] {
            return CommandResult(exitCode: 1, output: "simulated remove failure")
        }
        if Array(command.arguments.prefix(3)) == ["mcp", "get", "byoridb"] {
            return CommandResult(exitCode: 1, output: "simulated probe failure")
        }
        return CommandResult(exitCode: 0, output: "ok")
    }
}
