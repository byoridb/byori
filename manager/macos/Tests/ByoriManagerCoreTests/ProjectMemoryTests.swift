import XCTest
@testable import ByoriManagerCore

final class ProjectMemoryTests: XCTestCase {
    func testLifecyclePageDecodesWithoutOptionalSourceAndKeepsIDsExact() throws {
        let data = Data(#"{"items":[{"vid":"9223372036854775807","type":"decision","name":"decision:old","body":"rationale","ts":123,"lifecycle":"archived","review_reasons":["superseded"],"policy":{"archived":false,"pinned":true,"review_after":null,"source":null}}],"links":[],"truncated":true,"scan_incomplete":true}"#.utf8)
        let page = try JSONDecoder().decode(MemoryPage.self, from: data)
        XCTAssertEqual(page.items.first?.vid, "9223372036854775807")
        XCTAssertEqual(page.items.first?.lifecycle, "archived")
        XCTAssertEqual(page.items.first?.reviewReasonLabels, ["대체된 기록"])
        XCTAssertTrue(page.items.first?.policy.pinned == true)
        XCTAssertTrue(page.scanIncomplete == true)
    }

    func testCheckpointPayloadIsPrivateExactAndRemovedAfterExecution() async throws {
        let root = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = MemoryPayloadRunner()
        let paths = ManagerPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"))
        let client = ProjectMemoryClient(paths: paths, runner: runner)
        let draft = TaskCheckpointDraft(goal: "목표 $(shell)\nsecond line", verification: "not run")
        try await client.checkpoint(root: root, space: "project_space", taskID: "task-1", draft: draft)
        let capture = await runner.snapshot()
        let command = try XCTUnwrap(capture.command)
        let file = try XCTUnwrap(capture.file)
        XCTAssertFalse(command.arguments.joined().contains(draft.goal))
        XCTAssertEqual(command.workingDirectory, root.path)
        XCTAssertEqual(capture.mode, 0o600)
        XCTAssertEqual(capture.directoryMode, 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: capture.data) as? [String: String])
        XCTAssertEqual(payload["goal"], draft.goal)
        XCTAssertEqual(payload["verification"], "not run")
        XCTAssertEqual(payload["task_id"], "task-1")
    }

    func testFailedCallCleansPayloadAndDoesNotExposeRawError() async throws {
        let root = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = MemoryPayloadRunner(fails: true)
        let client = ProjectMemoryClient(paths: ManagerPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime")), runner: runner)
        do {
            _ = try await client.resume(root: root, space: "project_space", taskID: "task")
            XCTFail("failure must reach the caller")
        } catch { XCTAssertFalse(error.localizedDescription.contains("private-secret")) }
        let capture = await runner.snapshot()
        let file = try XCTUnwrap(capture.file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPartialBundleFailsInsteadOfUsingDifferentInstalledBridge() async throws {
        let root = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ManagerPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"))
        try FileManager.default.removeItem(at: paths.bundledMCP)
        do {
            _ = try await ProjectMemoryClient(paths: paths).command(action: "read", root: root, space: "project_space", payloadFile: root)
            XCTFail("partial bundle must fail")
        } catch let ManagerError.missingResource(path) { XCTAssertEqual(path, paths.bundledMCP.path) }
    }

    private func makeRuntime() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byori-memory-tests-\(UUID().uuidString)")
        for path in ["cli/byori.py", "mcp/byoridb_mcp.py", "mcp/code_graph.py"] {
            let file = root.appendingPathComponent("runtime").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        return root
    }
}

private actor MemoryPayloadRunner: CommandRunning {
    struct Capture: Sendable {
        var command: CommandSpec?
        var file: URL?
        var data = Data()
        var mode: Int?
        var directoryMode: Int?
    }
    private var capture = Capture()
    private let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func snapshot() -> Capture { capture }
    func run(_ command: CommandSpec) async -> CommandResult {
        capture.command = command
        if let index = command.arguments.firstIndex(of: "--payload-file"), index + 1 < command.arguments.count {
            let file = URL(fileURLWithPath: command.arguments[index + 1])
            capture.file = file
            capture.data = (try? Data(contentsOf: file)) ?? Data()
            capture.mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? Int
            capture.directoryMode = (try? FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions]) as? Int
        }
        return CommandResult(exitCode: fails ? 1 : 0, output: fails ? "private-secret" : "{\"ok\":true}")
    }
}
