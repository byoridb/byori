import Foundation
import XCTest
@testable import ByoriManagerCore

final class AntigravityIntegrationTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-antigravity-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        paths = ManagerPaths(home: root.appendingPathComponent("home"), runtimeRoot: root)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSkillInventoryRecognizesVerifiedRootsWithoutManagingLegacyFiles() throws {
        let roots: [(String, UserSkillOrigin)] = [
            (".gemini/config/skills", .antigravityShared),
            (".gemini/antigravity-cli/skills", .antigravityCLI),
            (".gemini/skills", .antigravityLegacy),
        ]
        for (directory, _) in roots {
            try write("skill", to: paths.home.appendingPathComponent("\(directory)/byoridb-memory/SKILL.md"))
        }
        let scanner = UserSkillScanner(home: paths.home)
        let inventory = scanner.scan(.antigravity)
        XCTAssertEqual(inventory.state, .ready)
        XCTAssertEqual(inventory.skills.map(\.origin), roots.map { $0.1 })
        XCTAssertEqual(inventory.skills.map(\.isByoriManaged), [true, false, false])
        for skill in inventory.skills {
            XCTAssertEqual(try scanner.validatedDirectory(for: skill).path, skill.directoryPath)
        }

        let actual = try XCTUnwrap(inventory.skills.first)
        let forged = UserSkillSummary(
            agent: .codex, name: actual.name, directoryPath: actual.directoryPath,
            skillFilePath: actual.skillFilePath, origin: .antigravityShared, isByoriManaged: false
        )
        XCTAssertThrowsError(try scanner.validatedDirectory(for: forged))
    }

    func testSkillSyncUsesSharedRootAndPreservesLegacyConfiguration() async throws {
        for asset in ManagedSkill.byoriDesign.assetPaths {
            try write("bundled \(asset)", to: paths.skillSource(.byoriDesign, assetPath: asset))
        }
        let legacy = paths.home.appendingPathComponent(".gemini/skills/byori-design/SKILL.md")
        let legacyConfig = paths.home.appendingPathComponent(".gemini/settings.json")
        try write("legacy skill", to: legacy)
        try write("legacy settings", to: legacyConfig)
        let service = ManagerService(paths: paths)
        _ = try await service.syncSkill(.antigravity, skill: .byoriDesign)

        for asset in ManagedSkill.byoriDesign.assetPaths {
            let destination = try XCTUnwrap(paths.skillDestination(.byoriDesign, for: .antigravity, assetPath: asset))
            XCTAssertTrue(destination.path.contains("/.gemini/config/skills/byori-design/"))
            XCTAssertEqual(try String(contentsOf: destination), "bundled \(asset)")
        }
        _ = try await service.removeSkill(.antigravity, skill: .byoriDesign)
        XCTAssertEqual(try String(contentsOf: legacy), "legacy skill")
        XCTAssertEqual(try String(contentsOf: legacyConfig), "legacy settings")
    }

    func testMCPInventoryIsBoundedRedactedAndDistinguishesInvalidConfiguration() throws {
        XCTAssertEqual(MCPInventoryParser.antigravityServers(in: paths.antigravityConfig), [])
        try write("""
        {"mcpServers": {
          "disabled-one": {"command":"/secret-path", "disabled":true, "env":{"TOKEN":"secret"}},
          "tools": {"serverUrl":"https://secret.invalid", "headers":{"Authorization":"secret"}},
          "unsafe name": {"command":"secret"}
        }}
        """, to: paths.antigravityConfig)
        let parsed = try XCTUnwrap(MCPInventoryParser.antigravityServers(in: paths.antigravityConfig))
        XCTAssertEqual(parsed.map(\.name), ["disabled-one", "tools"])
        XCTAssertEqual(parsed.map(\.status), [.disabled, .configured])
        XCTAssertEqual(MCPInventoryParser.antigravityServers(in: paths.antigravityConfig, limit: 1)?.count, 1)
        XCTAssertNil(ManagerService.settingsMCPCommand(
            name: "disabled-one", in: paths.antigravityConfig, serversKey: "mcpServers", commandKey: "command"
        ))
        try write("{broken", to: paths.antigravityConfig)
        XCTAssertNil(MCPInventoryParser.antigravityServers(in: paths.antigravityConfig))
        try write("{\"mcpServers\": []}", to: paths.antigravityConfig)
        XCTAssertNil(MCPInventoryParser.antigravityServers(in: paths.antigravityConfig))
    }

    func testMCPConnectAndDisconnectUseOnlyGlobalAntigravityConfiguration() async throws {
        let executable = try makeExecutable(paths.home.appendingPathComponent(".local/bin/agy"))
        _ = try makeExecutable(paths.mcpRunner)
        let legacy = paths.home.appendingPathComponent(".gemini/settings.json")
        try write("legacy config unchanged", to: legacy)
        try write("{\"mcpServers\": {\"existing\": {\"command\": \"/existing\"}}}", to: paths.antigravityConfig)
        let runner = AntigravityFixtureRunner()
        let service = ManagerService(paths: paths, runner: runner)
        _ = try await service.connectMCP(.antigravity)
        let inventories = await service.integrationInventories()
        let inventory = try XCTUnwrap(inventories.first { $0.kind == .antigravity })
        XCTAssertEqual(inventory.mcpState, .ready)
        XCTAssertEqual(inventory.mcpServers.first { $0.name == "byoridb" }?.management, .byoriManaged)
        XCTAssertNotNil(inventory.mcpServers.first { $0.name == "existing" })
        _ = try await service.disconnectMCP(.antigravity)
        XCTAssertEqual(MCPInventoryParser.antigravityServers(in: paths.antigravityConfig)?.map(\.name), ["existing"])
        XCTAssertEqual(try String(contentsOf: legacy), "legacy config unchanged")

        let commands = await runner.commands.filter { $0.executable == executable.path }
        XCTAssertEqual(commands.map(\.arguments), [
            ["mcp", "remove", "byoridb"],
            ["mcp", "add", "--type", "stdio", "byoridb", paths.mcpRunner.path],
            ["mcp", "remove", "byoridb"],
        ])
        XCTAssertTrue(commands.allSatisfy { $0.environment["HOME"] == paths.home.path })
        XCTAssertTrue(commands.allSatisfy { $0.workingDirectory == paths.home.path })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: paths.backups.path).isEmpty)
    }

    func testFailedMCPConnectRestoresExactOriginalConfiguration() async throws {
        _ = try makeExecutable(paths.home.appendingPathComponent(".local/bin/agy"))
        _ = try makeExecutable(paths.mcpRunner)
        let original = "{\"mcpServers\": {\"byoridb\": {\"command\": \"/previous\"}}}\n"
        try write(original, to: paths.antigravityConfig)
        let runner = AntigravityFixtureRunner(failAdd: true)
        let service = ManagerService(paths: paths, runner: runner)
        do {
            _ = try await service.connectMCP(.antigravity)
            XCTFail("failed add was reported as success")
        } catch let error as ManagerError {
            guard case .commandFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: paths.antigravityConfig), original)
    }

    func testInstalledAntigravityUsesItsNativeUpdater() async throws {
        let executable = try makeExecutable(paths.home.appendingPathComponent(".local/bin/agy"))
        let runner = AntigravityFixtureRunner()
        let service = ManagerService(paths: paths, runner: runner)
        _ = try await service.installOrUpdateCLI(.antigravity)
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.executable, executable.path)
        XCTAssertEqual(commands.first?.arguments, ["update"])
        XCTAssertEqual(commands.first?.timeout, 900)
    }

    func testDisconnectDetectsDisabledRegistrationBeyondInventoryLimit() async throws {
        _ = try makeExecutable(paths.home.appendingPathComponent(".local/bin/agy"))
        var servers: [String: Any] = [:]
        for index in 0..<250 { servers["a\(index)"] = ["command": "/fixture"] }
        servers["byoridb"] = ["command": paths.mcpRunner.path, "disabled": true]
        let original = try JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys])
        try FileManager.default.createDirectory(at: paths.antigravityConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: paths.antigravityConfig)
        XCTAssertFalse(try XCTUnwrap(MCPInventoryParser.antigravityServers(in: paths.antigravityConfig))
            .contains { $0.name == "byoridb" })
        XCTAssertEqual(MCPInventoryParser.antigravityServerIsPresent(name: "byoridb", in: paths.antigravityConfig), true)
        let runner = AntigravityFixtureRunner(preserveRemoval: true)
        let service = ManagerService(paths: paths, runner: runner)
        do {
            _ = try await service.disconnectMCP(.antigravity)
            XCTFail("registration beyond the display limit was reported as removed")
        } catch let error as ManagerError {
            guard case .verificationFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: paths.antigravityConfig), original)
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func makeExecutable(_ file: URL) throws -> URL {
        try write("#!/bin/sh\nexit 0\n", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}

/// Only models the observed CLI's config writes inside each test's temporary
/// HOME. Never launches a process, contacts a server, or reads user credentials.
private actor AntigravityFixtureRunner: CommandRunning {
    private(set) var commands: [CommandSpec] = []
    private let failAdd: Bool
    private let preserveRemoval: Bool

    init(failAdd: Bool = false, preserveRemoval: Bool = false) {
        self.failAdd = failAdd
        self.preserveRemoval = preserveRemoval
    }

    func run(_ command: CommandSpec) async -> CommandResult {
        commands.append(command)
        guard command.arguments.first == "mcp",
              command.executable.hasSuffix("/agy"),
              let home = command.environment["HOME"] else {
            return CommandResult(exitCode: 0, output: "fixture")
        }
        let config = URL(fileURLWithPath: home).appendingPathComponent(".gemini/config/mcp_config.json")
        do {
            let data = try Data(contentsOf: config)
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            if command.arguments[1] == "remove" {
                if !preserveRemoval { servers.removeValue(forKey: command.arguments[2]) }
            } else if command.arguments[1] == "add" {
                if failAdd { return CommandResult(exitCode: 1, output: "simulated failure") }
                servers[command.arguments[4]] = ["command": command.arguments[5], "disabled": false]
            }
            root["mcpServers"] = servers
            try JSONSerialization.data(withJSONObject: root).write(to: config)
            return CommandResult(exitCode: 0, output: "fixture")
        } catch {
            return CommandResult(exitCode: 1, output: "fixture error")
        }
    }
}
