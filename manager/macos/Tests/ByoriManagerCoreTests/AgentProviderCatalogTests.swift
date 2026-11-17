import XCTest
@testable import ByoriManagerCore

/// These pin the argument shapes that were read off each CLI's own `--help`.
/// Getting one wrong does not fail loudly — it writes a malformed entry into a
/// user's config, or removes nothing while reporting success.
final class AgentMCPCommandStyleTests: XCTestCase {
    func testClaudeRegistersAtUserScopeOverStdio() {
        XCTAssertEqual(
            AgentMCPCommandStyle.claude.addArguments(name: "byoridb", command: "/run-mcp.sh"),
            ["mcp", "add", "--transport", "stdio", "--scope", "user", "byoridb", "--", "/run-mcp.sh"]
        )
        XCTAssertEqual(
            AgentMCPCommandStyle.claude.removeArguments(name: "byoridb"),
            ["mcp", "remove", "--scope", "user", "byoridb"]
        )
    }

    func testCodexTakesTheCommandAfterASeparator() {
        XCTAssertEqual(
            AgentMCPCommandStyle.codex.addArguments(name: "byoridb", command: "/run-mcp.sh"),
            ["mcp", "add", "byoridb", "--", "/run-mcp.sh"]
        )
    }

    /// Antigravity takes the stdio command as a positional argument; it does
    /// not accept Gemini's `--scope` or `--transport` options.
    func testAntigravityPassesTheCommandPositionally() {
        XCTAssertEqual(
            AgentMCPCommandStyle.antigravity.addArguments(name: "byoridb", command: "/run-mcp.sh"),
            ["mcp", "add", "--type", "stdio", "byoridb", "/run-mcp.sh"]
        )
    }

    func testAntigravityRemovesItsGlobalRegistrationWithoutUnsupportedScopeFlags() {
        XCTAssertEqual(
            AgentMCPCommandStyle.antigravity.removeArguments(name: "byoridb"),
            ["mcp", "remove", "byoridb"]
        )
    }

    func testOnlyClaudeVerifiesScopeAndAntigravityReadsItsSettingsFile() {
        XCTAssertEqual(AgentMCPCommandStyle.claude.verification, .cliGet(requiresUserScope: true))
        XCTAssertEqual(AgentMCPCommandStyle.codex.verification, .cliGet(requiresUserScope: false))
        // Antigravity has no `mcp get`; a CLI get check cannot confirm it.
        XCTAssertEqual(
            AgentMCPCommandStyle.antigravity.verification,
            .settingsJSON(serversKey: "mcpServers", commandKey: "command")
        )
    }
}

final class AgentProviderCatalogTests: XCTestCase {
    func testEveryKindHasADescriptorWithADistinctExecutable() {
        let descriptors = AgentKind.allCases.map(\.descriptor)
        XCTAssertEqual(descriptors.count, AgentKind.allCases.count)
        XCTAssertEqual(Set(descriptors.map(\.executableName)).count, descriptors.count)
        XCTAssertEqual(Set(descriptors.map(\.id)).count, descriptors.count)
        XCTAssertTrue(descriptors.allSatisfy { !$0.displayName.isEmpty })
    }

    /// Persisted provider IDs are stable even when the executable has a
    /// different name, as Antigravity's `agy` does.
    func testDescriptorIdentityMatchesThePersistedProviderID() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(kind.descriptor.id, kind.rawValue, "\(kind)")
        }
        XCTAssertEqual(AgentKind.cursorAgent.rawValue, "cursor-agent")
    }

    func testAntigravityReplacesGeminiWithoutReinterpretingItsProviderID() {
        XCTAssertEqual(AgentKind.allCases.map(\.rawValue), [
            "claude", "codex", "antigravity", "cursor-agent", "opencode",
        ])
        XCTAssertNil(AgentKind(rawValue: "gemini"))
        XCTAssertEqual(AgentKind.antigravity.executableName, "agy")
        XCTAssertEqual(AgentKind.antigravity.displayName, "Antigravity CLI")
    }

    func testVerifiedProvidersAreFullyIntegrated() {
        for kind in [AgentKind.claude, .codex, .antigravity] {
            XCTAssertTrue(kind.descriptor.isFullyIntegrated, "\(kind)")
            XCTAssertNil(kind.descriptor.limitations, "\(kind)")
        }
    }

    /// A capability Byori does not have must be declared missing *and*
    /// explained. A silent nil would surface as a button that does nothing.
    func testPartiallySupportedProvidersDeclareTheirLimits() {
        for kind in [AgentKind.cursorAgent, .opencode] {
            let descriptor = kind.descriptor
            XCTAssertFalse(descriptor.isFullyIntegrated, "\(kind)")
            XCTAssertNotNil(descriptor.limitations, "\(kind) must explain what it cannot do")
            XCTAssertTrue(descriptor.canInstall, "\(kind) must expose its verified install command")
        }
    }

    func testAdditionalProvidersUseTheirOfficialInstallCommands() {
        XCTAssertEqual(
            AgentKind.antigravity.descriptor.install?.command,
            "/usr/bin/curl -fsSL https://antigravity.google/cli/install.sh | /bin/bash"
        )
        XCTAssertEqual(
            AgentKind.cursorAgent.descriptor.install?.command,
            "/usr/bin/curl -fsSL https://cursor.com/install | /bin/bash"
        )
        XCTAssertEqual(
            AgentKind.opencode.descriptor.install?.command,
            "/usr/bin/curl -fsSL https://opencode.ai/install | /bin/bash"
        )
    }

    /// Only verified vendor commands can be used to mutate MCP registrations.
    func testOnlyVerifiedProvidersClaimMCPSupport() {
        XCTAssertTrue(AgentKind.antigravity.descriptor.managesMCP)
        XCTAssertFalse(AgentKind.cursorAgent.descriptor.managesMCP)
        XCTAssertFalse(AgentKind.opencode.descriptor.managesMCP)
    }

    func testProvidersWithoutAVerifiedModelFlagDoNotAcceptOne() {
        XCTAssertFalse(AgentKind.cursorAgent.descriptor.supportsModelFlag)
        XCTAssertFalse(AgentKind.opencode.descriptor.supportsModelFlag)
        XCTAssertTrue(AgentKind.antigravity.descriptor.supportsModelFlag)
    }

    func testAntigravitySyncsSkillsIntoTheDocumentedSharedRoot() {
        XCTAssertEqual(AgentKind.antigravity.descriptor.skillsRootRelativePath, ".gemini/config/skills")
        XCTAssertTrue(AgentKind.antigravity.descriptor.managesSkill)
    }

    func testAntigravityUsesItsNativeUpdaterInsteadOfRepeatingTheInstaller() {
        XCTAssertEqual(AgentKind.antigravity.descriptor.updateArguments, ["update"])
        for kind in [AgentKind.claude, .codex, .cursorAgent, .opencode] {
            XCTAssertNil(kind.descriptor.updateArguments)
        }
    }
}

final class SettingsMCPParsingTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("byori-settings-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    /// Antigravity's global MCP configuration keeps stdio commands under
    /// `mcpServers`, independently of the legacy Gemini settings file.
    func testReadsTheRegisteredCommand() throws {
        let file = try write("""
        {"mcpServers":{"byoridb":{"command":"/run-mcp.sh","args":[]}}}
        """)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(
            ManagerService.settingsMCPCommand(
                name: "byoridb",
                in: file,
                serversKey: "mcpServers",
                commandKey: "command"
            ),
            "/run-mcp.sh"
        )
    }

    func testMissingFileOrServerReadsAsNotConnected() throws {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("byori-absent-\(UUID().uuidString).json")
        XCTAssertNil(ManagerService.settingsMCPCommand(
            name: "byoridb", in: absent, serversKey: "mcpServers", commandKey: "command"
        ))

        let other = try write(#"{"mcpServers":{"something-else":{"command":"/x"}}}"#)
        defer { try? FileManager.default.removeItem(at: other) }
        XCTAssertNil(ManagerService.settingsMCPCommand(
            name: "byoridb", in: other, serversKey: "mcpServers", commandKey: "command"
        ))
    }

    /// Only names are taken from a settings file: it also holds commands, env
    /// and headers, none of which belong in a Settings list.
    func testListsServerNamesOnly() throws {
        let file = try write("""
        {"mcpServers":{"b":{"command":"/b","env":{"TOKEN":"secret"}},"a":{"command":"/a"}}}
        """)
        defer { try? FileManager.default.removeItem(at: file) }
        let servers = MCPInventoryParser.settingsServers(in: file, serversKey: "mcpServers")
        XCTAssertEqual(servers.map(\.name), ["a", "b"])
        XCTAssertTrue(servers.allSatisfy { $0.status == .configured })
    }
}

/// `--dangerously-skip-permissions` and friends: flags the user types are handed
/// to the CLI verbatim as separate argv entries, never through a shell.
final class LaunchArgumentTests: XCTestCase {
    func testSplitsOnWhitespaceAndCollapsesRuns() {
        XCTAssertEqual(
            TerminalLaunchDescriptorFactory.splitArguments("  --dangerously-skip-permissions   --verbose "),
            ["--dangerously-skip-permissions", "--verbose"]
        )
        XCTAssertEqual(TerminalLaunchDescriptorFactory.splitArguments(""), [])
        XCTAssertEqual(TerminalLaunchDescriptorFactory.splitArguments("   "), [])
    }

    func testDoubleQuotesKeepASpacedValueTogether() {
        XCTAssertEqual(
            TerminalLaunchDescriptorFactory.splitArguments(#"--add-dir "/Users/me/My Code" --yes"#),
            ["--add-dir", "/Users/me/My Code", "--yes"]
        )
    }

    /// An empty pair of quotes is a real, intentional empty argument, so it is
    /// preserved rather than dropped by the whitespace collapsing.
    func testAnExplicitlyEmptyQuotedArgumentSurvives() {
        XCTAssertEqual(TerminalLaunchDescriptorFactory.splitArguments(#"--flag "" --next"#),
                       ["--flag", "", "--next"])
    }

    /// Shell metacharacters carry no meaning: there is no shell. They must come
    /// through as ordinary text rather than being stripped or acted upon.
    func testShellMetacharactersArePassedThroughAsText() {
        XCTAssertEqual(
            TerminalLaunchDescriptorFactory.splitArguments("--x=a;rm -rf /"),
            ["--x=a;rm", "-rf", "/"]
        )
    }
}
