import Foundation

public protocol KnowledgeGraphProviding: Sendable {
    /// Verifies that the configured local endpoint accepts the configured
    /// credential. A health response alone is insufficient because another
    /// ByoriDB process can own the same port while using a different data set.
    func verifyConnection(paths: ManagerPaths) async throws
    func loadGraph(
        paths: ManagerPaths,
        nodeLimit: Int,
        space: String?
    ) async throws -> KnowledgeGraphSnapshot
    func loadBody(
        paths: ManagerPaths,
        nodeID: Int64,
        tag: String,
        space: String?
    ) async throws -> String
}

public extension KnowledgeGraphProviding {
    func verifyConnection(paths: ManagerPaths) async throws {
        _ = try await loadGraph(paths: paths, nodeLimit: 1, space: nil)
    }

    func loadGraph(paths: ManagerPaths, nodeLimit: Int) async throws -> KnowledgeGraphSnapshot {
        try await loadGraph(paths: paths, nodeLimit: nodeLimit, space: nil)
    }

    func loadBody(paths: ManagerPaths, nodeID: Int64, tag: String) async throws -> String {
        try await loadBody(paths: paths, nodeID: nodeID, tag: tag, space: nil)
    }
}

public enum KnowledgeGraphClientError: LocalizedError, Sendable {
    case missingConfiguration
    case invalidConfiguration
    case unavailable
    case authenticationFailed
    case queryFailed
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "ByoriDB 연결 정보가 없습니다. ByoriDB를 먼저 설치해 주세요."
        case .invalidConfiguration:
            return "ByoriDB 연결 설정을 읽을 수 없습니다. 설치 복구를 실행해 주세요."
        case .unavailable:
            return "로컬 ByoriDB에 연결할 수 없습니다. 서비스 상태를 확인해 주세요."
        case .authenticationFailed:
            return "ByoriDB 인증에 실패했습니다. 다른 ByoriDB 프로세스가 포트를 사용 중이거나 저장 데이터와 연결 비밀번호가 다를 수 있습니다."
        case .queryFailed:
            return "지식 그래프를 조회하지 못했습니다. ByoriDB 버전과 로그를 확인해 주세요."
        case .invalidResponse:
            return "ByoriDB가 해석할 수 없는 응답을 반환했습니다."
        }
    }
}

public actor ByoriGraphClient: KnowledgeGraphProviding {
    /// note는 Layer 1(경량 메모), 나머지는 schema v2 typed wiki 태그(memory-ontology.md §4.1).
    private static let noteTag = "note"
    private static let typedWikiTags = ["module", "decision", "bug", "incident", "concept", "entity", "task"]
    private static let nodeTags = [noteTag] + typedWikiTags

    /// rel은 Layer 1의 범용 엣지, 나머지는 schema v2 typed wiki 엣지(memory-ontology.md §4.2).
    /// `decided_in`은 ontology 문서(§4.2)의 목표 스키마일 뿐 아직 `byoridb_mcp.py`
    /// migration에 없다 — 여기 추가하면 미정의 edge tag 조회로 loadGraph 전체가 실패한다.
    private static let legacyEdgeKind = "rel"
    private static let typedWikiEdgeKinds = [
        "part_of", "depends_on", "affects", "caused_by", "fixed_by", "supersedes", "about", "relates_to",
    ]
    private static let edgeKinds = [legacyEdgeKind] + typedWikiEdgeKinds

    /// 같은 vid에 여러 태그가 붙을 수 있다(note → typed 승격 후 note 태그가 남는 경우).
    /// queryAllTags는 태그별로 동시에 실행되므로 완료 순서가 매번 달라질 수 있어,
    /// 어떤 태그가 "이긴다"를 고정 우선순위로 강제한다 — typed가 note보다 우선.
    private static let nodeTagPriority: [String: Int] = Dictionary(
        uniqueKeysWithValues: (typedWikiTags + [noteTag]).enumerated().map { ($1, $0) }
    )

    private struct Credentials: Sendable {
        let password: String
        let space: String
    }

    private struct SessionRequest: Encodable {
        let username: String
        let password: String
    }

    private enum SessionIdentifier: Codable, Sendable {
        case string(String)
        case integer(Int64)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .integer(try container.decode(Int64.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .string(value): try container.encode(value)
            case let .integer(value): try container.encode(value)
            }
        }

        var decimalString: String {
            switch self {
            case let .string(value): return value
            case let .integer(value): return String(value)
            }
        }

        var isValid: Bool {
            let value = decimalString
            return !value.isEmpty && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value)
            }
        }
    }

    private struct SessionResponse: Decodable {
        let sessionID: SessionIdentifier

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
        }
    }

    private struct QueryRequest: Encodable {
        let sessionID: SessionIdentifier
        let query: String

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case query
        }
    }

    private enum JSONValue: Decodable, Sendable {
        case string(String)
        case integer(Int64)
        case decimal(Double)
        case boolean(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .decimal(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported JSON value"
                )
            }
        }

        var stringValue: String? {
            switch self {
            case let .string(value): return value
            case let .integer(value): return String(value)
            case let .decimal(value): return String(value)
            default: return nil
            }
        }

        var int64Value: Int64? {
            switch self {
            case let .integer(value): return value
            case let .string(value): return Int64(value)
            case let .decimal(value) where value.rounded() == value: return Int64(exactly: value)
            default: return nil
            }
        }
    }

    private struct QueryResponse: Decodable {
        let rows: [[String: JSONValue]]

        enum CodingKeys: String, CodingKey {
            case results
            case columnNames = "column_names"
            case columns
            case rows
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let results = try container.decodeIfPresent(
                [[String: JSONValue]].self,
                forKey: .results
            ) {
                rows = results
                return
            }

            let columns = try container.decodeIfPresent([String].self, forKey: .columnNames)
                ?? container.decodeIfPresent([String].self, forKey: .columns)
                ?? []
            let values = try container.decodeIfPresent([[JSONValue]].self, forKey: .rows) ?? []
            rows = values.map { row in
                Dictionary(uniqueKeysWithValues: zip(columns, row).map { ($0.0, $0.1) })
            }
        }
    }

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    public func verifyConnection(paths: ManagerPaths) async throws {
        let credentials = try credentials(at: paths.byoriHome.appendingPathComponent("env"))
        let baseURL = try localBaseURL(port: paths.httpPort)
        let sessionID = try await createSession(baseURL: baseURL, password: credentials.password)
        await deleteSession(baseURL: baseURL, sessionID: sessionID)
    }

    public func loadGraph(
        paths: ManagerPaths,
        nodeLimit: Int = 200,
        space: String? = nil
    ) async throws -> KnowledgeGraphSnapshot {
        let limit = min(max(nodeLimit, 1), 200)
        let edgeLimit = min(limit * 3, 500)
        let credentials = try credentials(at: paths.byoriHome.appendingPathComponent("env"))
        let selectedSpace = try validatedSpace(space ?? credentials.space)
        let baseURL = try localBaseURL(port: paths.httpPort)
        let sessionID = try await createSession(baseURL: baseURL, password: credentials.password)
        defer { Task { await deleteSession(baseURL: baseURL, sessionID: sessionID) } }

        _ = try await query(
            baseURL: baseURL,
            sessionID: sessionID,
            statement: "USE \(selectedSpace)"
        )

        // nGQL은 UNION으로 여러 태그를 한 결과로 합쳐주지 않으므로(첫 branch만 반환),
        // 태그/엣지 종류별로 나눠 조회한 뒤 클라이언트에서 병합한다.
        let nodeRows = try await queryAllTags(
            Self.nodeTags,
            baseURL: baseURL,
            sessionID: sessionID
        ) { tag in Self.nodeListStatement(tag: tag, limit: limit) }

        // 태그별 동시 조회는 완료 순서가 매번 달라질 수 있으므로, 같은 vid가 여러 태그를
        // 가진 경우(승격 후 note 태그가 남는 경우) 어떤 태그가 이기는지 고정한다.
        let orderedNodeRows = nodeRows.sorted {
            (Self.nodeTagPriority[$0.key] ?? Int.max) < (Self.nodeTagPriority[$1.key] ?? Int.max)
        }
        var seenNodes = Set<Int64>()
        var allNodes: [KnowledgeNode] = []
        for (tag, row) in orderedNodeRows {
            guard let id = row["vid"]?.int64Value,
                  let name = row["name"]?.stringValue,
                  seenNodes.insert(id).inserted else { continue }
            let kind = tag == Self.noteTag ? (row["kind"]?.stringValue ?? Self.noteTag) : tag
            allNodes.append(KnowledgeNode(
                id: id,
                name: name,
                kind: kind,
                tag: tag,
                timestamp: row["ts"]?.int64Value ?? 0
            ))
        }
        let nodesTruncated = allNodes.count > limit
        allNodes.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id < rhs.id
        }
        let nodes = Array(allNodes.prefix(limit))

        guard !nodes.isEmpty else {
            return KnowledgeGraphSnapshot(nodes: nodes, edges: [], nodesTruncated: nodesTruncated, edgesTruncated: false)
        }

        // 표시될 node 집합으로 서버 측에서 미리 걸러야, 엣지 종류별 LIMIT 컷오프가
        // "보이지 않는 endpoint로 향하는 엣지"에 낭비되어 표시 가능한 엣지를 놓치지 않는다.
        // 엔진이 `IN` 연산자를 지원하지 않으므로(실측: 리스트가 1개여도 무조건 0행)
        // `==`을 OR로 체이닝한다 — engine-contract.md 참고.
        let knownIDs = nodes.map(\.id).sorted()
        let visibleIDFilter = Self.idOrClause(field: "id(a)", ids: knownIDs)
            + " AND " + Self.idOrClause(field: "id(b)", ids: knownIDs)
        let edgeRows = try await queryAllTags(
            Self.edgeKinds,
            baseURL: baseURL,
            sessionID: sessionID
        ) { edgeKind in Self.edgeListStatement(edgeKind: edgeKind, visibleIDFilter: visibleIDFilter, limit: edgeLimit) }

        var seenEdges = Set<KnowledgeEdge>()
        var allEdges: [KnowledgeEdge] = []
        for (edgeKind, row) in edgeRows {
            guard let source = row["src"]?.int64Value,
                  let target = row["dst"]?.int64Value else { continue }
            let kind = edgeKind == Self.legacyEdgeKind ? (row["kind"]?.stringValue ?? "relates_to") : edgeKind
            let edge = KnowledgeEdge(source: source, target: target, kind: kind)
            guard seenEdges.insert(edge).inserted else { continue }
            allEdges.append(edge)
        }
        let edgesTruncated = allEdges.count > edgeLimit
        allEdges.sort { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            if lhs.target != rhs.target { return lhs.target < rhs.target }
            return lhs.kind < rhs.kind
        }
        let edges = Array(allEdges.prefix(edgeLimit))

        return KnowledgeGraphSnapshot(
            nodes: nodes,
            edges: edges,
            nodesTruncated: nodesTruncated,
            edgesTruncated: edgesTruncated
        )
    }

    /// `keys`(태그 또는 엣지 종류) 각각에 대해 `statement`로 만든 쿼리를 동시에 실행하고,
    /// 결과 행을 어떤 key에서 왔는지와 함께 평탄화해 반환한다.
    private func queryAllTags(
        _ keys: [String],
        baseURL: URL,
        sessionID: SessionIdentifier,
        statement: @Sendable @escaping (String) -> String
    ) async throws -> [(key: String, row: [String: JSONValue])] {
        try await withThrowingTaskGroup(of: [(key: String, row: [String: JSONValue])].self) { group in
            for key in keys {
                group.addTask {
                    let response = try await self.query(
                        baseURL: baseURL,
                        sessionID: sessionID,
                        statement: statement(key)
                    )
                    return response.rows.map { (key, $0) }
                }
            }
            var collected: [(key: String, row: [String: JSONValue])] = []
            for try await rows in group {
                collected.append(contentsOf: rows)
            }
            return collected
        }
    }

    private static func nodeListStatement(tag: String, limit: Int) -> String {
        if tag == noteTag {
            return """
            MATCH (n:note)
            RETURN id(n) AS vid, n.note.name AS name, n.note.kind AS kind, n.note.ts AS ts
            ORDER BY ts DESC, vid ASC LIMIT \(limit + 1) OFFSET 0
            """
        }
        return """
        MATCH (n:\(tag))
        RETURN id(n) AS vid, n.\(tag).name AS name, n.\(tag).ts AS ts
        ORDER BY ts DESC, vid ASC LIMIT \(limit + 1) OFFSET 0
        """
    }

    private static func edgeListStatement(edgeKind: String, visibleIDFilter: String, limit: Int) -> String {
        if edgeKind == legacyEdgeKind {
            return """
            MATCH (a:note)-[e:rel]->(b:note)
            WHERE \(visibleIDFilter)
            RETURN id(a) AS src, id(b) AS dst, e.rel.kind AS kind
            ORDER BY src ASC, dst ASC LIMIT \(limit + 1) OFFSET 0
            """
        }
        return """
        MATCH (a)-[e:\(edgeKind)]->(b)
        WHERE \(visibleIDFilter)
        RETURN id(a) AS src, id(b) AS dst
        ORDER BY src ASC, dst ASC LIMIT \(limit + 1) OFFSET 0
        """
    }

    /// 엔진이 `WHERE <expr> IN [...]`을 지원하지 않으므로(실측: 항상 0행 반환),
    /// `==`을 OR로 체이닝해 "field가 ids 중 하나와 같다"를 표현한다.
    private static func idOrClause(field: String, ids: [Int64]) -> String {
        "(" + ids.map { "\(field) == \($0)" }.joined(separator: " OR ") + ")"
    }

    public func loadBody(
        paths: ManagerPaths,
        nodeID: Int64,
        tag: String,
        space: String? = nil
    ) async throws -> String {
        let credentials = try credentials(at: paths.byoriHome.appendingPathComponent("env"))
        let selectedSpace = try validatedSpace(space ?? credentials.space)
        let baseURL = try localBaseURL(port: paths.httpPort)
        let sessionID = try await createSession(baseURL: baseURL, password: credentials.password)
        defer { Task { await deleteSession(baseURL: baseURL, sessionID: sessionID) } }
        _ = try await query(
            baseURL: baseURL,
            sessionID: sessionID,
            statement: "USE \(selectedSpace)"
        )
        // module 태그만 body 대신 summary 프로퍼티를 쓴다(memory-ontology.md §4.1).
        let resolvedTag = Self.nodeTags.contains(tag) ? tag : Self.noteTag
        let property = resolvedTag == "module" ? "summary" : "body"
        let response = try await query(
            baseURL: baseURL,
            sessionID: sessionID,
            statement: "MATCH (n:\(resolvedTag)) WHERE id(n) == \(nodeID) RETURN n.\(resolvedTag).\(property) AS body LIMIT 1"
        )
        return response.rows.first?["body"]?.stringValue ?? ""
    }

    private func validatedSpace(_ space: String) throws -> String {
        func isASCIIAlpha(_ scalar: Unicode.Scalar) -> Bool {
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        }
        func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
            (48...57).contains(scalar.value)
        }
        guard !space.isEmpty, space.count <= 64,
              let first = space.unicodeScalars.first,
              isASCIIAlpha(first) || first.value == 95,
              space.unicodeScalars.allSatisfy({
                  isASCIIAlpha($0) || isASCIIDigit($0) || $0.value == 95
              }) else {
            throw KnowledgeGraphClientError.invalidConfiguration
        }
        return space
    }

    private func credentials(at envURL: URL) throws -> Credentials {
        guard FileManager.default.fileExists(atPath: envURL.path) else {
            throw KnowledgeGraphClientError.missingConfiguration
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: envURL.path)
        if let size = attributes?[.size] as? NSNumber, size.intValue > 64 * 1_024 {
            throw KnowledgeGraphClientError.invalidConfiguration
        }
        guard let contents = try? String(contentsOf: envURL, encoding: .utf8) else {
            throw KnowledgeGraphClientError.invalidConfiguration
        }
        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        guard let password = values["BYORIDB_ROOT_PASSWORD"] ?? values["BYORIDB_PASSWORD"],
              !password.isEmpty else {
            throw KnowledgeGraphClientError.missingConfiguration
        }
        let space = values["BYORIDB_MEMORY_SPACE"] ?? "claude_memory"
        guard isIdentifier(space) else { throw KnowledgeGraphClientError.invalidConfiguration }
        return Credentials(password: password, space: space)
    }

    private func isIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }

    private func localBaseURL(port: Int) throws -> URL {
        guard (1...65_535).contains(port),
              let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw KnowledgeGraphClientError.invalidConfiguration
        }
        return url
    }

    private func createSession(
        baseURL: URL,
        password: String
    ) async throws -> SessionIdentifier {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(SessionRequest(username: "root", password: password))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw KnowledgeGraphClientError.unavailable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw KnowledgeGraphClientError.invalidResponse
        }
        if status == 401 || status == 403 {
            throw KnowledgeGraphClientError.authenticationFailed
        }
        guard (200..<300).contains(status) else {
            throw KnowledgeGraphClientError.unavailable
        }
        guard let decoded = try? decoder.decode(SessionResponse.self, from: data),
              decoded.sessionID.isValid else {
            throw KnowledgeGraphClientError.invalidResponse
        }
        return decoded.sessionID
    }

    private func query(
        baseURL: URL,
        sessionID: SessionIdentifier,
        statement: String
    ) async throws -> QueryResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/query"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(QueryRequest(sessionID: sessionID, query: statement))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw KnowledgeGraphClientError.unavailable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw KnowledgeGraphClientError.invalidResponse
        }
        if status == 401 || status == 403 {
            throw KnowledgeGraphClientError.authenticationFailed
        }
        guard (200..<300).contains(status) else {
            throw KnowledgeGraphClientError.queryFailed
        }
        guard let decoded = try? decoder.decode(QueryResponse.self, from: data) else {
            throw KnowledgeGraphClientError.invalidResponse
        }
        return decoded
    }

    private func deleteSession(baseURL: URL, sessionID: SessionIdentifier) async {
        guard sessionID.isValid else { return }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/v1/session/\(sessionID.decimalString)")
        )
        request.httpMethod = "DELETE"
        _ = try? await session.data(for: request)
    }
}
