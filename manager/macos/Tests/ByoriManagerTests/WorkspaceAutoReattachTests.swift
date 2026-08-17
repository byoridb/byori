import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceAutoReattachTests: XCTestCase {
    /// Opening Byori onto a session tmux is still running must not require a
    /// button press: the CLI kept running, and there is no other thing to do with
    /// that pane.
    func testLoadReattachesTheSelectedDetachedSession() async {
        let dataSource = ReattachDataSource(snapshot: makeSnapshot(detached: true))
        let model = WorkspaceViewModel(dataSource: dataSource)

        await model.load()

        XCTAssertEqual(dataSource.reattachedIDs, ["session123"])
        XCTAssertEqual(model.selection, .session("session123"))
        XCTAssertEqual(model.selectedSession?.isDetached, false)
        XCTAssertNil(model.alert)
    }

    func testAnAttachedSessionIsLeftAlone() async {
        let dataSource = ReattachDataSource(snapshot: makeSnapshot(detached: false))
        let model = WorkspaceViewModel(dataSource: dataSource)

        await model.load()

        XCTAssertTrue(dataSource.reattachedIDs.isEmpty)
    }

    /// The failure path must stay quiet — nobody asked for this attempt — and must
    /// not run again on the next load, or a session tmux has lost would reattach
    /// on every refresh forever.
    func testFailedAutomaticReattachIsSilentAndNotRetried() async {
        let dataSource = ReattachDataSource(snapshot: makeSnapshot(detached: true))
        dataSource.failure = WorkspaceAdapterError.invalidState("이 세션은 더 이상 실행 중이 아닙니다.")
        let model = WorkspaceViewModel(dataSource: dataSource)

        await model.load()
        XCTAssertEqual(dataSource.reattachedIDs, ["session123"])
        XCTAssertNil(model.alert, "An attempt the user did not ask for must not raise a dialog")

        await model.load(force: true)
        XCTAssertEqual(
            dataSource.reattachedIDs,
            ["session123"],
            "A failed automatic reattach must not be retried on the next load"
        )
    }

    /// The manual button keeps reporting failures: pressing it is a question, and
    /// silence would be the wrong answer.
    func testManualReattachStillReportsFailure() async {
        let dataSource = ReattachDataSource(snapshot: makeSnapshot(detached: true))
        dataSource.failure = WorkspaceAdapterError.invalidState("이 세션은 더 이상 실행 중이 아닙니다.")
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        let session = try! XCTUnwrap(model.selectedSession)

        await model.reattachSession(session)

        XCTAssertEqual(model.alert?.title, "세션에 다시 연결하지 못했습니다")
    }

    func testSelectingAnotherDetachedSessionAttachesIt() async {
        let dataSource = ReattachDataSource(snapshot: makeSnapshot(detached: true, secondSession: true))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        XCTAssertEqual(dataSource.reattachedIDs, ["session123"])

        model.select(.session("session456"))
        // select() hands the work to a Task, so let it run.
        await Task.yield()
        for _ in 0..<20 where dataSource.reattachedIDs.count < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(dataSource.reattachedIDs, ["session123", "session456"])
    }

    private func makeSnapshot(
        detached: Bool,
        secondSession: Bool = false
    ) -> WorkspacePresentationSnapshot {
        var sessions = [makeSession(id: "session123", detached: detached)]
        if secondSession {
            sessions.append(makeSession(id: "session456", detached: true))
        }
        let task = WorkspaceTaskItem(
            id: "task123",
            sourceTreeID: "worktree123",
            title: "Reattach on launch",
            status: .active,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessions: sessions
        )
        let sourceTree = WorkspaceSourceTreeItem(
            id: "worktree123",
            projectID: "project123",
            name: "feature/auto-reattach",
            url: URL(fileURLWithPath: "/tmp/byori-worktree", isDirectory: true),
            kind: .managedWorktree,
            branch: "feature/auto-reattach",
            headRevision: String(repeating: "a", count: 40),
            workingState: .clean,
            tasks: [task]
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

    private func makeSession(id: String, detached: Bool) -> WorkspaceSessionItem {
        WorkspaceSessionItem(
            id: id,
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
            nativeSessionID: UUID().uuidString,
            isDetached: detached
        )
    }
}

@MainActor
private final class ReattachDataSource: WorkspaceDataSource {
    var snapshot: WorkspacePresentationSnapshot
    var reattachedIDs: [String] = []
    var failure: Error?

    init(snapshot: WorkspacePresentationSnapshot) {
        self.snapshot = snapshot
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot { snapshot }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Not used by reattach tests.")
    }

    func reattachSession(id: String) async throws -> WorkspaceSessionLaunchResult {
        reattachedIDs.append(id)
        if let failure { throw failure }
        markAttached(id: id)
        guard let session = allSessions().first(where: { $0.id == id }) else {
            throw WorkspaceAdapterError.invalidState("Missing test session")
        }
        return WorkspaceSessionLaunchResult(
            projectID: "project123",
            sourceTreeID: "worktree123",
            task: task(),
            session: session
        )
    }

    private func markAttached(id: String) {
        for projectIndex in snapshot.projects.indices {
            for treeIndex in snapshot.projects[projectIndex].sourceTrees.indices {
                for taskIndex in snapshot.projects[projectIndex].sourceTrees[treeIndex].tasks.indices {
                    var sessions = snapshot.projects[projectIndex]
                        .sourceTrees[treeIndex].tasks[taskIndex].sessions
                    guard let sessionIndex = sessions.firstIndex(where: { $0.id == id }) else {
                        continue
                    }
                    sessions[sessionIndex].isDetached = false
                    snapshot.projects[projectIndex]
                        .sourceTrees[treeIndex].tasks[taskIndex].sessions = sessions
                }
            }
        }
    }

    private func task() -> WorkspaceTaskItem {
        snapshot.projects[0].sourceTrees[0].tasks[0]
    }

    private func allSessions() -> [WorkspaceSessionItem] {
        snapshot.projects.flatMap { $0.sourceTrees.flatMap { $0.tasks.flatMap(\.sessions) } }
    }
}
