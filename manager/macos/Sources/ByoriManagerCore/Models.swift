import Foundation

public enum AgentKind: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    public var executableName: String { rawValue }
}

public enum ManagedFileState: String, Equatable, Sendable {
    case missing
    case current
    case outdated
    case legacy
}

public struct AgentStatus: Identifiable, Equatable, Sendable {
    public let kind: AgentKind
    public let executablePath: String?
    public let version: String?
    public let mcpConnected: Bool
    public let skillState: ManagedFileState

    public var id: String { kind.id }
    public var isInstalled: Bool { executablePath != nil }

    public init(
        kind: AgentKind,
        executablePath: String?,
        version: String?,
        mcpConnected: Bool,
        skillState: ManagedFileState
    ) {
        self.kind = kind
        self.executablePath = executablePath
        self.version = version
        self.mcpConnected = mcpConnected
        self.skillState = skillState
    }
}

public struct ByoriStatus: Equatable, Sendable {
    public let isInstalled: Bool
    public let isHealthy: Bool
    public let serviceLoaded: Bool
    public let serverVersion: String?
    public let homePath: String
    public let pythonAvailable: Bool

    public init(
        isInstalled: Bool,
        isHealthy: Bool,
        serviceLoaded: Bool,
        serverVersion: String?,
        homePath: String,
        pythonAvailable: Bool
    ) {
        self.isInstalled = isInstalled
        self.isHealthy = isHealthy
        self.serviceLoaded = serviceLoaded
        self.serverVersion = serverVersion
        self.homePath = homePath
        self.pythonAvailable = pythonAvailable
    }
}

public struct ManagerSnapshot: Equatable, Sendable {
    public let byori: ByoriStatus
    public let agents: [AgentStatus]
    public let checkedAt: Date

    public init(byori: ByoriStatus, agents: [AgentStatus], checkedAt: Date = Date()) {
        self.byori = byori
        self.agents = agents
        self.checkedAt = checkedAt
    }

    public func agent(_ kind: AgentKind) -> AgentStatus? {
        agents.first { $0.kind == kind }
    }
}

public struct CommandSpec: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?
    public let timeout: TimeInterval

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    public init(exitCode: Int32, output: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.output = output
        self.timedOut = timedOut
    }
}

public struct OperationResult: Equatable, Sendable {
    public let summary: String
    public let detail: String

    public init(summary: String, detail: String = "") {
        self.summary = summary
        self.detail = detail
    }
}

public enum ManagerError: LocalizedError, Equatable {
    case missingExecutable(String)
    case missingResource(String)
    case prerequisite(String)
    case commandFailed(String, Int32, String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .missingExecutable(name):
            return "\(name) CLI를 찾을 수 없습니다. 먼저 설치해 주세요."
        case let .missingResource(path):
            return "앱 리소스를 찾을 수 없습니다: \(path)"
        case let .prerequisite(message):
            return message
        case let .commandFailed(label, code, output):
            let detail = output.isEmpty ? "출력 없음" : output
            return "\(label) 실패 (종료 코드 \(code))\n\(detail)"
        case let .verificationFailed(message):
            return "설정 검증 실패: \(message)"
        }
    }
}
