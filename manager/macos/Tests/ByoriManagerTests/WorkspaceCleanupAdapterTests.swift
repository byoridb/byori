import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceCleanupAdapterTests: XCTestCase {
    func testArchivedTaskCanBeListedAndRestoredWithoutChangingSessions() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let original = try await fixture.makeEndedTask()
        _ = try await fixture.source.loadWorkspace()
        try await fixture.source.archiveTask(id: original.id)
        let listed = try await fixture.source.archivedTasks(projectID: fixture.project.id)
        XCTAssertEqual(listed.items.map(\.id), [original.id])
        XCTAssertNil(listed.items.first?.restoreUnavailableReason)
        try await fixture.source.restoreTask(id: original.id)
        let restored = try await fixture.tasks.task(id: original.id)
        XCTAssertEqual(restored, original)
        XCTAssertTrue(restored?.sessions.allSatisfy { $0.status.isTerminal } == true)
        let remaining = try await fixture.source.archivedTasks(projectID: fixture.project.id)
        XCTAssertTrue(remaining.items.isEmpty)
    }

    func testRemovedProjectCannotHaveItsArchivedTaskRestored() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let original = try await fixture.makeEndedTask()
        _ = try await fixture.source.loadWorkspace()
        try await fixture.source.archiveTask(id: original.id)
        _ = try await fixture.registry.removeProject(id: fixture.project.id)
        do {
            try await fixture.source.restoreTask(id: original.id)
            XCTFail("Restoring requires a currently registered project")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("등록된 프로젝트"))
        }
        let archived = try await fixture.tasks.archivedTask(id: original.id)
        let active = try await fixture.tasks.task(id: original.id)
        XCTAssertEqual(archived, original)
        XCTAssertNil(active)
    }

    func testMissingCheckoutIsReportedAndRestoreLeavesArchiveIntact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let original = try await fixture.makeEndedTask()
        _ = try await fixture.source.loadWorkspace()
        try await fixture.source.archiveTask(id: original.id)
        try FileManager.default.moveItem(at: fixture.repository, to: fixture.root.appendingPathComponent("moved-repository"))
        _ = try await fixture.source.loadWorkspace()
        let listed = try await fixture.source.archivedTasks(projectID: fixture.project.id)
        XCTAssertNotNil(listed.items.first?.restoreUnavailableReason)
        do {
            try await fixture.source.restoreTask(id: original.id)
            XCTFail("Missing checkout must not receive a restored task")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("작업 폴더"))
        }
        let archived = try await fixture.tasks.archivedTask(id: original.id)
        XCTAssertEqual(archived, original)
    }

    func testNewActiveShellAfterCachedSnapshotBlocksArchive() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let original = try await fixture.makeEndedTask()
        _ = try await fixture.source.loadWorkspace()
        let shell = try await fixture.tasks.createSession(taskID: original.id, provider: .shell, model: "default")
        _ = try await fixture.tasks.updateSessionStatus(taskID: original.id, sessionID: shell.id, status: .active)
        do {
            try await fixture.source.archiveTask(id: original.id)
            XCTFail("A fresh persisted active shell must block a stale archive request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("active session"))
        }
        let task = try await fixture.tasks.task(id: original.id)
        let archived = try await fixture.tasks.archivedTask(id: original.id)
        XCTAssertNotNil(task)
        XCTAssertNil(archived)
    }

    private func makeFixture() async throws -> CleanupAdapterFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-cleanup-adapter-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let workspaceHome = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try await WorkspaceGitService().initializeRepository(at: repository)
        let registry = WorkspaceProjectRegistry(home: workspaceHome)
        let project = try await registry.registerProject(at: repository)
        let paths = ManagerPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"))
        let suite = "WorkspaceCleanupAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runner = CleanupAdapterNoCommands()
        let source = LiveWorkspaceDataSource(
            managerService: ManagerService(paths: paths, runner: runner),
            terminalController: TerminalSessionController(tmuxService: TmuxSessionService(paths: paths, runner: runner)),
            claudeGatewaySettings: ClaudeGatewaySettingsController(defaults: defaults, credentialStore: CleanupAdapterNoCredentials()),
            workspaceHome: workspaceHome
        )
        let snapshot = try await source.loadWorkspace()
        let checkoutID = try XCTUnwrap(snapshot.projects.first?.sourceTrees.first?.id)
        return CleanupAdapterFixture(root: root, repository: repository, project: project, checkoutID: checkoutID,
                                     registry: registry, tasks: WorkspaceTaskStore(home: workspaceHome), source: source,
                                     defaults: defaults, suite: suite)
    }
}

@MainActor
private struct CleanupAdapterFixture {
    let root: URL
    let repository: URL
    let project: WorkspaceProject
    let checkoutID: String
    let registry: WorkspaceProjectRegistry
    let tasks: WorkspaceTaskStore
    let source: LiveWorkspaceDataSource
    let defaults: UserDefaults
    let suite: String

    func makeEndedTask() async throws -> WorkspaceTask {
        let task = try await tasks.createTask(projectID: project.id,
                                              checkout: .init(kind: .sourceTree, id: checkoutID), title: "Ended task")
        let session = try await tasks.createSession(taskID: task.id, provider: .claude, model: "default")
        _ = try await tasks.updateSessionStatus(taskID: task.id, sessionID: session.id, status: .active)
        _ = try await tasks.updateSessionStatus(taskID: task.id, sessionID: session.id, status: .completed)
        let ended = try await tasks.task(id: task.id)
        return try XCTUnwrap(ended)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct CleanupAdapterNoCommands: CommandRunning {
    func run(_ command: CommandSpec) async -> CommandResult {
        CommandResult(exitCode: 1, output: "unavailable in test")
    }
}

private struct CleanupAdapterNoCredentials: ClaudeGatewayCredentialStoring {
    func readCredential() throws -> String? { nil }
    func writeCredential(_ credential: String) throws {}
    func deleteCredential() throws {}
}
