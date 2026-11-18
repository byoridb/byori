import XCTest
@testable import ByoriManagerCore

/// Every graph read logs in, so every graph read has to log out the way the
/// engine contract defines it, or engine sessions pile up until their TTL.
final class ByoriGraphClientSessionTests: XCTestCase {
    private var home: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-graph-\(UUID().uuidString)", isDirectory: true)
        let byoriHome = home.appendingPathComponent(".byoridb", isDirectory: true)
        try FileManager.default.createDirectory(at: byoriHome, withIntermediateDirectories: true)
        try "BYORIDB_ROOT_PASSWORD=fixture\n".write(
            to: byoriHome.appendingPathComponent("env"),
            atomically: true,
            encoding: .utf8
        )
        paths = ManagerPaths(home: home, runtimeRoot: home, byoriHome: byoriHome, httpPort: 29_669)
        EngineFixture.reset()
    }

    override func tearDownWithError() throws {
        EngineFixture.reset()
        try? FileManager.default.removeItem(at: home)
    }

    func testVerifiedConnectionSignsOutWithTheContractRequest() async throws {
        try await makeClient().verifyConnection(paths: paths)

        XCTAssertEqual(EngineFixture.signOuts(), [.init(path: "/api/v1/session", header: "123456")])
    }

    func testFailedVerificationStillSignsOut() async {
        EngineFixture.failQueries()

        do {
            try await makeClient().verifyConnection(paths: paths)
            XCTFail("a failing query must fail verification")
        } catch {}

        XCTAssertEqual(EngineFixture.signOuts(), [.init(path: "/api/v1/session", header: "123456")])
    }

    func testGraphLoadSignsOutBeforeReturning() async throws {
        _ = try await makeClient().loadGraph(paths: paths, space: "fixture_space")

        XCTAssertEqual(EngineFixture.signOuts(), [.init(path: "/api/v1/session", header: "123456")])
    }

    func testFailedGraphLoadSignsOutBeforeThrowing() async {
        EngineFixture.failQueries()

        do {
            _ = try await makeClient().loadGraph(paths: paths, space: "fixture_space")
            XCTFail("a failing query must fail the load")
        } catch {}

        XCTAssertEqual(EngineFixture.signOuts(), [.init(path: "/api/v1/session", header: "123456")])
    }

    func testBodyLoadSignsOutBeforeReturning() async throws {
        _ = try await makeClient().loadBodies(
            paths: paths,
            requests: [KnowledgeBodyRequest(nodeID: 7, tag: "note")],
            space: "fixture_space"
        )

        XCTAssertEqual(EngineFixture.signOuts(), [.init(path: "/api/v1/session", header: "123456")])
    }

    func testUnsupportedSignOutDoesNotFailTheRead() async throws {
        EngineFixture.rejectSignOut()

        try await makeClient().verifyConnection(paths: paths)

        XCTAssertEqual(EngineFixture.signOuts().count, 1)
    }

    private func makeClient() -> ByoriGraphClient {
        ByoriGraphClient(
            serviceVerifier: LocalServiceVerifier(runner: TrustedServiceRunner()),
            protocolClasses: [EngineFixture.self]
        )
    }
}

/// Answers `launchctl print` and `lsof` as if the configured port belonged to
/// this user's ByoriDB job.
private struct TrustedServiceRunner: CommandRunning {
    func run(_ command: CommandSpec) async -> CommandResult {
        if command.executable.hasSuffix("launchctl") {
            return CommandResult(exitCode: 0, output: "\tpid = 4242\n")
        }
        return CommandResult(exitCode: 0, output: "p4242\n")
    }
}

/// A minimal engine: login hands out session 123456, queries return one row
/// (or 500 after `failQueries`), and sign-out requests are recorded.
private final class EngineFixture: URLProtocol, @unchecked Sendable {
    struct SignOut: Equatable {
        let path: String
        let header: String?
    }

    private struct State {
        var signOuts: [SignOut] = []
        var queriesFail = false
        var signOutStatus = 200
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset() { withState { $0 = State() } }
    static func failQueries() { withState { $0.queriesFail = true } }
    static func rejectSignOut() { withState { $0.signOutStatus = 405 } }
    static func signOuts() -> [SignOut] { withState { $0.signOuts } }

    private static func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body): (Int, String)
        switch (request.httpMethod ?? "GET", path) {
        case ("POST", "/api/v1/session"):
            (status, body) = (200, #"{"session_id":"123456"}"#)
        case ("POST", "/api/v1/query"):
            (status, body) = Self.withState { $0.queriesFail }
                ? (500, "{}")
                : (200, #"{"results":[{"name":"fixture","body":"text"}]}"#)
        case ("DELETE", _):
            let signOut = SignOut(path: path, header: request.value(forHTTPHeaderField: "X-ByoriDB-Session-Id"))
            status = Self.withState {
                $0.signOuts.append(signOut)
                return $0.signOutStatus
            }
            body = "{}"
        default:
            (status, body) = (404, "{}")
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
