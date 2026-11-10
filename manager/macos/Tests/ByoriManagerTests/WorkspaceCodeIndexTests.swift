import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceCodeIndexTests: XCTestCase {
    func testProjectEntryChoosesPrimaryAndWorktreeEntryKeepsItsCheckout() async throws {
        let source = IndexWorkspaceSource()
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.select(.project("project"))
        model.showCodeIndex()
        XCTAssertEqual(model.codeIndexScope?.sourceTreeID, "primary")
        XCTAssertEqual(model.codeIndexScope?.space, "byori_project")

        model.select(.sourceTree("worktree"))
        model.showCodeIndex()
        let scope = try XCTUnwrap(model.codeIndexScope)
        XCTAssertEqual(scope.sourceTreeID, "worktree")
        XCTAssertEqual(scope.root.path, "/tmp/byori-feature")
        model.dismissCodeIndex()
        XCTAssertNil(model.codeIndexScope)
        model.showCodeIndex()
        XCTAssertNotEqual(scope.id, model.codeIndexScope?.id)
    }

    func testQueriesSourceReadsAndAnalysisKeepCapturedWorktreeAfterSelectionMoves() async throws {
        let source = IndexWorkspaceSource()
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.select(.sourceTree("worktree"))
        model.showCodeIndex()
        let scope = try XCTUnwrap(model.codeIndexScope)
        let provider = model.codeIndexProvider(for: scope)
        model.select(.sourceTree("primary"))

        _ = try await provider.queryCodeIndex(.init(action: .status), projectRoot: scope.root, space: scope.space)
        _ = try await model.readIndexedSource("src/main.rs", scope: scope)
        try await model.analyzeCodeIndex(scope: scope)

        XCTAssertEqual(source.queryCheckout, "worktree")
        XCTAssertEqual(source.sourceRead?.sourceTreeID, "worktree")
        XCTAssertEqual(source.sourceRead?.relativePath, "src/main.rs")
        XCTAssertEqual(source.analyzedCheckout, "worktree")
        XCTAssertFalse(model.isBuildingProjectMemory)
    }

    func testProviderRejectsMismatchedRootAndSpaceBeforeReading() async throws {
        let source = IndexWorkspaceSource()
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.select(.project("project"))
        model.showCodeIndex()
        let scope = try XCTUnwrap(model.codeIndexScope)
        let provider = model.codeIndexProvider(for: scope)
        for (root, space) in [(scope.root, "another_space"), (URL(fileURLWithPath: "/tmp/elsewhere"), scope.space)] {
            do {
                _ = try await provider.queryCodeIndex(.init(action: .status), projectRoot: root, space: space)
                XCTFail("A different checkout must never be queried through this browser.")
            } catch { XCTAssertNil(source.queryCheckout) }
        }
    }

    func testAnalysisFailureRemainsAnErrorAndClearsRunningState() async throws {
        let source = IndexWorkspaceSource()
        source.analysisFails = true
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.select(.project("project"))
        model.showCodeIndex()
        let scope = try XCTUnwrap(model.codeIndexScope)
        do {
            try await model.analyzeCodeIndex(scope: scope)
            XCTFail("Analysis failure must reach the code index screen.")
        } catch {
            XCTAssertFalse(model.isBuildingProjectMemory)
            XCTAssertNil(model.lastProjectMemorySummary)
        }
    }
}

@MainActor
private final class IndexWorkspaceSource: WorkspaceDataSource {
    var queryCheckout: String?
    var sourceRead: WorkspaceFileReadRequest?
    var analyzedCheckout: String?
    var analysisFails = false

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        let primary = WorkspaceSourceTreeItem(
            id: "primary", projectID: "project", name: "main",
            url: URL(fileURLWithPath: "/tmp/byori"), kind: .primary,
            branch: "main", headRevision: nil, workingState: .clean, tasks: []
        )
        let worktree = WorkspaceSourceTreeItem(
            id: "worktree", projectID: "project", name: "feature",
            url: URL(fileURLWithPath: "/tmp/byori-feature"), kind: .managedWorktree,
            branch: "feature", headRevision: nil, workingState: .clean, tasks: []
        )
        return WorkspacePresentationSnapshot(projects: [WorkspaceProjectItem(
            id: "project", name: "Byori", repositoryURL: primary.url, memorySpace: "byori_project",
            registration: .trusted, sourceTrees: [worktree, primary], hiddenSourceTrees: []
        )])
    }
    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }
    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("unused")
    }
    func readCodeIndex(
        _ request: CodeIndexRequest, projectID: String, sourceTreeID: String
    ) async throws -> CodeIndexResponse {
        queryCheckout = sourceTreeID
        return CodeIndexResponse(checkoutID: sourceTreeID)
    }
    func readFile(_ request: WorkspaceFileReadRequest) async throws -> WorkspaceFileDocument {
        sourceRead = request
        return WorkspaceFileDocument(relativePath: request.relativePath, text: "fn main() {}", revision: "hash", byteSize: 12)
    }
    func buildProjectMemory(projectID: String, sourceTreeID: String) async throws -> String {
        analyzedCheckout = sourceTreeID
        if analysisFails { throw WorkspaceAdapterError.invalidState("index failed") }
        return "indexed worktree"
    }
}
