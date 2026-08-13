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

}
