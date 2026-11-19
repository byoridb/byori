import ByoriManagerCore
import XCTest
@testable import ByoriManager

/// The Issues tab shows GitHub's record, not its own guess: a change appears
/// only after gh has made it and the issue has been read back (#22).
@MainActor
final class WorkspaceIssuesViewModelTests: XCTestCase {
    func testTheListAndRepositoryAreReadOnce() async {
        let github = FakeIssues()
        let model = WorkspaceIssuesViewModel { github }

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        XCTAssertEqual(model.listPhase, .ready)
        XCTAssertEqual(model.repository, "byoridb/byori")
        XCTAssertEqual(model.issues.map(\.number), [22, 70])
        let lists = await github.listCalls
        XCTAssertEqual(lists, 1)
    }

    /// The requirement gh reports is what the tab shows, word for word.
    func testAMissingLoginIsShownAsTheFix() async {
        let model = WorkspaceIssuesViewModel { throw GitHubIssueError.notAuthenticated }

        await model.reloadList()

        XCTAssertEqual(model.listPhase, .failed(GitHubIssueError.notAuthenticated.localizedDescription))
        XCTAssertTrue(model.issues.isEmpty)
    }

    func testClosingShowsTheIssueAsGitHubNowHasIt() async throws {
        let github = FakeIssues()
        let model = WorkspaceIssuesViewModel { github }
        await model.reloadList()
        await model.select(22)

        await model.close(reason: .notPlanned)

        let closes = await github.closes
        XCTAssertEqual(closes.map(\.reason), [.notPlanned])
        XCTAssertEqual(model.detail?.summary.state, .closed, "read back after the write")
        XCTAssertNil(model.actionError)
    }

    func testAFailedWriteLeavesTheIssueAsItWasAndSaysWhy() async throws {
        let github = FakeIssues()
        await github.failWrites(with: .commandFailed("GraphQL: Could not resolve to an issue"))
        let model = WorkspaceIssuesViewModel { github }
        await model.select(22)

        await model.toggleLabel("bug")

        XCTAssertEqual(model.detail?.summary.labels, [], "nothing changed on GitHub, so nothing changes here")
        XCTAssertEqual(model.actionError, "GraphQL: Could not resolve to an issue")
    }

    func testTogglingALabelAddsOrRemovesIt() async throws {
        let github = FakeIssues()
        let model = WorkspaceIssuesViewModel { github }
        await model.select(22)

        await model.toggleLabel("bug")
        await model.toggleLabel("bug")

        let edits = await github.edits
        XCTAssertEqual(edits.map(\.add), [["bug"], []])
        XCTAssertEqual(edits.map(\.remove), [[], ["bug"]])
    }

    func testACommentIsClearedOnlyOnceItIsPosted() async throws {
        let github = FakeIssues()
        let model = WorkspaceIssuesViewModel { github }
        await model.select(22)
        model.commentDraft = "  looks good  "

        await model.postComment()

        let comments = await github.comments
        XCTAssertEqual(comments, ["looks good"])
        XCTAssertEqual(model.commentDraft, "")

        await github.failWrites(with: .commandFailed("rate limited"))
        model.commentDraft = "second"
        await model.postComment()
        XCTAssertEqual(model.commentDraft, "second", "a failed post keeps what was typed")
    }

    func testANewIssueIsOpenedOnceCreated() async throws {
        let github = FakeIssues()
        let model = WorkspaceIssuesViewModel { github }
        model.prepareNewIssue()
        XCTAssertFalse(model.canCreateIssue, "a title is required")
        model.newIssueTitle = "New thing"
        model.newIssueBody = "body"

        await model.createIssue()

        XCTAssertFalse(model.isPresentingNewIssue)
        XCTAssertEqual(model.selectedNumber, 117)
        let created = await github.created
        XCTAssertEqual(created.map(\.title), ["New thing"])
    }
}

private actor FakeIssues: GitHubIssueProviding {
    private var issuesByNumber: [Int: GitHubIssueSummary] = [
        22: GitHubIssueSummary(number: 22, title: "Issues tab", state: .open),
        70: GitHubIssueSummary(number: 70, title: "tmux", state: .open),
    ]
    private var writeFailure: GitHubIssueError?
    private(set) var listCalls = 0
    private(set) var closes: [(number: Int, reason: GitHubIssueCloseReason)] = []
    private(set) var edits: [(add: [String], remove: [String])] = []
    private(set) var comments: [String] = []
    private(set) var created: [(title: String, body: String)] = []

    func failWrites(with error: GitHubIssueError) { writeFailure = error }

    func repository() async throws -> GitHubRepository { GitHubRepository(nameWithOwner: "byoridb/byori") }

    func issues(filter: GitHubIssueListFilter, search: String) async throws -> [GitHubIssueSummary] {
        listCalls += 1
        return issuesByNumber.values.sorted { $0.number < $1.number }
    }

    func issue(number: Int) async throws -> GitHubIssueDetail {
        guard let summary = issuesByNumber[number] else { throw GitHubIssueError.commandFailed("no issue") }
        return GitHubIssueDetail(summary: summary, body: "", url: nil, createdAt: nil, comments: [])
    }

    func createIssue(title: String, body: String) async throws -> Int {
        if let writeFailure { throw writeFailure }
        created.append((title, body))
        issuesByNumber[117] = GitHubIssueSummary(number: 117, title: title, state: .open)
        return 117
    }

    func close(number: Int, reason: GitHubIssueCloseReason) async throws {
        if let writeFailure { throw writeFailure }
        closes.append((number, reason))
        let old = issuesByNumber[number]!
        issuesByNumber[number] = GitHubIssueSummary(
            number: number, title: old.title, state: .closed,
            stateReason: reason == .completed ? "COMPLETED" : "NOT_PLANNED"
        )
    }

    func reopen(number: Int) async throws {
        if let writeFailure { throw writeFailure }
    }

    func comment(number: Int, body: String) async throws {
        if let writeFailure { throw writeFailure }
        comments.append(body)
    }

    func edit(number: Int, addLabels: [String], removeLabels: [String],
              addAssignees: [String], removeAssignees: [String]) async throws {
        if let writeFailure { throw writeFailure }
        edits.append((addLabels, removeLabels))
        let old = issuesByNumber[number]!
        var labels = old.labels.filter { !removeLabels.contains($0.name) }
        labels += addLabels.map { GitHubLabel(name: $0, color: "d73a4a") }
        issuesByNumber[number] = GitHubIssueSummary(
            number: number, title: old.title, state: old.state, labels: labels
        )
    }

    func labels() async throws -> [GitHubLabel] { [GitHubLabel(name: "bug", color: "d73a4a")] }
    func assignableUsers() async throws -> [String] { ["kimjuik"] }
}
