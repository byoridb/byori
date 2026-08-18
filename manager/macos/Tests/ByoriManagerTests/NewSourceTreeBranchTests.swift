import ByoriManagerCore
import XCTest
@testable import ByoriManager

/// A worktree can only sit on a local branch. Picking a remote-tracking branch is
/// still offered — working on a colleague's branch is why a second checkout gets
/// opened — but it has to become a local branch, never a detached HEAD.
@MainActor
final class NewSourceTreeBranchTests: XCTestCase {
    /// A remote pick turns into a new local branch, so it must not be what the
    /// sheet silently starts on when a local branch is free.
    func testDefaultsToAFreeLocalBranchRatherThanARemoteOne() async {
        let model = await presentSheet(branches: [
            .init(name: "main", isRemote: false, isCheckedOut: true),
            .init(name: "feature/one", isRemote: false, isCheckedOut: false),
            .init(name: "origin/feature/two", isRemote: true, isCheckedOut: false),
        ])

        XCTAssertEqual(model.newSourceTreeDraft.selectedBranch, "feature/one")
        XCTAssertNil(model.newSourceTreeValidationMessage)
    }

    /// A fresh clone has one local branch and it is checked out, so the only
    /// actionable choice is a remote branch whose local name is still free.
    func testDefaultsToAUsableRemoteBranchWhenNoLocalBranchIsFree() async {
        let model = await presentSheet(branches: [
            .init(name: "main", isRemote: false, isCheckedOut: true),
            .init(name: "origin/main", isRemote: true, isCheckedOut: false),
            .init(name: "origin/feature/two", isRemote: true, isCheckedOut: false),
        ])

        XCTAssertEqual(
            model.newSourceTreeDraft.selectedBranch,
            "origin/feature/two",
            "origin/main would need a local main, and that name is taken"
        )
        XCTAssertNil(model.newSourceTreeValidationMessage)
    }

    func testLocalBranchIsCheckedOutAsItIs() async {
        let dataSource = BranchDataSource(branches: [
            .init(name: "main", isRemote: false, isCheckedOut: true),
            .init(name: "feature/one", isRemote: false, isCheckedOut: false),
        ])
        let model = await presentSheet(dataSource: dataSource)

        await model.createSourceTree()

        XCTAssertEqual(
            dataSource.created,
            [.init(projectID: "project123", branch: "feature/one", startPoint: nil)]
        )
    }

    /// The bug this guards: `git worktree add <path> origin/main` resolves and
    /// detaches HEAD, so the checkout's commits belong to no branch.
    func testRemotePickBecomesALocalBranchStartedFromTheRemoteRef() async {
        let dataSource = BranchDataSource(branches: [
            .init(name: "main", isRemote: false, isCheckedOut: true),
            .init(name: "origin/feature/two", isRemote: true, isCheckedOut: false),
        ])
        let model = await presentSheet(dataSource: dataSource)
        XCTAssertEqual(model.newSourceTreeDraft.selectedBranch, "origin/feature/two")

        await model.createSourceTree()

        XCTAssertEqual(dataSource.created, [.init(
            projectID: "project123",
            branch: "feature/two",
            startPoint: "origin/feature/two"
        )])
    }

    /// Two branches cannot share a name, and the local one is already in the
    /// picker, so the sheet says which entry to pick instead of failing on Create.
    func testRemotePickWhoseLocalNameIsTakenNamesTheLocalBranch() async {
        let dataSource = BranchDataSource(branches: [
            .init(name: "main", isRemote: false, isCheckedOut: true),
            .init(name: "origin/main", isRemote: true, isCheckedOut: false),
        ])
        let model = await presentSheet(dataSource: dataSource)
        model.newSourceTreeDraft.selectedBranch = "origin/main"

        XCTAssertEqual(
            model.newSourceTreeValidationMessage,
            "A local branch named main already exists. Choose it instead."
        )

        await model.createSourceTree()
        XCTAssertTrue(dataSource.created.isEmpty, "the refusal must create nothing")
    }

    func testRemoteNameWithoutABranchComponentIsRejected() {
        XCTAssertNil(WorkspaceViewModel.localBranchName(forRemote: "origin"))
        XCTAssertNil(WorkspaceViewModel.localBranchName(forRemote: "origin/"))
        XCTAssertEqual(WorkspaceViewModel.localBranchName(forRemote: "origin/main"), "main")
        XCTAssertEqual(
            WorkspaceViewModel.localBranchName(forRemote: "upstream/feature/x"),
            "feature/x",
            "only the remote name is stripped; the rest is the branch"
        )
    }

    // MARK: - Fixture

    private func presentSheet(branches: [WorkspaceGitBranch]) async -> WorkspaceViewModel {
        await presentSheet(dataSource: BranchDataSource(branches: branches))
    }

    private func presentSheet(dataSource: BranchDataSource) async -> WorkspaceViewModel {
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        await model.prepareNewSourceTree(projectID: "project123")
        return model
    }
}

@MainActor
private final class BranchDataSource: WorkspaceDataSource {
    struct Created: Equatable {
        let projectID: String
        let branch: String
        let startPoint: String?
    }

    private let listedBranches: [WorkspaceGitBranch]
    var created: [Created] = []

    init(branches: [WorkspaceGitBranch]) {
        listedBranches = branches
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        let primary = WorkspaceSourceTreeItem(
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
        return WorkspacePresentationSnapshot(projects: [WorkspaceProjectItem(
            id: "project123",
            name: "Byori",
            repositoryURL: URL(fileURLWithPath: "/tmp/byori", isDirectory: true),
            memorySpace: "byori_project123",
            registration: .trusted,
            sourceTrees: [primary],
            hiddenSourceTrees: []
        )])
    }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }

    func branches(projectID: String) async throws -> [WorkspaceGitBranch] { listedBranches }

    func createSourceTree(
        projectID: String,
        branch: String,
        startPoint: String?
    ) async throws -> URL {
        created.append(.init(projectID: projectID, branch: branch, startPoint: startPoint))
        return URL(fileURLWithPath: "/tmp/byori-worktrees/\(branch)", isDirectory: true)
    }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Sessions are not part of this fixture.")
    }

    func sessionPersistenceWarning() async -> String? { nil }
}
