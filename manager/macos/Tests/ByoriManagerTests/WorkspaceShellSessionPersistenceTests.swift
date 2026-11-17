import ByoriManagerCore
import XCTest
@testable import ByoriManager

/// Uses the real task store's one-open-session contract. Only the actual shell
/// process is substituted; accepting arbitrary session arrays in an in-memory
/// fixture would hide the duplicate-open failure these tests reproduce.
@MainActor
final class WorkspaceShellSessionPersistenceTests: XCTestCase {
    func testReopeningTerminalFocusesTheOnePersistedActiveShell() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = WorkspaceViewModel(dataSource: fixture.source)
        await model.load()

        await model.startShellSession(target: fixture.checkoutTarget)
        let firstSelection = model.selection
        await model.startShellSession(target: fixture.checkoutTarget)

        let tasks = try await fixture.store.tasks(projectID: fixture.project.id, limit: 100).tasks
        XCTAssertNil(model.alert, "A second open must not raise openSessionExists")
        XCTAssertEqual(fixture.source.startRequests.count, 1, "The second click must focus, not try to create another session")
        XCTAssertEqual(fixture.source.processLaunchCount, 1)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.sessions.count, 1)
        XCTAssertEqual(tasks.first?.sessions.first?.status, .active)
        XCTAssertEqual(model.selection, firstSelection)
    }

    func testActiveAgentTaskTargetGetsDedicatedShellTaskAndPreservesAgentRecord() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let agent = try await fixture.source.persistActiveSession(provider: .claude, title: "Agent work")
        let model = WorkspaceViewModel(dataSource: fixture.source)
        await model.load()

        await model.startShellSession(target: .init(
            projectID: fixture.project.id, sourceTreeID: fixture.checkoutID, existingTaskID: agent.task.id
        ))

        let tasks = try await fixture.store.tasks(projectID: fixture.project.id, limit: 100).tasks
        let persistedAgent = try await fixture.store.task(id: agent.task.id)
        XCTAssertNil(model.alert)
        XCTAssertEqual(persistedAgent, agent.task, "A shell click must not modify the agent's task or session")
        XCTAssertEqual(tasks.count, 2)
        let shellTask = try XCTUnwrap(tasks.first { $0.id != agent.task.id })
        XCTAssertEqual(shellTask.checkout, agent.task.checkout)
        XCTAssertEqual(shellTask.sessions.map(\.provider), [.shell])
        XCTAssertEqual(shellTask.sessions.first?.status, .active)
        XCTAssertNil(fixture.source.startRequests.first?.existingTaskID)
        XCTAssertEqual(model.selectedSession?.providerID, "shell")
    }

    func testEndedShellAppendsAReplacementOnlyAfterPersistedSessionEnds() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = WorkspaceViewModel(dataSource: fixture.source)
        await model.load()
        await model.startShellSession(target: fixture.checkoutTarget)
        let firstTaskList = try await fixture.store.tasks(projectID: fixture.project.id, limit: 100)
        let firstTask = try XCTUnwrap(firstTaskList.tasks.first)
        let firstSession = try XCTUnwrap(firstTask.sessions.first)
        _ = try await fixture.store.updateSessionStatus(
            taskID: firstTask.id, sessionID: firstSession.id, status: .completed
        )
        // The model still displays the old active session. Opening must use the
        // persisted terminal state, not focus that stale cached presentation.
        await model.startShellSession(target: fixture.checkoutTarget)

        let tasks = try await fixture.store.tasks(projectID: fixture.project.id, limit: 100).tasks
        XCTAssertNil(model.alert)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, firstTask.id)
        XCTAssertEqual(tasks.first?.sessions.map(\.status), [.completed, .active])
        XCTAssertEqual(fixture.source.processLaunchCount, 2)
        XCTAssertEqual(fixture.source.startRequests.last?.existingTaskID, firstTask.id)
        XCTAssertNotEqual(model.selectedSession?.id, firstSession.id)
    }

    func testShellCreatedAfterCachedSnapshotIsFocusedWithoutAnotherTask() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = WorkspaceViewModel(dataSource: fixture.source)
        await model.load()
        XCTAssertTrue(model.projects.first?.sourceTrees.first?.tasks.isEmpty == true)
        let external = try await fixture.source.persistActiveSession(provider: .shell, title: "터미널")

        await model.startShellSession(target: fixture.checkoutTarget)

        let tasks = try await fixture.store.tasks(projectID: fixture.project.id, limit: 100).tasks
        XCTAssertNil(model.alert)
        XCTAssertTrue(fixture.source.startRequests.isEmpty, "A fresh read must find the persisted shell before launching")
        XCTAssertEqual(fixture.source.processLaunchCount, 0)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first, external.task)
        XCTAssertEqual(model.selection, .session(external.session.id))
    }

    func testDetachedPersistedShellReattachesWithoutCreatingSessionMetadata() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = WorkspaceViewModel(dataSource: fixture.source)
        await model.load()
        let external = try await fixture.source.persistActiveSession(provider: .shell, title: "터미널", detached: true)

        await model.startShellSession(target: fixture.checkoutTarget)

        let tasks = try await fixture.store.tasks(projectID: fixture.project.id, limit: 100).tasks
        XCTAssertNil(model.alert)
        XCTAssertEqual(fixture.source.reattachedIDs, [external.session.id])
        XCTAssertTrue(fixture.source.startRequests.isEmpty)
        XCTAssertEqual(fixture.source.processLaunchCount, 0)
        XCTAssertEqual(tasks, [external.task])
        XCTAssertEqual(model.selection, .session(external.session.id))
        XCTAssertFalse(model.selectedSession?.isDetached ?? true)
    }

    private func makeFixture() async throws -> PersistedShellFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-persisted-shell-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let home = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try await WorkspaceGitService().initializeRepository(at: repository)
        let registry = WorkspaceProjectRegistry(home: home)
        let project = try await registry.registerProject(at: repository)
        let checkoutID = try XCTUnwrap(project.sourceTrees.first?.id)
        let store = WorkspaceTaskStore(home: home)
        let source = PersistedShellDataSource(registry: registry, store: store, project: project, checkoutID: checkoutID)
        return PersistedShellFixture(root: root, project: project, checkoutID: checkoutID, store: store, source: source)
    }
}

@MainActor
private struct PersistedShellFixture {
    let root: URL
    let project: WorkspaceProject
    let checkoutID: String
    let store: WorkspaceTaskStore
    let source: PersistedShellDataSource
    var checkoutTarget: WorkspaceNewSessionTarget {
        .init(projectID: project.id, sourceTreeID: checkoutID, existingTaskID: nil)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// This adapter does no shell reuse/selection. Every start request goes through
/// the production store and fails if its task already contains an open session.
@MainActor
private final class PersistedShellDataSource: WorkspaceDataSource {
    private let registry: WorkspaceProjectRegistry
    private let store: WorkspaceTaskStore
    private let project: WorkspaceProject
    private let checkoutID: String
    private var detachedIDs: Set<String> = []
    var startRequests: [WorkspaceSessionLaunchRequest] = []
    var reattachedIDs: [String] = []
    var processLaunchCount = 0

    init(registry: WorkspaceProjectRegistry, store: WorkspaceTaskStore, project: WorkspaceProject, checkoutID: String) {
        self.registry = registry
        self.store = store
        self.project = project
        self.checkoutID = checkoutID
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        let registered = try await registry.projects()
        var projects: [WorkspaceProjectItem] = []
        for project in registered {
            let tasks = try await store.tasks(projectID: project.id, limit: 100).tasks
            var trees: [WorkspaceSourceTreeItem] = []
            for tree in project.sourceTrees {
                let url = URL(fileURLWithPath: tree.path, isDirectory: true)
                let status = try await WorkspaceGitService().status(at: url, maxChanges: 10)
                trees.append(.init(id: tree.id, projectID: project.id, name: status.branch, url: url, kind: .primary,
                                   branch: status.branch, headRevision: status.headRevision,
                                   workingState: status.isClean ? .clean : .modified(changeCount: status.changes.count),
                                   tasks: tasks.filter { $0.checkout == .init(kind: .sourceTree, id: tree.id) }.map(taskItem)))
            }
            projects.append(.init(id: project.id, name: project.name, repositoryURL: URL(fileURLWithPath: project.rootPath),
                                  memorySpace: project.memorySpace, registration: .trusted, sourceTrees: trees, hiddenSourceTrees: []))
        }
        return .init(projects: projects)
    }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }

    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult {
        startRequests.append(request)
        guard request.projectID == project.id, request.sourceTreeID == checkoutID else {
            throw WorkspaceAdapterError.invalidState("Request left its registered checkout")
        }
        let task: WorkspaceTask
        if let existingID = request.existingTaskID {
            let existing = try await store.task(id: existingID)
            task = try XCTUnwrap(existing)
            guard task.projectID == request.projectID,
                  task.checkout == .init(kind: .sourceTree, id: request.sourceTreeID) else {
                throw WorkspaceAdapterError.invalidState("Request changed task ownership")
            }
        } else {
            task = try await store.createTask(projectID: request.projectID,
                                              checkout: .init(kind: .sourceTree, id: request.sourceTreeID),
                                              title: request.newTaskTitle ?? "Missing task title")
        }
        // Do not bypass WorkspaceTask.adding: this is the production regression
        // boundary that the earlier array-appending unit fixture did not enforce.
        let session = try await store.createSession(taskID: task.id, name: request.sessionName,
                                                     provider: .init(rawValue: request.providerID), model: "default")
        _ = try await store.updateSessionStatus(taskID: task.id, sessionID: session.id, status: .active,
                                                nativeSessionID: UUID().uuidString.lowercased())
        processLaunchCount += 1 // Substitutes only the actual PTY/shell process.
        return try await result(taskID: task.id, sessionID: session.id)
    }

    func reattachSession(id: String) async throws -> WorkspaceSessionLaunchResult {
        let tasks = try await store.tasks(projectID: project.id, limit: 100).tasks
        guard let task = tasks.first(where: { $0.sessions.contains(where: { $0.id == id }) }),
              let session = task.sessions.first(where: { $0.id == id }),
              !session.status.isTerminal, detachedIDs.contains(id) else {
            throw WorkspaceAdapterError.invalidState("Only a live detached process can be attached")
        }
        detachedIDs.remove(id)
        reattachedIDs.append(id)
        return try await result(taskID: task.id, sessionID: id)
    }

    func persistActiveSession(provider: WorkspaceProvider, title: String, detached: Bool = false) async throws
        -> (task: WorkspaceTask, session: WorkspaceSession) {
        let task = try await store.createTask(projectID: project.id, checkout: .init(kind: .sourceTree, id: checkoutID), title: title)
        let session = try await store.createSession(taskID: task.id, provider: provider, model: "default")
        let active = try await store.updateSessionStatus(taskID: task.id, sessionID: session.id, status: .active,
                                                        nativeSessionID: UUID().uuidString.lowercased())
        if detached { detachedIDs.insert(active.id) }
        let updated = try await store.task(id: task.id)
        return (try XCTUnwrap(updated), active)
    }

    private func result(taskID: String, sessionID: String) async throws -> WorkspaceSessionLaunchResult {
        let saved = try await store.task(id: taskID)
        let task = taskItem(try XCTUnwrap(saved))
        let session = try XCTUnwrap(task.sessions.first { $0.id == sessionID })
        return .init(projectID: project.id, sourceTreeID: checkoutID, task: task, session: session)
    }

    private func taskItem(_ task: WorkspaceTask) -> WorkspaceTaskItem {
        .init(id: task.id, sourceTreeID: task.checkout.id, title: task.title,
              status: WorkspaceTaskItemStatus(rawValue: task.status.rawValue) ?? .open, createdAt: task.createdAt,
              sessions: task.sessions.map { session in
                let state: WorkspaceSessionItemStatus
                switch session.status {
                case .created: state = .preparing
                case .active: state = .running
                case .completed: state = .completed
                case .failed: state = .failed
                case .cancelled: state = .cancelled
                }
                return .init(id: session.id, taskID: task.id, name: session.name, providerID: session.provider.rawValue,
                             providerName: session.provider.rawValue, providerSystemImage: "terminal",
                             modelID: session.model, modelName: session.model, state: state, statusDetail: nil,
                             startedAt: session.startedAt, endedAt: session.endedAt, nativeSessionID: session.nativeSessionID,
                             isDetached: detachedIDs.contains(session.id))
              })
    }
}
