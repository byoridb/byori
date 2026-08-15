import SwiftUI
import XCTest
@testable import ByoriManager

/// Colour is the only thing telling a clean checkout from one with uncommitted
/// changes at a glance, and the outline and the status bar both read it from
/// here. These pin the two rules that were broken while each surface had its own
/// mapping: clean earns no accent, and teal belongs to running alone.
final class WorkspacePaletteTests: XCTestCase {
    func testCleanWorkingTreeEarnsNoColor() {
        XCTAssertNil(
            WorkspacePalette.workingTreeColor(.clean),
            "clean is the default state and must not spend an accent"
        )
    }

    func testUncommittedChangesAndUnavailableGitAreDistinct() {
        XCTAssertEqual(WorkspacePalette.workingTreeColor(.modified(changeCount: 3)), .orange)
        XCTAssertEqual(
            WorkspacePalette.workingTreeColor(.unavailable(reason: "not a repository")),
            .red
        )
    }

    /// A clean checkout used to be teal, which is the running accent. One dot in
    /// one column then meant "clean" on a source-tree row and "running" on a
    /// session row.
    func testWorkingTreeNeverUsesTheRunningAccent() {
        let states: [WorkspaceWorkingTreeStatus] = [
            .clean,
            .modified(changeCount: 1),
            .unavailable(reason: "unreadable"),
        ]
        for state in states {
            XCTAssertNotEqual(
                WorkspacePalette.workingTreeColor(state),
                WorkspacePalette.running,
                "teal is reserved for a running session"
            )
        }
        XCTAssertEqual(WorkspacePalette.statusColor(.running), WorkspacePalette.running)
    }
}
