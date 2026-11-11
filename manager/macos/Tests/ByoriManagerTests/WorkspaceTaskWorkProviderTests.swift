import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceTaskWorkProviderTests: XCTestCase {
    func testCapturedProviderKeepsOriginalTaskAndCheckoutForEveryOperation() async throws {
        let source = TaskWorkScopeFixtureSource()
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.select(.task("task-1"))
        model.showTaskWork()
        let scope = try XCTUnwrap(model.taskWorkScope)
        let provider = model.taskWorkProvider(for: scope)

        XCTAssertEqual(scope.projectID, "project")
        XCTAssertEqual(scope.sourceTreeID, "worktree")
        XCTAssertEqual(scope.taskID, "task-1")
        XCTAssertEqual(scope.root, source.worktreeURL)

        model.select(.sourceTree("primary"))
        _ = try await provider.loadWorkflow()
        model.select(.task("task-2"))
        let plan = TaskWorkflowPreset.bugFix.makePlan(goal: "captured task")
        try await provider.saveWorkflow(plan)
        model.select(.project("project"))
        let snapshot = try await provider.loadVerification()
        let commands = [VerificationCommand(id: "check", name: "Check", executable: "fake-tool")]
        try await provider.saveVerificationCommands(commands)
        let receipt = try await provider.runVerification(commandID: "check")

        XCTAssertEqual(source.calls.map(\.operation), ["loadWorkflow", "saveWorkflow", "loadVerification", "saveCommands", "run"])
        XCTAssertEqual(source.calls.map(\.scope), Array(repeating: scope, count: 5))
        XCTAssertEqual(source.savedPlan, plan)
        XCTAssertEqual(source.savedCommands, commands)
        XCTAssertEqual(source.runCommandID, "check")
        XCTAssertEqual(snapshot.scope.taskID, "task-1")
        XCTAssertEqual(receipt.scope.checkoutID, "worktree")
        XCTAssertEqual(receipt.scope.root, source.worktreeURL)
        model.dismissTaskWork()
        XCTAssertNil(model.taskWorkScope)
    }

    func testProjectOrSourceTreeSelectionDoesNotCreateTaskWorkScope() async {
        let model = WorkspaceViewModel(dataSource: TaskWorkScopeFixtureSource())
        await model.load()
        model.select(.project("project"))
        model.showTaskWork()
        XCTAssertNil(model.taskWorkScope)
        model.select(.sourceTree("worktree"))
        model.showTaskWork()
        XCTAssertNil(model.taskWorkScope)
    }

    func testExplicitTaskActionCapturesRequestedTaskInsteadOfSelectedTask() async throws {
        let source = TaskWorkScopeFixtureSource()
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.select(.task("task-2"))
        model.showTaskWork(taskID: "task-1")
        let scope = try XCTUnwrap(model.taskWorkScope)
        XCTAssertEqual(scope.taskID, "task-1")
        XCTAssertEqual(scope.sourceTreeID, "worktree")
        XCTAssertEqual(scope.root, source.worktreeURL)
    }

    func testMissingExplicitTaskDoesNotFallBackToAnotherSelectedTask() async {
        let model = WorkspaceViewModel(dataSource: TaskWorkScopeFixtureSource())
        await model.load()
        model.select(.task("task-2"))
        model.showTaskWork(taskID: "removed-task")
        XCTAssertNil(model.taskWorkScope)
    }
}

/// All verification methods only record arguments and return values; no command,
/// service, launchd operation or user state is touched by these scope tests.
@MainActor
private final class TaskWorkScopeFixtureSource: WorkspaceDataSource {
    struct Call { let operation: String; let scope: WorkspaceTaskWorkScope }
    let worktreeURL = URL(fileURLWithPath: "/private/tmp/byori-task-work-scope-feature")
    var calls: [Call] = []
    var savedPlan: TaskWorkflowPlan?
    var savedCommands: [VerificationCommand]?
    var runCommandID: String?

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        let task = WorkspaceTaskItem(id: "task-1", sourceTreeID: "worktree", title: "Feature task",
                                     status: .open, createdAt: Date(), sessions: [])
        let other = WorkspaceTaskItem(id: "task-2", sourceTreeID: "primary", title: "Other task",
                                      status: .open, createdAt: Date(), sessions: [])
        let primary = WorkspaceSourceTreeItem(
            id: "primary", projectID: "project", name: "main", url: URL(fileURLWithPath: "/private/tmp/byori-task-work-scope-main"),
            kind: .primary, branch: "main", headRevision: nil, workingState: .clean, tasks: [other]
        )
        let worktree = WorkspaceSourceTreeItem(
            id: "worktree", projectID: "project", name: "feature", url: worktreeURL,
            kind: .managedWorktree, branch: "feature", headRevision: nil, workingState: .clean, tasks: [task]
        )
        return .init(projects: [WorkspaceProjectItem(
            id: "project", name: "Byori", repositoryURL: primary.url, memorySpace: "project_space",
            registration: .trusted, sourceTrees: [primary, worktree], hiddenSourceTrees: []
        )])
    }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }
    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("unused")
    }
    func loadContext(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceContextSnapshot {
        .init(items: [], isTruncated: false)
    }

    func loadTaskWorkflow(scope: WorkspaceTaskWorkScope) async throws -> TaskWorkflowPlan? {
        calls.append(.init(operation: "loadWorkflow", scope: scope))
        return nil
    }
    func saveTaskWorkflow(scope: WorkspaceTaskWorkScope, plan: TaskWorkflowPlan) async throws {
        calls.append(.init(operation: "saveWorkflow", scope: scope)); savedPlan = plan
    }
    func loadTaskVerification(scope: WorkspaceTaskWorkScope) async throws -> VerificationSnapshot {
        calls.append(.init(operation: "loadVerification", scope: scope))
        return .init(scope: verificationScope(scope), profile: .init(), receipts: [], current: nil)
    }
    func saveTaskVerificationCommands(scope: WorkspaceTaskWorkScope, commands: [VerificationCommand]) async throws {
        calls.append(.init(operation: "saveCommands", scope: scope)); savedCommands = commands
    }
    func runTaskVerification(scope: WorkspaceTaskWorkScope, commandID: String) async throws -> VerificationReceipt {
        calls.append(.init(operation: "run", scope: scope)); runCommandID = commandID
        return .init(scope: verificationScope(scope),
                     command: .init(id: commandID, name: "Fake", executable: "fake-tool"),
                     resolvedExecutable: "/fake/tool", outcome: .cancelled)
    }
    private func verificationScope(_ scope: WorkspaceTaskWorkScope) -> VerificationScope {
        .init(projectID: scope.projectID, checkoutID: scope.sourceTreeID, taskID: scope.taskID, root: scope.root)
    }
}
