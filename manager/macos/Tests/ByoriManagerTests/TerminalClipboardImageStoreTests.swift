import AppKit
import XCTest
@testable import ByoriManager

@MainActor
final class TerminalClipboardImageStoreTests: XCTestCase {
    func testPersistsClipboardImageAsPrivatePNG() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ByoriClipboardImageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalClipboardImageStore(
            sessionID: UUID(),
            temporaryDirectory: root
        )
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()

        let url = try XCTUnwrap(store.persistPNG(image))
        let data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testShellQuotesPathsWithoutExecutingTheirContents() {
        XCTAssertEqual(
            TerminalClipboardImageStore.shellQuoted("/tmp/a b'c.png"),
            "'/tmp/a b'\\''c.png'"
        )
    }
}
