import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceBranchCreationTests: XCTestCase {
    func testActiveShellAllowsBranchCreationButStillBlocksProjectRemoval() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.addActiveSession(provider: .shell)

        try await fixture.source.createBranch(
            projectID: fixture.project.id, sourceTreeID: fixture.checkoutID,
            name: "byori/new-task", startPoint: "main"
        )
        let status = try await WorkspaceGitService().status(at: fixture.repository, maxChanges: 1)
        XCTAssertEqual(status.branch, "byori/new-task")

        do {
            try await fixture.source.removeProject(id: fixture.project.id)
            XCTFail("Removal must still preserve the active shell's project registration")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("active writing session"))
        }
        let projects = try await fixture.registry.projects()
        XCTAssertEqual(projects.map(\.id), [fixture.project.id])
    }

    func testAgentStartedAfterSnapshotBlocksBranchChangeWithoutCreatingBranch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        // The data source already loaded a free checkout. The mutation must read
        // persisted sessions again instead of trusting that earlier snapshot.
        try await fixture.addActiveSession(provider: .claude)

        do {
            try await fixture.source.createBranch(
                projectID: fixture.project.id, sourceTreeID: fixture.checkoutID,
                name: "byori/new-task", startPoint: "main"
            )
            XCTFail("An active agent must prevent its checkout being switched")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("active writing session"))
        }
        let branches = try await WorkspaceGitService().branches(at: fixture.repository)
        XCTAssertEqual(branches.map(\.name), ["main"])
        XCTAssertTrue(try XCTUnwrap(branches.first).isCheckedOut)
    }

    private func makeFixture() async throws -> BranchCreationFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-branch-adapter-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let workspaceHome = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try await WorkspaceGitService().initializeRepository(at: repository)
        let registry = WorkspaceProjectRegistry(home: workspaceHome)
        let project = try await registry.registerProject(at: repository)
        let paths = ManagerPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"))
        let suite = "WorkspaceBranchCreationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // No live tmux server, Keychain, runtime service, or vendor CLI is used.
        let runner = BranchCreationNoCommands()
        let source = LiveWorkspaceDataSource(
            managerService: ManagerService(paths: paths, runner: runner),
            terminalController: TerminalSessionController(
                tmuxService: TmuxSessionService(paths: paths, runner: runner)
            ),
            claudeGatewaySettings: ClaudeGatewaySettingsController(
                defaults: defaults, credentialStore: BranchCreationNoCredentials()
            ),
            workspaceHome: workspaceHome
        )
        let snapshot = try await source.loadWorkspace()
        let checkoutID = try XCTUnwrap(snapshot.projects.first?.sourceTrees.first?.id)
        return BranchCreationFixture(
            root: root, repository: repository, project: project, checkoutID: checkoutID,
            registry: registry, tasks: WorkspaceTaskStore(home: workspaceHome), source: source,
            defaults: defaults, suite: suite
        )
    }
}

@MainActor
private struct BranchCreationFixture {
    let root: URL
    let repository: URL
    let project: WorkspaceProject
    let checkoutID: String
    let registry: WorkspaceProjectRegistry
    let tasks: WorkspaceTaskStore
    let source: LiveWorkspaceDataSource
    let defaults: UserDefaults
    let suite: String

    func addActiveSession(provider: WorkspaceProvider) async throws {
        let task = try await tasks.createTask(
            projectID: project.id,
            checkout: WorkspaceCheckoutReference(kind: .sourceTree, id: checkoutID),
            title: "Already running"
        )
        let session = try await tasks.createSession(taskID: task.id, provider: provider, model: "default")
        _ = try await tasks.updateSessionStatus(taskID: task.id, sessionID: session.id, status: .active)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct BranchCreationNoCommands: CommandRunning {
    func run(_ command: CommandSpec) async -> CommandResult {
        CommandResult(exitCode: 1, output: "unavailable in test")
    }
}

private struct BranchCreationNoCredentials: ClaudeGatewayCredentialStoring {
    func readCredential() throws -> String? { nil }
    func writeCredential(_ credential: String) throws {}
    func deleteCredential() throws {}
}
