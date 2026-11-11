import Foundation

public protocol CodeIndexProviding: Sendable {
    func queryCodeIndex(
        _ request: CodeIndexRequest, projectRoot: URL, space: String
    ) async throws -> CodeIndexResponse
}

public enum CodeIndexAction: String, Sendable, CaseIterable {
    case status, verify, files, symbols, relations, impact
}

public struct CodeIndexChangedFile: Decodable, Sendable, Equatable, Identifiable {
    public let path: String
    public let change: String
    public var id: String { change + ":" + path }
    public init(path: String, change: String) { self.path = path; self.change = change }
}

/// A bounded source-byte observation, never an assertion of semantic validity.
public struct CodeIndexVerification: Decodable, Sendable, Equatable {
    public let state: String
    public let complete: Bool
    public let checkedAt: Int64
    public let snapshotID: String?
    public let checkedFiles: Int
    public let skippedFiles: Int
    public let added: Int
    public let modified: Int
    public let deleted: Int
    public let samples: [CodeIndexChangedFile]
    public let reason: String?
    public let currentRevision: String?
    public let revisionChanged: Bool?
    public let coverage: String

    enum CodingKeys: String, CodingKey {
        case state, complete, added, modified, deleted, samples, reason, coverage
        case checkedAt = "checked_at", snapshotID = "snapshot_id", checkedFiles = "checked_files"
        case skippedFiles = "skipped_files", currentRevision = "current_revision", revisionChanged = "revision_changed"
    }

    public init(state: String = "not_checked", complete: Bool = false, checkedAt: Int64 = 0,
                snapshotID: String? = nil, checkedFiles: Int = 0, skippedFiles: Int = 0,
                added: Int = 0, modified: Int = 0, deleted: Int = 0,
                samples: [CodeIndexChangedFile] = [], reason: String? = nil,
                currentRevision: String? = nil, revisionChanged: Bool? = nil, coverage: String = "") {
        self.state = state; self.complete = complete; self.checkedAt = checkedAt; self.snapshotID = snapshotID
        self.checkedFiles = checkedFiles; self.skippedFiles = skippedFiles
        self.added = added; self.modified = modified; self.deleted = deleted; self.samples = samples
        self.reason = reason; self.currentRevision = currentRevision; self.revisionChanged = revisionChanged
        self.coverage = coverage
    }
}

public struct CodeIndexRequest: Sendable, Equatable {
    public let action: CodeIndexAction
    public var query: String
    public var language: String?
    public var file: String?
    public var symbolID: String?
    public var direction: String
    public var kind: String
    public var depth: Int
    public var limit: Int
    public var offset: Int

    public init(action: CodeIndexAction, query: String = "", language: String? = nil,
                file: String? = nil, symbolID: String? = nil, direction: String = "outgoing",
                kind: String = "calls", depth: Int = 3, limit: Int = 50, offset: Int = 0) {
        self.action = action; self.query = query; self.language = language; self.file = file
        self.symbolID = symbolID; self.direction = direction; self.kind = kind
        self.depth = depth; self.limit = limit; self.offset = offset
    }
}

public struct CodeIndexDiagnostic: Decodable, Sendable, Equatable {
    public let file: String
    public let message: String
    public init(file: String = "", message: String) { self.file = file; self.message = message }
}

public struct CodeIndexLanguageStats: Decodable, Sendable, Equatable {
    public let files: Int
    public let symbols: Int
    public init(files: Int = 0, symbols: Int = 0) { self.files = files; self.symbols = symbols }
}

public struct CodeIndexSnapshot: Decodable, Sendable, Equatable {
    public let root: String
    public let checkoutID: String
    public let snapshotID: String
    public let revision: String
    public let indexedAt: Int64
    public let files: Int
    public let symbols: Int
    public let resolvedReferences: Int
    public let unresolvedReferences: Int
    public let languages: [String]
    public let languageStats: [String: CodeIndexLanguageStats]?
    public let diagnostics: [CodeIndexDiagnostic]
    public let diagnosticsCount: Int
    public let diagnosticsTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case root, revision, files, symbols, languages, diagnostics
        case checkoutID = "checkout_id", snapshotID = "snapshot_id", indexedAt = "indexed_at"
        case resolvedReferences = "resolved_references", unresolvedReferences = "unresolved_references"
        case languageStats = "language_stats", diagnosticsCount = "diagnostics_count"
        case diagnosticsTruncated = "diagnostics_truncated"
    }

    public init(root: String = "", checkoutID: String = "", snapshotID: String,
                revision: String = "", indexedAt: Int64 = 0, files: Int = 0, symbols: Int = 0,
                resolvedReferences: Int = 0, unresolvedReferences: Int = 0,
                languages: [String] = [], languageStats: [String: CodeIndexLanguageStats]? = nil,
                diagnostics: [CodeIndexDiagnostic] = [], diagnosticsCount: Int = 0,
                diagnosticsTruncated: Bool = false) {
        self.root = root; self.checkoutID = checkoutID; self.snapshotID = snapshotID
        self.revision = revision; self.indexedAt = indexedAt; self.files = files; self.symbols = symbols
        self.resolvedReferences = resolvedReferences; self.unresolvedReferences = unresolvedReferences
        self.languages = languages; self.languageStats = languageStats; self.diagnostics = diagnostics
        self.diagnosticsCount = diagnosticsCount; self.diagnosticsTruncated = diagnosticsTruncated
    }
}

public struct CodeIndexFile: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let language: String
    public let contentHash: String?
    enum CodingKeys: String, CodingKey { case id, path, language; case contentHash = "content_hash" }
    public init(id: String, path: String, language: String = "", contentHash: String? = nil) {
        self.id = id; self.path = path; self.language = language; self.contentHash = contentHash
    }
}

public struct CodeIndexSymbol: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let qualifiedName: String
    public let kind: String
    public let file: String
    public let language: String
    public let startLine: Int
    public let endLine: Int
    public let contentHash: String?
    enum CodingKeys: String, CodingKey {
        case id, name, kind, file, language
        case qualifiedName = "qualified_name", startLine = "start_line", endLine = "end_line"
        case contentHash = "content_hash"
    }
    public init(id: String, name: String, qualifiedName: String = "", kind: String = "function",
                file: String, language: String = "", startLine: Int = 1, endLine: Int = 1,
                contentHash: String? = nil) {
        self.id = id; self.name = name; self.qualifiedName = qualifiedName; self.kind = kind
        self.file = file; self.language = language; self.startLine = startLine; self.endLine = endLine
        self.contentHash = contentHash
    }
}

public struct CodeIndexRelation: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source: String
    public let target: String?
    public let name: String
    public let kind: String
    public let file: String
    public let resolution: String
    public let line: Int
    public init(id: String, source: String, target: String? = nil, name: String = "",
                kind: String = "calls", file: String, resolution: String = "resolved", line: Int = 1) {
        self.id = id; self.source = source; self.target = target; self.name = name; self.kind = kind
        self.file = file; self.resolution = resolution; self.line = line
    }
}

public struct CodeIndexImpact: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let distance: Int
    public init(id: String, distance: Int) { self.id = id; self.distance = distance }
}

/// Each response names its immutable snapshot. A UI must discard earlier pages
/// and selections if a later response names a different snapshot.
public struct CodeIndexResponse: Decodable, Sendable, Equatable {
    public let checkoutID: String
    public let index: CodeIndexSnapshot?
    public var indexed: Bool { index != nil }
    public let files: [CodeIndexFile]
    public let symbols: [CodeIndexSymbol]
    public let relations: [CodeIndexRelation]
    public let impacted: [CodeIndexImpact]
    public let truncated: Bool
    public let nextOffset: Int?
    public let depth: Int?
    public let verification: CodeIndexVerification?

    enum CodingKeys: String, CodingKey {
        case index, files, symbols, relations, impacted, truncated, depth, verification
        case checkoutID = "checkout_id", nextOffset = "next_offset"
    }

    public init(checkoutID: String = "", index: CodeIndexSnapshot? = nil,
                files: [CodeIndexFile] = [], symbols: [CodeIndexSymbol] = [],
                relations: [CodeIndexRelation] = [], impacted: [CodeIndexImpact] = [],
                truncated: Bool = false, nextOffset: Int? = nil, depth: Int? = nil,
                verification: CodeIndexVerification? = nil) {
        self.checkoutID = checkoutID; self.index = index; self.files = files; self.symbols = symbols
        self.relations = relations; self.impacted = impacted; self.truncated = truncated
        self.nextOffset = nextOffset; self.depth = depth
        self.verification = verification
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkoutID = try c.decode(String.self, forKey: .checkoutID)
        index = try c.decodeIfPresent(CodeIndexSnapshot.self, forKey: .index)
        files = try c.decodeIfPresent([CodeIndexFile].self, forKey: .files) ?? []
        symbols = try c.decodeIfPresent([CodeIndexSymbol].self, forKey: .symbols) ?? []
        relations = try c.decodeIfPresent([CodeIndexRelation].self, forKey: .relations) ?? []
        impacted = try c.decodeIfPresent([CodeIndexImpact].self, forKey: .impacted) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        nextOffset = try c.decodeIfPresent(Int.self, forKey: .nextOffset)
        depth = try c.decodeIfPresent(Int.self, forKey: .depth)
        verification = try c.decodeIfPresent(CodeIndexVerification.self, forKey: .verification)
    }
}
