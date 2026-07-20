import Foundation

public protocol KnowledgeGraphProviding: Sendable {
    func loadGraph(paths: ManagerPaths, nodeLimit: Int) async throws -> KnowledgeGraphSnapshot
    func loadBody(paths: ManagerPaths, nodeID: Int64) async throws -> String
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
            return "ByoriDB 인증에 실패했습니다. 설치 복구로 연결 정보를 확인해 주세요."
        case .queryFailed:
            return "지식 그래프를 조회하지 못했습니다. ByoriDB 버전과 로그를 확인해 주세요."
        case .invalidResponse:
            return "ByoriDB가 해석할 수 없는 응답을 반환했습니다."
        }
    }
}

public actor ByoriGraphClient: KnowledgeGraphProviding {
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

    public func loadGraph(
        paths: ManagerPaths,
        nodeLimit: Int = 200
    ) async throws -> KnowledgeGraphSnapshot {
        let limit = min(max(nodeLimit, 1), 200)
        let edgeLimit = min(limit * 3, 500)
        let credentials = try credentials(at: paths.byoriHome.appendingPathComponent("env"))
        let baseURL = try localBaseURL(port: paths.httpPort)
        let sessionID = try await createSession(baseURL: baseURL, password: credentials.password)
        defer { Task { await deleteSession(baseURL: baseURL, sessionID: sessionID) } }

        _ = try await query(
            baseURL: baseURL,
            sessionID: sessionID,
            statement: "USE \(credentials.space)"
        )
        let nodeResponse = try await query(
            baseURL: baseURL,
            sessionID: sessionID,
            statement: """
            MATCH (n:note)
            RETURN id(n) AS vid, n.note.name AS name, n.note.kind AS kind, n.note.ts AS ts
            ORDER BY vid ASC LIMIT \(limit + 1) OFFSET 0
            """
        )
        let edgeResponse = try await query(
            baseURL: baseURL,
            sessionID: sessionID,
            statement: """
            MATCH (a:note)-[e:rel]->(b:note)
            RETURN id(a) AS src, id(b) AS dst, e.rel.kind AS kind
            ORDER BY src ASC, dst ASC LIMIT \(edgeLimit + 1) OFFSET 0
            """
        )

        let nodesTruncated = nodeResponse.rows.count > limit
        var seenNodes = Set<Int64>()
        let nodes = nodeResponse.rows.prefix(limit).compactMap { row -> KnowledgeNode? in
            guard let id = row["vid"]?.int64Value,
                  let name = row["name"]?.stringValue,
                  seenNodes.insert(id).inserted else { return nil }
            return KnowledgeNode(
                id: id,
                name: name,
                kind: row["kind"]?.stringValue ?? "note",
                timestamp: row["ts"]?.int64Value ?? 0
            )
        }
        let knownIDs = Set(nodes.map(\.id))
        let edgesTruncated = edgeResponse.rows.count > edgeLimit
        var seenEdges = Set<KnowledgeEdge>()
        let edges = edgeResponse.rows.prefix(edgeLimit).compactMap { row -> KnowledgeEdge? in
            guard let source = row["src"]?.int64Value,
                  let target = row["dst"]?.int64Value,
                  knownIDs.contains(source), knownIDs.contains(target) else { return nil }
            let edge = KnowledgeEdge(
                source: source,
                target: target,
                kind: row["kind"]?.stringValue ?? "relates_to"
            )
            return seenEdges.insert(edge).inserted ? edge : nil
        }
        return KnowledgeGraphSnapshot(
            nodes: nodes,
            edges: edges,
            nodesTruncated: nodesTruncated,
            edgesTruncated: edgesTruncated
        )
    }

    public func loadBody(paths: ManagerPaths, nodeID: Int64) async throws -> String {
        let credentials = try credentials(at: paths.byoriHome.appendingPathComponent("env"))
        let baseURL = try localBaseURL(port: paths.httpPort)
        let sessionID = try await createSession(baseURL: baseURL, password: credentials.password)
        defer { Task { await deleteSession(baseURL: baseURL, sessionID: sessionID) } }
        _ = try await query(
            baseURL: baseURL,
            sessionID: sessionID,
            statement: "USE \(credentials.space)"
        )
        let response = try await query(
            baseURL: baseURL,
            sessionID: sessionID,
            statement: "MATCH (n:note) WHERE id(n) == \(nodeID) RETURN n.note.body AS body LIMIT 1"
        )
        return response.rows.first?["body"]?.stringValue ?? ""
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
