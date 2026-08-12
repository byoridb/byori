import XCTest
@testable import ByoriManager

final class WorkspaceSourceTreePresentationTests: XCTestCase {
    func testCheckoutKindsUseDistinctLaunchLabels() {
        XCTAssertEqual(WorkspaceSourceTreeItemKind.primary.locationLabel, "Primary checkout")
        XCTAssertEqual(WorkspaceSourceTreeItemKind.managedWorktree.locationLabel, "Byori worktree")
        XCTAssertEqual(WorkspaceSourceTreeItemKind.externalCheckout.locationLabel, "External checkout")
        XCTAssertEqual(WorkspaceSourceTreeItemKind.managedWorktree.removalLabel, "Worktree")
        XCTAssertEqual(WorkspaceSourceTreeItemKind.externalCheckout.removalLabel, "External Checkout")
    }

    func testManagedWorktreeExplanationDistinguishesOriginalFolder() {
        XCTAssertTrue(
            WorkspaceSourceTreeItemKind.managedWorktree.sessionLocationDetail
                .contains("not the original project folder")
        )
        XCTAssertTrue(
            WorkspaceSourceTreeItemKind.primary.sessionLocationDetail
                .contains("original project folder")
        )
    }

    func testSessionsDefaultToActivityAndRememberTheirOwnSurface() {
        var preferences = WorkspaceSessionSurfacePreferences()

        XCTAssertEqual(preferences.selection(for: "first"), .activity)
        XCTAssertEqual(preferences.selection(for: "second"), .activity)

        preferences.select(.terminal, for: "first")

        XCTAssertEqual(preferences.selection(for: "first"), .terminal)
        XCTAssertEqual(preferences.selection(for: "second"), .activity)
    }

    func testSessionDurationFormattingUsesLiveOrEndedTime() {
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            WorkspaceSessionDurationFormatter.string(
                startedAt: start,
                endedAt: nil,
                now: start.addingTimeInterval(125)
            ),
            "2:05"
        )
        XCTAssertEqual(
            WorkspaceSessionDurationFormatter.string(
                startedAt: start,
                endedAt: start.addingTimeInterval(3_661),
                now: start.addingTimeInterval(9_999)
            ),
            "1:01:01"
        )
        XCTAssertEqual(
            WorkspaceSessionDurationFormatter.string(
                startedAt: nil,
                endedAt: nil,
                now: start
            ),
            "Not started"
        )
    }
}
