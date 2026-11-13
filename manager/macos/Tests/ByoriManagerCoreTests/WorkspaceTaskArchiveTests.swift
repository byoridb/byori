import XCTest
@testable import ByoriManagerCore

final class WorkspaceTaskArchiveTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var store: WorkspaceTaskStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-task-archive-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = WorkspaceTaskStore(home: home, now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRoundTripPreservesExactMetadataAndSidecars() async throws {
        let task = try await makeTask()
        let session = try await store.createSession(taskID: task.id, name: "Quiet Harbor", provider: .codex, model: "default")
        _ = try await store.updateSessionStatus(taskID: task.id, sessionID: session.id, status: .cancelled)
        let loaded = try await store.task(id: task.id)
        let before = try XCTUnwrap(loaded)
        let active = directory(task.id, archived: false)
        let sidecars = ["workflow.json": Data("{\"goal\":\"keep\"}".utf8),
                        "runs/receipt/output.txt": Data([0, 1, 2, 10, 255])]
        for (path, bytes) in sidecars {
            let url = active.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let state = try Data(contentsOf: active.appendingPathComponent("state.json"))
        _ = try await store.archiveTask(id: task.id)
        let archived = try await store.archivedTask(id: task.id)
        XCTAssertEqual(archived, before)

        let restored = try await store.restoreTask(id: task.id)

        XCTAssertEqual(restored, before)
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("state.json")), state)
        for (path, bytes) in sidecars { XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent(path)), bytes) }
        let archiveList = try await store.archivedTasks()
        XCTAssertTrue(archiveList.tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(task.id, archived: true).path))
    }

    func testArchivedListingFiltersSortsAndReportsRequestedLimit() async throws {
        var alpha: [WorkspaceTask] = []
        for _ in 0..<3 {
            let task = try await makeTask(projectID: "alpha")
            alpha.append(try await store.archiveTask(id: task.id))
        }
        let other = try await makeTask(projectID: "beta")
        _ = try await store.archiveTask(id: other.id)

        let selected = try await store.archivedTasks(projectID: "alpha", limit: 2)
        XCTAssertEqual(selected.tasks.map(\.id), Array(alpha.map(\.id).sorted().prefix(2)))
        XCTAssertTrue(selected.isTruncated)
        let full = try await store.archivedTasks(projectID: "alpha", limit: 20)
        XCTAssertEqual(full.tasks.count, 3)
        XCTAssertFalse(full.isTruncated)
        let minimum = try await store.archivedTasks(limit: 0)
        XCTAssertEqual(minimum.tasks.count, 1)
        XCTAssertTrue(minimum.isTruncated)
    }

    func testMissingArchiveIsEmptyAndMissingTaskCannotRestore() async throws {
        let empty = try await store.archivedTasks()
        XCTAssertTrue(empty.tasks.isEmpty)
        XCTAssertFalse(empty.isTruncated)
        let missing = try await store.archivedTask(id: "missing")
        XCTAssertNil(missing)
        await assertRestoreRefused("missing")
    }

    func testListingReportsWhenDirectoryScanIsIncomplete() async throws {
        let archive = home.appendingPathComponent("archived-tasks", isDirectory: true)
        for index in 0..<2_001 {
            try FileManager.default.createDirectory(
                at: archive.appendingPathComponent("empty-\(index)"), withIntermediateDirectories: true
            )
        }
        let listing = try await store.archivedTasks()
        XCTAssertTrue(listing.tasks.isEmpty)
        XCTAssertTrue(listing.isTruncated, "an incomplete scan must not claim the archive is definitively empty")
    }

    func testDestinationDirectoryOrDanglingSymlinkIsNeverOverwritten() async throws {
        let task = try await makeArchivedTask()
        let active = directory(task.id, archived: false)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let marker = active.appendingPathComponent("keep.txt")
        try Data("destination".utf8).write(to: marker)
        await assertRestoreRefused(task.id)
        XCTAssertEqual(try String(contentsOf: marker), "destination")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory(task.id, archived: true).path))

        try FileManager.default.removeItem(at: active)
        let nowhere = root.appendingPathComponent("does-not-exist")
        try FileManager.default.createSymbolicLink(at: active, withDestinationURL: nowhere)
        await assertRestoreRefused(task.id)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: active.path), nowhere.path)
    }

    func testTraversalIDsAreRejectedWithoutChangingArchive() async throws {
        let task = try await makeArchivedTask()
        let before = try Data(contentsOf: directory(task.id, archived: true).appendingPathComponent("state.json"))
        for id in [".", "..", "../escape", "/absolute", "", "name/child"] {
            await assertRestoreRefused(id)
            do {
                _ = try await store.archivedTask(id: id)
                XCTFail("Unsafe id should not be read: \(id)")
            } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: directory(task.id, archived: true).appendingPathComponent("state.json")), before)
    }

    func testSymlinkArchiveDirectoryAndStateAreRefused() async throws {
        let task = try await makeArchivedTask()
        let archived = directory(task.id, archived: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.moveItem(at: archived, to: outside)
        try FileManager.default.createSymbolicLink(at: archived, withDestinationURL: outside)
        await assertRestoreRefused(task.id)
        do {
            _ = try await store.archivedTasks()
            XCTFail("Archive listing must not traverse a directory symlink")
        } catch {}
        try FileManager.default.removeItem(at: archived)
        try FileManager.default.moveItem(at: outside, to: archived)
        let state = archived.appendingPathComponent("state.json")
        let outsideState = root.appendingPathComponent("outside-state.json")
        try FileManager.default.moveItem(at: state, to: outsideState)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: outsideState)
        await assertRestoreRefused(task.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideState.path))
    }

    func testSymlinkActiveRootIsRefused() async throws {
        let task = try await makeArchivedTask()
        let activeRoot = home.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.removeItem(at: activeRoot)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: activeRoot, withDestinationURL: outside)
        await assertRestoreRefused(task.id)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testArchivedStateMustMatchDirectoryAndHaveNoActiveSessions() async throws {
        let task = try await makeArchivedTask()
        let state = directory(task.id, archived: true).appendingPathComponent("state.json")
        let original = try Data(contentsOf: state)
        var document = try XCTUnwrap(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        var value = try XCTUnwrap(document["task"] as? [String: Any])
        value["id"] = "another-task"
        document["task"] = value
        try JSONSerialization.data(withJSONObject: document).write(to: state)
        await assertRestoreRefused(task.id)

        value["id"] = task.id
        value["sessions"] = [["id": "active-session", "provider": "codex", "model": "default",
                              "status": "active", "created_at": "2023-11-14T22:13:20Z"]]
        document["task"] = value
        try JSONSerialization.data(withJSONObject: document).write(to: state)
        await assertRestoreRefused(task.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(task.id, archived: false).path))
    }

    func testListingSkipsMissingStateButFailsClosedOnMalformedState() async throws {
        let task = try await makeArchivedTask()
        let archive = home.appendingPathComponent("archived-tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: archive.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("ignored".utf8).write(to: archive.appendingPathComponent("notes.txt"))
        let listing = try await store.archivedTasks()
        XCTAssertEqual(listing.tasks.map(\.id), [task.id])
        try Data("{broken".utf8).write(to: directory(task.id, archived: true).appendingPathComponent("state.json"))
        do {
            _ = try await store.archivedTasks()
            XCTFail("Malformed metadata must not silently disappear from the archive")
        } catch {}
    }

    private func makeTask(projectID: String = "project") async throws -> WorkspaceTask {
        try await store.createTask(projectID: projectID, checkout: .init(kind: .sourceTree, id: "source"), title: "Keep this task")
    }

    private func makeArchivedTask() async throws -> WorkspaceTask {
        let task = try await makeTask()
        return try await store.archiveTask(id: task.id)
    }

    private func directory(_ id: String, archived: Bool) -> URL {
        home.appendingPathComponent(archived ? "archived-tasks" : "tasks").appendingPathComponent(id, isDirectory: true)
    }

    private func assertRestoreRefused(_ id: String) async {
        do {
            _ = try await store.restoreTask(id: id)
            XCTFail("Restoration should be refused: \(id)")
        } catch {}
    }

}
