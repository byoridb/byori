import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceSessionLocationTests: XCTestCase {
    /// An idle main checkout gets a new branch, without duplicating the files.
    func testSessionCreatesBranchInPrimaryCheckoutWhenItIsFree() async {
        let dataSource = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await startSession(in: model, titled: "Fix the parser")

        XCTAssertTrue(dataSource.createdWorktrees.isEmpty, "A free checkout needs no worktree")
        XCTAssertEqual(dataSource.createdBranches, [.init(projectID: "project123", sourceTreeID: "primary123", name: "byori/fix-the-parser", startPoint: "main")])
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

    /// A folder registered before its first commit. The primary is busy, so a second
    /// session needs a worktree — and Git cannot cut one from an unborn HEAD. Byori's
    /// own new projects get a root commit, so this is a folder that arrived without
    /// one, and the sheet has to say that rather than pass Git's refusal through.
    func testASecondSessionWithoutAnyCommitsNamesWhatIsMissing() async {
        let dataSource = LocationDataSource(
            snapshot: makeSnapshot(primaryBusy: true),
            branches: []
        )
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await startSession(in: model, titled: "Review the API")

        XCTAssertTrue(dataSource.createdWorktrees.isEmpty, "there is nothing to branch from")
        XCTAssertTrue(dataSource.startedRequests.isEmpty)
        XCTAssertEqual(
            model.newSessionError,
            "첫 커밋이 있어야 새 브랜치나 워크트리를 만들 수 있습니다."
        )
    }

    /// Opening the sheet must not create anything: a cancelled sheet that left a
    /// branch and a directory behind would be worse than the button it replaced.
    func testOpeningAndCancellingTheSheetCreatesNothing() async {
        let dataSource = LocationDataSource(snapshot: makeSnapshot(primaryBusy: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.prepareNewSession()
        XCTAssertTrue(model.isPresentingNewSession)
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .newWorktree)
        XCTAssertTrue(model.plannedSessionLocation.contains("byori/session"))
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
            "byori/설계-검토",
            "Korean task titles should remain recognizable in Git"
        )
        XCTAssertEqual(
            WorkspaceViewModel.availableBranchName(
                for: "Fix the parser",
                avoiding: ["byori/fix-the-parser", "byori/fix-the-parser-2"]
            ),
            "byori/fix-the-parser-3"
        )
    }

    func testRecommendationPrefillsEditableBranchAndTracksTaskTitle() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false), branches: [
            .init(name: "main", isRemote: false, isCheckedOut: true),
            .init(name: "byori/사용량-표시", isRemote: false, isCheckedOut: false),
        ])
        let model = await openSheet(source)
        XCTAssertEqual(model.sessionLocationRecommendation.strategy, .newBranch)
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .newBranch)
        XCTAssertEqual(model.newSessionDraft.startPoint, "main")
        model.newSessionDraft.newTaskTitle = "사용량 표시"
        XCTAssertEqual(model.newSessionDraft.newBranchName, "byori/사용량-표시-2")
        XCTAssertTrue(source.createdBranches.isEmpty)
        XCTAssertTrue(source.createdWorktrees.isEmpty)
    }

    func testManualStrategyNameAndBaseSurviveInputChangesAndBranchReload() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false), branches: [
            .init(name: "main", isRemote: false, isCheckedOut: true),
            .init(name: "origin/release", isRemote: true, isCheckedOut: false),
        ])
        let model = await openSheet(source)
        model.chooseSessionLocationStrategy(.newWorktree)
        model.updateSessionBranchName("feature/my-choice")
        model.updateSessionStartPoint("origin/release")
        model.newSessionDraft.newTaskTitle = "A different task"
        model.newSessionDraft.workflowPreset = .codeReview
        await model.retrySessionBranches()
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .newWorktree)
        XCTAssertEqual(model.newSessionDraft.newBranchName, "feature/my-choice")
        XCTAssertEqual(model.newSessionDraft.startPoint, "origin/release")
        model.applySessionLocationRecommendation()
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .currentCheckout)
        XCTAssertEqual(model.newSessionDraft.newBranchName, "byori/a-different-task")
        XCTAssertEqual(model.newSessionDraft.startPoint, "main")
    }

    func testClearedManualBranchNameRemainsEmptyUntilRecommendationReapplied() async {
        let model = await openSheet(LocationDataSource(snapshot: makeSnapshot(primaryBusy: false)))
        model.updateSessionBranchName("")
        model.newSessionDraft.newTaskTitle = "Changed title"
        await model.retrySessionBranches()
        XCTAssertEqual(model.newSessionDraft.newBranchName, "")
        XCTAssertNotNil(model.sessionPlanValidationMessage)
        model.applySessionLocationRecommendation()
        XCTAssertEqual(model.newSessionDraft.newBranchName, "byori/changed-title")
    }

    func testDirectMainIsAnExplicitChoiceThatCreatesNothing() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = await openSheet(source)
        configureLaunch(model)
        model.chooseSessionLocationStrategy(.currentCheckout)
        await model.startSession()
        XCTAssertTrue(source.createdBranches.isEmpty)
        XCTAssertTrue(source.createdWorktrees.isEmpty)
        XCTAssertEqual(source.startedRequests.map(\.sourceTreeID), ["primary123"])
    }

    func testFeatureBranchAndCodeReviewRecommendCurrentCheckout() async {
        let feature = await openSheet(LocationDataSource(snapshot: makeSnapshot(primaryBusy: false, branch: "feature/parser")))
        XCTAssertEqual(feature.newSessionDraft.locationStrategy, .currentCheckout)
        XCTAssertTrue(feature.sessionLocationStrategyLabel(.currentCheckout).contains("feature/parser"))
        let review = await openSheet(LocationDataSource(snapshot: makeSnapshot(primaryBusy: false)))
        review.newSessionDraft.workflowPreset = .codeReview
        XCTAssertEqual(review.newSessionDraft.locationStrategy, .currentCheckout)
    }

    func testDirtyCheckoutRecommendsCurrentAndRequiresExplicitAcknowledgement() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false, workingState: .modified(changeCount: 2)))
        let model = await openSheet(source)
        configureLaunch(model)
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .currentCheckout)
        XCTAssertFalse(model.canStartSession)
        model.newSessionDraft.acceptsModifiedWorkingTree = true
        XCTAssertTrue(model.canStartSession)
        await model.startSession()
        XCTAssertEqual(source.startedRequests.count, 1)
        XCTAssertTrue(source.createdBranches.isEmpty)
    }

    func testDirtyCheckoutNeverSwitchesBranchEvenWithAcknowledgement() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false, workingState: .modified(changeCount: 1)))
        let model = await openSheet(source)
        configureLaunch(model)
        model.chooseSessionLocationStrategy(.newBranch)
        model.newSessionDraft.acceptsModifiedWorkingTree = true
        await model.startSession()
        XCTAssertTrue(source.createdBranches.isEmpty)
        XCTAssertTrue(source.startedRequests.isEmpty)
        XCTAssertTrue(model.newSessionError?.contains("커밋") == true)
    }

    func testBusyDirtyCheckoutCanUseWorktreeFromCommittedBase() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: true, workingState: .modified(changeCount: 2)))
        let model = await openSheet(source)
        configureLaunch(model)
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .newWorktree)
        XCTAssertTrue(model.canStartSession)
        await model.startSession()
        XCTAssertEqual(source.createdWorktrees.count, 1)
        XCTAssertTrue(source.createdBranches.isEmpty)
    }

    func testExplicitBusySourceIsRetainedEvenWhenAnotherCheckoutIsFree() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: true))
        let other = WorkspaceSourceTreeItem(
            id: "free-other", projectID: "project123", name: "Other",
            url: URL(fileURLWithPath: "/tmp/byori-other"), kind: .managedWorktree,
            branch: "feature/other", headRevision: String(repeating: "a", count: 40),
            workingState: .clean, tasks: []
        )
        source.snapshot.projects[0].sourceTrees.append(other)
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        await model.prepareNewSession(target: .init(projectID: "project123", sourceTreeID: "primary123", existingTaskID: nil))
        XCTAssertEqual(model.newSessionDraft.sourceTreeID, "primary123")
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .newWorktree)
        model.chooseSessionLocationStrategy(.currentCheckout)
        configureLaunch(model)
        XCTAssertFalse(model.canStartSession)
        XCTAssertTrue(source.startedRequests.isEmpty)
    }

    func testExistingTaskKeepsItsCheckoutAndLocksStrategy() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        source.snapshot.projects[0].sourceTrees[0].tasks = [
            .init(id: "existing", sourceTreeID: "primary123", title: "Continue", status: .open, createdAt: Date(), sessions: []),
        ]
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        await model.prepareNewSession(target: .init(projectID: "project123", sourceTreeID: "primary123", existingTaskID: "existing"))
        XCTAssertTrue(model.sessionLocationIsLocked)
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .currentCheckout)
        model.chooseSessionLocationStrategy(.newWorktree)
        configureLaunch(model)
        await model.startSession()
        XCTAssertEqual(source.startedRequests.first?.existingTaskID, "existing")
        XCTAssertTrue(source.createdBranches.isEmpty)
        XCTAssertTrue(source.createdWorktrees.isEmpty)
    }

    func testChosenWorktreeBranchAndRemoteBaseAreExecutedExactly() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false), branches: [
            .init(name: "main", isRemote: false, isCheckedOut: true),
            .init(name: "origin/release", isRemote: true, isCheckedOut: false),
        ])
        let model = await openSheet(source)
        configureLaunch(model)
        model.chooseSessionLocationStrategy(.newWorktree)
        model.updateSessionBranchName("feature/release-fix")
        model.updateSessionStartPoint("origin/release")
        await model.startSession()
        XCTAssertEqual(source.createdWorktrees, [.init(projectID: "project123", branch: "feature/release-fix", startPoint: "origin/release")])
    }

    func testCheckoutBecomingBusyAfterSheetOpenedBlocksWithoutChangingPlan() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = await openSheet(source)
        configureLaunch(model)
        source.snapshot = makeSnapshot(primaryBusy: true)
        await model.startSession()
        XCTAssertTrue(source.createdBranches.isEmpty)
        XCTAssertTrue(source.createdWorktrees.isEmpty)
        XCTAssertTrue(source.startedRequests.isEmpty)
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .newBranch)
        XCTAssertNotNil(model.newSessionError)
    }

    func testBranchCollisionAppearingAfterSheetOpenedRequiresAReview() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = await openSheet(source)
        configureLaunch(model)
        let reviewed = model.newSessionDraft.newBranchName
        source.listedBranches.append(.init(name: reviewed, isRemote: false, isCheckedOut: false))
        await model.startSession()
        XCTAssertTrue(source.createdBranches.isEmpty)
        XCTAssertTrue(source.startedRequests.isEmpty)
        XCTAssertEqual(model.newSessionDraft.newBranchName, reviewed, "Do not quietly choose a different branch at confirmation")
        XCTAssertNotNil(model.newSessionError)
    }

    func testChangedHeadAfterSheetOpenedRequiresReviewEvenForDirectWork() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = await openSheet(source)
        configureLaunch(model)
        model.chooseSessionLocationStrategy(.currentCheckout)
        source.snapshot.projects[0].sourceTrees[0].headRevision = String(repeating: "c", count: 40)
        await model.startSession()
        XCTAssertTrue(source.startedRequests.isEmpty)
        XCTAssertTrue(model.newSessionError?.contains("커밋이 바뀌었습니다") == true)
    }

    func testFailedProviderLaunchReusesCreatedBranchOnRetry() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        source.failedStartsRemaining = 1
        let model = await openSheet(source)
        configureLaunch(model)
        await model.startSession()
        XCTAssertNotNil(model.newSessionError)
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .currentCheckout)
        await model.startSession()
        XCTAssertEqual(source.createdBranches.count, 1)
        XCTAssertEqual(source.startedRequests.count, 2)
        XCTAssertNil(model.newSessionError)
    }

    func testFailedRefreshReusesCreatedWorktreeAndLocksThePendingPlan() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: true))
        source.failNextPostCreationLoad = true
        let model = await openSheet(source)
        configureLaunch(model)
        let reviewedName = model.newSessionDraft.newBranchName
        await model.startSession()
        XCTAssertTrue(model.sessionPlanHasPendingLocation)
        XCTAssertTrue(model.sessionLocationIsLocked)
        model.updateSessionBranchName("a-different-name")
        model.chooseSessionLocationStrategy(.currentCheckout)
        model.applySessionLocationRecommendation()
        XCTAssertEqual(model.newSessionDraft.newBranchName, reviewedName)
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .newWorktree)
        await model.startSession()
        XCTAssertEqual(source.createdWorktrees.count, 1)
        XCTAssertEqual(source.startedRequests.count, 1)
        XCTAssertNil(model.newSessionError)
    }

    func testGeneratedNamesAvoidGitDirectoryFileConflicts() {
        XCTAssertEqual(WorkspaceViewModel.availableBranchName(for: "Fix", avoiding: ["byori"]), "byori-fix")
        XCTAssertEqual(WorkspaceViewModel.availableBranchName(for: "Fix", avoiding: ["byori/fix/child"]), "byori/fix-2")
    }

    func testInvalidManualNamesAreRefusedBeforeGitMutation() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = await openSheet(source)
        configureLaunch(model)
        for name in ["--force", "feature/../bad", "feature name", "bad.lock", ".hidden", "HEAD", "x@{y"] {
            model.updateSessionBranchName(name)
            await model.startSession()
            XCTAssertNotNil(model.newSessionError, name)
        }
        XCTAssertTrue(source.createdBranches.isEmpty)
        XCTAssertTrue(source.startedRequests.isEmpty)
    }

    func testProjectRowPlusUsesPrimaryBaseWithoutLosingRecommendation() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        await model.prepareNewSession(target: .init(projectID: "project123", sourceTreeID: "", existingTaskID: nil))
        XCTAssertTrue(model.isPresentingNewSession)
        XCTAssertEqual(model.newSessionDraft.sourceTreeID, "primary123")
        XCTAssertEqual(model.newSessionDraft.locationStrategy, .newBranch)
    }

    func testMissingNamedCheckoutIsNotReplacedByPrimaryCheckout() async {
        let source = LocationDataSource(snapshot: makeSnapshot(primaryBusy: false))
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        await model.prepareNewSession(target: .init(projectID: "project123", sourceTreeID: "removed", existingTaskID: nil))
        XCTAssertFalse(model.isPresentingNewSession)
        XCTAssertNotNil(model.alert)
    }

    private func openSheet(_ source: LocationDataSource) async -> WorkspaceViewModel {
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        await model.prepareNewSession()
        return model
    }

    private func configureLaunch(_ model: WorkspaceViewModel) {
        model.newSessionDraft.newTaskTitle = "Fix parser"
        model.chooseProvider("claude")
        model.chooseModel("default")
    }

    private func startSession(in model: WorkspaceViewModel, titled title: String) async {
        await model.prepareNewSession()
        model.newSessionDraft.newTaskTitle = title
        model.chooseProvider("claude")
        model.chooseModel("default")
        await model.startSession()
    }

    private func makeSnapshot(primaryBusy: Bool, branch: String = "main", workingState: WorkspaceWorkingTreeStatus = .clean) -> WorkspacePresentationSnapshot {
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
            name: branch,
            url: URL(fileURLWithPath: "/tmp/byori", isDirectory: true),
            kind: .primary,
            branch: branch,
            headRevision: String(repeating: "a", count: 40),
            workingState: workingState,
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
    var listedBranches: [WorkspaceGitBranch]
    struct CreatedBranch: Equatable {
        let projectID: String
        let sourceTreeID: String
        let name: String
        let startPoint: String
    }
    var createdBranches: [CreatedBranch] = []
    var failedStartsRemaining = 0
    var failNextPostCreationLoad = false
    private var didCreateLocation = false

    init(
        snapshot: WorkspacePresentationSnapshot,
        branches: [WorkspaceGitBranch] = [
            WorkspaceGitBranch(name: "main", isRemote: false, isCheckedOut: true),
        ]
    ) {
        self.snapshot = snapshot
        listedBranches = branches
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        if didCreateLocation && failNextPostCreationLoad {
            failNextPostCreationLoad = false
            throw WorkspaceAdapterError.invalidState("Temporary refresh failure")
        }
        return snapshot
    }

    func createBranch(projectID: String, sourceTreeID: String, name: String, startPoint: String) async throws {
        createdBranches.append(.init(projectID: projectID, sourceTreeID: sourceTreeID, name: name, startPoint: startPoint))
        guard let index = snapshot.projects[0].sourceTrees.firstIndex(where: { $0.id == sourceTreeID }) else {
            throw WorkspaceAdapterError.invalidState("Missing checkout")
        }
        snapshot.projects[0].sourceTrees[index].branch = name
        listedBranches.append(.init(name: name, isRemote: false, isCheckedOut: true))
        didCreateLocation = true
    }

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

    func branches(projectID: String) async throws -> [WorkspaceGitBranch] { listedBranches }

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
        listedBranches.append(.init(name: branch, isRemote: false, isCheckedOut: true))
        didCreateLocation = true
        return created.url
    }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        startedRequests.append(request)
        if failedStartsRemaining > 0 {
            failedStartsRemaining -= 1
            throw WorkspaceAdapterError.invalidState("Provider could not launch")
        }
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
