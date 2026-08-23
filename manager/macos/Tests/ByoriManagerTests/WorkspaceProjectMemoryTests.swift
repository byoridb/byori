import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceProjectMemoryTests: XCTestCase {
    /// The graph used to start empty, so the first weeks of using Byori were spent
    /// earning the thing it advertises. The history is already in the clone; this is
    /// the app offering to read it.
    func testBuildingMemoryRunsForTheSelectedProjectAndReloadsContext() async {
        let dataSource = ProjectMemoryDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.buildProjectMemory()

        XCTAssertEqual(dataSource.builtProjectIDs, ["project123"])
        XCTAssertEqual(model.lastProjectMemorySummary, "wrote 350 memories and 453 relations")
        XCTAssertGreaterThanOrEqual(dataSource.contextLoads, 2, "the tab that was empty must reload")
        XCTAssertFalse(model.isBuildingProjectMemory)
        XCTAssertNil(model.alert)
    }

    func testAFailureIsReportedAndNotSilentlySwallowed() async {
        let dataSource = ProjectMemoryDataSource(snapshot: makeSnapshot())
        dataSource.failure = WorkspaceAdapterError.invalidState("byori init failed: no commits were read")
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.buildProjectMemory()

        XCTAssertEqual(model.alert?.title, "프로젝트 기억을 만들지 못했습니다")
        XCTAssertTrue(model.alert?.message.contains("no commits were read") == true)
        XCTAssertNil(model.lastProjectMemorySummary)
    }

    /// Reading a large repository takes minutes, so a second press must not start a
    /// second pass over the same history.
    func testASecondRequestWhileRunningIsIgnored() async {
        let dataSource = ProjectMemoryDataSource(snapshot: makeSnapshot())
        dataSource.gate = true
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        let first = Task { await model.buildProjectMemory() }
        // Let the first call reach its suspension inside the data source.
        for _ in 0..<50 where !model.isBuildingProjectMemory {
            await Task.yield()
        }
        await model.buildProjectMemory()
        dataSource.release()
        await first.value

        XCTAssertEqual(dataSource.builtProjectIDs, ["project123"])
    }

    func testNothingHappensWithoutASelectedProject() async {
        let dataSource = ProjectMemoryDataSource(snapshot: WorkspacePresentationSnapshot(projects: []))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.buildProjectMemory()

        XCTAssertTrue(dataSource.builtProjectIDs.isEmpty)
        XCTAssertNil(model.alert)
    }

    private func makeSnapshot() -> WorkspacePresentationSnapshot {
        let sourceTree = WorkspaceSourceTreeItem(
            id: "primary123",
            projectID: "project123",
            name: "main",
            url: URL(fileURLWithPath: "/tmp/byori", isDirectory: true),
            kind: .primary,
            branch: "main",
            headRevision: String(repeating: "a", count: 40),
            workingState: .clean,
            tasks: []
        )
        let project = WorkspaceProjectItem(
            id: "project123",
            name: "Byori",
            repositoryURL: URL(fileURLWithPath: "/tmp/byori", isDirectory: true),
            memorySpace: "byori_project123",
            registration: .trusted,
            sourceTrees: [sourceTree],
            hiddenSourceTrees: []
        )
        return WorkspacePresentationSnapshot(projects: [project])
    }
}

@MainActor
private final class ProjectMemoryDataSource: WorkspaceDataSource {
    var snapshot: WorkspacePresentationSnapshot
    var builtProjectIDs: [String] = []
    var contextLoads = 0
    var failure: Error?
    var gate = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(snapshot: WorkspacePresentationSnapshot) {
        self.snapshot = snapshot
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot { snapshot }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Not used by these tests.")
    }

    func loadContext(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceContextSnapshot {
        contextLoads += 1
        return WorkspaceContextSnapshot(items: [], isTruncated: false)
    }

    func buildProjectMemory(projectID: String) async throws -> String {
        builtProjectIDs.append(projectID)
        if gate {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        if let failure { throw failure }
        return "wrote 350 memories and 453 relations"
    }
}
