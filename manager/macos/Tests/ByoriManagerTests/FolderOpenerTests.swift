import XCTest
@testable import ByoriManager

/// Open Logs, Open Backups, and the agent config buttons create what is missing
/// and say so when they cannot, instead of opening nothing in silence.
@MainActor
final class FolderOpenerTests: XCTestCase {
    private var root: URL!
    private var opened: [URL] = []
    private var revealed: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        opened = []
        revealed = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func opener(opens: Bool = true) -> FolderOpener {
        var opener = FolderOpener()
        opener.open = { [unowned self] url in
            opened.append(url)
            return opens
        }
        opener.reveal = { [unowned self] urls in revealed.append(contentsOf: urls) }
        return opener
    }

    func testAMissingFolderIsCreatedThenOpened() {
        let logs = root.appendingPathComponent("logs", isDirectory: true)

        XCTAssertNil(opener().openDirectory(logs))

        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.path))
        XCTAssertEqual(opened, [logs])
    }

    func testAFolderThatCannotBeCreatedIsReportedAndNotOpened() throws {
        let blocker = root.appendingPathComponent("logs")
        try Data().write(to: blocker)

        let failure = opener().openDirectory(blocker.appendingPathComponent("inner", isDirectory: true))

        XCTAssertNotNil(failure)
        XCTAssertEqual(opened, [])
    }

    func testARefusedOpenIsReported() {
        XCTAssertNotNil(opener(opens: false).openDirectory(root))
    }

    func testAnExistingConfigIsOpened() throws {
        let config = root.appendingPathComponent("config.toml")
        try Data().write(to: config)

        XCTAssertNil(opener().openFileOrRevealFolder(config))

        XCTAssertEqual(opened, [config])
        XCTAssertEqual(revealed, [])
    }

    func testAMissingConfigRevealsItsFolderCreatingIt() {
        let folder = root.appendingPathComponent(".codex", isDirectory: true)

        XCTAssertNil(opener().openFileOrRevealFolder(folder.appendingPathComponent("config.toml")))

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(revealed.map(\.standardizedFileURL), [folder.standardizedFileURL])
        XCTAssertEqual(opened, [])
    }

    func testAConfigFolderThatCannotBeCreatedIsReported() throws {
        let blocker = root.appendingPathComponent(".codex")
        try Data().write(to: blocker)

        XCTAssertNotNil(opener().openFileOrRevealFolder(blocker.appendingPathComponent("sub/config.toml")))
        XCTAssertEqual(revealed, [])
    }
}
