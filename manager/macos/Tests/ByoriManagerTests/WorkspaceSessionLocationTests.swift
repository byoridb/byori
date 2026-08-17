import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceSessionLocationTests: XCTestCase {
    /// One session at a time is the common case, and it should run where the user
    /// already works: no second copy of the repository, no cold build, nothing to
    /// clean up.
    func testSessionRunsInThePrimaryCheckoutWhenItIsFree() async {
        let dataSource = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await startSession(in: model, titled: "Fix the parser")

        XCTAssertTrue(dataSource.createdWorktrees.isEmpty, "A free checkout needs no worktree")
        XCTAssertEqual(dataSource.startedRequests.map(\.sourceTreeID), ["primary123"])
        XCTAssertNil(model.newSessionError)
    }

    /// The case worktrees exist for: something is already writing, so the second
    /// session needs its own files. Byori cuts it instead of asking.
    func testSecondConcurrentSessionGetsAWorktreeWithoutBeingAsked() async {
        let dataSource = LocationDataSource(snapshot: makeSnapshot(primaryBusy: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await startSession(in: model, titled: "Review the API")

        XCTAssertEqual(
            dataSource.createdWorktrees,
            [.init(projectID: "project123", branch: "byori/review-the-api", startPoint: "main")]
        )
        XCTAssertEqual(dataSource.startedRequests.map(\.sourceTreeID), ["worktree-byori/review-the-api"])
        XCTAssertNil(model.newSessionError)
    }

    /// Opening the sheet must not create anything: a cancelled sheet that left a
    /// branch and a directory behind would be worse than the button it replaced.
    func testOpeningAndCancellingTheSheetCreatesNothing() async {
        let dataSource = LocationDataSource(snapshot: makeSnapshot(primaryBusy: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.prepareNewSession()
        XCTAssertTrue(model.isPresentingNewSession)
        XCTAssertEqual(model.plannedSessionLocation, "새 워크트리 (Byori가 자동으로 만듭니다)")
        model.dismissNewSession()

        XCTAssertTrue(dataSource.createdWorktrees.isEmpty)
        XCTAssertTrue(dataSource.startedRequests.isEmpty)
    }

    func testPlannedLocationNamesTheCheckoutWhenOneIsFree() async {
        let dataSource = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.prepareNewSession()

        XCTAssertTrue(model.plannedSessionLocation.contains("main"))
    }

    func testBranchNamesAreDerivedPrefixedAndDeduplicated() {
        XCTAssertEqual(
            WorkspaceViewModel.availableBranchName(for: "Fix the parser", avoiding: []),
            "byori/fix-the-parser"
        )
        XCTAssertEqual(
            WorkspaceViewModel.availableBranchName(for: "  Fix   the parser!  ", avoiding: []),
            "byori/fix-the-parser"
        )
        XCTAssertEqual(
            WorkspaceViewModel.availableBranchName(for: nil, avoiding: []),
            "byori/session"
        )
        XCTAssertEqual(
            WorkspaceViewModel.availableBranchName(for: "설계 검토", avoiding: []),
            "byori/session",
            "A title with no ASCII alphanumerics still has to produce a legal branch name"
        )
        XCTAssertEqual(
            WorkspaceViewModel.availableBranchName(
                for: "Fix the parser",
                avoiding: ["byori/fix-the-parser", "byori/fix-the-parser-2"]
            ),
            "byori/fix-the-parser-3"
        )
    }

    private func startSession(in model: WorkspaceViewModel, titled title: String) async {
        await model.prepareNewSession()
        model.newSessionDraft.newTaskTitle = title
        model.chooseProvider("claude")
        model.chooseModel("default")
        await model.startSession()
    }

    private func makeSnapshot(primaryBusy: Bool) -> WorkspacePresentationSnapshot {
        let tasks: [WorkspaceTaskItem] = primaryBusy
            ? [WorkspaceTaskItem(
                id: "task123",
                sourceTreeID: "primary123",
                title: "Already writing",
                status: .active,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                sessions: [WorkspaceSessionItem(
                    id: "session123",
                    taskID: "task123",
                    name: nil,
                    providerID: "claude",
                    providerName: "Claude Code",
                    providerSystemImage: "terminal",
                    modelID: "default",
                    modelName: "CLI default",
                    state: .running,
                    statusDetail: nil,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    endedAt: nil,
                    nativeSessionID: UUID().uuidString
                )]
            )]
            : []
        let primary = WorkspaceSourceTreeItem(
            id: "primary123",
            projectID: "project123",
            name: "main",
            url: URL(fileURLWithPath: "/tmp/byori", isDirectory: true),
            kind: .primary,
            branch: "main",
            headRevision: String(repeating: "a", count: 40),
            workingState: .clean,
            tasks: tasks
        )
        let project = WorkspaceProjectItem(
            id: "project123",
            name: "Byori",
            repositoryURL: URL(fileURLWithPath: "/tmp/byori", isDirectory: true),
            memorySpace: "byori_project123",
            registration: .trusted,
            sourceTrees: [primary],
            hiddenSourceTrees: []
        )
        return WorkspacePresentationSnapshot(projects: [project])
    }
}

@MainActor
private final class LocationDataSource: WorkspaceDataSource {
    struct CreatedWorktree: Equatable {
        let projectID: String
        let branch: String
        let startPoint: String?
    }

    var snapshot: WorkspacePresentationSnapshot
    var createdWorktrees: [CreatedWorktree] = []
    var startedRequests: [WorkspaceSessionLaunchRequest] = []

    init(snapshot: WorkspacePresentationSnapshot) {
        self.snapshot = snapshot
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot { snapshot }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] {
        [WorkspaceProviderOption(
            id: "claude",
            displayName: "Claude Code",
            systemImage: "terminal",
            availability: .available,
            models: [WorkspaceModelOption(
                id: "default",
                displayName: "CLI default",
                availability: .available,
                acceptsCustomIdentifier: false
            )]
        )]
    }

    func branches(projectID: String) async throws -> [WorkspaceGitBranch] {
        [WorkspaceGitBranch(name: "main", isRemote: false, isCheckedOut: true)]
    }

    func createSourceTree(
        projectID: String,
        branch: String,
        startPoint: String?
    ) async throws -> URL {
        createdWorktrees.append(.init(projectID: projectID, branch: branch, startPoint: startPoint))
        let created = WorkspaceSourceTreeItem(
            id: "worktree-\(branch)",
            projectID: projectID,
            name: branch,
            url: URL(fileURLWithPath: "/tmp/byori-worktrees/\(branch)", isDirectory: true),
            kind: .managedWorktree,
            branch: branch,
            headRevision: String(repeating: "b", count: 40),
            workingState: .clean,
            tasks: []
        )
        snapshot.projects[0].sourceTrees.append(created)
        return created.url
    }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        startedRequests.append(request)
        let session = WorkspaceSessionItem(
            id: "session-\(startedRequests.count)",
            taskID: "task-\(startedRequests.count)",
            name: request.sessionName,
            providerID: request.providerID,
            providerName: "Claude Code",
            providerSystemImage: "terminal",
            modelID: "default",
            modelName: "CLI default",
            state: .running,
            statusDetail: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            endedAt: nil,
            nativeSessionID: UUID().uuidString
        )
        let task = WorkspaceTaskItem(
            id: session.taskID,
            sourceTreeID: request.sourceTreeID,
            title: request.newTaskTitle ?? "Task",
            status: .active,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            sessions: [session]
        )
        guard let treeIndex = snapshot.projects[0].sourceTrees
            .firstIndex(where: { $0.id == request.sourceTreeID }) else {
            throw WorkspaceAdapterError.invalidState("Unknown source tree \(request.sourceTreeID)")
        }
        snapshot.projects[0].sourceTrees[treeIndex].tasks.append(task)
        return WorkspaceSessionLaunchResult(
            projectID: request.projectID,
            sourceTreeID: request.sourceTreeID,
            task: task,
            session: session
        )
    }

    func sessionPersistenceWarning() async -> String? { nil }
}
