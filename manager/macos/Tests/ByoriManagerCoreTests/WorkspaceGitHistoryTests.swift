import XCTest
@testable import ByoriManagerCore

final class WorkspaceGitLogParsingTests: XCTestCase {
    private func record(
        sha: String,
        parents: String = "",
        author: String = "Teo",
        date: String = "2026-08-09T12:00:00+09:00",
        refs: String = "",
        subject: String
    ) -> String {
        [sha, parents, author, date, refs, subject].joined(separator: "\u{1f}") + "\u{1e}"
    }

    func testParsesFieldsAndParents() {
        let commits = WorkspaceGitLogFormat.parse(
            record(sha: String(repeating: "a", count: 40), parents: "", subject: "root")
                + "\n"
                + record(
                    sha: String(repeating: "b", count: 40),
                    parents: "\(String(repeating: "a", count: 40)) \(String(repeating: "c", count: 40))",
                    subject: "merge"
                )
        )
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "root")
        XCTAssertTrue(commits[0].parents.isEmpty)
        XCTAssertEqual(commits[1].parents.count, 2)
        XCTAssertTrue(commits[1].isMerge)
        XCTAssertEqual(commits[1].shortSHA, "bbbbbbb")
        XCTAssertNotNil(commits[0].authorDate)
    }

    /// Subjects routinely contain commas, arrows, and colons. The separators are
    /// ASCII control characters precisely so none of that has to be escaped.
    func testKeepsPunctuationInSubjects() {
        let commits = WorkspaceGitLogFormat.parse(record(
            sha: String(repeating: "a", count: 40),
            subject: "fix(ui): keep a, b -> c and tag: v1 intact"
        ))
        XCTAssertEqual(commits.first?.subject, "fix(ui): keep a, b -> c and tag: v1 intact")
    }

    func testSkipsMalformedRecords() {
        XCTAssertTrue(WorkspaceGitLogFormat.parse("").isEmpty)
        XCTAssertTrue(WorkspaceGitLogFormat.parse("not-a-sha\u{1f}\u{1f}\u{1f}\u{1f}\u{1f}x\u{1e}").isEmpty)
        XCTAssertTrue(WorkspaceGitLogFormat.parse("\u{1e}\u{1e}").isEmpty)
    }

    // MARK: - Decorations

    /// Branch names here contain slashes, so short decorations cannot say
    /// whether `feat/x` is local or a remote-tracking ref. Full ref names can.
    func testTellsLocalBranchesFromRemoteOnesWhenBothContainSlashes() {
        let refs = WorkspaceGitLogFormat.parseRefs(
            "HEAD -> refs/heads/feat/git-history-graph, refs/remotes/origin/feat/git-history-graph"
        )
        XCTAssertEqual(refs.count, 3)
        XCTAssertEqual(refs[0].kind, .head)
        XCTAssertEqual(refs[1], WorkspaceGitRef(name: "feat/git-history-graph", kind: .localBranch))
        XCTAssertEqual(refs[2], WorkspaceGitRef(name: "origin/feat/git-history-graph", kind: .remoteBranch))
        XCTAssertTrue(refs[1].isCheckoutable)
        XCTAssertFalse(refs[2].isCheckoutable)
    }

    /// A bare `HEAD` decoration means HEAD is detached. It must not read as
    /// "this branch is checked out", or the UI would hide the very checkout that
    /// reattaches it.
    func testParsesTagsAndDetachedHead() {
        let refs = WorkspaceGitLogFormat.parseRefs("HEAD, tag: refs/tags/v0.3.0, refs/heads/main")
        XCTAssertEqual(refs[0], WorkspaceGitRef(name: "HEAD", kind: .detachedHead))
        XCTAssertEqual(refs[1], WorkspaceGitRef(name: "v0.3.0", kind: .tag))
        XCTAssertEqual(refs[2], WorkspaceGitRef(name: "main", kind: .localBranch))
        // A tag must never be offered as a checkout: it would detach HEAD.
        XCTAssertFalse(refs[1].isCheckoutable)
    }

    func testDropsTheRemoteHeadPointer() {
        let refs = WorkspaceGitLogFormat.parseRefs(
            "refs/remotes/origin/main, refs/remotes/origin/HEAD, refs/heads/main"
        )
        XCTAssertEqual(refs.map(\.name), ["origin/main", "main"])
    }

    func testTreatsUnknownNamespacesAsNonCheckoutable() {
        let refs = WorkspaceGitLogFormat.parseRefs("refs/stash, refs/notes/commits")
        XCTAssertTrue(refs.allSatisfy { !$0.isCheckoutable })
    }
}

final class WorkspaceGitGraphLayoutTests: XCTestCase {
    private func commit(_ sha: String, parents: [String] = []) -> WorkspaceGitCommit {
        WorkspaceGitCommit(
            sha: sha,
            parents: parents,
            authorName: "Teo",
            authorDate: nil,
            refs: [],
            subject: sha
        )
    }

    private func layout(_ commits: [WorkspaceGitCommit]) -> WorkspaceGitGraph {
        WorkspaceGitGraph.layout(commits: commits, isTruncated: false)
    }

    func testAStraightHistoryStaysInOneLane() {
        let graph = layout([
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a"),
        ])
        XCTAssertEqual(graph.rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(graph.laneCount, 1)
        XCTAssertTrue(graph.rows.allSatisfy(\.passingLanes.isEmpty))
    }

    /// A merge's second parent has to open a lane of its own, and the commits
    /// that belong to that side sit in it until it rejoins.
    func testAMergeOpensASecondLaneAndClosesItOnRejoin() {
        let graph = layout([
            commit("m", parents: ["a2", "b1"]),   // merge
            commit("b1", parents: ["a1"]),        // side branch
            commit("a2", parents: ["a1"]),        // mainline
            commit("a1"),
        ])
        let lanes = Dictionary(uniqueKeysWithValues: graph.rows.map { ($0.commit.sha, $0.lane) })
        XCTAssertEqual(lanes["m"], 0)
        XCTAssertEqual(lanes["a2"], 0, "the first parent keeps the merge's lane")
        XCTAssertEqual(lanes["b1"], 1, "the second parent opens a new lane")
        // Both sides converge on a1. The side branch reserved it first, but the
        // mainline must not be dragged into lane 1 for the rest of the graph —
        // the parent is pulled back to the leftmost converging lane.
        XCTAssertEqual(lanes["a1"], 0, "the mainline stays in its lane through a rejoin")
        XCTAssertEqual(graph.laneCount, 2)
        XCTAssertTrue(graph.rows.last?.passingLanes.isEmpty ?? false)
    }

    func testTheMergeRowRecordsAnEdgeToEachParent() {
        let graph = layout([
            commit("m", parents: ["a2", "b1"]),
            commit("b1"),
            commit("a2"),
        ])
        let merge = try? XCTUnwrap(graph.rows.first)
        XCTAssertEqual(merge?.outgoing.count, 2)
        XCTAssertEqual(merge?.outgoing.first?.toLane, 0)
        XCTAssertEqual(merge?.outgoing.last?.toLane, 1)
    }

    /// Without lane reuse the graph drifts right forever: every finished branch
    /// would leave a dead column behind it.
    func testAFreedLaneIsReused() {
        let graph = layout([
            commit("m", parents: ["a1", "b1"]),
            commit("b1"),                 // tip with no parents: its lane ends here
            commit("a1"),
            commit("x"),                  // unrelated root
        ])
        XCTAssertEqual(graph.rows.last?.lane, 0)
        XCTAssertEqual(graph.laneCount, 2)
    }

    func testUnrelatedRootsEachGetALane() {
        let graph = layout([
            commit("a", parents: ["a0"]),
            commit("b", parents: ["b0"]),
            commit("a0"),
            commit("b0"),
        ])
        XCTAssertEqual(graph.rows.map(\.lane), [0, 1, 0, 1])
        // While a0 is drawn, b0's lane is still waiting and must be drawn through.
        XCTAssertEqual(graph.rows[2].passingLanes, [1])
    }

    func testEmptyHistoryProducesNoLanes() {
        let graph = layout([])
        XCTAssertTrue(graph.rows.isEmpty)
        XCTAssertEqual(graph.laneCount, 0)
    }

    /// A truncated log has parents that were never walked. They must simply end
    /// their lane instead of being drawn as if they continued.
    func testParentsMissingFromATruncatedLogDoNotKeepLanesOpen() {
        let graph = WorkspaceGitGraph.layout(
            commits: [commit("c", parents: ["missing"])],
            isTruncated: true
        )
        XCTAssertTrue(graph.isTruncated)
        XCTAssertEqual(graph.rows.first?.outgoing.count, 1)
        XCTAssertEqual(graph.rows.first?.lane, 0)
    }
}
