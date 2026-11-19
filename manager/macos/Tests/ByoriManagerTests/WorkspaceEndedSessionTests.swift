import ByoriManagerCore
import XCTest
@testable import ByoriManager

/// An ended tmux session leaves only "[exited]" in its terminal, so a session
/// that finished or was stopped hands the view back to its project. One that
/// failed stays on screen so its exit code can be read.
@MainActor
final class WorkspaceEndedSessionTests: XCTestCase {
    func testASessionThatFinishesReturnsToItsProject() async {
        let dataSource = EndedSessionDataSource(state: .running)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        XCTAssertEqual(model.selection, .session("session123"))

        dataSource.state = .completed
        await model.load(force: true)

        XCTAssertEqual(model.selection, .project("project123"))
    }

    func testAStoppedSessionReturnsToItsProject() async {
        let dataSource = EndedSessionDataSource(state: .running)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        dataSource.state = .cancelled
        await model.load(force: true)

        XCTAssertEqual(model.selection, .project("project123"))
    }

    func testAFailedSessionStaysSelected() async {
        let dataSource = EndedSessionDataSource(state: .running)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        dataSource.state = .failed
        await model.load(force: true)

        XCTAssertEqual(model.selection, .session("session123"))
        XCTAssertEqual(model.selectedSession?.statusDetail, "Exit code 1")
    }

    /// Only the moment of ending closes the pane; a refresh while a session
    /// keeps running, or one that was already over, leaves selection alone.
    func testRefreshesThatAreNotAnEndingKeepTheSelection() async {
        let dataSource = EndedSessionDataSource(state: .running)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        await model.load(force: true)
        XCTAssertEqual(model.selection, .session("session123"))

        dataSource.state = .failed
        await model.load(force: true)
        dataSource.state = .completed
        await model.load(force: true)
        XCTAssertEqual(model.selection, .session("session123"))
    }

    func testClosingAnEndedSessionSelectsItsProject() async {
        let dataSource = EndedSessionDataSource(state: .running)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        dataSource.state = .failed
        await model.load(force: true)
        let session = try! XCTUnwrap(model.selectedSession)

        model.closeEndedSession(session)

        XCTAssertEqual(model.selection, .project("project123"))
    }
}

@MainActor
private final class EndedSessionDataSource: WorkspaceDataSource {
    var state: WorkspaceSessionItemStatus

    init(state: WorkspaceSessionItemStatus) {
        self.state = state
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        let session = WorkspaceSessionItem(
            id: "session123",
            taskID: "task123",
            name: nil,
            providerID: "codex",
            providerName: "Codex",
            providerSystemImage: "terminal",
            modelID: "default",
            modelName: "CLI default",
            state: state,
            statusDetail: state == .failed ? "Exit code 1" : nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: state.isActive ? nil : Date(timeIntervalSince1970: 1_700_000_100),
            nativeSessionID: UUID().uuidString,
            isDetached: false
        )
        let task = WorkspaceTaskItem(
            id: "task123",
            sourceTreeID: "tree123",
            title: "desc",
            status: .active,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessions: [session]
        )
        let sourceTree = WorkspaceSourceTreeItem(
            id: "tree123",
            projectID: "project123",
            name: "main",
            url: URL(fileURLWithPath: "/tmp/byori-ended", isDirectory: true),
            kind: .primary,
            branch: "main",
            headRevision: String(repeating: "a", count: 40),
            workingState: .clean,
            tasks: [task]
        )
        let project = WorkspaceProjectItem(
            id: "project123",
            name: "byoridb-studio",
            repositoryURL: URL(fileURLWithPath: "/tmp/byori-ended", isDirectory: true),
            memorySpace: "byori_project123",
            registration: .trusted,
            sourceTrees: [sourceTree],
            hiddenSourceTrees: []
        )
        return WorkspacePresentationSnapshot(projects: [project])
    }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Not used by ended-session tests.")
    }

    func reattachSession(id: String) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Not used by ended-session tests.")
    }
}
