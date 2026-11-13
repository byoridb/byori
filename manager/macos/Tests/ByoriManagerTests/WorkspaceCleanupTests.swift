import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProjectSearchMatchesNameWithWhitespaceCaseDiacriticsAndHangul() async {
        let source = CleanupDataSource(snapshot: .init(projects: [
            project(id: "one", name: "Byori Workspace"),
            project(id: "two", name: "Café"),
            project(id: "three", name: "한글 프로젝트"),
        ]))
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.projectSearchQuery = "  BYORI\n"
        XCTAssertEqual(model.filteredProjects.map(\.id), ["one"])
        model.projectSearchQuery = "cafe"
        XCTAssertEqual(model.filteredProjects.map(\.id), ["two"])
        model.projectSearchQuery = "프로젝트"
        XCTAssertEqual(model.filteredProjects.map(\.id), ["three"])
        model.projectSearchQuery = "absent"
        XCTAssertTrue(model.filteredProjects.isEmpty)
        model.projectSearchQuery = " \n "
        XCTAssertEqual(model.filteredProjects.count, 3)
    }

    func testSearchDoesNotChangeSelectionOrUnderlyingProjects() async {
        let source = CleanupDataSource(snapshot: .init(projects: [
            project(id: "one", name: "Visible"), project(id: "two", name: "Selected"),
        ]))
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.select(.project("two"))
        model.projectSearchQuery = "Visible"
        XCTAssertEqual(model.selection, .project("two"))
        XCTAssertEqual(model.projects.count, 2)
        XCTAssertEqual(model.filteredProjects.map(\.id), ["one"])
        model.projectSearchQuery = ""
        XCTAssertEqual(model.selection, .project("two"))
    }

    func testDefaultThirtyDayCandidatesAreUnselectedAndBasedOnNewestEnd() async {
        let source = makeSource(tasks: [
            task("old", daysAgo: 40), task("recent", daysAgo: 10),
            task("edge", daysAgo: 30), task("mixed", daysAgo: 40, extra: [session("newer", daysAgo: 5)]),
        ])
        let model = await open(source)
        XCTAssertEqual(model.cleanupThreshold, .thirtyDays)
        XCTAssertEqual(model.cleanupCandidates.map(\.id), ["old"])
        XCTAssertTrue(model.selectedCleanupTaskIDs.isEmpty)
        XCTAssertTrue(source.archivedIDs.isEmpty)
    }

    func testUnknownEndDatesAreOnlyIncludedInAllEnded() async {
        var unknown = task("unknown", daysAgo: 40)
        unknown.sessions[0].endedAt = nil
        let mixed = task("mixed", daysAgo: 40, extra: [session("unknown-newer", daysAgo: nil)])
        let source = makeSource(tasks: [unknown, mixed, task("known", daysAgo: 40)])
        let model = await open(source)
        XCTAssertEqual(model.cleanupCandidates.map(\.id), ["known"])
        model.cleanupThreshold = .allEnded
        XCTAssertEqual(Set(model.cleanupCandidates.map(\.id)), ["unknown", "mixed", "known"])
        XCTAssertNil(model.cleanupCandidates.first { $0.id == "mixed" }?.latestEndedAt)
    }

    func testAllTerminalStatesQualifyAndEveryActiveStateIncludingShellIsExcluded() async {
        var tasks: [WorkspaceTaskItem] = []
        for state in WorkspaceSessionItemStatus.allCases {
            var value = task(state.rawValue, daysAgo: 60)
            value.sessions[0].state = state
            tasks.append(value)
        }
        var shell = task("active-shell", daysAgo: 60)
        shell.sessions = [session("shell", daysAgo: 60, state: .running, providerID: "shell")]
        tasks.append(shell)
        var detached = task("detached", daysAgo: 60)
        detached.sessions[0].isDetached = true
        tasks.append(detached)
        tasks.append(.init(id: "empty", sourceTreeID: "tree", title: "Empty", status: .open, createdAt: now, sessions: []))
        let model = await open(makeSource(tasks: tasks))
        XCTAssertEqual(Set(model.cleanupCandidates.map(\.id)), ["completed", "failed", "cancelled", "timedOut"])
        XCTAssertEqual(model.cleanupActiveExclusionCount, 5)
    }

    func testDateAndProjectFiltersClearSelectionsAndPreserveScope() async {
        let source = CleanupDataSource(snapshot: .init(projects: [
            project(id: "one", name: "One", tasks: [task("one-old", daysAgo: 40), task("one-recent", daysAgo: 10)]),
            project(id: "two", name: "Two", tasks: [task("two-old", daysAgo: 100)]),
        ]))
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["one-old", "two-old"]
        model.selectedArchivedTaskIDs = ["archived"]
        model.cleanupProjectID = "one"
        XCTAssertEqual(model.cleanupCandidates.map(\.id), ["one-old"])
        XCTAssertTrue(model.selectedCleanupTaskIDs.isEmpty)
        XCTAssertTrue(model.selectedArchivedTaskIDs.isEmpty)
        model.selectedCleanupTaskIDs = ["one-old"]
        model.cleanupThreshold = .sevenDays
        XCTAssertTrue(model.selectedCleanupTaskIDs.isEmpty)
        XCTAssertEqual(Set(model.cleanupCandidates.map(\.id)), ["one-old", "one-recent"])
        model.cleanupThreshold = .ninetyDays
        XCTAssertTrue(model.cleanupCandidates.isEmpty)
    }

    func testUnregisteredPreviewProjectCannotBeCleaned() async {
        var preview = project(id: "preview", name: "Preview", tasks: [task("old", daysAgo: 60)])
        preview.registration = .approvalRequired
        let model = await open(CleanupDataSource(snapshot: .init(projects: [preview])))
        XCTAssertTrue(model.cleanupProjects.isEmpty)
        XCTAssertTrue(model.cleanupCandidates.isEmpty)
    }

    func testSnapshotTruncationIsVisibleOnlyForAffectedScope() async {
        let snapshot = WorkspacePresentationSnapshot(projects: [
            project(id: "one", name: "One"), project(id: "two", name: "Two"),
        ], truncatedTaskProjectIDs: ["one"])
        let source = CleanupDataSource(snapshot: snapshot)
        source.archiveTruncated = true
        let model = await open(source)
        XCTAssertTrue(model.cleanupActiveListIsTruncated)
        XCTAssertTrue(model.cleanupArchiveListIsTruncated)
        model.cleanupProjectID = "two"
        XCTAssertFalse(model.cleanupActiveListIsTruncated)
    }

    func testOpeningAndDismissingCleanupChangesNothing() async {
        let source = makeSource(tasks: [task("old", daysAgo: 60)])
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["old"]
        model.dismissSessionCleanup()
        XCTAssertTrue(source.archivedIDs.isEmpty)
        XCTAssertEqual(source.snapshot.projects[0].sourceTrees[0].tasks.count, 1)
    }

    func testArchiveMovesOnlyExplicitSelectedTasksAndRefreshesBothLists() async {
        let source = makeSource(tasks: [task("one", daysAgo: 60), task("two", daysAgo: 60)])
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["one", "not-a-candidate"]
        await model.archiveSelectedCleanupTasks()
        XCTAssertEqual(source.archivedIDs, ["one"])
        XCTAssertEqual(model.cleanupCandidates.map(\.id), ["two"])
        XCTAssertEqual(model.archivedCleanupTasks.map(\.id), ["one"])
        XCTAssertTrue(model.selectedCleanupTaskIDs.isEmpty)
        XCTAssertEqual(model.cleanupResultSummary, "1개 작업을 보관했습니다.")
    }

    func testNewActiveSessionAfterReviewIsSkipped() async {
        let source = makeSource(tasks: [task("old", daysAgo: 60)])
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["old"]
        source.snapshot.projects[0].sourceTrees[0].tasks[0].sessions[0].state = .running
        await model.archiveSelectedCleanupTasks()
        XCTAssertTrue(source.archivedIDs.isEmpty)
        XCTAssertEqual(model.cleanupActiveExclusionCount, 1)
        XCTAssertTrue(model.cleanupError?.contains("상태") == true)
    }

    func testAddedEndedSessionAfterReviewAlsoRequiresNewReview() async {
        let source = makeSource(tasks: [task("old", daysAgo: 60)])
        let model = await open(source)
        model.cleanupThreshold = .allEnded
        model.selectedCleanupTaskIDs = ["old"]
        source.snapshot.projects[0].sourceTrees[0].tasks[0].sessions.append(session("unseen", daysAgo: 40))
        await model.archiveSelectedCleanupTasks()
        XCTAssertTrue(source.archivedIDs.isEmpty)
        XCTAssertNotNil(model.cleanupError)
    }

    func testTaskBecomingRecentAfterReviewIsSkipped() async {
        let source = makeSource(tasks: [task("old", daysAgo: 60)])
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["old"]
        source.snapshot.projects[0].sourceTrees[0].tasks[0].sessions[0].endedAt = now
        await model.archiveSelectedCleanupTasks()
        XCTAssertTrue(source.archivedIDs.isEmpty)
    }

    func testEachTaskIsRecheckedBetweenSequentialArchives() async {
        let source = makeSource(tasks: [task("one", daysAgo: 60), task("two", daysAgo: 60)])
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["one", "two"]
        source.afterArchive = { source in
            if let index = source.snapshot.projects[0].sourceTrees[0].tasks.firstIndex(where: { $0.id == "two" }) {
                source.snapshot.projects[0].sourceTrees[0].tasks[index].sessions[0].state = .preparing
            }
        }
        await model.archiveSelectedCleanupTasks()
        XCTAssertEqual(source.archivedIDs, ["one"])
        XCTAssertEqual(model.cleanupResultSummary, "1개 작업을 보관했습니다. 1개는 보관하지 않았습니다.")
    }

    func testPartialFailureKeepsOtherSuccessesAndReportsBoth() async {
        let source = makeSource(tasks: [task("one", daysAgo: 60), task("two", daysAgo: 60)])
        source.archiveFailures = ["one"]
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["one", "two"]
        await model.archiveSelectedCleanupTasks()
        XCTAssertEqual(source.archivedIDs, ["two"])
        XCTAssertEqual(model.cleanupCandidates.map(\.id), ["one"])
        XCTAssertEqual(model.selectedCleanupTaskIDs, ["one"])
        XCTAssertTrue(model.cleanupError?.contains("one") == true)
        XCTAssertEqual(model.cleanupResultSummary, "1개 작업을 보관했습니다. 1개는 보관하지 않았습니다.")
    }

    func testProjectRemovedAfterReviewIsNotArchived() async {
        let source = makeSource(tasks: [task("old", daysAgo: 60)])
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["old"]
        source.snapshot.projects = []
        await model.archiveSelectedCleanupTasks()
        XCTAssertTrue(source.archivedIDs.isEmpty)
        XCTAssertNotNil(model.cleanupError)
    }

    func testRestoreReturnsTaskWithoutLaunchingAnySession() async {
        let source = makeSource(tasks: [task("old", daysAgo: 60)])
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["old"]
        await model.archiveSelectedCleanupTasks()
        model.selectedArchivedTaskIDs = ["old"]
        await model.restoreSelectedCleanupTasks()
        XCTAssertEqual(source.restoredIDs, ["old"])
        XCTAssertEqual(model.cleanupCandidates.map(\.id), ["old"])
        XCTAssertTrue(model.archivedCleanupTasks.isEmpty)
        XCTAssertEqual(source.launchCalls, 0)
        XCTAssertEqual(model.cleanupResultSummary, "1개 작업을 복원했습니다.")
    }

    func testUnavailableArchivedLocationCannotBeSelectedForRestore() async {
        let source = makeSource(tasks: [])
        source.archiveRows = [.init(id: "missing", projectID: "project", projectName: "Project", sourceTreeID: "tree",
                                   title: "Missing", sessionCount: 1, latestEndedAt: nil,
                                   restoreUnavailableReason: "Restore checkout first")]
        let model = await open(source)
        model.selectedArchivedTaskIDs = ["missing"]
        await model.restoreSelectedCleanupTasks()
        XCTAssertTrue(source.restoredIDs.isEmpty)
    }

    func testCheckoutRemovedAfterArchiveReviewBlocksRestore() async {
        let source = makeSource(tasks: [task("old", daysAgo: 60)])
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["old"]
        await model.archiveSelectedCleanupTasks()
        model.selectedArchivedTaskIDs = ["old"]
        source.snapshot.projects[0].sourceTrees = []
        await model.restoreSelectedCleanupTasks()
        XCTAssertTrue(source.restoredIDs.isEmpty)
        XCTAssertNotNil(model.cleanupError)
    }

    func testArchivingSelectedSessionKeepsItsOwningCheckoutSelected() async {
        let source = makeSource(tasks: [task("old", daysAgo: 60), task("another", daysAgo: 40)])
        let model = await open(source)
        model.select(.session("old-session"))
        model.selectedCleanupTaskIDs = ["old"]
        await model.archiveSelectedCleanupTasks()
        XCTAssertEqual(model.selection, .sourceTree("tree"))
    }

    func testFailedWorkspaceRefreshClearsStaleArchiveScopeAndSelection() async {
        let source = makeSource(tasks: [task("old", daysAgo: 60)])
        let model = await open(source)
        model.selectedCleanupTaskIDs = ["old"]
        await model.archiveSelectedCleanupTasks()
        model.selectedArchivedTaskIDs = ["old"]
        source.loadFailure = true
        await model.refreshSessionCleanup()
        XCTAssertTrue(model.cleanupProjects.isEmpty)
        XCTAssertTrue(model.archivedCleanupTasks.isEmpty)
        XCTAssertTrue(model.selectedArchivedTaskIDs.isEmpty)
        if case .failed = model.cleanupArchivedPhase {} else { XCTFail("Stale archives must not appear ready") }
    }

    func testProjectFilterRefreshQueriesScopedArchiveList() async {
        let source = CleanupDataSource(snapshot: .init(projects: [project(id: "one", name: "One"), project(id: "two", name: "Two")]))
        let model = await open(source)
        model.cleanupProjectID = "two"
        await model.refreshSessionCleanup()
        XCTAssertEqual(source.lastArchivedProjectID, "two")
    }

    private func open(_ source: CleanupDataSource) async -> WorkspaceViewModel {
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        await model.prepareSessionCleanup(now: now)
        return model
    }

    private func makeSource(tasks: [WorkspaceTaskItem]) -> CleanupDataSource {
        CleanupDataSource(snapshot: .init(projects: [project(id: "project", name: "Project", tasks: tasks)]))
    }

    private func project(id: String, name: String, tasks: [WorkspaceTaskItem] = []) -> WorkspaceProjectItem {
        .init(id: id, name: name, repositoryURL: URL(fileURLWithPath: "/tmp/\(id)"), memorySpace: "byori_\(id)",
              registration: .trusted, sourceTrees: [
                .init(id: "tree", projectID: id, name: "main", url: URL(fileURLWithPath: "/tmp/\(id)"), kind: .primary,
                      branch: "main", headRevision: String(repeating: "a", count: 40), workingState: .clean, tasks: tasks),
              ], hiddenSourceTrees: [])
    }

    private func task(_ id: String, daysAgo: Int, extra: [WorkspaceSessionItem] = []) -> WorkspaceTaskItem {
        .init(id: id, sourceTreeID: "tree", title: id, status: .completed, createdAt: now.addingTimeInterval(-200 * 86_400),
              sessions: [session("\(id)-session", daysAgo: daysAgo)] + extra)
    }

    private func session(_ id: String, daysAgo: Int?, state: WorkspaceSessionItemStatus = .completed,
                         providerID: String = "claude") -> WorkspaceSessionItem {
        .init(id: id, taskID: id, name: nil, providerID: providerID, providerName: providerID,
              providerSystemImage: "terminal", modelID: "default", modelName: "Default", state: state,
              statusDetail: nil, startedAt: now.addingTimeInterval(-100 * 86_400),
              endedAt: daysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) }, nativeSessionID: nil)
    }
}

@MainActor
private final class CleanupDataSource: WorkspaceDataSource {
    var snapshot: WorkspacePresentationSnapshot
    var archiveRows: [WorkspaceArchivedTaskItem] = []
    var archiveTruncated = false
    var archivedIDs: [String] = []
    var restoredIDs: [String] = []
    var archiveFailures: Set<String> = []
    var afterArchive: ((CleanupDataSource) -> Void)?
    var launchCalls = 0
    var loadFailure = false
    var lastArchivedProjectID: String?
    private var archivedOriginals: [String: WorkspaceTaskItem] = [:]

    init(snapshot: WorkspacePresentationSnapshot) { self.snapshot = snapshot }
    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        if loadFailure { throw WorkspaceAdapterError.invalidState("Workspace unavailable") }
        return snapshot
    }
    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }
    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult {
        launchCalls += 1
        throw WorkspaceAdapterError.invalidState("Cleanup never launches")
    }
    func archivedTasks(projectID: String?) async throws -> WorkspaceArchivedTaskList {
        lastArchivedProjectID = projectID
        return .init(items: archiveRows.filter { projectID == nil || $0.projectID == projectID }, isTruncated: archiveTruncated)
    }
    func archiveTask(id: String) async throws {
        if archiveFailures.contains(id) { throw WorkspaceAdapterError.invalidState("Archive refused") }
        for projectIndex in snapshot.projects.indices {
            for treeIndex in snapshot.projects[projectIndex].sourceTrees.indices {
                guard let index = snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks.firstIndex(where: { $0.id == id }) else { continue }
                let task = snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks.remove(at: index)
                let project = snapshot.projects[projectIndex]
                let dates = task.sessions.compactMap(\.endedAt)
                archivedOriginals[id] = task
                archiveRows.append(.init(id: id, projectID: project.id, projectName: project.name, sourceTreeID: task.sourceTreeID,
                                         title: task.title, sessionCount: task.sessions.count,
                                         latestEndedAt: dates.count == task.sessions.count ? dates.max() : nil,
                                         restoreUnavailableReason: nil))
                archivedIDs.append(id)
                afterArchive?(self)
                return
            }
        }
        throw WorkspaceAdapterError.invalidState("Task missing")
    }
    func restoreTask(id: String) async throws {
        guard let row = archiveRows.first(where: { $0.id == id }), let task = archivedOriginals[id],
              let projectIndex = snapshot.projects.firstIndex(where: { $0.id == row.projectID }),
              let treeIndex = snapshot.projects[projectIndex].sourceTrees.firstIndex(where: { $0.id == row.sourceTreeID }) else {
            throw WorkspaceAdapterError.invalidState("Archived task missing")
        }
        snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks.append(task)
        archiveRows.removeAll { $0.id == id }
        archivedOriginals.removeValue(forKey: id)
        restoredIDs.append(id)
    }
}
