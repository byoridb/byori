import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceRemovalTests: XCTestCase {
    func testRemovingTaskArchivesItAndSelectsItsSourceTree() async {
        let dataSource = RemovalDataSource(snapshot: makeSnapshot(includeTask: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        let task = try! XCTUnwrap(model.projects.first?.sourceTrees.first?.tasks.first)

        await model.archiveTask(task)

        XCTAssertEqual(dataSource.archivedTaskIDs, [task.id])
        XCTAssertTrue(model.projects.first?.sourceTrees.first?.tasks.isEmpty == true)
        XCTAssertEqual(model.selection, .sourceTree("worktree123"))
        XCTAssertNil(model.alert)
    }

    func testDeletingManagedWorktreeCanRequestSafeBranchDeletion() async {
        let dataSource = RemovalDataSource(snapshot: makeSnapshot(includeTask: false))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        let sourceTree = try! XCTUnwrap(model.projects.first?.sourceTrees.first)

        await model.deleteManagedSourceTree(sourceTree, deletingBranch: true)

        XCTAssertEqual(
            dataSource.worktreeDeletions,
            [.init(projectID: "project123", sourceTreeID: "worktree123", deletingBranch: true)]
        )
        XCTAssertTrue(model.projects.first?.sourceTrees.isEmpty == true)
        XCTAssertEqual(model.selection, .project("project123"))
        XCTAssertNil(model.alert)
    }

    func testManagedWorktreeDeletionRequiresTasksToBeRemovedFirst() async {
        let dataSource = RemovalDataSource(snapshot: makeSnapshot(includeTask: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        let sourceTree = try! XCTUnwrap(model.projects.first?.sourceTrees.first)

        await model.deleteManagedSourceTree(sourceTree, deletingBranch: false)

        XCTAssertTrue(dataSource.worktreeDeletions.isEmpty)
        XCTAssertEqual(model.alert?.title, "Worktree could not be deleted")
        XCTAssertTrue(model.alert?.message.contains("Remove this worktree's tasks") == true)
    }

    func testBranchDeletionRefusalReportsThatOnlyBranchWasKept() async {
        let dataSource = RemovalDataSource(snapshot: makeSnapshot(includeTask: false))
        dataSource.worktreeRemovalResult = WorkspaceGitWorktreeRemovalResult(
            branch: "feature/task-removal",
            branchDeleted: false,
            branchDeletionFailure: "The worktree was deleted, but Git kept the unmerged branch."
        )
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        let sourceTree = try! XCTUnwrap(model.projects.first?.sourceTrees.first)

        await model.deleteManagedSourceTree(sourceTree, deletingBranch: true)

        XCTAssertEqual(model.alert?.title, "Worktree deleted, branch kept")
        XCTAssertTrue(model.alert?.message.contains("unmerged branch") == true)
        XCTAssertTrue(model.projects.first?.sourceTrees.isEmpty == true)
    }

    private func makeSnapshot(includeTask: Bool) -> WorkspacePresentationSnapshot {
        let task = WorkspaceTaskItem(
            id: "task123",
            sourceTreeID: "worktree123",
            title: "Remove completed work",
            status: .active,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessions: []
        )
        let sourceTree = WorkspaceSourceTreeItem(
            id: "worktree123",
            projectID: "project123",
            name: "feature/task-removal",
            url: URL(fileURLWithPath: "/tmp/byori-worktree", isDirectory: true),
            kind: .managedWorktree,
            branch: "feature/task-removal",
            headRevision: String(repeating: "a", count: 40),
            workingState: .clean,
            tasks: includeTask ? [task] : []
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
private final class RemovalDataSource: WorkspaceDataSource {
    struct WorktreeDeletion: Equatable {
        let projectID: String
        let sourceTreeID: String
        let deletingBranch: Bool
    }

    var snapshot: WorkspacePresentationSnapshot
    var archivedTaskIDs: [String] = []
    var worktreeDeletions: [WorktreeDeletion] = []
    var worktreeRemovalResult = WorkspaceGitWorktreeRemovalResult(
        branch: "feature/task-removal",
        branchDeleted: true
    )

    init(snapshot: WorkspacePresentationSnapshot) {
        self.snapshot = snapshot
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot { snapshot }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Not used by removal tests.")
    }

    func archiveTask(id: String) async throws {
        archivedTaskIDs.append(id)
        for projectIndex in snapshot.projects.indices {
            for sourceTreeIndex in snapshot.projects[projectIndex].sourceTrees.indices {
                snapshot.projects[projectIndex].sourceTrees[sourceTreeIndex].tasks.removeAll {
                    $0.id == id
                }
            }
        }
    }

    func deleteManagedSourceTree(
        projectID: String,
        sourceTreeID: String,
        deletingBranch: Bool
    ) async throws -> WorkspaceGitWorktreeRemovalResult {
        worktreeDeletions.append(.init(
            projectID: projectID,
            sourceTreeID: sourceTreeID,
            deletingBranch: deletingBranch
        ))
        guard let projectIndex = snapshot.projects.firstIndex(where: { $0.id == projectID }) else {
            throw WorkspaceAdapterError.invalidState("Missing test project")
        }
        snapshot.projects[projectIndex].sourceTrees.removeAll { $0.id == sourceTreeID }
        return worktreeRemovalResult
    }
}
