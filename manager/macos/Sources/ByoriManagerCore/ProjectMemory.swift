import Foundation

public enum MemoryView: String, CaseIterable, Sendable, Identifiable, Hashable {
    case current, review, archived, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .current: return "현재"
        case .review: return "재검토"
        case .archived: return "보관함"
        case .all: return "전체"
        }
    }
}

public struct MemoryPolicySource: Decodable, Hashable, Sendable {
    public let path: String
    public let contentHash: String
    public let checkoutID: String
    public let verifiedAt: Int64
    enum CodingKeys: String, CodingKey {
        case path
        case contentHash = "content_hash", checkoutID = "checkout_id", verifiedAt = "verified_at"
    }
}

public struct MemoryPolicy: Decodable, Hashable, Sendable {
    public let archived: Bool
    public let pinned: Bool
    public let reviewAfter: Int64?
    public let source: MemoryPolicySource?
    enum CodingKeys: String, CodingKey { case archived, pinned, source; case reviewAfter = "review_after" }
}

public struct MemoryRecord: Decodable, Hashable, Sendable, Identifiable {
    public let vid: String
    public let type: String
    public let kind: String?
    public let name: String
    public let body: String
    public let bodyTruncated: Bool?
    public let ts: Int64
    public let lifecycle: String
    public let reviewReasons: [String]
    public let policy: MemoryPolicy
    public var id: String { vid }
    public var reviewReasonLabels: [String] {
        reviewReasons.map { reason in
            switch reason {
            case "archived": return "보관됨"
            case "superseded": return "대체된 기록"
            case "review_due": return "재검토 시점 도래"
            case "source_other_checkout": return "다른 작업 트리의 근거"
            case "source_changed": return "근거 파일 변경"
            case "source_unavailable": return "근거 파일 확인 불가"
            case "source_verification_limit": return "근거 확인 범위 초과"
            default: return "재검토 필요"
            }
        }
    }
    enum CodingKeys: String, CodingKey {
        case vid, type, kind, name, body, ts, lifecycle, policy
        case reviewReasons = "review_reasons"
        case bodyTruncated = "body_truncated"
    }
}

public struct MemoryRelation: Decodable, Sendable {
    public let relation: String
    public let sourceVID: String
    public let targetVID: String
    enum CodingKeys: String, CodingKey {
        case relation, sourceVID = "source_vid", targetVID = "target_vid"
    }
}

public struct MemoryPage: Decodable, Sendable {
    public let items: [MemoryRecord]
    public let links: [MemoryRelation]
    public let truncated: Bool
    public let scanIncomplete: Bool?
    enum CodingKeys: String, CodingKey { case items, links, truncated; case scanIncomplete = "scan_incomplete" }
}

public struct TaskCheckpointDraft: Codable, Equatable, Sendable {
    public var goal: String
    public var decisions: String
    public var attempts: String
    public var verification: String
    public var nextSteps: String
    public init(goal: String = "", decisions: String = "", attempts: String = "",
                verification: String = "", nextSteps: String = "") {
        self.goal = goal; self.decisions = decisions; self.attempts = attempts
        self.verification = verification; self.nextSteps = nextSteps
    }
    enum CodingKeys: String, CodingKey { case goal, decisions, attempts, verification; case nextSteps = "next_steps" }
    public var text: String {
        "목표\n\(goal)\n\n확정한 결정\n\(decisions)\n\n시도와 결과\n\(attempts)\n\n검증 상태\n\(verification)\n\n다음 작업\n\(nextSteps)"
    }
}

public struct TaskCheckpoint: Decodable, Sendable {
    public let taskID: String
    public let checkoutID: String
    public let revision: String
    public let createdAt: Int64
    public let goal: String
    public let decisions: String
    public let attempts: String
    public let verification: String
    public let nextSteps: String
    enum CodingKeys: String, CodingKey {
        case goal, decisions, attempts, verification, revision
        case taskID = "task_id", checkoutID = "checkout_id", createdAt = "created_at", nextSteps = "next_steps"
    }
    public var draft: TaskCheckpointDraft {
        .init(goal: goal, decisions: decisions, attempts: attempts, verification: verification, nextSteps: nextSteps)
    }
}

public struct TaskResume: Decodable, Sendable {
    public let found: Bool
    public let checkpoint: TaskCheckpoint?
    public let currentRevision: String?
    public let revisionState: String
    enum CodingKeys: String, CodingKey { case found, checkpoint; case currentRevision = "current_revision", revisionState = "revision_state" }
}

/// One process uses the bundled MCP implementation, so lifecycle decisions are
/// identical in the app and agents. No credentials or checkpoint bodies in argv.
public actor ProjectMemoryClient {
    private let paths: ManagerPaths
    private let runner: any CommandRunning
    public init(paths: ManagerPaths, runner: any CommandRunning = ProcessCommandRunner()) {
        self.paths = paths; self.runner = runner
    }

    public func read(root: URL, space: String, view: MemoryView) async throws -> MemoryPage {
        let data = try await call("read", root: root, space: space,
                                  payload: ["view": view.rawValue, "limit": 100, "include_links": true])
        return try decode(MemoryPage.self, data)
    }

    public func policy(root: URL, space: String, type: String, name: String,
                       archived: Bool? = nil, pinned: Bool? = nil,
                       reviewAfter: Int64? = nil, sourcePath: String? = nil,
                       verifySource: Bool = false) async throws {
        var payload: [String: Any] = ["type": type, "name": name]
        if let archived { payload["archived"] = archived }
        if let pinned { payload["pinned"] = pinned }
        if let reviewAfter { payload["review_after"] = reviewAfter }
        if let sourcePath { payload["source"] = ["path": sourcePath] }
        if verifySource { payload["verify_source"] = true }
        _ = try await call("policy", root: root, space: space, payload: payload)
    }

    public func resume(root: URL, space: String, taskID: String) async throws -> TaskResume {
        try decode(TaskResume.self, await call("resume", root: root, space: space, payload: ["task_id": taskID]))
    }

    public func checkpoint(root: URL, space: String, taskID: String, draft: TaskCheckpointDraft) async throws {
        let bytes = try JSONEncoder().encode(draft)
        var payload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
        payload["task_id"] = taskID
        _ = try await call("checkpoint", root: root, space: space, payload: payload)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ManagerError.verificationFailed("기억 응답을 읽을 수 없습니다. 앱과 런타임 버전을 확인해 주세요.") }
    }

    private func call(_ action: String, root: URL, space: String, payload: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard space.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil else {
            throw ManagerError.prerequisite("프로젝트 기억 공간이 올바르지 않습니다.")
        }
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard bytes.count <= 64 * 1024 else { throw ManagerError.prerequisite("기억 입력은 64 KiB 이하여야 합니다.") }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("byori-memory-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("request.json")
        try bytes.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let command = try command(action: action, root: root, space: space, payloadFile: file)
        let result = await runner.run(command)
        try Task.checkCancellation()
        guard result.succeeded else {
            throw ManagerError.verificationFailed("프로젝트 기억 작업을 완료하지 못했습니다. ByoriDB 연결과 입력 조건을 확인해 주세요.")
        }
        return Data(result.output.utf8)
    }

    func command(action: String, root: URL, space: String, payloadFile: URL) throws -> CommandSpec {
        let arguments = ["memory", action, root.path, "--space", space, "--json", "--payload-file", payloadFile.path]
        let environment = ["PATH": paths.processPath, "BYORIDB_HOME": paths.byoriHome.path,
                           "BYORIDB_HTTP_PORT": String(paths.httpPort), "BYORIDB_GRAPH_PORT": String(paths.graphPort)]
        if FileManager.default.fileExists(atPath: paths.bundledByoriCLI.path) {
            guard let python = paths.executable(named: "python3") else { throw ManagerError.prerequisite("기억 조회에는 Python 3가 필요합니다.") }
            for resource in [paths.bundledMCP, paths.bundledCodeGraph] {
                guard FileManager.default.fileExists(atPath: resource.path) else { throw ManagerError.missingResource(resource.path) }
            }
            return CommandSpec(executable: python.path, arguments: [paths.bundledByoriCLI.path] + arguments,
                               environment: environment, workingDirectory: root.path, timeout: 45)
        }
        guard FileManager.default.isExecutableFile(atPath: paths.byoriCLI.path) else { throw ManagerError.missingResource(paths.byoriCLI.path) }
        return CommandSpec(executable: paths.byoriCLI.path, arguments: arguments,
                           environment: environment, workingDirectory: root.path, timeout: 45)
    }
}
