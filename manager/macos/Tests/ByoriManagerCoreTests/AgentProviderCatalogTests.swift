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

    /// Gemini takes the command as a positional, so a `--` separator would be
    /// consumed as the command itself.
    func testGeminiPassesTheCommandPositionally() {
        XCTAssertEqual(
            AgentMCPCommandStyle.gemini.addArguments(name: "byoridb", command: "/run-mcp.sh"),
            ["mcp", "add", "--scope", "user", "--transport", "stdio", "byoridb", "/run-mcp.sh"]
        )
    }

    /// `gemini mcp remove` defaults to project scope. Omitting the scope would
    /// leave the user-scope registration in place while reporting success.
    func testGeminiRemovesFromTheSameScopeItAddedTo() {
        let remove = AgentMCPCommandStyle.gemini.removeArguments(name: "byoridb")
        XCTAssertEqual(remove, ["mcp", "remove", "--scope", "user", "byoridb"])
        let add = AgentMCPCommandStyle.gemini.addArguments(name: "byoridb", command: "/x")
        XCTAssertEqual(scope(in: remove), scope(in: add))
    }

    func testOnlyClaudeVerifiesScopeAndOnlyGeminiReadsItsSettingsFile() {
        XCTAssertEqual(AgentMCPCommandStyle.claude.verification, .cliGet(requiresUserScope: true))
        XCTAssertEqual(AgentMCPCommandStyle.codex.verification, .cliGet(requiresUserScope: false))
        // Gemini CLI 0.37 has no `mcp get` at all, so a CLI-based check would
        // always fail and the connect flow would never confirm.
        XCTAssertEqual(
            AgentMCPCommandStyle.gemini.verification,
            .settingsJSON(serversKey: "mcpServers", commandKey: "command")
        )
    }

    private func scope(in arguments: [String]) -> String? {
        arguments.firstIndex(of: "--scope").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
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

    /// The rawValue is what Byori looks up on `PATH` and what a persisted
    /// session records, so the two must not drift apart.
    func testExecutableNameMatchesTheRawValue() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(kind.descriptor.executableName, kind.rawValue, "\(kind)")
        }
        XCTAssertEqual(AgentKind.cursorAgent.rawValue, "cursor-agent")
    }

    func testClaudeAndCodexRemainFullyIntegrated() {
        for kind in [AgentKind.claude, .codex] {
            XCTAssertTrue(kind.descriptor.isFullyIntegrated, "\(kind)")
            XCTAssertNil(kind.descriptor.limitations, "\(kind)")
        }
    }

    /// A capability Byori does not have must be declared missing *and*
    /// explained. A silent nil would surface as a button that does nothing.
    func testPartiallySupportedProvidersDeclareTheirLimits() {
        for kind in [AgentKind.gemini, .cursorAgent, .opencode] {
            let descriptor = kind.descriptor
            XCTAssertFalse(descriptor.isFullyIntegrated, "\(kind)")
            XCTAssertNotNil(descriptor.limitations, "\(kind) must explain what it cannot do")
            XCTAssertTrue(descriptor.canInstall, "\(kind) must expose its verified install command")
        }
    }

    func testAdditionalProvidersUseTheirOfficialInstallCommands() {
        XCTAssertEqual(
            AgentKind.gemini.descriptor.install?.command,
            "/usr/bin/env brew install gemini-cli"
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

    /// Gemini's MCP registration was verified against the real CLI; the other
    /// two were not, and inventing flags for them would corrupt a user's config.
    func testOnlyVerifiedProvidersClaimMCPSupport() {
        XCTAssertTrue(AgentKind.gemini.descriptor.managesMCP)
        XCTAssertFalse(AgentKind.cursorAgent.descriptor.managesMCP)
        XCTAssertFalse(AgentKind.opencode.descriptor.managesMCP)
    }

    func testProvidersWithoutAVerifiedModelFlagDoNotAcceptOne() {
        XCTAssertFalse(AgentKind.cursorAgent.descriptor.supportsModelFlag)
        XCTAssertFalse(AgentKind.opencode.descriptor.supportsModelFlag)
        XCTAssertTrue(AgentKind.gemini.descriptor.supportsModelFlag)
    }
}

final class SettingsMCPParsingTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("byori-settings-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    /// The shape below is exactly what `gemini mcp add --scope user` wrote in a
    /// sandboxed home.
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
