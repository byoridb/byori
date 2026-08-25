import Foundation

/// The coding CLIs Byori ships knowledge of.
///
/// What each one supports lives in `AgentProviderCatalog`, not here: being in
/// this list means Byori can detect and launch the CLI, not that every
/// integration applies to it.
public enum AgentKind: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case gemini
    case cursorAgent = "cursor-agent"
    case opencode

    public var id: String { rawValue }
}

public enum ManagedFileState: String, Equatable, Sendable {
    case missing
    case current
    case outdated
    case legacy
}

public enum ManagedSkill: String, CaseIterable, Identifiable, Sendable {
    case byoridbMemory = "byoridb-memory"
    case byoriDesign = "byori-design"

    public var id: String { rawValue }

    /// Names the skill in the UI. Kept short because it always appears next to
    /// the CLI's own name.
    public var displayName: String {
        switch self {
        case .byoridbMemory: return "Memory"
        case .byoriDesign: return "Design"
        }
    }

    public var assetPaths: [String] {
        switch self {
        case .byoridbMemory:
            return ["SKILL.md"]
        case .byoriDesign:
            return ["SKILL.md", "agents/openai.yaml"]
        }
    }
}

public struct AgentStatus: Identifiable, Equatable, Sendable {
    public let kind: AgentKind
    public let executablePath: String?
    public let version: String?
    public let mcpConnected: Bool
    public let skillStates: [ManagedSkill: ManagedFileState]

    public var id: String { kind.id }
    public var isInstalled: Bool { executablePath != nil }
    public var skillState: ManagedFileState { state(for: .byoridbMemory) }

    public init(
        kind: AgentKind,
        executablePath: String?,
        version: String?,
        mcpConnected: Bool,
        skillStates: [ManagedSkill: ManagedFileState]
    ) {
        self.kind = kind
        self.executablePath = executablePath
        self.version = version
        self.mcpConnected = mcpConnected
        self.skillStates = skillStates
    }

    public init(
        kind: AgentKind,
        executablePath: String?,
        version: String?,
        mcpConnected: Bool,
        skillState: ManagedFileState
    ) {
        self.init(
            kind: kind,
            executablePath: executablePath,
            version: version,
            mcpConnected: mcpConnected,
            skillStates: [.byoridbMemory: skillState]
        )
    }

    public func state(for skill: ManagedSkill) -> ManagedFileState {
        skillStates[skill] ?? .missing
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

    /// A missing binary is reported as `notInstalled` even when a launch agent is
    /// still registered for it: that leftover is not a service the user can bring
    /// back with Start, and installing is the step that fixes it.
    public var condition: ByoriServiceCondition {
        if isHealthy { return .running }
        guard isInstalled else { return .notInstalled }
        return serviceLoaded ? .unresponsive : .stopped
    }
}

/// The engine states worth telling apart, derived once.
///
/// `unresponsive` and `stopped` are not the same problem — a registered service
/// that does not answer needs a restart, an unregistered one needs a start — and
/// every surface that reports the engine (Settings overview, the ByoriDB page,
/// the menu bar) has to agree on which of the two it is looking at.
public enum ByoriServiceCondition: Equatable, Sendable {
    case running
    case unresponsive
    case stopped
    case notInstalled

    /// The one bounded label for this state. Surfaces may add a consequence
    /// sentence of their own, but never a second name for the same state.
    public var label: String {
        switch self {
        case .running: return "실행 중"
        case .unresponsive: return "응답 없음"
        case .stopped: return "중지됨"
        case .notInstalled: return "설치 필요"
        }
    }

    /// True only for the state that needs nothing from the user.
    public var isSatisfied: Bool { self == .running }
}

/// Whether Byori should bring ByoriDB back up on its own.
///
/// Kept as a rule rather than a chain of `if`s in the view model because the
/// wrong answer is quiet in both directions: starting a service the user
/// deliberately stopped, or leaving agents running against no memory.
public enum ByoriAutostart {
    public static func shouldStart(_ status: ByoriStatus, userStoppedThisLaunch: Bool) -> Bool {
        // An explicit stop that undoes itself is worse than one that sticks.
        guard !userStoppedThisLaunch else { return false }
        // Installing is a larger operation with its own confirmation, and the
        // UI already asks for it. Autostart only ever restarts.
        guard status.isInstalled else { return false }
        // Loaded but unhealthy still needs a start: the launch agent is
        // registered and the server behind it is not answering.
        return !status.serviceLoaded || !status.isHealthy
    }
}

public struct ManagerSnapshot: Equatable, Sendable {
    public let byori: ByoriStatus
    /// Session persistence is a local requirement like Python 3, so it is read
    /// with the rest of the status rather than only when a session is created.
    public let tmux: TmuxStatus
    public let agents: [AgentStatus]
    public let checkedAt: Date

    public init(
        byori: ByoriStatus,
        tmux: TmuxStatus,
        agents: [AgentStatus],
        checkedAt: Date = Date()
    ) {
        self.byori = byori
        self.tmux = tmux
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
    case rollbackFailed(String)

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
        case let .rollbackFailed(message):
            return "자동 롤백 실패: \(message)"
        }
    }
}
