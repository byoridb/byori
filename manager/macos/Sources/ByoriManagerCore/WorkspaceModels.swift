import Foundation

public struct WorkspaceProvider: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let claude = WorkspaceProvider(rawValue: "claude")
    public static let codex = WorkspaceProvider(rawValue: "codex")
}

public struct WorkspaceProject: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let rootPath: String
    public let memorySpace: String
    public let remote: String?
    public let addedAt: Date
    public let sourceTrees: [WorkspaceSourceTree]

    public init(
        id: String,
        name: String,
        rootPath: String,
        memorySpace: String,
        remote: String? = nil,
        addedAt: Date,
        sourceTrees: [WorkspaceSourceTree]
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.memorySpace = memorySpace
        self.remote = remote
        self.addedAt = addedAt
        self.sourceTrees = sourceTrees
    }
}

/// A repository that can be registered, but has not been written to `projects.json`.
/// Keeping this separate from `WorkspaceProject` prevents UI callers from treating a
/// discovery fallback as durable state.
public struct WorkspaceProjectPreview: Equatable, Sendable {
    public let name: String
    public let rootPath: String
    public let remote: String?

    public init(name: String, rootPath: String, remote: String? = nil) {
        self.name = name
        self.rootPath = rootPath
        self.remote = remote
    }
}

public struct WorkspaceSourceTree: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let projectID: String
    public let path: String
    public let worktrees: [WorkspaceWorktree]

    public init(
        id: String,
        projectID: String,
        path: String,
        worktrees: [WorkspaceWorktree] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.path = path
        self.worktrees = worktrees
    }
}

public struct WorkspaceWorktree: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let sourceTreeID: String
    public let path: String
    public let branch: String?
    public let baseRevision: String?
    public let isManaged: Bool

    public init(
        id: String,
        sourceTreeID: String,
        path: String,
        branch: String? = nil,
        baseRevision: String? = nil,
        isManaged: Bool
    ) {
        self.id = id
        self.sourceTreeID = sourceTreeID
        self.path = path
        self.branch = branch
        self.baseRevision = baseRevision
        self.isManaged = isManaged
    }
}

public enum WorkspaceCheckoutKind: String, Codable, Sendable {
    case sourceTree = "source_tree"
    case worktree
}

/// The SourceTree/Worktree node directly above a task in the workspace hierarchy.
public struct WorkspaceCheckoutReference: Equatable, Codable, Sendable {
    public let kind: WorkspaceCheckoutKind
    public let id: String

    public init(kind: WorkspaceCheckoutKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

public enum WorkspaceTaskStatus: String, Codable, CaseIterable, Sendable {
    case open
    case active
    case completed
    case blocked
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .cancelled
    }
}

public enum WorkspaceSessionStatus: String, Codable, CaseIterable, Sendable {
    case created
    case active
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    fileprivate func canTransition(to next: WorkspaceSessionStatus) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.created, .active), (.created, .failed), (.created, .cancelled),
             (.active, .completed), (.active, .failed), (.active, .cancelled):
            return true
        default:
            return false
        }
    }
}

/// Session name, provider, and model are immutable values. State updates return a
/// new value while copying this identity verbatim; persistence never replaces it.
public struct WorkspaceSession: Identifiable, Equatable, Codable, Sendable {
    public static let maximumNameScalarCount = 80
    public static let maximumNameUTF8Bytes = 320

    public let id: String
    public let name: String?
    public let provider: WorkspaceProvider
    public let model: String
    public let status: WorkspaceSessionStatus
    public let nativeSessionID: String?
    public let createdAt: Date
    public let startedAt: Date?
    public let endedAt: Date?

    public static func normalizedName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try WorkspaceValidation.sessionName(normalized)
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name = "display_name"
        case provider
        case model
        case status
        case nativeSessionID = "native_session_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    public init(
        id: String,
        name: String? = nil,
        provider: WorkspaceProvider,
        model: String,
        status: WorkspaceSessionStatus = .created,
        nativeSessionID: String? = nil,
        createdAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) throws {
        try WorkspaceValidation.identifier(id, label: "session id")
        try WorkspaceValidation.sessionName(name)
        try WorkspaceValidation.provider(provider)
        try WorkspaceValidation.model(model)
        try WorkspaceValidation.nativeSessionID(nativeSessionID)
        self.id = id
        self.name = name
        self.provider = provider
        self.model = model
        self.status = status
        self.nativeSessionID = nativeSessionID
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    func updating(
        status nextStatus: WorkspaceSessionStatus,
        nativeSessionID nextNativeSessionID: String?,
        at date: Date
    ) throws -> WorkspaceSession {
        guard status.canTransition(to: nextStatus) else {
            throw WorkspaceError.invalidSessionTransition(from: status, to: nextStatus)
        }
        try WorkspaceValidation.nativeSessionID(nextNativeSessionID)
        return try WorkspaceSession(
            id: id,
            name: name,
            provider: provider,
            model: model,
            status: nextStatus,
            nativeSessionID: nextNativeSessionID,
            createdAt: createdAt,
            startedAt: startedAt ?? (nextStatus == .active ? date : nil),
            endedAt: nextStatus.isTerminal ? (endedAt ?? date) : nil
        )
    }
}

public struct WorkspaceTask: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let projectID: String
    public let checkout: WorkspaceCheckoutReference
    public let title: String
    public let status: WorkspaceTaskStatus
    public let sessions: [WorkspaceSession]
    public let createdAt: Date
    public let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case checkout
        case title
        case status
        case sessions
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        projectID: String,
        checkout: WorkspaceCheckoutReference,
        title: String,
        status: WorkspaceTaskStatus = .open,
        sessions: [WorkspaceSession] = [],
        createdAt: Date,
        updatedAt: Date
    ) throws {
        try WorkspaceValidation.identifier(id, label: "task id")
        try WorkspaceValidation.identifier(projectID, label: "project id")
        try WorkspaceValidation.identifier(checkout.id, label: "checkout id")
        try WorkspaceValidation.title(title)
        guard Set(sessions.map(\.id)).count == sessions.count else {
            throw WorkspaceError.invalidTask("session ids must be unique")
        }
        guard sessions.filter({ !$0.status.isTerminal }).count <= 1 else {
            throw WorkspaceError.invalidTask("a task may have only one open session")
        }
        self.id = id
        self.projectID = projectID
        self.checkout = checkout
        self.title = title
        self.status = status
        self.sessions = sessions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func adding(session: WorkspaceSession, at date: Date) throws -> WorkspaceTask {
        guard !status.isTerminal else {
            throw WorkspaceError.invalidTask("cannot add a session to a terminal task")
        }
        guard sessions.allSatisfy({ $0.status.isTerminal }) else {
            throw WorkspaceError.openSessionExists(id)
        }
        return try WorkspaceTask(
            id: id,
            projectID: projectID,
            checkout: checkout,
            title: title,
            status: status == .open ? .active : status,
            sessions: sessions + [session],
            createdAt: createdAt,
            updatedAt: date
        )
    }

    func replacing(session: WorkspaceSession, at date: Date) throws -> WorkspaceTask {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            throw WorkspaceError.sessionNotFound(session.id)
        }
        var replacement = sessions
        replacement[index] = session
        return try WorkspaceTask(
            id: id,
            projectID: projectID,
            checkout: checkout,
            title: title,
            status: status,
            sessions: replacement,
            createdAt: createdAt,
            updatedAt: date
        )
    }

    func updating(status nextStatus: WorkspaceTaskStatus, at date: Date) throws -> WorkspaceTask {
        guard !(status.isTerminal && status != nextStatus) else {
            throw WorkspaceError.invalidTask("a terminal task cannot be reopened")
        }
        guard !nextStatus.isTerminal || sessions.allSatisfy({ $0.status.isTerminal }) else {
            throw WorkspaceError.invalidTask("an open session must end before its task can close")
        }
        return try WorkspaceTask(
            id: id,
            projectID: projectID,
            checkout: checkout,
            title: title,
            status: nextStatus,
            sessions: sessions,
            createdAt: createdAt,
            updatedAt: date
        )
    }
}

public struct WorkspaceTaskList: Equatable, Sendable {
    public let tasks: [WorkspaceTask]
    public let isTruncated: Bool

    public init(tasks: [WorkspaceTask], isTruncated: Bool) {
        self.tasks = tasks
        self.isTruncated = isTruncated
    }
}

public enum WorkspaceError: LocalizedError, Equatable, Sendable {
    case invalidRegistry(String)
    case unsupportedProjectSchema(Int)
    case invalidProject(String)
    case invalidTask(String)
    case invalidIdentifier(String)
    case invalidProvider(String)
    case invalidModel
    case invalidSessionName
    case projectNotFound(String)
    case taskNotFound(String)
    case sessionNotFound(String)
    case openSessionExists(String)
    case invalidSessionTransition(from: WorkspaceSessionStatus, to: WorkspaceSessionStatus)
    case notGitRepository(String)
    case gitCommandFailed(String)
    case persistence(String)
    case inspection(String)
    case fileNotEditable(String)
    /// The file changed underneath an open editor. Agents write these trees
    /// while the user has them open, so this is an ordinary race, not a bug.
    case fileChangedOnDisk(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRegistry(message): return "Invalid Byori project registry: \(message)"
        case let .unsupportedProjectSchema(version):
            return "Project registry schema \(version) cannot be modified safely."
        case let .invalidProject(message): return "Invalid workspace project: \(message)"
        case let .invalidTask(message): return "Invalid workspace task: \(message)"
        case let .invalidIdentifier(label): return "Invalid workspace identifier: \(label)"
        case let .invalidProvider(provider): return "Invalid workspace provider: \(provider)"
        case .invalidModel: return "A non-empty, bounded model selector is required."
        case .invalidSessionName:
            return "Session name must be trimmed, non-empty, and at most 80 characters."
        case let .projectNotFound(id): return "Workspace project was not found: \(id)"
        case let .taskNotFound(id): return "Workspace task was not found: \(id)"
        case let .sessionNotFound(id): return "Workspace session was not found: \(id)"
        case let .openSessionExists(id): return "Task \(id) already has an open session."
        case let .invalidSessionTransition(from, to):
            return "Session cannot transition from \(from.rawValue) to \(to.rawValue)."
        case let .notGitRepository(path): return "Not a Git repository: \(path)"
        case let .gitCommandFailed(message): return "Git inspection failed: \(message)"
        case let .persistence(message): return "Workspace persistence failed: \(message)"
        case let .inspection(message): return "Workspace inspection failed: \(message)"
        case let .fileNotEditable(message): return "File cannot be edited here: \(message)"
        case let .fileChangedOnDisk(path):
            return "\(path) changed on disk since it was opened. Reload it before saving."
        }
    }
}

enum WorkspaceValidation {
    static func identifier(_ value: String, label: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar == "_" || scalar == "-" || scalar == "."
              }) else {
            throw WorkspaceError.invalidIdentifier(label)
        }
    }

    static func provider(_ value: WorkspaceProvider) throws {
        do {
            try identifier(value.rawValue, label: "provider")
            guard value.rawValue.utf8.count <= 64 else { throw WorkspaceError.invalidProvider(value.rawValue) }
        } catch {
            throw WorkspaceError.invalidProvider(value.rawValue)
        }
    }

    static func model(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
            throw WorkspaceError.invalidModel
        }
    }

    static func sessionName(_ value: String?) throws {
        guard let value else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value,
              !value.isEmpty,
              value.unicodeScalars.count <= WorkspaceSession.maximumNameScalarCount,
              value.utf8.count <= WorkspaceSession.maximumNameUTF8Bytes,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw WorkspaceError.invalidSessionName
        }
    }

    static func title(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !value.isEmpty, value.utf8.count <= 500 else {
            throw WorkspaceError.invalidTask("title must be between 1 and 500 UTF-8 bytes")
        }
    }

    static func nativeSessionID(_ value: String?) throws {
        guard let value else { return }
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw WorkspaceError.invalidTask("native session id is invalid")
        }
    }
}
