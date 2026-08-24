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

    /// Adding a repository is the one moment the user is certainly looking, so it is
    /// where the offer belongs. Waiting for them to find the Context tab left the
    /// product's whole point invisible on the first run.
    func testAddingARepositoryOffersToReadItsHistory() async {
        let repository = URL(fileURLWithPath: "/tmp/byori", isDirectory: true)
        let dataSource = ProjectMemoryDataSource(snapshot: WorkspacePresentationSnapshot(projects: []))
        dataSource.snapshotAfterRegistration = makeSnapshot()
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.addProjectFolder(at: repository)

        XCTAssertEqual(model.projectMemoryOffer?.projectID, "project123")
        XCTAssertEqual(model.projectMemoryOffer?.projectName, "Byori")
        // The tab it is about is already open behind the dialog, so declining still
        // leaves the answer in view.
        XCTAssertEqual(model.inspectorTab, .context)
        XCTAssertEqual(model.selection, .project("project123"))
        XCTAssertTrue(dataSource.builtProjectIDs.isEmpty, "nothing runs until it is accepted")
    }

    func testAcceptingTheOfferBuildsThatProjectsMemory() async {
        let repository = URL(fileURLWithPath: "/tmp/byori", isDirectory: true)
        let dataSource = ProjectMemoryDataSource(snapshot: WorkspacePresentationSnapshot(projects: []))
        dataSource.snapshotAfterRegistration = makeSnapshot()
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        await model.addProjectFolder(at: repository)

        await model.acceptProjectMemoryOffer()

        XCTAssertNil(model.projectMemoryOffer)
        XCTAssertEqual(dataSource.builtProjectIDs, ["project123"])
    }

    /// Re-adding a repository that already has memories must not read as "start
    /// over", so a populated graph is never asked.
    func testAProjectThatAlreadyRemembersSomethingIsNotAsked() async {
        let repository = URL(fileURLWithPath: "/tmp/byori", isDirectory: true)
        let dataSource = ProjectMemoryDataSource(snapshot: WorkspacePresentationSnapshot(projects: []))
        dataSource.snapshotAfterRegistration = makeSnapshot()
        dataSource.contextItems = [
            WorkspaceContextItem(
                id: "1", kind: "decision", title: "decision:use-redb",
                summary: "Adopt pure-Rust redb.", provenance: "commit 71a98f",
                updatedAt: nil, tags: []
            )
        ]
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.addProjectFolder(at: repository)

        XCTAssertNil(model.projectMemoryOffer)
    }

    /// `byori init` needs the engine that just failed to answer, so an offer here
    /// would only produce a second error.
    func testAFailedContextReadOffersNothing() async {
        let repository = URL(fileURLWithPath: "/tmp/byori", isDirectory: true)
        let dataSource = ProjectMemoryDataSource(snapshot: WorkspacePresentationSnapshot(projects: []))
        dataSource.snapshotAfterRegistration = makeSnapshot()
        dataSource.contextFailure = WorkspaceAdapterError.invalidState("the engine is not answering")
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.addProjectFolder(at: repository)

        XCTAssertNil(model.projectMemoryOffer)
    }

    /// `byori open` registers the repository itself and then asks the app to open it,
    /// so the app's job is to notice the new project and land on it.
    func testOpeningARepositoryTheCLIAlreadyRegisteredSelectsItAndOffers() async {
        let dataSource = ProjectMemoryDataSource(snapshot: WorkspacePresentationSnapshot(projects: []))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        // What `byori open` did before the app was asked: wrote the registry entry.
        dataSource.snapshot = makeSnapshot()

        await model.openProject(at: URL(fileURLWithPath: "/tmp/byori", isDirectory: true))

        XCTAssertTrue(dataSource.registeredURLs.isEmpty, "it was already registered")
        XCTAssertEqual(model.selection, .project("project123"))
        XCTAssertEqual(model.inspectorTab, .context)
        XCTAssertEqual(model.projectMemoryOffer?.projectID, "project123")
    }

    /// A folder opened from Finder, or `open -a Byori <folder>`, was never registered
    /// by anything. Refusing it would be an app that opens only what it already knows.
    func testAnUnregisteredRepositoryIsRegisteredFirst() async {
        let dataSource = ProjectMemoryDataSource(snapshot: WorkspacePresentationSnapshot(projects: []))
        dataSource.snapshotAfterRegistration = makeSnapshot()
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.openProject(at: URL(fileURLWithPath: "/tmp/byori", isDirectory: true))

        XCTAssertEqual(dataSource.registeredURLs.map(\.path), ["/tmp/byori"])
        XCTAssertEqual(model.projectMemoryOffer?.projectID, "project123")
        XCTAssertNil(model.alert)
    }

    func testAFolderThatCannotBeRegisteredIsReportedNotIgnored() async {
        let dataSource = ProjectMemoryDataSource(snapshot: WorkspacePresentationSnapshot(projects: []))
        dataSource.registrationFailure = WorkspaceAdapterError
            .invalidState("repository is not a Git repository")
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.openProject(at: URL(fileURLWithPath: "/tmp/plain", isDirectory: true))

        XCTAssertEqual(model.alert?.title, "프로젝트를 열지 못했습니다")
        XCTAssertTrue(model.alert?.message.contains("not a Git repository") == true)
        XCTAssertNil(model.projectMemoryOffer)
    }

    /// A memory space belongs to the project, not to a checkout. Selecting a project
    /// row used to leave the tab on a spinner that never resolved, which is where the
    /// empty-graph affordance was supposed to be.
    func testSelectingAProjectRowReadsItsContext() async {
        let dataSource = ProjectMemoryDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        model.select(.project("project123"))
        for _ in 0..<200 where dataSource.contextRequests.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(dataSource.contextRequests.map(\.projectID), ["project123"])
        // Read from the primary checkout, since a project row names none.
        XCTAssertEqual(dataSource.contextRequests.map(\.sourceTreeID), ["primary123"])
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
    /// What `loadWorkspace` returns once a project has been registered.
    var snapshotAfterRegistration: WorkspacePresentationSnapshot?
    var builtProjectIDs: [String] = []
    var contextLoads = 0
    var contextRequests: [WorkspaceInspectorRequest] = []
    var contextItems: [WorkspaceContextItem] = []
    var contextFailure: Error?
    var registrationFailure: Error?
    var registeredURLs: [URL] = []
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
        contextRequests.append(request)
        if let contextFailure { throw contextFailure }
        return WorkspaceContextSnapshot(items: contextItems, isTruncated: false)
    }

    func inspectProjectFolder(at folderURL: URL) async throws -> WorkspaceProjectFolderStatus {
        .gitRepository(folderURL)
    }

    func registerProject(at repositoryURL: URL) async throws {
        if let registrationFailure { throw registrationFailure }
        registeredURLs.append(repositoryURL)
        if let snapshotAfterRegistration {
            snapshot = snapshotAfterRegistration
        }
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
