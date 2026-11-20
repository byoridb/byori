import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    func testSearchFindsTaskBranchAndSessionAcrossFieldsWithoutChangingRecords() async {
        let selected = project("selected", name: "Café", tasks: [
            task("checkout", title: "결제 화면", sessions: [session("comet", taskID: "checkout", name: "Mossy Comet")]),
            task("docs", title: "문서 정리", sessions: [])
        ])
        let other = project("other", name: "Different", tasks: [])
        let model = WorkspaceViewModel(dataSource: NavigationSource(projects: [selected, other]))
        await model.load()
        model.select(.session("comet"))

        for query in [" cafe ", "결제", "FEATURE/selected", "MOSSY", "cafe 결제 comet"] {
            model.projectSearchQuery = query
            XCTAssertEqual(model.filteredProjects.map(\.id), ["selected"], query)
            XCTAssertEqual(model.projects, [selected, other])
            XCTAssertEqual(model.selection, .session("comet"))
        }
        model.projectSearchQuery = "결제"
        let tree = selected.sourceTrees[0]
        XCTAssertTrue(model.sidebarTaskIsVisible(tree.tasks[0], in: tree, project: selected))
        XCTAssertFalse(model.sidebarTaskIsVisible(tree.tasks[1], in: tree, project: selected))
        model.projectSearchQuery = "absent"
        XCTAssertTrue(model.filteredProjects.isEmpty)
        XCTAssertEqual(model.selection, .session("comet"))
        model.projectSearchQuery = ""
        XCTAssertEqual(model.filteredProjects.map(\.id), ["selected", "other"])
    }

    func testOpenFilterIncludesActiveAndDetachedAndNeverAltersSelection() async {
        let states = WorkspaceSessionItemStatus.allCases
        var tasks = states.map { state in
            task(state.rawValue, title: state.rawValue,
                sessions: [session(state.rawValue, taskID: state.rawValue, state: state)])
        }
        var detached = session("detached", taskID: "detached", state: .completed)
        detached.isDetached = true
        tasks.append(task("detached", title: "Detached", sessions: [detached]))
        let busy = project("busy", tasks: tasks)
        let idle = project("idle", tasks: [])
        let model = WorkspaceViewModel(dataSource: NavigationSource(projects: [idle, busy]))
        await model.load()
        model.select(.project("idle"))
        model.workspaceListFilter = .openSessions

        XCTAssertEqual(model.filteredProjects.map(\.id), ["busy"])
        XCTAssertEqual(model.selection, .project("idle"))
        XCTAssertEqual(model.openSessionCount, 4)
        let tree = busy.sourceTrees[0]
        XCTAssertEqual(tree.tasks.filter { model.sidebarTaskIsVisible($0, in: tree, project: busy) }.map(\.id),
            ["preparing", "running", "waitingForUser", "detached"])
        model.presentQuickSwitch(openSessionsOnly: true)
        XCTAssertEqual(model.quickSwitchResults.count, model.openSessionCount)
        XCTAssertTrue(model.quickSwitchResults.allSatisfy(\.isOpenSession))
        model.isPresentingQuickSwitch = false
        XCTAssertEqual(model.selection, .project("idle"))
    }

    func testPinOrderIsStableAndPreferencesPersistOnlyThroughSuppliedStore() async throws {
        let suite = "byori-navigation-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = NavigationSource(projects: [project("one"), project("two"), project("three")])
        let model = WorkspaceViewModel(dataSource: source,
            navigationPreferences: WorkspaceNavigationPreferencesStore(defaults: defaults))
        await model.load()
        model.toggleProjectPin("three")
        model.toggleProjectPin("one")
        XCTAssertEqual(model.filteredProjects.map(\.id), ["one", "three", "two"])
        model.toggleProjectPin("missing")
        XCTAssertEqual(model.pinnedProjectIDs, ["one", "three"])
        model.workspaceListFilter = .openSessions

        let reopened = WorkspaceViewModel(dataSource: source,
            navigationPreferences: WorkspaceNavigationPreferencesStore(defaults: defaults))
        XCTAssertEqual(reopened.pinnedProjectIDs, ["one", "three"])
        XCTAssertEqual(reopened.workspaceListFilter, .openSessions)
        let isolated = WorkspaceViewModel(dataSource: source)
        XCTAssertTrue(isolated.pinnedProjectIDs.isEmpty)
        XCTAssertEqual(isolated.workspaceListFilter, .all)
        model.toggleProjectPin("one")
        model.workspaceListFilter = .all
        XCTAssertEqual(model.filteredProjects.map(\.id), ["three", "one", "two"])
    }

    func testQuickSwitchChoosesMatchingOpenSessionAndRejectsStaleTarget() async throws {
        let current = project("one", name: "한글 프로젝트", tasks: [
            task("task", title: "결제 화면", sessions: [session("session", taskID: "task", name: "Orbit")])
        ])
        let source = NavigationSource(projects: [current])
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        model.select(.project("one"))
        model.presentQuickSwitch()
        model.quickSwitchQuery = "한글 orbit"
        let result = try XCTUnwrap(model.quickSwitchResults.first)
        XCTAssertEqual(model.quickSwitchResults.count, 1)
        XCTAssertEqual(result.selection, .session("session"))
        XCTAssertEqual(model.selection, .project("one"))
        model.chooseQuickSwitchResult(result)
        XCTAssertEqual(model.selection, .session("session"))
        XCTAssertFalse(model.isPresentingQuickSwitch)

        model.presentQuickSwitch()
        source.projects = []
        await model.load(force: true)
        let selectionAfterRemoval = model.selection
        model.chooseQuickSwitchResult(result)
        XCTAssertEqual(model.selection, selectionAfterRemoval)
        XCTAssertTrue(model.isPresentingQuickSwitch)
    }

    func testOldSessionNameFindsTaskWithoutClaimingAnOpenTerminal() {
        let old = session("old", taskID: "task", name: "Old Finch", state: .completed)
        let current = session("current", taskID: "task", name: "New Comet", state: .running)
        let projects = [project("one", tasks: [task("task", title: "Work", sessions: [old, current])])]
        let results = WorkspaceNavigation.quickSwitchResults(projects: projects,
            query: "old finch", openSessionsOnly: false, pins: [])
        XCTAssertEqual(results.map(\.selection), [.task("task")])
        XCTAssertFalse(results[0].isOpenSession)
        XCTAssertTrue(WorkspaceNavigation.quickSwitchResults(projects: projects,
            query: "old finch", openSessionsOnly: true, pins: []).isEmpty)
    }

    func testUnknownSavedFilterFallsBackAndMalformedPinsDoNotAffectProjects() throws {
        let suite = "byori-navigation-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["filter": "removed-filter", "pinnedProjectIDs": ["", "one", "one"]],
            forKey: "workspace.navigation.v1")
        let preferences = WorkspaceNavigationPreferencesStore(defaults: defaults).load()
        XCTAssertEqual(preferences.filter, .all)
        XCTAssertEqual(preferences.pinnedProjectIDs, ["one"])
    }

    private func project(_ id: String, name: String? = nil, tasks: [WorkspaceTaskItem] = []) -> WorkspaceProjectItem {
        let url = URL(fileURLWithPath: "/tmp/byori-nav-\(id)", isDirectory: true)
        let tree = WorkspaceSourceTreeItem(id: "tree-\(id)", projectID: id, name: "main", url: url,
            kind: .primary, branch: "feature/\(id)", headRevision: nil, workingState: .clean,
            tasks: tasks.map { task in
                WorkspaceTaskItem(id: task.id, sourceTreeID: "tree-\(id)", title: task.title,
                    status: task.status, createdAt: task.createdAt, sessions: task.sessions)
            })
        return .init(id: id, name: name ?? id, repositoryURL: url, memorySpace: "space-\(id)",
            registration: .trusted, sourceTrees: [tree], hiddenSourceTrees: [])
    }

    private func task(_ id: String, title: String, sessions: [WorkspaceSessionItem]) -> WorkspaceTaskItem {
        .init(id: id, sourceTreeID: "tree", title: title, status: .open,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), sessions: sessions)
    }

    private func session(_ id: String, taskID: String, name: String? = nil,
                         state: WorkspaceSessionItemStatus = .running) -> WorkspaceSessionItem {
        .init(id: id, taskID: taskID, name: name, providerID: "codex", providerName: "Codex",
            providerSystemImage: "terminal", modelID: "default", modelName: "CLI default", state: state,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), nativeSessionID: UUID().uuidString)
    }
}

@MainActor
private final class NavigationSource: WorkspaceDataSource {
    var projects: [WorkspaceProjectItem]
    init(projects: [WorkspaceProjectItem]) { self.projects = projects }
    func loadWorkspace() async throws -> WorkspacePresentationSnapshot { .init(projects: projects) }
    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }
    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Not used by navigation tests.")
    }
    func reattachSession(id: String) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Not used by navigation tests.")
    }
}
