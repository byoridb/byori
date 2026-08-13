import Foundation
import XCTest
@testable import ByoriManagerCore

final class AgentCommandCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ByoriAgentCommandCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testDirectSkillCommandsBecomeProviderSpecificInsertions() throws {
        try write(
            """
            ---
            name: impeccable
            ---
            ## Commands
            | Command | Description |
            |---|---|
            | `init` | Initialize |
            | `critique [target]` | Review a target |
            """,
            to: ".agents/skills/impeccable/SKILL.md"
        )
        try write(
            """
            ---
            name: impeccable
            ---
            ## Commands
            | Command | Description |
            |---|---|
            | `init` | Initialize |
            """,
            to: ".claude/skills/impeccable/SKILL.md"
        )

        let groups = AgentCommandCatalogScanner(home: root).scan()
        let codex = try XCTUnwrap(groups.first { $0.agent == .codex && $0.name == "impeccable" })
        let claude = try XCTUnwrap(groups.first { $0.agent == .claude && $0.name == "impeccable" })

        XCTAssertEqual(codex.commands.map(\.insertion), ["$impeccable init", "$impeccable critique "])
        XCTAssertEqual(claude.commands.map(\.insertion), ["/impeccable init"])
    }

    func testClaudeUsesOnlyInstalledPluginCommandDirectories() throws {
        let installed = root.appendingPathComponent(
            ".claude/plugins/cache/cah/cah/0.4.0",
            isDirectory: true
        )
        try write(
            """
            {"name":"cah","displayName":"Connexioh AI-DLC"}
            """,
            to: ".claude/plugins/cache/cah/cah/0.4.0/.claude-plugin/plugin.json"
        )
        try write("# Start", to: ".claude/plugins/cache/cah/cah/0.4.0/commands/start.md")
        let index = """
        {"version":2,"plugins":{"cah@cah":[{"installPath":"\(installed.path)"}]}}
        """
        try write(index, to: ".claude/plugins/installed_plugins.json")
        try write("# Not installed", to: ".claude/plugins/cache/unused/nope/1.0/commands/nope.md")

        let groups = AgentCommandCatalogScanner(home: root).scan()
        let plugin = try XCTUnwrap(groups.first { $0.agent == .claude && $0.name == "Connexioh AI-DLC" })

        XCTAssertEqual(plugin.source, .plugin)
        XCTAssertEqual(plugin.commands, [AgentQuickCommand(title: "start", insertion: "/cah:start ")])
        XCTAssertFalse(groups.flatMap(\.commands).contains { $0.insertion.contains("nope") })
    }

    func testCodexPluginSkillsUseNamespacedInvocationAndDeduplicateVersions() throws {
        try write(
            "[plugins.\"github@remote\"]\nenabled = true\n",
            to: ".codex/config.toml"
        )
        for version in ["0.1.0", "0.2.0"] {
            try write(
                "{\"name\":\"github\"}",
                to: ".codex/plugins/cache/remote/github/\(version)/.codex-plugin/plugin.json"
            )
            try write(
                "---\nname: gh-fix-ci\n---\n# Fix CI",
                to: ".codex/plugins/cache/remote/github/\(version)/skills/gh-fix-ci/SKILL.md"
            )
        }

        let groups = AgentCommandCatalogScanner(home: root).scan()
        let github = groups.filter { $0.agent == .codex && $0.name == "github · gh-fix-ci" }

        XCTAssertEqual(github.count, 1)
        XCTAssertEqual(github[0].commands.map(\.insertion), ["$github:gh-fix-ci "])
    }

    func testCodexCachedButDisabledPluginsStayOutOfTheMenu() throws {
        try write(
            "[plugins.\"github@remote\"]\nenabled = false\n",
            to: ".codex/config.toml"
        )
        try write(
            "{\"name\":\"github\"}",
            to: ".codex/plugins/cache/remote/github/0.2.0/.codex-plugin/plugin.json"
        )
        try write(
            "---\nname: gh-fix-ci\n---\n# Fix CI",
            to: ".codex/plugins/cache/remote/github/0.2.0/skills/gh-fix-ci/SKILL.md"
        )

        XCTAssertFalse(
            AgentCommandCatalogScanner(home: root).scan()
                .flatMap(\.commands)
                .contains { $0.insertion == "$github:gh-fix-ci " }
        )
    }

    func testSymlinkedSkillsAreIgnored() throws {
        try write("---\nname: outside\n---", to: "outside/SKILL.md")
        let skills = root.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skills.appendingPathComponent("linked"),
            withDestinationURL: root.appendingPathComponent("outside", isDirectory: true)
        )

        XCTAssertTrue(AgentCommandCatalogScanner(home: root).scan().isEmpty)
    }

    private func write(_ value: String, to relativePath: String) throws {
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: destination)
    }
}
