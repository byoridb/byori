import XCTest
@testable import ByoriManagerCore

final class CodeIndexTests: XCTestCase {
    func testVersion035SnapshotWithoutLanguageCountsStillDecodes() throws {
        let json = #"{"checkout_id":"aaaaaaaaaaaaaaaa","index":{"root":"/tmp/repo","checkout_id":"aaaaaaaaaaaaaaaa","snapshot_id":"old","revision":"abc","indexed_at":1794297601451,"files":4,"symbols":8,"resolved_references":3,"unresolved_references":2,"languages":["swift"],"diagnostics":[],"diagnostics_count":0,"diagnostics_truncated":false}}"#
        let response = try JSONDecoder().decode(CodeIndexResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.indexed)
        XCTAssertEqual(response.index?.indexedAt, 1_794_297_601_451)
        XCTAssertNil(response.index?.languageStats)
        XCTAssertNil(response.verification)
        XCTAssertEqual(response.symbols, [])
        XCTAssertFalse(response.truncated)
    }

    func testBoundedSourceVerificationDecodesSeparatelyFromSnapshot() throws {
        let json = #"{"checkout_id":"aaaaaaaaaaaaaaaa","index":null,"verification":{"state":"not_checked","complete":false,"checked_at":1234,"snapshot_id":"a","checked_files":0,"skipped_files":0,"added":0,"modified":0,"deleted":0,"samples":[],"reason":"byte_limit","current_revision":null,"revision_changed":null,"coverage":"source bytes only"}}"#
        let response = try JSONDecoder().decode(CodeIndexResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.verification?.state, "not_checked")
        XCTAssertEqual(response.verification?.reason, "byte_limit")
        XCTAssertFalse(response.verification?.complete ?? true)
        XCTAssertEqual(response.verification?.checkedAt, 1234)
    }

    func testUnindexedResponseAndUnresolvedReferencesDecode() throws {
        let empty = try JSONDecoder().decode(CodeIndexResponse.self, from: Data(#"{"checkout_id":"aaaaaaaaaaaaaaaa","indexed":false,"index":null}"#.utf8))
        XCTAssertFalse(empty.indexed)
        let reference = try JSONDecoder().decode(CodeIndexRelation.self, from: Data(#"{"id":"ref","source":"symbol:a","target":null,"name":"dynamic.run","kind":"calls","file":"main.py","line":2,"resolution":"unresolved"}"#.utf8))
        XCTAssertNil(reference.target)
        XCTAssertEqual(reference.resolution, "unresolved")
    }

    func testQueryUsesBundledPairWithoutRequiringAnIndexerAndPreservesLiteralArguments() async throws {
        let root = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ManagerPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"))
        let service = ManagerService(paths: paths)
        let command = try await service.codeIndexCommand(
            CodeIndexRequest(action: .symbols, query: "--hello ' $()", language: "swift", file: "dir/a.swift", offset: 50),
            projectRoot: root.appendingPathComponent("worktree"), space: "project_space"
        )
        XCTAssertTrue(command.arguments.contains("--query=--hello ' $()"))
        XCTAssertTrue(command.arguments.contains("--file=dir/a.swift"))
        XCTAssertEqual(command.arguments.prefix(3), [paths.bundledByoriCLI.path, "code", "symbols"])
        XCTAssertEqual(command.workingDirectory, root.appendingPathComponent("worktree").path)
        XCTAssertNil(command.environment["BYORI_INDEXER"])
        XCTAssertEqual(command.timeout, 45)
    }

    func testIncompleteBundleDoesNotFallBackToInstalledRuntime() async throws {
        let root = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ManagerPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"))
        try FileManager.default.removeItem(at: paths.bundledCodeGraph)
        do {
            _ = try await ManagerService(paths: paths).codeIndexCommand(.init(action: .status), projectRoot: root, space: "project_space")
            XCTFail("incomplete matching bridge must fail")
        } catch let ManagerError.missingResource(path) {
            XCTAssertEqual(path, paths.bundledCodeGraph.path)
        }
    }

    func testInvalidBoundsAreRejectedBeforeExecuting() async throws {
        let service = ManagerService()
        do {
            _ = try await service.codeIndexCommand(.init(action: .files, limit: 101), projectRoot: URL(fileURLWithPath: "/tmp/project"), space: "project_space")
            XCTFail("unbounded query must fail")
        } catch let ManagerError.prerequisite(message) {
            XCTAssertTrue(message.contains("조회 조건"))
        }
    }

    func testFailureAndMalformedResponseDoNotExposeRawOutput() async throws {
        let root = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ManagerPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"))
        for code in [Int32(0), Int32(1)] {
            let service = ManagerService(paths: paths, runner: CodeQueryRunner(result: .init(exitCode: code, output: "secret-token")))
            do {
                _ = try await service.queryCodeIndex(.init(action: .status), projectRoot: root, space: "project_space")
                XCTFail("invalid response must fail")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("secret-token"))
            }
        }
    }

    private func makeRuntime() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byori-code-query-\(UUID().uuidString)")
        for relative in ["runtime/cli/byori.py", "runtime/mcp/byoridb_mcp.py", "runtime/mcp/code_graph.py"] {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# fixture\n".utf8).write(to: file)
        }
        return root
    }
}

private struct CodeQueryRunner: CommandRunning {
    let result: CommandResult
    func run(_ command: CommandSpec) async -> CommandResult { result }
}
