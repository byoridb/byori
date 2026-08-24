import XCTest
@testable import ByoriManagerCore

/// What the app accepts as "open this repository".
///
/// The strictness is deliberate. An accepted request registers whatever root it
/// names, and registering a project assigns it a memory space — so a malformed or
/// hostile URL that resolved to some other directory would silently create a graph
/// for a project the user never chose.
final class ByoriOpenRequestTests: XCTestCase {
    func testTheCLIsURLIsUnderstood() {
        let request = ByoriOpenRequest(url: URL(string: "byori://project?root=/Users/me/shop")!)

        XCTAssertEqual(request?.root.path, "/Users/me/shop")
    }

    func testAPathWithSpacesSurvivesPercentEncoding() {
        let url = ByoriOpenRequest.url(forRoot: URL(fileURLWithPath: "/Users/me/My Work/shop"))

        XCTAssertEqual(url?.absoluteString, "byori://project?root=/Users/me/My%20Work/shop")
        XCTAssertEqual(ByoriOpenRequest(url: url!)?.root.path, "/Users/me/My Work/shop")
    }

    /// `open -a Byori <folder>` and a folder dropped on the icon mean the same thing.
    func testAFileURLIsAcceptedAsTheSameRequest() {
        let request = ByoriOpenRequest(url: URL(fileURLWithPath: "/Users/me/shop", isDirectory: true))

        XCTAssertEqual(request?.root.path, "/Users/me/shop")
    }

    func testTheVerbAPersonWouldTryByHandAlsoWorks() throws {
        let url = try XCTUnwrap(URL(string: "byori://open?root=/Users/me/shop"))

        XCTAssertEqual(ByoriOpenRequest(url: url)?.root.path, "/Users/me/shop")
    }

    func testAnythingElseIsRefused() {
        let refused = [
            // Not ours.
            "https://example.com/project?root=/Users/me/shop",
            // No root to open.
            "byori://project",
            "byori://project?root=",
            // Relative, so it would resolve against the app's working directory
            // rather than where the command was typed.
            "byori://project?root=shop",
            "byori://project?root=../../etc",
            // An action the app does not implement must not be read as "open".
            "byori://install?root=/Users/me/shop",
        ]

        for text in refused {
            let url = URL(string: text)
            XCTAssertNil(
                url.flatMap(ByoriOpenRequest.init(url:)),
                "\(text) should not be accepted"
            )
        }
    }

    func testTheSpellingIsSharedBetweenSenderAndParser() throws {
        let root = URL(fileURLWithPath: "/Users/me/shop", isDirectory: true)
        let url = try XCTUnwrap(ByoriOpenRequest.url(forRoot: root))

        XCTAssertEqual(url.scheme, ByoriOpenRequest.scheme)
        XCTAssertEqual(ByoriOpenRequest(url: url)?.root.path, root.standardizedFileURL.path)
    }
}
