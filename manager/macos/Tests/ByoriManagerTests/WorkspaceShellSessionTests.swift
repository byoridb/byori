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
        XCTAssertNil(request.existingTaskID, "The agent task does not own the shell")
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
        model.newSessionDraft.taskChoice = .newTask
        model.newSessionDraft.newTaskTitle = "Fix the parser"
        model.chooseSessionLocationStrategy(.currentCheckout)
        model.chooseProvider("claude")
        model.chooseModel("default")
        await model.startSession()

        XCTAssertEqual(dataSource.startedRequests.map(\.sourceTreeID), ["primary123"])
        XCTAssertTrue(dataSource.createdWorktrees.isEmpty)
    }

    /// Reopening an active terminal focuses it instead of violating the task's
    /// one-open-session invariant or leaving another task behind.
    func testRepeatedTerminalOpenFocusesTheExistingSession() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.startShellSession()
        await model.startShellSession()

        XCTAssertEqual(dataSource.startedRequests.count, 1)
        XCTAssertEqual(dataSource.startedRequests[0].newTaskTitle, WorkspaceViewModel.shellTaskTitle)
        XCTAssertEqual(model.selection, .session("session-1"))
        XCTAssertEqual(dataSource.snapshot.projects[0].sourceTrees[0].tasks.count, 1)
        XCTAssertEqual(dataSource.snapshot.projects[0].sourceTrees[0].tasks[0].sessions.count, 1)
        XCTAssertNil(model.alert)
    }

    func testExplicitActiveAgentTargetCreatesASeparateShellTask() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot(withRunningAgent: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.startShellSession(target: .init(
            projectID: "project123", sourceTreeID: "primary123", existingTaskID: "task-agent"
        ))

        XCTAssertEqual(dataSource.startedRequests.count, 1)
        XCTAssertNil(dataSource.startedRequests.first?.existingTaskID)
        XCTAssertEqual(dataSource.snapshot.projects[0].sourceTrees[0].tasks[0].sessions.count, 1)
        XCTAssertEqual(dataSource.snapshot.projects[0].sourceTrees[0].tasks.count, 2)
        XCTAssertNil(model.alert)
    }

    func testEndedAgentTaskIsNeverReusedEvenWhenNamedTerminal() async {
        var snapshot = makeSnapshot(withRunningAgent: true)
        snapshot.projects[0].sourceTrees[0].tasks[0].title = WorkspaceViewModel.shellTaskTitle
        snapshot.projects[0].sourceTrees[0].tasks[0].sessions[0].state = .completed
        let dataSource = ShellDataSource(snapshot: snapshot)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.startShellSession(target: .init(
            projectID: "project123", sourceTreeID: "primary123", existingTaskID: "task-agent"
        ))

        XCTAssertNil(dataSource.startedRequests.first?.existingTaskID)
        XCTAssertEqual(dataSource.snapshot.projects[0].sourceTrees[0].tasks[0].sessions.count, 1)
        XCTAssertNil(model.alert)
    }

    func testEndedShellSessionReusesItsTaskWithoutDiscardingHistory() async {
        var snapshot = makeSnapshot(withRunningShell: true)
        snapshot.projects[0].sourceTrees[0].tasks[0].sessions[0].state = .completed
        snapshot.projects[0].sourceTrees[0].tasks[0].title = "Build terminal"
        let dataSource = ShellDataSource(snapshot: snapshot)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.startShellSession()

        XCTAssertEqual(dataSource.startedRequests.first?.existingTaskID, "task-shell")
        XCTAssertNil(dataSource.startedRequests.first?.newTaskTitle)
        XCTAssertEqual(dataSource.snapshot.projects[0].sourceTrees[0].tasks.count, 1)
        XCTAssertEqual(dataSource.snapshot.projects[0].sourceTrees[0].tasks[0].sessions.count, 2)
        XCTAssertNil(model.alert)
    }

    func testCompletedShellTaskIsNotReopened() async {
        var snapshot = makeSnapshot(withRunningShell: true)
        snapshot.projects[0].sourceTrees[0].tasks[0].status = .completed
        snapshot.projects[0].sourceTrees[0].tasks[0].sessions[0].state = .completed
        let dataSource = ShellDataSource(snapshot: snapshot)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.startShellSession()

        XCTAssertNil(dataSource.startedRequests.first?.existingTaskID)
        XCTAssertEqual(dataSource.snapshot.projects[0].sourceTrees[0].tasks.count, 2)
        XCTAssertNil(model.alert)
    }

    func testFreshSnapshotFindsShellCreatedAfterTheLastRefresh() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        dataSource.snapshot = makeSnapshot(withRunningShell: true)

        await model.startShellSession()

        XCTAssertTrue(dataSource.startedRequests.isEmpty)
        XCTAssertEqual(model.selection, .session("session-shell"))
        XCTAssertNil(model.alert)
    }

    func testDetachedShellReattachesWithoutCreatingASession() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot(withRunningAgent: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        dataSource.snapshot = makeSnapshot(withRunningAgent: true, withRunningShell: true)
        dataSource.snapshot.projects[0].sourceTrees[0].tasks[1].sessions[0].isDetached = true

        await model.startShellSession()

        XCTAssertEqual(dataSource.reattachedIDs, ["session-shell"])
        XCTAssertTrue(dataSource.startedRequests.isEmpty)
        XCTAssertEqual(model.selection, .session("session-shell"))
        XCTAssertEqual(model.selectedSession?.isDetached, false)
        XCTAssertNil(model.alert)
    }

    func testFailedDetachedShellReattachDoesNotStartAnotherShell() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        dataSource.snapshot = makeSnapshot(withRunningShell: true)
        dataSource.snapshot.projects[0].sourceTrees[0].tasks[0].sessions[0].isDetached = true
        dataSource.reattachFailure = WorkspaceAdapterError.invalidState("Lost terminal")

        await model.startShellSession()

        XCTAssertTrue(dataSource.startedRequests.isEmpty)
        XCTAssertEqual(model.alert?.title, "세션에 다시 연결하지 못했습니다")
        XCTAssertFalse(model.isStartingSession)
    }

    func testShellInAnotherCheckoutDoesNotCaptureTheRequestedLocation() async {
        var snapshot = makeSnapshot(withRunningShell: true)
        let otherTree = WorkspaceSourceTreeItem(
            id: "worktree456", projectID: "project123", name: "feature/work",
            url: URL(fileURLWithPath: "/tmp/byori-worktree"), kind: .managedWorktree,
            branch: "feature/work", headRevision: String(repeating: "a", count: 40),
            workingState: .clean, tasks: []
        )
        snapshot.projects[0].sourceTrees.append(otherTree)
        let dataSource = ShellDataSource(snapshot: snapshot)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.startShellSession(target: .init(
            projectID: "project123", sourceTreeID: "worktree456", existingTaskID: nil
        ))

        XCTAssertEqual(dataSource.startedRequests.first?.sourceTreeID, "worktree456")
        XCTAssertNil(dataSource.startedRequests.first?.existingTaskID)
        XCTAssertEqual(model.selection, .session("session-1"))
        XCTAssertTrue(dataSource.createdWorktrees.isEmpty)
    }

    func testRefreshFailureDoesNotLaunchUsingTheOldSnapshot() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        let selection = model.selection
        dataSource.loadFailure = WorkspaceAdapterError.invalidState("Refresh unavailable")

        await model.startShellSession()

        XCTAssertTrue(dataSource.startedRequests.isEmpty)
        XCTAssertEqual(model.selection, selection)
        XCTAssertNotNil(model.alert)
        XCTAssertFalse(model.isStartingSession)
    }

    func testRemovedCheckoutDoesNotFallBackToAnotherOrCreateWorktree() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        dataSource.snapshot.projects[0].sourceTrees = []

        await model.startShellSession()

        XCTAssertTrue(dataSource.startedRequests.isEmpty)
        XCTAssertTrue(dataSource.createdWorktrees.isEmpty)
        XCTAssertNotNil(model.alert)
    }

    func testRepeatedClicksDuringRefreshStartOnlyOneShell() async {
        let dataSource = ShellDataSource(snapshot: makeSnapshot())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        dataSource.suspendsLoad = true
        let first = Task { await model.startShellSession() }
        for _ in 0..<20 where !dataSource.hasPendingLoad { await Task.yield() }
        XCTAssertTrue(dataSource.hasPendingLoad)
        XCTAssertTrue(model.isStartingSession)

        await model.startShellSession()
        dataSource.resumeLoad()
        await first.value

        XCTAssertEqual(dataSource.startedRequests.count, 1)
        XCTAssertFalse(model.isStartingSession)
        XCTAssertNil(model.alert)
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
    var reattachedIDs: [String] = []
    var loadFailure: Error?
    var reattachFailure: Error?
    var suspendsLoad = false
    private var pendingLoad: CheckedContinuation<Void, Never>?
    var hasPendingLoad: Bool { pendingLoad != nil }

    init(snapshot: WorkspacePresentationSnapshot) {
        self.snapshot = snapshot
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        if let loadFailure { throw loadFailure }
        if suspendsLoad { await withCheckedContinuation { pendingLoad = $0 } }
        return snapshot
    }

    func resumeLoad() {
        suspendsLoad = false
        pendingLoad?.resume()
        pendingLoad = nil
    }

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
        guard let projectIndex = snapshot.projects.firstIndex(where: { $0.id == request.projectID }),
              let treeIndex = snapshot.projects[projectIndex].sourceTrees
                .firstIndex(where: { $0.id == request.sourceTreeID }) else {
            throw WorkspaceAdapterError.invalidState("Unknown checkout \(request.sourceTreeID)")
        }
        if let taskID = request.existingTaskID {
            guard let task = snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks.first(where: { $0.id == taskID }),
                  task.status.allowsNewSession else {
                throw WorkspaceAdapterError.invalidState("Task is missing or ended")
            }
            guard task.sessions.allSatisfy({ !$0.state.isActive && !$0.isDetached }) else {
                throw WorkspaceError.openSessionExists(taskID)
            }
        }
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
        if let existingIndex = snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks
            .firstIndex(where: { $0.id == taskID }) {
            snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks[existingIndex].sessions.append(session)
        } else {
            snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks.append(WorkspaceTaskItem(
                id: taskID,
                sourceTreeID: request.sourceTreeID,
                title: request.newTaskTitle ?? "Task",
                status: .active,
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                sessions: [session]
            ))
        }
        let task = snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks
            .first { $0.id == taskID }!
        return WorkspaceSessionLaunchResult(
            projectID: request.projectID,
            sourceTreeID: request.sourceTreeID,
            task: task,
            session: session
        )
    }

    func reattachSession(id: String) async throws -> WorkspaceSessionLaunchResult {
        reattachedIDs.append(id)
        if let reattachFailure { throw reattachFailure }
        for projectIndex in snapshot.projects.indices {
            for treeIndex in snapshot.projects[projectIndex].sourceTrees.indices {
                for taskIndex in snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks.indices {
                    guard let sessionIndex = snapshot.projects[projectIndex].sourceTrees[treeIndex]
                        .tasks[taskIndex].sessions.firstIndex(where: { $0.id == id }) else { continue }
                    snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks[taskIndex].sessions[sessionIndex].isDetached = false
                    let task = snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks[taskIndex]
                    return WorkspaceSessionLaunchResult(
                        projectID: snapshot.projects[projectIndex].id,
                        sourceTreeID: snapshot.projects[projectIndex].sourceTrees[treeIndex].id,
                        task: task, session: task.sessions[sessionIndex]
                    )
                }
            }
        }
        throw WorkspaceAdapterError.invalidState("Unknown shell session")
    }

    func sessionPersistenceWarning() async -> String? { nil }
}
