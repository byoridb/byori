import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceShellSessionTests: XCTestCase {
    /// A terminal is not a launch to configure — no provider, model or flag — so
    /// it opens directly instead of through the session sheet.
    func testOpeningATerminalNeedsNoSheet() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.startShellSession()

        XCTAssertFalse(model.isPresentingNewSession)
        XCTAssertEqual(dataSource.startedRequests.count, 1)
        let request = try! XCTUnwrap(dataSource.startedRequests.first)
        XCTAssertEqual(request.providerID, "shell")
        XCTAssertEqual(request.sourceTreeID, "primary123", "A shell belongs in the checkout on screen")
        XCTAssertEqual(request.newTaskTitle, WorkspaceViewModel.shellTaskTitle)
        XCTAssertTrue(dataSource.createdWorktrees.isEmpty, "A terminal must never cut a worktree")
        XCTAssertNil(model.alert)
    }

    /// The point of the feature: a shell beside a running agent, in the agent's
    /// own checkout. It must not be pushed elsewhere and must not displace it.
    func testTerminalOpensAlongsideARunningAgentInTheSameCheckout() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot(withRunningAgent: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.startShellSession()

        let request = try! XCTUnwrap(dataSource.startedRequests.first)
        XCTAssertEqual(request.sourceTreeID, "primary123")
        XCTAssertTrue(dataSource.createdWorktrees.isEmpty)
    }

    /// A running shell is not an agent writing in the checkout, so the next agent
    /// session still gets the primary checkout rather than a fresh worktree.
    func testARunningShellDoesNotMakeTheCheckoutBusy() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot(withRunningShell: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        let sourceTree = try! XCTUnwrap(model.projects.first?.sourceTrees.first)
        XCTAssertFalse(sourceTree.hasActiveWritingSession)

        await model.prepareNewSession()
        model.newSessionDraft.newTaskTitle = "Fix the parser"
        model.chooseProvider("claude")
        model.chooseModel("default")
        await model.startSession()

        XCTAssertEqual(dataSource.startedRequests.map(\.sourceTreeID), ["primary123"])
        XCTAssertTrue(dataSource.createdWorktrees.isEmpty)
    }

    /// Opening a terminal repeatedly must not leave a task behind each time.
    func testRepeatedTerminalsReuseTheShellTask() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.startShellSession()
        await model.startShellSession()

        XCTAssertEqual(dataSource.startedRequests.count, 2)
        XCTAssertEqual(dataSource.startedRequests[0].newTaskTitle, WorkspaceViewModel.shellTaskTitle)
        XCTAssertNil(dataSource.startedRequests[1].newTaskTitle, "The second terminal joins the first one's task")
        XCTAssertNotNil(dataSource.startedRequests[1].existingTaskID)
    }

    private func makeSnapshot(
        withRunningAgent: Bool = false,
        withRunningShell: Bool = false
    ) -> WorkspacePresentationSnapshot {
        var tasks: [WorkspaceTaskItem] = []
        if withRunningAgent {
            tasks.append(makeTask(
                id: "task-agent",
                title: "Already writing",
                session: makeSession(id: "session-agent", providerID: "claude")
            ))
        }
        if withRunningShell {
            tasks.append(makeTask(
                id: "task-shell",
                title: WorkspaceViewModel.shellTaskTitle,
                session: makeSession(id: "session-shell", providerID: "shell")
            ))
        }
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

    private func makeTask(id: String, title: String, session: WorkspaceSessionItem) -> WorkspaceTaskItem {
        WorkspaceTaskItem(
            id: id,
            sourceTreeID: "primary123",
            title: title,
            status: .active,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessions: [session]
        )
    }

    private func makeSession(id: String, providerID: String) -> WorkspaceSessionItem {
        WorkspaceSessionItem(
            id: id,
            taskID: providerID == "shell" ? "task-shell" : "task-agent",
            name: nil,
            providerID: providerID,
            providerName: providerID == "shell" ? "터미널" : "Claude Code",
            providerSystemImage: "terminal",
            modelID: "default",
            modelName: "CLI default",
            state: .running,
            statusDetail: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: nil,
            nativeSessionID: UUID().uuidString
        )
    }
}

@MainActor
private final class ShellDataSource: WorkspaceDataSource {
    struct CreatedWorktree: Equatable {
        let branch: String
    }

    var snapshot: WorkspacePresentationSnapshot
    var startedRequests: [WorkspaceSessionLaunchRequest] = []
    var createdWorktrees: [CreatedWorktree] = []

    init(snapshot: WorkspacePresentationSnapshot) {
        self.snapshot = snapshot
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot { snapshot }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] {
        [
            WorkspaceProviderOption(
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
            ),
            WorkspaceProviderOption(
                id: "shell",
                displayName: "터미널",
                systemImage: "apple.terminal",
                availability: .available,
                models: [WorkspaceModelOption(
                    id: "default",
                    displayName: "로그인 셸",
                    availability: .available,
                    acceptsCustomIdentifier: false
                )]
            ),
        ]
    }

    func branches(projectID: String) async throws -> [WorkspaceGitBranch] {
        [WorkspaceGitBranch(name: "main", isRemote: false, isCheckedOut: true)]
    }

    func createSourceTree(projectID: String, branch: String, startPoint: String?) async throws -> URL {
        createdWorktrees.append(.init(branch: branch))
        return URL(fileURLWithPath: "/tmp/byori-worktrees/\(branch)", isDirectory: true)
    }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        startedRequests.append(request)
        let index = startedRequests.count
        let session = WorkspaceSessionItem(
            id: "session-\(index)",
            taskID: request.existingTaskID ?? "task-\(index)",
            name: request.sessionName,
            providerID: request.providerID,
            providerName: request.providerID == "shell" ? "터미널" : "Claude Code",
            providerSystemImage: "terminal",
            modelID: "default",
            modelName: "CLI default",
            state: .running,
            statusDetail: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            endedAt: nil,
            nativeSessionID: UUID().uuidString
        )
        let taskID = session.taskID
        guard let treeIndex = snapshot.projects[0].sourceTrees
            .firstIndex(where: { $0.id == request.sourceTreeID }) else {
            throw WorkspaceAdapterError.invalidState("Unknown checkout \(request.sourceTreeID)")
        }
        if let existingIndex = snapshot.projects[0].sourceTrees[treeIndex].tasks
            .firstIndex(where: { $0.id == taskID }) {
            snapshot.projects[0].sourceTrees[treeIndex].tasks[existingIndex].sessions.append(session)
        } else {
            snapshot.projects[0].sourceTrees[treeIndex].tasks.append(WorkspaceTaskItem(
                id: taskID,
                sourceTreeID: request.sourceTreeID,
                title: request.newTaskTitle ?? "Task",
                status: .active,
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                sessions: [session]
            ))
        }
        let task = snapshot.projects[0].sourceTrees[treeIndex].tasks
            .first { $0.id == taskID }!
        return WorkspaceSessionLaunchResult(
            projectID: request.projectID,
            sourceTreeID: request.sourceTreeID,
            task: task,
            session: session
        )
    }

    func sessionPersistenceWarning() async -> String? { nil }
}
