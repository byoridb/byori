import XCTest
@testable import ByoriManagerCore

/// The Issues tab (#22) changes GitHub on the user's behalf through their own
/// `gh`, so what it runs is pinned here: which repository, which arguments,
/// and what a failure is reported as.
final class GitHubIssueServiceTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-gh-\(UUID().uuidString)", isDirectory: true)
        paths = ManagerPaths(home: root, runtimeRoot: root)
        // `~/.local/bin` is searched first, so the machine's own gh never runs.
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let gh = bin.appendingPathComponent("gh")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func service(_ gh: FakeGH) -> GitHubIssueService {
        GitHubIssueService(directory: root, paths: paths, runner: gh)
    }

    /// The repository comes from the checkout's remotes once; after that every
    /// command names it, so gh cannot resolve a different one.
    func testTheRepositoryIsResolvedOnceAndNamedOnEveryCommand() async throws {
        let gh = FakeGH()
        let issues = service(gh)

        _ = try await issues.issues(filter: .open, search: "")
        try await issues.reopen(number: 3)

        let calls = await gh.calls
        XCTAssertEqual(calls.filter { $0.arguments.starts(with: ["repo", "view"]) }.count, 1)
        XCTAssertEqual(calls.first?.workingDirectory, root.path)
        for call in calls.dropFirst() {
            XCTAssertEqual(Array(call.arguments.suffix(2)), ["-R", "byoridb/byori"], "\(call.arguments)")
        }
        let environment = try XCTUnwrap(calls.first?.environment)
        XCTAssertEqual(environment["GH_PROMPT_DISABLED"], "1", "gh must never wait on a prompt nobody sees")
        XCTAssertEqual(calls.first?.environmentRemovals, ["GH_REPO"])
    }

    /// gh reads a bare OWNER/REPO as github.com, so an Enterprise repository
    /// is named with its host — otherwise every command would target a
    /// same-named repository on github.com.
    func testAnEnterpriseRepositoryIsNamedWithItsHost() async throws {
        let gh = FakeGH()
        await gh.answer("repo view", with: """
        {"nameWithOwner": "team/app", "hasIssuesEnabled": true, "url": "https://ghe.example.com/team/app"}
        """)
        let issues = service(gh)

        try await issues.reopen(number: 1)
        _ = try await issues.assignableUsers()

        let reopen = try await XCTUnwrapAsync(await gh.call("issue reopen"))
        XCTAssertEqual(Array(reopen.arguments.suffix(2)), ["-R", "ghe.example.com/team/app"])
        let api = try await XCTUnwrapAsync(await gh.call("api"))
        XCTAssertEqual(Array(api.arguments.prefix(3)), ["api", "--hostname", "ghe.example.com"])
    }

    func testTheListIsReadEvenAfterAWarning() async throws {
        let gh = FakeGH()
        await gh.answer("issue list", with: """
        warning: something gh wanted to say
        [{"number": 22, "title": "Issues tab", "state": "OPEN", "stateReason": "",
          "labels": [{"name": "enhancement", "color": "a2eeef", "description": ""}],
          "assignees": [{"login": "kimjuik"}], "author": {"login": "kimjuik"},
          "updatedAt": "2026-08-09T10:30:33Z"}]
        """)

        let list = try await service(gh).issues(filter: .all, search: "  tab  ")

        XCTAssertEqual(list.count, 1)
        let issue = try XCTUnwrap(list.first)
        XCTAssertEqual(issue.number, 22)
        XCTAssertEqual(issue.state, .open)
        XCTAssertNil(issue.stateReason, "an empty reason is no reason")
        XCTAssertEqual(issue.labels, [GitHubLabel(name: "enhancement", color: "a2eeef")])
        XCTAssertEqual(issue.assignees, ["kimjuik"])
        XCTAssertNotNil(issue.updatedAt)
        let call = try await XCTUnwrapAsync(await gh.call("issue list"))
        XCTAssertTrue(call.arguments.contains("all"))
        XCTAssertTrue(call.arguments.contains("--search=tab"), "\(call.arguments)")
    }

    func testAnIssueIsReadWithItsComments() async throws {
        let gh = FakeGH()
        await gh.answer("issue view", with: """
        {"number": 70, "title": "tmux", "body": "body text", "state": "CLOSED",
         "stateReason": "COMPLETED", "labels": [], "assignees": [],
         "author": {"login": "a"}, "createdAt": "2026-08-25T13:26:28Z",
         "updatedAt": "2026-11-19T01:56:14Z", "url": "https://github.com/byoridb/byori/issues/70",
         "comments": [{"id": "IC_1", "author": {"login": "b"}, "body": "hello",
                       "createdAt": "2026-11-19T01:00:00Z"}]}
        """)

        let issue = try await service(gh).issue(number: 70)

        XCTAssertEqual(issue.summary.state, .closed)
        XCTAssertEqual(issue.summary.stateReason, "COMPLETED")
        XCTAssertEqual(issue.body, "body text")
        XCTAssertEqual(issue.url?.absoluteString, "https://github.com/byoridb/byori/issues/70")
        XCTAssertEqual(issue.comments, [GitHubIssueComment(
            id: "IC_1", author: "b", body: "hello",
            createdAt: ISO8601DateFormatter().date(from: "2026-11-19T01:00:00Z")
        )])
    }

    /// Text is passed as `--flag=value`, so a title that starts with a dash is
    /// a title, not an option.
    func testCreatingAnIssueReturnsItsNumberAndCannotBeReadAsFlags() async throws {
        let gh = FakeGH()
        await gh.answer("issue create", with: "https://github.com/byoridb/byori/issues/117\n")

        let number = try await service(gh).createIssue(title: "--help", body: "-R other/repo")

        XCTAssertEqual(number, 117)
        let call = try await XCTUnwrapAsync(await gh.call("issue create"))
        XCTAssertTrue(call.arguments.contains("--title=--help"))
        XCTAssertTrue(call.arguments.contains("--body=-R other/repo"))
        XCTAssertEqual(Array(call.arguments.suffix(2)), ["-R", "byoridb/byori"])
    }

    func testClosingNamesTheReason() async throws {
        let gh = FakeGH()

        try await service(gh).close(number: 5, reason: .notPlanned)

        let call = try await XCTUnwrapAsync(await gh.call("issue close"))
        XCTAssertTrue(call.arguments.contains("--reason=not planned"), "\(call.arguments)")
    }

    func testEditingSendsOnlyTheChanges() async throws {
        let gh = FakeGH()
        let issues = service(gh)

        try await issues.edit(number: 9, addLabels: ["bug"], removeLabels: ["question"],
                              addAssignees: ["a"], removeAssignees: [])
        try await issues.edit(number: 9, addLabels: [], removeLabels: [], addAssignees: [], removeAssignees: [])

        let edits = await gh.calls.filter { $0.arguments.starts(with: ["issue", "edit"]) }
        XCTAssertEqual(edits.count, 1, "an edit with no changes runs nothing")
        XCTAssertEqual(Array(edits[0].arguments.prefix(6)),
                       ["issue", "edit", "9", "--add-label=bug", "--remove-label=question", "--add-assignee=a"])
    }

    func testAssignableUsersAreListedOnePerLine() async throws {
        let gh = FakeGH()
        await gh.answer("api", with: "kimjuik\nTeoConnexioh\n")

        let users = try await service(gh).assignableUsers()

        XCTAssertEqual(users, ["kimjuik", "TeoConnexioh"])
        let call = try await XCTUnwrapAsync(await gh.call("api"))
        XCTAssertTrue(call.arguments.contains("repos/byoridb/byori/assignees"))
    }

    // MARK: - What cannot be done, and what to do about it

    func testWithoutGhTheRequirementIsNamed() async throws {
        let gh = FakeGH()
        let issues = GitHubIssueService(directory: root, paths: paths, runner: gh, locateGH: { nil })

        await assertFails(issues, with: .ghMissing)
        let calls = await gh.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testFailuresAreReportedAsWhatFixesThem() async throws {
        let cases: [(String, GitHubIssueError)] = [
            ("To get started with GitHub CLI, please run:  gh auth login", .notAuthenticated),
            ("HTTP 401: Bad credentials (https://api.github.com/graphql)", .notAuthenticated),
            ("failed to run git: fatal: not a git repository (or any of the parent directories): .git",
             .noGitHubRepository),
            ("none of the git remotes configured for this repository point to a known GitHub host",
             .noGitHubRepository),
            ("X No default remote repository has been set. please run `gh repo set-default`",
             .needsDefaultRepository),
            ("GraphQL: Something else entirely", .commandFailed("GraphQL: Something else entirely")),
        ]
        for (output, expected) in cases {
            let gh = FakeGH()
            await gh.fail("repo view", with: output)
            await assertFails(service(gh), with: expected)
        }
    }

    func testARepositoryWithIssuesTurnedOffSaysSo() async throws {
        let gh = FakeGH()
        await gh.answer("repo view", with: #"{"nameWithOwner": "o/r", "hasIssuesEnabled": false}"#)

        await assertFails(service(gh), with: .issuesDisabled("o/r"))
    }

    private func assertFails(
        _ service: GitHubIssueService,
        with expected: GitHubIssueError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.issues(filter: .open, search: "")
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as GitHubIssueError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// A gh that answers by subcommand prefix and records every call.
private actor FakeGH: CommandRunning {
    private(set) var calls: [CommandSpec] = []
    private var answers: [String: CommandResult] = [
        "repo view": CommandResult(exitCode: 0, output: #"{"nameWithOwner": "byoridb/byori", "hasIssuesEnabled": true, "url": "https://github.com/byoridb/byori"}"#),
        "issue list": CommandResult(exitCode: 0, output: "[]"),
    ]

    func answer(_ prefix: String, with output: String) {
        answers[prefix] = CommandResult(exitCode: 0, output: output)
    }

    func fail(_ prefix: String, with output: String) {
        answers[prefix] = CommandResult(exitCode: 1, output: output)
    }

    func call(_ prefix: String) -> CommandSpec? {
        calls.first { $0.arguments.joined(separator: " ").hasPrefix(prefix) }
    }

    func run(_ command: CommandSpec) async -> CommandResult {
        calls.append(command)
        let joined = command.arguments.joined(separator: " ")
        for (prefix, result) in answers where joined.hasPrefix(prefix) {
            return result
        }
        return CommandResult(exitCode: 0, output: "")
    }
}
