import XCTest
@testable import ByoriManagerCore

/// The editor writes into the user's own repositories, so the interesting cases
/// here are the refusals: anything that escapes the source tree, corrupts a
/// file, or overwrites work the user never saw.
final class WorkspaceFileDocumentTests: XCTestCase {
    private var root: URL!
    private let service = LocalWorkspaceFileDocumentService()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("byori-file-document-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ contents: String, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Reading

    func testReadsTextAndReportsItsSize() async throws {
        try write("hello\n", to: "notes.md")
        let document = try await service.read(at: root, relativePath: "notes.md")
        XCTAssertEqual(document.text, "hello\n")
        XCTAssertEqual(document.byteSize, 6)
        XCTAssertFalse(document.revision.isEmpty)
    }

    func testRefusesBinaryAndNonUTF8Content() async throws {
        let binary = root.appendingPathComponent("image.bin")
        try Data([0x89, 0x50, 0x00, 0x4E]).write(to: binary)
        await assertRefused(relativePath: "image.bin", containing: "binary")

        let latin1 = root.appendingPathComponent("legacy.txt")
        try Data([0x41, 0xFF, 0xFE, 0x42]).write(to: latin1)
        await assertRefused(relativePath: "legacy.txt", containing: "UTF-8")
    }

    func testRefusesFilesOverTheEditLimit() async throws {
        let big = root.appendingPathComponent("big.log")
        try Data(repeating: 0x61, count: WorkspaceFileDocumentLimits.maxByteSize + 1).write(to: big)
        await assertRefused(relativePath: "big.log", containing: "limit")
    }

    func testRefusesDirectories() async throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        await assertRefused(relativePath: "src", containing: "not a regular file")
    }

    // MARK: - Containment

    func testRefusesPathsThatClimbOutOfTheSourceTree() async throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try Data("secret\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        for path in ["../outside.txt", "a/../../outside.txt", "/etc/hosts", "./notes.md", ""] {
            await assertRefused(relativePath: path, containing: nil)
        }
    }

    /// A relative path can look harmless and still resolve outside the tree when
    /// a component is a symbolic link, so containment is checked after resolving
    /// rather than on the spelling alone.
    func testRefusesSymbolicLinksThatLeaveTheSourceTree() async throws {
        let outsideDirectory = root.deletingLastPathComponent()
            .appendingPathComponent("byori-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let secret = outsideDirectory.appendingPathComponent("secret.txt")
        try Data("secret\n".utf8).write(to: secret)

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"),
            withDestinationURL: secret
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outsideDirectory
        )

        await assertRefused(relativePath: "link.txt", containing: "symbolic link")
        await assertRefused(relativePath: "escape/secret.txt", containing: "escapes")

        // The file outside the tree must be untouched by the refused writes.
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "secret\n")
    }

    func testContainmentComparesPathComponentsNotPrefixes() {
        let root = URL(fileURLWithPath: "/tmp/repo")
        XCTAssertTrue(LocalWorkspaceFileDocumentService.isContained(
            URL(fileURLWithPath: "/tmp/repo/src/main.swift"), in: root
        ))
        // "/tmp/repository" shares a string prefix with "/tmp/repo" and is a
        // different directory.
        XCTAssertFalse(LocalWorkspaceFileDocumentService.isContained(
            URL(fileURLWithPath: "/tmp/repository/main.swift"), in: root
        ))
        XCTAssertFalse(LocalWorkspaceFileDocumentService.isContained(root, in: root))
    }

    // MARK: - Writing

    func testWritesAndReturnsTheNewRevision() async throws {
        try write("one\n", to: "notes.md")
        let opened = try await service.read(at: root, relativePath: "notes.md")
        let saved = try await service.write(
            at: root,
            relativePath: "notes.md",
            text: "two\n",
            expectedRevision: opened.revision
        )
        XCTAssertEqual(saved.text, "two\n")
        XCTAssertNotEqual(saved.revision, opened.revision)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("notes.md"), encoding: .utf8),
            "two\n"
        )
    }

    /// The whole point of the revision. An agent session writing the same file
    /// between open and save must not have its work silently replaced.
    func testRefusesToSaveOverAFileThatChangedOnDisk() async throws {
        try write("original\n", to: "notes.md")
        let opened = try await service.read(at: root, relativePath: "notes.md")
        try write("written by an agent\n", to: "notes.md")

        do {
            _ = try await service.write(
                at: root,
                relativePath: "notes.md",
                text: "my edit\n",
                expectedRevision: opened.revision
            )
            XCTFail("expected the stale write to be refused")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .fileChangedOnDisk("notes.md"))
        }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("notes.md"), encoding: .utf8),
            "written by an agent\n"
        )
    }

    /// An atomic write creates a replacement file, which does not inherit the
    /// original mode. Losing the executable bit would break a checked-in script
    /// after a one-character fix.
    func testPreservesExecutablePermissions() async throws {
        let script = try write("#!/bin/sh\necho one\n", to: "run.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let opened = try await service.read(at: root, relativePath: "run.sh")
        _ = try await service.write(
            at: root,
            relativePath: "run.sh",
            text: "#!/bin/sh\necho two\n",
            expectedRevision: opened.revision
        )

        let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o755)
    }

    func testRefusesToCreateNewFiles() async throws {
        do {
            _ = try await service.write(
                at: root,
                relativePath: "new.txt",
                text: "hello\n",
                expectedRevision: ""
            )
            XCTFail("expected creating a new file to be refused")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
        }
    }

    // MARK: - Helpers

    private func assertRefused(
        relativePath: String,
        containing fragment: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.read(at: root, relativePath: relativePath)
            XCTFail("expected \(relativePath) to be refused", file: file, line: line)
        } catch {
            guard let fragment else { return }
            XCTAssertTrue(
                "\(error)".localizedCaseInsensitiveContains(fragment),
                "\(relativePath): \(error)",
                file: file,
                line: line
            )
        }
    }
}
