import XCTest
@testable import ByoriManagerCore

/// Skill and command scanners read only files that are what they appear to be:
/// a link to a regular file elsewhere is refused like a directory or a gap.
final class URLRegularFileTests: XCTestCase {
    func testOnlyAnUnlinkedRegularFileQualifies() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-regular-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("SKILL.md")
        try Data("body".utf8).write(to: file)
        let link = directory.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertTrue(file.isUnlinkedRegularFile)
        XCTAssertFalse(link.isUnlinkedRegularFile)
        XCTAssertFalse(directory.isUnlinkedRegularFile)
        XCTAssertFalse(directory.appendingPathComponent("missing.md").isUnlinkedRegularFile)
    }
}
