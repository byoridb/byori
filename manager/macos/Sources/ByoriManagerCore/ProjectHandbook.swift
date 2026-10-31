import Foundation

public enum ProjectHandbookFreshness: String, Codable, Equatable, Sendable {
    case current
    case missing
    case stale
    case unavailable
}

public struct ProjectHandbookStatus: Equatable, Sendable {
    public let freshness: ProjectHandbookFreshness
    public let reason: String
    public let generation: String?
    public let path: String?

    public init(
        freshness: ProjectHandbookFreshness,
        reason: String,
        generation: String?,
        path: String?
    ) {
        self.freshness = freshness
        self.reason = reason
        self.generation = generation
        self.path = path
    }
}

/// A handbook body together with the independently checked publication state.
///
/// When `isPreview` is true, `generation` identifies the local preview while
/// `publishedGeneration` identifies the last published artifact, if one exists.
/// A preview never promotes the freshness state to current.
public struct ProjectHandbookSnapshot: Equatable, Sendable {
    public let freshness: ProjectHandbookFreshness
    public let reason: String
    public let generation: String
    public let publishedGeneration: String?
    public let path: String?
    public let handbook: String
    public let isPreview: Bool
    public let claimCount: Int
    public let warnings: [String]
    public let excludedSourceCount: Int?
    public let sensitiveSourceCount: Int?
    public let omittedSectionCount: Int?
    public let buildChanged: Bool?

    public init(
        freshness: ProjectHandbookFreshness,
        reason: String,
        generation: String,
        publishedGeneration: String?,
        path: String?,
        handbook: String,
        isPreview: Bool,
        claimCount: Int,
        warnings: [String],
        excludedSourceCount: Int?,
        sensitiveSourceCount: Int?,
        omittedSectionCount: Int?,
        buildChanged: Bool? = nil
    ) {
        self.freshness = freshness
        self.reason = reason
        self.generation = generation
        self.publishedGeneration = publishedGeneration
        self.path = path
        self.handbook = handbook
        self.isPreview = isPreview
        self.claimCount = claimCount
        self.warnings = warnings
        self.excludedSourceCount = excludedSourceCount
        self.sensitiveSourceCount = sensitiveSourceCount
        self.omittedSectionCount = omittedSectionCount
        self.buildChanged = buildChanged
    }
}

public struct ProjectHandbookSourceLimits: Equatable, Sendable {
    public let maxCommits: Int
    public let maxFiles: Int
    public let maxFileBytes: Int
    public let maxTotalBytes: Int
    public let excludePaths: [String]

    public init(
        maxCommits: Int,
        maxFiles: Int,
        maxFileBytes: Int,
        maxTotalBytes: Int,
        excludePaths: [String]
    ) {
        self.maxCommits = maxCommits
        self.maxFiles = maxFiles
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.excludePaths = excludePaths
    }
}

/// Explicit, checkout-scoped consent and collection bounds for automatic refresh.
/// A nil revision is the verified disabled default and does not imply a file exists.
public struct ProjectHandbookRefreshConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let revision: String?
    public let changeID: String?
    public let projectRoot: String
    public let checkoutID: String
    public let debounceMilliseconds: Int
    public let sourceLimits: ProjectHandbookSourceLimits
    public let maxCharacters: Int

    public init(
        enabled: Bool,
        revision: String?,
        changeID: String? = nil,
        projectRoot: String,
        checkoutID: String,
        debounceMilliseconds: Int,
        sourceLimits: ProjectHandbookSourceLimits,
        maxCharacters: Int
    ) {
        self.enabled = enabled
        self.revision = revision
        self.changeID = changeID
        self.projectRoot = projectRoot
        self.checkoutID = checkoutID
        self.debounceMilliseconds = debounceMilliseconds
        self.sourceLimits = sourceLimits
        self.maxCharacters = maxCharacters
    }
}

public enum ProjectHandbookRefreshDisposition: String, Codable, Equatable, Sendable {
    case disabled
    case unchanged
    case rebuilt
    case busy
    case cancelled
    case failed
}

/// Result of the consent-aware coordinator. Only `snapshot` carries a body, and
/// it is present solely when the coordinator returned a verified current read.
public struct ProjectHandbookRefreshResult: Equatable, Sendable {
    public let disposition: ProjectHandbookRefreshDisposition
    public let freshness: ProjectHandbookFreshness
    public let reason: String
    public let generation: String?
    public let snapshot: ProjectHandbookSnapshot?
    public let changed: Bool?

    public init(
        disposition: ProjectHandbookRefreshDisposition,
        freshness: ProjectHandbookFreshness,
        reason: String,
        generation: String?,
        snapshot: ProjectHandbookSnapshot?,
        changed: Bool?
    ) {
        self.disposition = disposition
        self.freshness = freshness
        self.reason = reason
        self.generation = generation
        self.snapshot = snapshot
        self.changed = changed
    }
}

public enum ProjectHandbookHost: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

public enum ProjectHandbookConnectionStatus: String, Codable, Equatable, Sendable {
    case unconfigured
    case configured
    case disconnected

    public var displayName: String {
        switch self {
        case .unconfigured: return "Not configured"
        case .configured: return "Configured"
        case .disconnected: return "Disconnected"
        }
    }
}

/// Project-local adapter state. `configured` proves only that Byori's owned
/// block and private backup pass the CLI's integrity checks. Host discovery,
/// startup execution, and handbook consumption remain explicitly unverified.
public struct ProjectHandbookConnection: Equatable, Sendable {
    public let host: ProjectHandbookHost
    public let status: ProjectHandbookConnectionStatus
    public let changed: Bool
    public let instructionFile: String
    public let handbookFile: String
    public let handbookPresent: Bool
    public let warnings: [String]
    public let wouldChange: Bool?
    public let managedBlock: String?
    public let backupFile: String?
    public let removedInstructionFile: Bool?

    public init(
        host: ProjectHandbookHost,
        status: ProjectHandbookConnectionStatus,
        changed: Bool,
        instructionFile: String,
        handbookFile: String,
        handbookPresent: Bool,
        warnings: [String],
        wouldChange: Bool? = nil,
        managedBlock: String? = nil,
        backupFile: String? = nil,
        removedInstructionFile: Bool? = nil
    ) {
        self.host = host
        self.status = status
        self.changed = changed
        self.instructionFile = instructionFile
        self.handbookFile = handbookFile
        self.handbookPresent = handbookPresent
        self.warnings = warnings
        self.wouldChange = wouldChange
        self.managedBlock = managedBlock
        self.backupFile = backupFile
        self.removedInstructionFile = removedInstructionFile
    }

    /// This is deliberately not named `isConnected`: no host-consumption test
    /// has run merely because the project instruction file is configured.
    public var isConfigured: Bool { status == .configured }
}

public enum ProjectHandbookServiceError: LocalizedError, Equatable, Sendable {
    case commandFailed(String)
    case invalidResponse(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(message),
             let .invalidResponse(message),
             let .verificationFailed(message):
            return message
        }
    }
}

enum ProjectHandbookAction: String {
    case preview
    case build
    case show
    case status

    var readsSources: Bool { self == .preview || self == .build }
}

enum ProjectHandbookRefreshAction: String {
    case sync
    case refresh
}

enum ProjectHandbookConnectionAction: String {
    case connect
    case disconnect
}

struct ProjectHandbookPayload: Decodable {
    let schemaVersion: Int?
    let generation: String?
    let currentGeneration: String?
    let projectRoot: String?
    let handbook: String?
    let published: Bool?
    let changed: Bool?
    let claimCount: Int?
    let warnings: [String]?
    let excludedSources: Int?
    let sensitiveSourcesWithheld: Int?
    let omittedSections: Int?
    let state: ProjectHandbookFreshness?
    let reason: String?
    let path: String?
    let refresh: ProjectHandbookRefreshDisposition?
}

struct ProjectHandbookRefreshConfigurationPayload: Decodable {
    struct SourceLimits: Decodable {
        let maxCommits: Int?
        let maxFiles: Int?
        let maxFileBytes: Int?
        let maxTotalBytes: Int?
        let excludePaths: [String]?

        enum CodingKeys: String, CodingKey {
            case maxCommits = "max_commits"
            case maxFiles = "max_files"
            case maxFileBytes = "max_file_bytes"
            case maxTotalBytes = "max_total_bytes"
            case excludePaths = "exclude_paths"
        }
    }

    let schemaVersion: Int?
    let enabled: Bool?
    let revision: String?
    let changeID: String?
    let projectRoot: String?
    let checkoutID: String?
    let debounceMs: Int?
    let sourceLimits: SourceLimits?
    let maxChars: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case enabled
        case revision
        case changeID = "change_id"
        case projectRoot = "project_root"
        case checkoutID = "checkout_id"
        case debounceMs = "debounce_ms"
        case sourceLimits = "source_limits"
        case maxChars = "max_chars"
    }
}

struct ProjectHandbookConnectionPayload: Decodable {
    let schemaVersion: Int?
    let host: ProjectHandbookHost?
    let status: ProjectHandbookConnectionStatus?
    let verification: String?
    let startupConsumption: String?
    let changed: Bool?
    let instructionFile: String?
    let handbookFile: String?
    let handbookPresent: Bool?
    let warnings: [String]?
    let wouldChange: Bool?
    let managedBlock: String?
    let backupFile: String?
    let removedInstructionFile: Bool?
}
