import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class CodeIndexViewModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/project-worktree")

    func testOpeningReadsSavedSnapshotAndKeepsExplicitCheckoutAndSpace() async {
        let provider = CodeIndexFixtureProvider()
        let model = makeModel(provider)
        await model.load()

        XCTAssertEqual(model.snapshot?.snapshotID, "snapshot-a")
        XCTAssertEqual(model.files.map(\.path), ["a.swift"])
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.request.action), [.status, .files])
        XCTAssertTrue(calls.allSatisfy { $0.root == root && $0.space == "project_space" })
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isLoadingList)
    }

    func testMissingIndexDoesNotQueryFilesOrStartAnalysis() async {
        let provider = CodeIndexFixtureProvider()
        await provider.set(.init(), for: "status::0:")
        let model = makeModel(provider)
        await model.load()

        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.hasLoaded)
        let actions = await provider.calls.map(\.request.action)
        XCTAssertEqual(actions, [.status])
    }

    func testPaginationAppendsWithoutDuplicates() async {
        let provider = CodeIndexFixtureProvider()
        await provider.set(.init(index: snapshot(), files: [file("a.swift")], nextOffset: 50), for: "files::0:")
        await provider.set(.init(index: snapshot(), files: [file("a.swift"), file("b.swift")]), for: "files::50:")
        let model = makeModel(provider)
        await model.load()
        await model.loadMore()

        XCTAssertEqual(model.files.map(\.path), ["a.swift", "b.swift"])
        XCTAssertNil(model.nextOffset)
    }

    func testSlowOlderSearchCannotReplaceNewerResults() async {
        let provider = CodeIndexFixtureProvider()
        await provider.set(.init(index: snapshot(), files: [file("old.swift")]), for: "files:old:0:", held: true)
        await provider.set(.init(index: snapshot(), files: [file("new.swift")]), for: "files:new:0:")
        let model = makeModel(provider)
        await model.load()
        model.searchText = "old"
        let oldSearch = Task { await model.reloadResults() }
        await provider.waitFor("files:old:0:")

        model.searchText = "new"
        await model.reloadResults()
        await provider.release("files:old:0:")
        await oldSearch.value

        XCTAssertEqual(model.files.map(\.path), ["new.swift"])
        XCTAssertFalse(model.isLoadingList)
    }

    func testNewSnapshotDuringPaginationRestartsAtFirstPage() async {
        let provider = CodeIndexFixtureProvider()
        await provider.set(.init(index: snapshot(), files: [file("a.swift")], nextOffset: 50), for: "files::0:")
        let model = makeModel(provider)
        await model.load()
        await provider.set(.init(index: snapshot("snapshot-b"), files: [file("z.swift")]), for: "files::0:")
        await provider.set(.init(index: snapshot("snapshot-b"), files: [file("never-append.swift")]), for: "files::50:")

        await model.loadMore()

        XCTAssertEqual(model.snapshot?.snapshotID, "snapshot-b")
        XCTAssertEqual(model.files.map(\.path), ["z.swift"])
        XCTAssertNotNil(model.snapshotNotice)
    }

    func testSlowRelationsFromPreviousSelectionCannotReplaceCurrentSelection() async {
        let provider = CodeIndexFixtureProvider()
        let oldKey = "relations::0:file:a.swift"
        let newKey = "relations::0:file:b.swift"
        await provider.set(.init(index: snapshot(), relations: [relation("old")]), for: oldKey, held: true)
        await provider.set(.init(index: snapshot(), relations: [relation("new")]), for: newKey)
        let model = makeModel(provider)
        await model.load()
        model.selectFile(file("a.swift"))
        await provider.waitFor(oldKey)
        model.selectFile(file("b.swift"))
        await provider.waitFor(newKey)
        await provider.release(oldKey)
        for _ in 0..<100 where model.isLoadingDetail { await Task.yield() }

        XCTAssertEqual(model.selection?.id, "file:b.swift")
        XCTAssertEqual(model.relations.map(\.id), ["new"])
    }

    func testChangedSnapshotDuringDetailClearsSelectionAndReloads() async {
        let provider = CodeIndexFixtureProvider()
        let model = makeModel(provider)
        await model.load()
        let newer = snapshot("snapshot-b")
        await provider.set(.init(index: newer), for: "status::0:")
        await provider.set(.init(index: newer, files: [file("new.swift")]), for: "files::0:")
        await provider.set(.init(index: newer, relations: [relation("wrong-snapshot")]), for: "relations::0:file:a.swift")

        model.selectFile(file("a.swift"))
        await provider.waitFor("relations::0:file:a.swift")
        // Wait for the automatically triggered status + first-page reload.
        for _ in 0..<200 where model.snapshot?.snapshotID != "snapshot-b" || model.isLoadingList {
            await Task.yield()
        }

        XCTAssertEqual(model.snapshot?.snapshotID, "snapshot-b")
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.relations.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isLoadingDetail)
        XCTAssertEqual(model.files.map(\.path), ["new.swift"])
    }

    func testDismissalDiscardsLateResponseAndAllowsFreshReopen() async {
        let provider = CodeIndexFixtureProvider()
        await provider.set(.init(index: snapshot()), for: "status::0:", held: true)
        let model = makeModel(provider)
        let loading = Task { await model.load() }
        await provider.waitFor("status::0:")
        model.cancel()
        await provider.release("status::0:")
        await loading.value
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isLoading)

        await model.load()
        XCTAssertEqual(model.snapshot?.snapshotID, "snapshot-a")
    }

    private func makeModel(_ provider: CodeIndexFixtureProvider) -> CodeIndexViewModel {
        CodeIndexViewModel(provider: provider, projectRoot: root, space: "project_space")
    }

    private func snapshot(_ id: String = "snapshot-a") -> CodeIndexSnapshot {
        CodeIndexSnapshot(root: root.path, checkoutID: "checkout", snapshotID: id, files: 1, languages: ["swift"])
    }

    private func file(_ path: String) -> CodeIndexFile { CodeIndexFile(id: "file:" + path, path: path, language: "swift") }
    private func relation(_ id: String) -> CodeIndexRelation {
        CodeIndexRelation(id: id, source: "file:a.swift", target: "file:b.swift", name: "b", kind: "imports", file: "a.swift")
    }
}

private actor CodeIndexFixtureProvider: CodeIndexProviding {
    struct Call: Sendable {
        let request: CodeIndexRequest
        let root: URL
        let space: String
    }
    private(set) var calls: [Call] = []
    private var replies: [String: CodeIndexResponse] = [:]
    private var held: Set<String> = []
    private var pending: [String: CheckedContinuation<CodeIndexResponse, Never>] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func set(_ response: CodeIndexResponse, for key: String, held: Bool = false) {
        replies[key] = response
        if held { self.held.insert(key) }
    }

    func waitFor(_ key: String) async {
        if calls.contains(where: { Self.key($0.request) == key }) { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    func release(_ key: String) {
        held.remove(key)
        pending.removeValue(forKey: key)?.resume(returning: replies[key] ?? .init())
    }

    func queryCodeIndex(_ request: CodeIndexRequest, projectRoot: URL, space: String) async throws -> CodeIndexResponse {
        calls.append(Call(request: request, root: projectRoot, space: space))
        let key = Self.key(request)
        let waiters = self.waiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume() }
        if held.contains(key) {
            return await withCheckedContinuation { pending[key] = $0 }
        }
        if let reply = replies[key] { return reply }
        let snapshot = CodeIndexSnapshot(root: projectRoot.path, checkoutID: "checkout", snapshotID: "snapshot-a", files: 1, languages: ["swift"])
        if request.action == .files {
            return .init(index: snapshot, files: [CodeIndexFile(id: "file:a.swift", path: "a.swift", language: "swift")])
        }
        return .init(index: snapshot)
    }

    private static func key(_ request: CodeIndexRequest) -> String {
        "\(request.action.rawValue):\(request.query):\(request.offset):\(request.symbolID ?? "")"
    }
}
