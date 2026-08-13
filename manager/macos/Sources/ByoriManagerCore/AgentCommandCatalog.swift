import Foundation

public enum AgentCommandSource: String, Equatable, Sendable {
    case plugin
    case skill
}

public struct AgentQuickCommand: Identifiable, Equatable, Sendable {
    public let title: String
    public let insertion: String

    public var id: String { insertion }

    public init(title: String, insertion: String) {
        self.title = title
        self.insertion = insertion
    }
}

public struct AgentCommandGroup: Identifiable, Equatable, Sendable {
    public let agent: AgentKind
    public let name: String
    public let source: AgentCommandSource
    public let commands: [AgentQuickCommand]

    public var id: String { "\(agent.rawValue):\(source.rawValue):\(name)" }

    public init(
        agent: AgentKind,
        name: String,
        source: AgentCommandSource,
        commands: [AgentQuickCommand]
    ) {
        self.agent = agent
        self.name = name
        self.source = source
        self.commands = commands
    }
}

/// Builds the bounded, read-only command menu shown above a live terminal.
///
/// The catalog never executes a command and never reads arbitrary Markdown.
/// It visits only known user Skill roots, Claude's installed-plugin records,
/// and Codex's versioned plugin cache. Symlinks are rejected before a file is
/// opened, and every file and result collection has a hard size limit.
public struct AgentCommandCatalogScanner: @unchecked Sendable {
    private struct ClaudeInstalledPlugins: Decodable {
        struct Installation: Decodable {
            let installPath: String
        }

        let plugins: [String: [Installation]]
    }

    private struct PluginIdentity {
        let name: String
        let displayName: String
        let root: URL
    }

    private let home: URL
    private let fileManager: FileManager
    private let maximumGroups = 200
    private let maximumCommandsPerGroup = 40
    private let maximumMarkdownBytes = 512 * 1_024

    public init(home: URL, fileManager: FileManager = .default) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.fileManager = fileManager
    }

    public func scan() -> [AgentCommandGroup] {
        var groups: [AgentCommandGroup] = []
        groups.append(contentsOf: directSkillGroups(
            agent: .claude,
            roots: [home.appendingPathComponent(".claude/skills", isDirectory: true)]
        ))
        groups.append(contentsOf: claudePluginGroups())
        groups.append(contentsOf: directSkillGroups(
            agent: .codex,
            roots: [
                home.appendingPathComponent(".agents/skills", isDirectory: true),
                home.appendingPathComponent(".codex/skills", isDirectory: true),
            ]
        ))
        groups.append(contentsOf: codexPluginGroups())
        return merged(groups).prefix(maximumGroups).map { $0 }
    }

    private func directSkillGroups(agent: AgentKind, roots: [URL]) -> [AgentCommandGroup] {
        var groups: [AgentCommandGroup] = []
        for root in roots where safeDirectory(root) {
            guard let children = safeChildren(of: root) else { continue }
            for directory in children where safeDirectory(directory) {
                let skillFile = directory.appendingPathComponent("SKILL.md")
                guard let markdown = safeMarkdown(at: skillFile) else { continue }
                let name = frontmatterValue("name", in: markdown) ?? directory.lastPathComponent
                guard let safeName = safeName(name) else { continue }
                groups.append(commandGroup(
                    agent: agent,
                    name: safeName,
                    source: .skill,
                    prefix: agent == .claude ? "/\(safeName)" : "$\(safeName)",
                    markdown: markdown
                ))
            }
        }
        return groups
    }

    private func claudePluginGroups() -> [AgentCommandGroup] {
        let index = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = safeData(at: index),
              let installed = try? JSONDecoder().decode(ClaudeInstalledPlugins.self, from: data) else {
            return []
        }

        var groups: [AgentCommandGroup] = []
        for (identifier, installations) in installed.plugins.sorted(by: { $0.key < $1.key }) {
            guard let pluginName = safeName(String(identifier.split(separator: "@").first ?? "")) else {
                continue
            }
            for installation in installations {
                let root = URL(fileURLWithPath: installation.installPath, isDirectory: true)
                    .standardizedFileURL
                guard root.path.hasPrefix(home.path + "/"), safeDirectory(root) else { continue }
                let identity = pluginIdentity(at: root, fallbackName: pluginName)
                groups.append(contentsOf: pluginCommandGroups(
                    identity: identity,
                    agent: .claude,
                    invocationPrefix: "/\(identity.name):"
                ))
                groups.append(contentsOf: pluginSkillGroups(
                    identity: identity,
                    agent: .claude,
                    invocationPrefix: "/\(identity.name):"
                ))
            }
        }
        return groups
    }

    private func codexPluginGroups() -> [AgentCommandGroup] {
        let cache = home.appendingPathComponent(".codex/plugins/cache", isDirectory: true)
        let enabledPlugins = enabledCodexPluginIDs()
        guard !enabledPlugins.isEmpty,
              safeDirectory(cache), let marketplaces = safeChildren(of: cache) else { return [] }
        var groups: [AgentCommandGroup] = []

        for marketplace in marketplaces where safeDirectory(marketplace) {
            guard let plugins = safeChildren(of: marketplace) else { continue }
            for plugin in plugins where safeDirectory(plugin) {
                let pluginID = "\(plugin.lastPathComponent)@\(marketplace.lastPathComponent)"
                guard enabledPlugins.contains(pluginID) else { continue }
                guard let versions = safeChildren(of: plugin) else { continue }
                for version in versions.reversed() where safeDirectory(version) {
                    let manifest = version
                        .appendingPathComponent(".codex-plugin", isDirectory: true)
                        .appendingPathComponent("plugin.json")
                    guard safeRegularFile(manifest) else { continue }
                    let identity = pluginIdentity(at: version, fallbackName: plugin.lastPathComponent)
                    groups.append(contentsOf: pluginCommandGroups(
                        identity: identity,
                        agent: .codex,
                        invocationPrefix: "$\(identity.name):"
                    ))
                    groups.append(contentsOf: pluginSkillGroups(
                        identity: identity,
                        agent: .codex,
                        invocationPrefix: "$\(identity.name):"
                    ))
                }
            }
        }
        return groups
    }

    /// Codex keeps downloaded and historical bundles in its cache. Only the
    /// explicit `enabled = true` plugin sections in config.toml are active and
    /// should appear in a live session's command menu.
    private func enabledCodexPluginIDs() -> Set<String> {
        let config = home.appendingPathComponent(".codex/config.toml")
        guard let data = safeData(at: config), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let sectionPattern = #"^\[plugins\.\"([^\"]+)\"\]$"#
        var currentPlugin: String?
        var enabled = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                currentPlugin = nil
                if let match = line.range(of: sectionPattern, options: .regularExpression) {
                    let section = String(line[match])
                    let prefix = "[plugins.\""
                    let suffix = "\"]"
                    let start = section.index(section.startIndex, offsetBy: prefix.count)
                    let end = section.index(section.endIndex, offsetBy: -suffix.count)
                    let candidate = String(section[start..<end])
                    let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
                    if parts.count == 2,
                       safeName(String(parts[0])) != nil,
                       safeName(String(parts[1])) != nil {
                        currentPlugin = candidate
                    }
                }
                continue
            }
            if line == "enabled = true", let currentPlugin {
                enabled.insert(currentPlugin)
            }
        }
        return enabled
    }

    private func pluginCommandGroups(
        identity: PluginIdentity,
        agent: AgentKind,
        invocationPrefix: String
    ) -> [AgentCommandGroup] {
        let directory = identity.root.appendingPathComponent("commands", isDirectory: true)
        guard safeDirectory(directory), let files = safeChildren(of: directory) else { return [] }
        let commands = files.compactMap { file -> AgentQuickCommand? in
            guard file.pathExtension.lowercased() == "md", safeRegularFile(file),
                  let commandName = safeName(file.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            return AgentQuickCommand(
                title: commandName,
                insertion: "\(invocationPrefix)\(commandName) "
            )
        }
        guard !commands.isEmpty else { return [] }
        return [AgentCommandGroup(
            agent: agent,
            name: identity.displayName,
            source: .plugin,
            commands: Array(commands.prefix(maximumCommandsPerGroup))
        )]
    }

    private func pluginSkillGroups(
        identity: PluginIdentity,
        agent: AgentKind,
        invocationPrefix: String
    ) -> [AgentCommandGroup] {
        let skills = identity.root.appendingPathComponent("skills", isDirectory: true)
        guard safeDirectory(skills), let directories = safeChildren(of: skills) else { return [] }
        return directories.compactMap { directory in
            guard safeDirectory(directory),
                  let markdown = safeMarkdown(at: directory.appendingPathComponent("SKILL.md")) else {
                return nil
            }
            let declaredName = frontmatterValue("name", in: markdown) ?? directory.lastPathComponent
            guard let name = safeName(declaredName) else { return nil }
            return commandGroup(
                agent: agent,
                name: "\(identity.displayName) · \(name)",
                source: .plugin,
                prefix: "\(invocationPrefix)\(name)",
                markdown: markdown
            )
        }
    }

    private func commandGroup(
        agent: AgentKind,
        name: String,
        source: AgentCommandSource,
        prefix: String,
        markdown: String
    ) -> AgentCommandGroup {
        let documented = documentedCommands(in: markdown)
        let commands: [AgentQuickCommand]
        if documented.isEmpty {
            commands = [AgentQuickCommand(title: name, insertion: prefix + " ")]
        } else {
            commands = documented.prefix(maximumCommandsPerGroup).map { raw in
                AgentQuickCommand(
                    title: raw,
                    insertion: insertion(prefix: prefix, documentedCommand: raw)
                )
            }
        }
        return AgentCommandGroup(agent: agent, name: name, source: source, commands: commands)
    }

    private func documentedCommands(in markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: .newlines)
        var commands: [String] = []
        var expectsSeparator = false
        var readingCommandTable = false

        for line in lines {
            let cells = markdownTableCells(line)
            guard !cells.isEmpty else {
                expectsSeparator = false
                readingCommandTable = false
                continue
            }
            if cells[0].lowercased() == "command" || cells[0] == "명령" || cells[0] == "명령어" {
                expectsSeparator = true
                readingCommandTable = false
                continue
            }
            if expectsSeparator {
                readingCommandTable = cells[0].allSatisfy { $0 == "-" || $0 == ":" || $0.isWhitespace }
                expectsSeparator = false
                continue
            }
            guard readingCommandTable,
                  let command = normalizedDocumentedCommand(cells[0]),
                  !commands.contains(command) else { continue }
            commands.append(command)
        }
        return commands
    }

    private func markdownTableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return [] }
        return trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
    }

    private func normalizedDocumentedCommand(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 160,
              !value.contains("|") && !value.contains("\n"),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    private func insertion(prefix: String, documentedCommand: String) -> String {
        if documentedCommand.hasPrefix("/") || documentedCommand.hasPrefix("$") {
            return documentedCommand + (documentedCommand.contains("[") ? " " : "")
        }
        let withoutPlaceholders = documentedCommand.replacingOccurrences(
            of: #"\s*(\[[^\]]+\]|<[^>]+>)"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let needsArgument = withoutPlaceholders != documentedCommand
        return "\(prefix) \(withoutPlaceholders)" + (needsArgument ? " " : "")
    }

    private func pluginIdentity(at root: URL, fallbackName: String) -> PluginIdentity {
        let claudeManifest = root
            .appendingPathComponent(".claude-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
        let codexManifest = root
            .appendingPathComponent(".codex-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
        let manifest = safeData(at: claudeManifest) ?? safeData(at: codexManifest)
        guard let manifest,
              let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] else {
            return PluginIdentity(name: fallbackName, displayName: fallbackName, root: root)
        }
        let name = (object["name"] as? String).flatMap(safeName) ?? fallbackName
        let displayName = (object["displayName"] as? String).flatMap(safeDisplayName)
            ?? name
        return PluginIdentity(name: name, displayName: displayName, root: root)
    }

    private func frontmatterValue(_ key: String, in markdown: String) -> String? {
        guard markdown.hasPrefix("---\n") || markdown.hasPrefix("---\r\n") else { return nil }
        for line in markdown.components(separatedBy: .newlines).dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
            let prefix = key + ":"
            guard line.hasPrefix(prefix) else { continue }
            return line.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private func merged(_ groups: [AgentCommandGroup]) -> [AgentCommandGroup] {
        var order: [String] = []
        var byID: [String: AgentCommandGroup] = [:]
        for group in groups where !group.commands.isEmpty {
            if let existing = byID[group.id] {
                let commands = (existing.commands + group.commands).reduce(into: [AgentQuickCommand]()) {
                    result, candidate in
                    if !result.contains(where: { $0.insertion == candidate.insertion }) {
                        result.append(candidate)
                    }
                }
                byID[group.id] = AgentCommandGroup(
                    agent: group.agent,
                    name: group.name,
                    source: group.source,
                    commands: Array(commands.prefix(maximumCommandsPerGroup))
                )
            } else {
                order.append(group.id)
                byID[group.id] = group
            }
        }
        return order.compactMap { byID[$0] }.sorted {
            if $0.agent != $1.agent { return $0.agent.rawValue < $1.agent.rawValue }
            if $0.source != $1.source { return $0.source.rawValue > $1.source.rawValue }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func safeChildren(of directory: URL) -> [URL]? {
        try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func safeMarkdown(at url: URL) -> String? {
        guard let data = safeData(at: url), data.count <= maximumMarkdownBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func safeData(at url: URL) -> Data? {
        guard safeRegularFile(url),
              url.standardizedFileURL.path.hasPrefix(home.path + "/"),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? maximumMarkdownBytes + 1) <= maximumMarkdownBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func safeDirectory(_ url: URL) -> Bool {
        guard url.standardizedFileURL.path.hasPrefix(home.path + "/"),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func safeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func safeName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 100,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private func safeDisplayName(_ raw: String) -> String? {
        let value = SafeDisplayText.strippingTerminalControls(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 120, !value.contains("\n") else { return nil }
        return value
    }
}
