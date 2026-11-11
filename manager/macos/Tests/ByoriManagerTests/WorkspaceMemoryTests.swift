import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceMemoryTests: XCTestCase {
    func testCheckpointKeepsCapturedTaskAndCheckoutWhenSelectionChanges() async throws {
        let source = LifecycleWorkspaceSource()
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.select(.task("task-1"))
        model.showMemory()
        let scope = try XCTUnwrap(model.memoryScope)
        XCTAssertEqual(scope.taskID, "task-1")
        XCTAssertEqual(scope.sourceTreeID, "worktree")
        model.select(.sourceTree("primary"))
        let draft = TaskCheckpointDraft(goal: "continue this task")
        _ = try await model.resumeCheckpoint(scope: scope)
        try await model.saveCheckpoint(scope: scope, draft: draft)
        XCTAssertEqual(source.resumeScope, ["project", "worktree", "task-1"])
        XCTAssertEqual(source.saveScope, ["project", "worktree", "task-1"])
        XCTAssertEqual(source.draft, draft)
        model.dismissMemory()
        XCTAssertNil(model.memoryScope)
    }

    func testProjectCheckpointUsesPrimaryAndExplicitProjectTask() async throws {
        let model = WorkspaceViewModel(dataSource: LifecycleWorkspaceSource())
        await model.load()
        model.select(.project("project"))
        model.showMemory()
        let scope = try XCTUnwrap(model.memoryScope)
        XCTAssertEqual(scope.sourceTreeID, "primary")
        XCTAssertEqual(scope.taskID, "project")
    }

    func testMemoryFilterFlowsIntoInspectorRequests() async {
        let source = LifecycleWorkspaceSource()
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        XCTAssertEqual(model.memoryView, .current)
        model.setMemoryView(.archived)
        await model.refreshInspector()
        XCTAssertEqual(source.contextRequests.last?.memoryView, .archived)
    }
}

@MainActor
private final class LifecycleWorkspaceSource: WorkspaceDataSource {
    var contextRequests: [WorkspaceInspectorRequest] = []
    var resumeScope: [String]?
    var saveScope: [String]?
    var draft: TaskCheckpointDraft?

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        let task = WorkspaceTaskItem(id: "task-1", sourceTreeID: "worktree", title: "Task", status: .open, createdAt: Date(), sessions: [])
        let primary = WorkspaceSourceTreeItem(
            id: "primary", projectID: "project", name: "main", url: URL(fileURLWithPath: "/tmp/byori"),
            kind: .primary, branch: "main", headRevision: nil, workingState: .clean, tasks: []
        )
        let worktree = WorkspaceSourceTreeItem(
            id: "worktree", projectID: "project", name: "feature", url: URL(fileURLWithPath: "/tmp/byori-feature"),
            kind: .managedWorktree, branch: "feature", headRevision: nil, workingState: .clean, tasks: [task]
        )
        return WorkspacePresentationSnapshot(projects: [WorkspaceProjectItem(
            id: "project", name: "Byori", repositoryURL: primary.url, memorySpace: "project_space",
            registration: .trusted, sourceTrees: [worktree, primary], hiddenSourceTrees: []
        )])
    }
    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }
    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("unused")
    }
    func loadContext(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceContextSnapshot {
        contextRequests.append(request)
        return WorkspaceContextSnapshot(items: [], isTruncated: false)
    }
    func resumeCheckpoint(projectID: String, sourceTreeID: String, taskID: String) async throws -> TaskResume {
        resumeScope = [projectID, sourceTreeID, taskID]
        return try JSONDecoder().decode(TaskResume.self, from: Data(#"{"found":false,"checkpoint":null,"current_revision":null,"revision_state":"unverified"}"#.utf8))
    }
    func saveCheckpoint(projectID: String, sourceTreeID: String, taskID: String, draft: TaskCheckpointDraft) async throws {
        saveScope = [projectID, sourceTreeID, taskID]
        self.draft = draft
    }
}
