import Foundation

public enum MCPServerStatus: String, Equatable, Sendable {
    case connected
    case configured
    case authenticationRequired
    case disabled
    case pendingApproval
    case unavailable
    case unknown
}

public enum MCPServerManagement: String, Equatable, Sendable {
    case byoriManaged
    case unmanaged
    case claudeCloudReadOnly

    public var canRemove: Bool {
        self != .claudeCloudReadOnly
    }
}

public struct MCPServerSummary: Identifiable, Equatable, Sendable {
    public let agent: AgentKind
    public let name: String
    public let status: MCPServerStatus
    public let management: MCPServerManagement

    public var id: String { "\(agent.rawValue):\(name)" }

    public init(
        agent: AgentKind,
        name: String,
        status: MCPServerStatus,
        management: MCPServerManagement
    ) {
        self.agent = agent
        self.name = name
        self.status = status
        self.management = management
    }
}

public enum AgentInventoryState: String, Equatable, Sendable {
    case ready
    case cliMissing
    case unavailable
}

public enum UserSkillOrigin: String, Equatable, Sendable {
    case claudeUser
    case codexShared
    case codexLegacy
}

public struct UserSkillSummary: Identifiable, Equatable, Sendable {
    public let agent: AgentKind
    public let name: String
    public let directoryPath: String
    public let skillFilePath: String
    public let origin: UserSkillOrigin
    public let isByoriManaged: Bool

    public var id: String { "\(agent.rawValue):\(directoryPath)" }

    public init(
        agent: AgentKind,
        name: String,
        directoryPath: String,
        skillFilePath: String,
        origin: UserSkillOrigin,
        isByoriManaged: Bool
    ) {
        self.agent = agent
        self.name = name
        self.directoryPath = directoryPath
        self.skillFilePath = skillFilePath
        self.origin = origin
        self.isByoriManaged = isByoriManaged
    }
}

public struct AgentIntegrationInventory: Identifiable, Equatable, Sendable {
    public let kind: AgentKind
    public let mcpState: AgentInventoryState
    public let mcpServers: [MCPServerSummary]
    public let skillsState: AgentInventoryState
    public let skills: [UserSkillSummary]
    public let skillsWereTruncated: Bool

    public var id: String { kind.id }

    public init(
        kind: AgentKind,
        mcpState: AgentInventoryState,
        mcpServers: [MCPServerSummary],
        skillsState: AgentInventoryState,
        skills: [UserSkillSummary],
        skillsWereTruncated: Bool
    ) {
        self.kind = kind
        self.mcpState = mcpState
        self.mcpServers = mcpServers
        self.skillsState = skillsState
        self.skills = skills
        self.skillsWereTruncated = skillsWereTruncated
    }
}

public enum MCPInventoryParser {
    public struct ParsedServer: Equatable, Sendable {
        public let name: String
        public let status: MCPServerStatus
        public let isClaudeCloud: Bool

        public init(name: String, status: MCPServerStatus, isClaudeCloud: Bool = false) {
            self.name = name
            self.status = status
            self.isClaudeCloud = isClaudeCloud
        }
    }

    /// Parses only the non-sensitive fields needed by Settings. Values such as
    /// command, args, env, headers, URLs and tokens are deliberately ignored.
    public static func codexServers(fromJSON output: String, limit: Int = 200) -> [ParsedServer]? {
        let boundedLimit = max(0, min(limit, 500))
        guard boundedLimit > 0 else { return [] }
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let objects: [[String: Any]]
        if let array = root as? [[String: Any]] {
            objects = array
        } else if let dictionary = root as? [String: Any],
                  let array = (dictionary["servers"] ?? dictionary["mcp_servers"])
                    as? [[String: Any]] {
            objects = array
        } else {
            return nil
        }

        var seen = Set<String>()
        var servers: [ParsedServer] = []
        for object in objects.prefix(boundedLimit) {
            guard let rawName = object["name"] as? String,
                  let name = safeServerName(rawName),
                  seen.insert(name).inserted else {
                continue
            }
            let enabled = object["enabled"] as? Bool
            let rawStatus = (object["status"] as? String)
                ?? (object["connection_status"] as? String)
            let status = coarseStatus(rawStatus, enabled: enabled)
            servers.append(ParsedServer(name: name, status: status))
        }
        return servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Claude's human-readable list can include full command arguments. This
    /// parser never returns a raw line: it extracts a conservative server name,
    /// a coarse state and whether the item belongs to a claude.ai cloud section.
    public static func claudeServers(fromText output: String, limit: Int = 200) -> [ParsedServer] {
        let boundedLimit = max(0, min(limit, 500))
        guard boundedLimit > 0 else { return [] }
        var servers: [ParsedServer] = []
        var seen = Set<String>()
        var inClaudeCloudSection = false

        for rawLine in output.components(separatedBy: .newlines) {
            let line = SafeDisplayText.strippingTerminalControls(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            if lower.hasPrefix("claude.ai "), let separator = line.firstIndex(of: ":") {
                let nameStart = line.index(line.startIndex, offsetBy: "claude.ai ".count)
                let rawName = String(line[nameStart..<separator])
                if let name = safeDisplayName(rawName), seen.insert(name).inserted {
                    servers.append(ParsedServer(
                        name: name,
                        status: coarseClaudeStatus(line),
                        isClaudeCloud: true
                    ))
                    if servers.count >= boundedLimit { break }
                }
                continue
            }

            if lower.contains("claude.ai"),
               lower.contains("connector"),
               !line.contains(": ") {
                inClaudeCloudSection = true
                continue
            }
            if isLocalSectionHeading(lower) {
                inClaudeCloudSection = false
                continue
            }
            if lower.hasPrefix("checking mcp") || lower.hasPrefix("no mcp") {
                continue
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            var rawName = String(line[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rawName = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "-•✓✔✗×⏸ "))
            guard let name = safeServerName(rawName), seen.insert(name).inserted else { continue }

            let explicitlyCloud = lower.contains("[claude.ai]")
                || lower.contains("(claude.ai)")
                || lower.contains("claude.ai connector")
            servers.append(ParsedServer(
                name: name,
                status: coarseClaudeStatus(line),
                isClaudeCloud: inClaudeCloudSection || explicitlyCloud
            ))
            if servers.count >= boundedLimit { break }
        }
        return servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func safeServerName(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
              value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    private static func safeDisplayName(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func coarseStatus(_ rawValue: String?, enabled: Bool?) -> MCPServerStatus {
        if enabled == false { return .disabled }
        guard let rawValue else { return enabled == true ? .configured : .unknown }
        let value = SafeDisplayText.strippingTerminalControls(rawValue).lowercased()
        if value.contains("needs authentication")
            || value.contains("authentication required")
            || value.contains("not authenticated")
            || value.contains("unauthorized")
            || value.contains("sign in") {
            return .authenticationRequired
        }
        if value.contains("pending") || value.contains("approval") || value.contains("⏸") {
            return .pendingApproval
        }
        if value.contains("disabled") { return .disabled }
        if value.contains("disconnected") || value.contains("not connected")
            || value.contains("unavailable")
            || value.contains("failed") || value.contains("error")
            || value.contains("timeout") || value.contains("✗") || value.contains("×") {
            return .unavailable
        }
        if value.contains("connected") || value.contains("healthy")
            || value.contains("ready") || value.contains("✓") || value.contains("✔") {
            return .connected
        }
        return enabled == true ? .configured : .unknown
    }

    private static func coarseClaudeStatus(_ line: String) -> MCPServerStatus {
        // The command portion can contain arbitrary words such as "error" or
        // "disabled". Claude prints the health state after its final ` - `;
        // classify only that suffix so secret-bearing arguments cannot affect
        // or escape into the stored summary.
        let statusSuffix = line.components(separatedBy: " - ").last ?? line
        return coarseStatus(statusSuffix, enabled: nil)
    }

    private static func isLocalSectionHeading(_ lower: String) -> Bool {
        guard lower.hasSuffix(":") else { return false }
        return lower.contains("local") || lower.contains("user")
            || lower.contains("project") || lower.contains("configured")
    }

}

public struct UserSkillScanner: @unchecked Sendable {
    public struct ScanResult: Equatable, Sendable {
        public let state: AgentInventoryState
        public let skills: [UserSkillSummary]
        public let wasTruncated: Bool

        public init(
            state: AgentInventoryState,
            skills: [UserSkillSummary],
            wasTruncated: Bool
        ) {
            self.state = state
            self.skills = skills
            self.wasTruncated = wasTruncated
        }
    }

    private struct Root {
        let url: URL
        let origin: UserSkillOrigin
        let managedSkillFile: URL?
    }

    private let home: URL
    private let fileManager: FileManager

    public init(home: URL, fileManager: FileManager = .default) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.fileManager = fileManager
    }

    public func scan(_ kind: AgentKind, limit: Int = 200) -> ScanResult {
        let boundedLimit = max(0, min(limit, 500))
        var skills: [UserSkillSummary] = []
        var wasTruncated = false
        var hadUnavailableRoot = false

        for root in roots(for: kind) {
            guard fileManager.fileExists(atPath: root.url.path) else { continue }
            guard safeDirectory(root.url) else {
                hadUnavailableRoot = true
                continue
            }
            guard let children = try? fileManager.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                hadUnavailableRoot = true
                continue
            }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if skills.count >= boundedLimit {
                    wasTruncated = true
                    break
                }
                guard let summary = summary(for: child, root: root, agent: kind) else { continue }
                skills.append(summary)
            }
            if wasTruncated { break }
        }

        return ScanResult(
            state: hadUnavailableRoot ? .unavailable : .ready,
            skills: skills,
            wasTruncated: wasTruncated
        )
    }

    public func validatedDirectory(for skill: UserSkillSummary) throws -> URL {
        guard skill.agent == agent(for: skill.origin),
              let root = roots(for: skill.agent).first(where: { $0.origin == skill.origin }),
              safeDirectory(root.url) else {
            throw ManagerError.prerequisite("이 Skill 경로는 해당 에이전트의 사용자 Skill 폴더가 아닙니다.")
        }

        let candidate = URL(fileURLWithPath: skill.directoryPath, isDirectory: true)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == root.url.standardizedFileURL,
              candidate.lastPathComponent == skill.name,
              safeDirectory(candidate),
              candidate.resolvingSymlinksInPath().standardizedFileURL == candidate,
              let verified = summary(for: candidate, root: root, agent: skill.agent),
              verified.skillFilePath == skill.skillFilePath else {
            throw ManagerError.prerequisite("Skill이 이동되었거나 안전하게 관리할 수 없는 경로입니다. 목록을 새로고침해 주세요.")
        }
        return candidate
    }

    private func roots(for kind: AgentKind) -> [Root] {
        switch kind {
        case .claude:
            let root = home.appendingPathComponent(".claude/skills", isDirectory: true)
            return [Root(
                url: root,
                origin: .claudeUser,
                managedSkillFile: root.appendingPathComponent("byoridb-memory/SKILL.md")
            )]
        case .codex:
            let shared = home.appendingPathComponent(".agents/skills", isDirectory: true)
            let legacy = home.appendingPathComponent(".codex/skills", isDirectory: true)
            return [
                Root(
                    url: shared,
                    origin: .codexShared,
                    managedSkillFile: shared.appendingPathComponent("byoridb-memory/SKILL.md")
                ),
                Root(url: legacy, origin: .codexLegacy, managedSkillFile: nil),
            ]
        }
    }

    private func agent(for origin: UserSkillOrigin) -> AgentKind {
        origin == .claudeUser ? .claude : .codex
    }

    private func summary(for child: URL, root: Root, agent: AgentKind) -> UserSkillSummary? {
        let directory = child.standardizedFileURL
        guard directory.deletingLastPathComponent() == root.url.standardizedFileURL,
              safeDirectory(directory),
              directory.resolvingSymlinksInPath().standardizedFileURL == directory else {
            return nil
        }
        let skillFile = directory.appendingPathComponent("SKILL.md")
        guard safeRegularFile(skillFile),
              skillFile.resolvingSymlinksInPath().standardizedFileURL == skillFile.standardizedFileURL else {
            return nil
        }
        return UserSkillSummary(
            agent: agent,
            name: directory.lastPathComponent,
            directoryPath: directory.path,
            skillFilePath: skillFile.path,
            origin: root.origin,
            isByoriManaged: root.managedSkillFile?.standardizedFileURL == skillFile.standardizedFileURL
        )
    }

    private func safeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
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
}
