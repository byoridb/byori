import Foundation

// GitHub issues for a project's repository, read and changed through the
// user's own `gh` (#22).
//
// Byori never reads or stores a GitHub token: `gh` already holds the user's
// login, and every request goes through it. What gh cannot do — no binary, no
// login, no GitHub remote — is reported as a requirement with the command that
// resolves it, never worked around.

public struct GitHubRepository: Equatable, Sendable {
    public let nameWithOwner: String
    /// `github.com`, or a GitHub Enterprise host.
    public let host: String

    public init(nameWithOwner: String, host: String = "github.com") {
        self.nameWithOwner = nameWithOwner
        self.host = host
    }

    /// What `-R` takes. gh reads a bare OWNER/REPO as github.com, so an
    /// Enterprise repository has to carry its host.
    var selector: String {
        host == "github.com" ? nameWithOwner : "\(host)/\(nameWithOwner)"
    }
}

public enum GitHubIssueState: String, Equatable, Sendable {
    case open = "OPEN"
    case closed = "CLOSED"
}

/// What the issue list asks gh for. `all` is its own value rather than "no
/// filter" because gh lists only open issues when `--state` is omitted.
public enum GitHubIssueListFilter: String, CaseIterable, Identifiable, Sendable {
    case open, closed, all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .open: return "열림"
        case .closed: return "닫힘"
        case .all: return "전체"
        }
    }
}

/// The two reasons GitHub records for a close. "duplicate" also exists but
/// needs the duplicated issue named, which this surface does not ask for.
public enum GitHubIssueCloseReason: String, CaseIterable, Identifiable, Sendable {
    case completed
    case notPlanned = "not planned"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .completed: return "완료로 닫기"
        case .notPlanned: return "계획 안 함으로 닫기"
        }
    }
}

public struct GitHubLabel: Identifiable, Hashable, Sendable {
    public let name: String
    /// Six hex digits without `#`, as GitHub stores it.
    public let color: String
    public let description: String?

    public var id: String { name }

    public init(name: String, color: String, description: String? = nil) {
        self.name = name
        self.color = color
        self.description = description
    }
}

public struct GitHubIssueSummary: Identifiable, Equatable, Sendable {
    public let number: Int
    public let title: String
    public let state: GitHubIssueState
    /// `COMPLETED`, `NOT_PLANNED` or `REOPENED` as gh reports it; nil for an
    /// issue that was never closed.
    public let stateReason: String?
    public let labels: [GitHubLabel]
    public let assignees: [String]
    public let author: String?
    public let updatedAt: Date?

    public var id: Int { number }

    public init(
        number: Int,
        title: String,
        state: GitHubIssueState,
        stateReason: String? = nil,
        labels: [GitHubLabel] = [],
        assignees: [String] = [],
        author: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.number = number
        self.title = title
        self.state = state
        self.stateReason = stateReason
        self.labels = labels
        self.assignees = assignees
        self.author = author
        self.updatedAt = updatedAt
    }
}

public struct GitHubIssueComment: Identifiable, Equatable, Sendable {
    public let id: String
    public let author: String?
    public let body: String
    public let createdAt: Date?

    public init(id: String, author: String?, body: String, createdAt: Date?) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

public struct GitHubIssueDetail: Identifiable, Equatable, Sendable {
    public let summary: GitHubIssueSummary
    public let body: String
    public let url: URL?
    public let createdAt: Date?
    public let comments: [GitHubIssueComment]

    public var id: Int { summary.number }

    public init(
        summary: GitHubIssueSummary,
        body: String,
        url: URL?,
        createdAt: Date?,
        comments: [GitHubIssueComment]
    ) {
        self.summary = summary
        self.body = body
        self.url = url
        self.createdAt = createdAt
        self.comments = comments
    }
}

/// Why the issues of a project cannot be shown or changed, phrased for the
/// person who has to fix it.
public enum GitHubIssueError: Error, Equatable, LocalizedError, Sendable {
    case ghMissing
    case notAuthenticated
    case noGitHubRepository
    /// More than one GitHub remote and no default chosen; gh will not guess.
    case needsDefaultRepository
    case issuesDisabled(String)
    case commandFailed(String)
    case unreadableResponse

    public var errorDescription: String? {
        switch self {
        case .ghMissing:
            return "GitHub CLI(gh)가 필요합니다. brew install gh로 설치한 뒤 gh auth login으로 로그인하세요."
        case .notAuthenticated:
            return "gh가 GitHub에 로그인되어 있지 않습니다. 터미널에서 gh auth login을 실행하세요."
        case .noGitHubRepository:
            return "이 프로젝트에 GitHub 저장소를 가리키는 git remote가 없습니다."
        case .needsDefaultRepository:
            return "GitHub remote가 여러 개입니다. 프로젝트 폴더에서 gh repo set-default로 사용할 저장소를 정하세요."
        case let .issuesDisabled(repository):
            return "\(repository) 저장소는 이슈를 사용하지 않도록 설정되어 있습니다."
        case let .commandFailed(output):
            return output.isEmpty ? "gh 명령이 실패했습니다." : output
        case .unreadableResponse:
            return "gh의 응답을 읽지 못했습니다. gh를 최신 버전으로 업데이트한 뒤 다시 시도하세요."
        }
    }

    /// gh reports every one of these as exit code 1 with a sentence, so the
    /// sentence is all there is to go on. Anything unrecognised keeps gh's own
    /// words.
    static func classify(_ output: String) -> GitHubIssueError {
        let text = output.lowercased()
        if text.contains("gh auth login") || text.contains("not logged in")
            || text.contains("bad credentials") || text.contains("http 401") {
            return .notAuthenticated
        }
        if text.contains("set-default") {
            return .needsDefaultRepository
        }
        if text.contains("not a git repository") || text.contains("no git remotes")
            || text.contains("none of the git remotes") {
            return .noGitHubRepository
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(String(trimmed.prefix(600)))
    }
}

public protocol GitHubIssueProviding: Sendable {
    func repository() async throws -> GitHubRepository
    func issues(filter: GitHubIssueListFilter, search: String) async throws -> [GitHubIssueSummary]
    func issue(number: Int) async throws -> GitHubIssueDetail
    /// Returns the new issue's number.
    func createIssue(title: String, body: String) async throws -> Int
    func close(number: Int, reason: GitHubIssueCloseReason) async throws
    func reopen(number: Int) async throws
    func comment(number: Int, body: String) async throws
    func edit(
        number: Int,
        addLabels: [String],
        removeLabels: [String],
        addAssignees: [String],
        removeAssignees: [String]
    ) async throws
    func labels() async throws -> [GitHubLabel]
    func assignableUsers() async throws -> [String]
}

/// Runs `gh` for one checkout. The repository is resolved once from that
/// checkout's remotes and then named explicitly with `-R`, so every later
/// command targets the same repository whatever gh's cwd resolution would do.
public actor GitHubIssueService: GitHubIssueProviding {
    public static let listLimit = 100

    private let directory: URL
    private let paths: ManagerPaths
    private let runner: CommandRunning
    private let locateGH: @Sendable () -> URL?
    private var resolved: GitHubRepository?

    public init(directory: URL, paths: ManagerPaths, runner: CommandRunning = ProcessCommandRunner()) {
        self.init(directory: directory, paths: paths, runner: runner, locateGH: { paths.executable(named: "gh") })
    }

    init(
        directory: URL,
        paths: ManagerPaths,
        runner: CommandRunning,
        locateGH: @escaping @Sendable () -> URL?
    ) {
        self.directory = directory
        self.paths = paths
        self.runner = runner
        self.locateGH = locateGH
    }

    public func repository() async throws -> GitHubRepository {
        if let resolved { return resolved }
        let output = try await gh(["repo", "view", "--json", "nameWithOwner,hasIssuesEnabled,url"], pinned: false)
        guard let object = Self.json(output) as? [String: Any],
              let name = object["nameWithOwner"] as? String else {
            throw GitHubIssueError.unreadableResponse
        }
        if object["hasIssuesEnabled"] as? Bool == false {
            throw GitHubIssueError.issuesDisabled(name)
        }
        let host = (object["url"] as? String).flatMap { URL(string: $0)?.host } ?? "github.com"
        let repository = GitHubRepository(nameWithOwner: name, host: host)
        resolved = repository
        return repository
    }

    public func issues(filter: GitHubIssueListFilter, search: String) async throws -> [GitHubIssueSummary] {
        var arguments = [
            "issue", "list",
            "--state", filter.rawValue,
            "--limit", String(Self.listLimit),
            "--json", "number,title,state,stateReason,labels,assignees,author,updatedAt",
        ]
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { arguments.append("--search=\(query)") }
        let output = try await gh(arguments)
        guard let items = Self.json(output) as? [[String: Any]] else {
            throw GitHubIssueError.unreadableResponse
        }
        return try items.map(Self.summary)
    }

    public func issue(number: Int) async throws -> GitHubIssueDetail {
        let output = try await gh([
            "issue", "view", String(number),
            "--json", "number,title,body,state,stateReason,labels,assignees,author,createdAt,updatedAt,url,comments",
        ])
        guard let object = Self.json(output) as? [String: Any] else {
            throw GitHubIssueError.unreadableResponse
        }
        return try Self.detail(object)
    }

    public func createIssue(title: String, body: String) async throws -> Int {
        // gh prints the new issue's URL; its number is the last path component.
        let output = try await gh(["issue", "create", "--title=\(title)", "--body=\(body)"], timeout: 60)
        guard let number = Self.createdIssueNumber(output) else {
            throw GitHubIssueError.unreadableResponse
        }
        return number
    }

    public func close(number: Int, reason: GitHubIssueCloseReason) async throws {
        _ = try await gh(["issue", "close", String(number), "--reason=\(reason.rawValue)"], timeout: 60)
    }

    public func reopen(number: Int) async throws {
        _ = try await gh(["issue", "reopen", String(number)], timeout: 60)
    }

    public func comment(number: Int, body: String) async throws {
        _ = try await gh(["issue", "comment", String(number), "--body=\(body)"], timeout: 60)
    }

    public func edit(
        number: Int,
        addLabels: [String],
        removeLabels: [String],
        addAssignees: [String],
        removeAssignees: [String]
    ) async throws {
        var arguments = ["issue", "edit", String(number)]
        arguments += addLabels.map { "--add-label=\($0)" }
        arguments += removeLabels.map { "--remove-label=\($0)" }
        arguments += addAssignees.map { "--add-assignee=\($0)" }
        arguments += removeAssignees.map { "--remove-assignee=\($0)" }
        guard arguments.count > 3 else { return }
        _ = try await gh(arguments, timeout: 60)
    }

    public func labels() async throws -> [GitHubLabel] {
        let output = try await gh(["label", "list", "--limit", "200", "--json", "name,color,description"])
        guard let items = Self.json(output) as? [[String: Any]] else {
            throw GitHubIssueError.unreadableResponse
        }
        return items.compactMap(Self.label)
    }

    public func assignableUsers() async throws -> [String] {
        let repository = try await repository()
        let output = try await gh(
            ["api", "--hostname", repository.host, "--paginate",
             "repos/\(repository.nameWithOwner)/assignees", "--jq", ".[].login"],
            pinned: false
        )
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Running gh

    private func gh(_ arguments: [String], pinned: Bool = true, timeout: TimeInterval = 30) async throws -> String {
        guard let executable = locateGH() else {
            throw GitHubIssueError.ghMissing
        }
        var fullArguments = arguments
        if pinned {
            let repository = try await repository()
            fullArguments += ["-R", repository.selector]
        }
        let result = await runner.run(CommandSpec(
            executable: executable.path,
            arguments: fullArguments,
            environment: [
                "PATH": paths.processPath,
                "GH_PROMPT_DISABLED": "1",
                "GH_NO_UPDATE_NOTIFIER": "1",
                "GH_PAGER": "cat",
                "NO_COLOR": "1",
            ],
            workingDirectory: directory.path,
            timeout: timeout,
            // A repository named by the environment would override the one
            // this checkout's remotes resolve to.
            environmentRemovals: ["GH_REPO"]
        ))
        guard result.succeeded else {
            if result.timedOut {
                throw GitHubIssueError.commandFailed("gh가 시간 안에 응답하지 않았습니다. 네트워크 연결을 확인하세요.")
            }
            throw GitHubIssueError.classify(result.output)
        }
        return result.output
    }

    // MARK: - Parsing

    /// The runner merges stderr into the output, so a warning gh prints can
    /// precede the document. The document is cut from its first opening
    /// bracket to its last closing one.
    static func json(_ output: String) -> Any? {
        if let data = output.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) {
            return value
        }
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = output.lastIndex(where: { $0 == "}" || $0 == "]" }),
              start < end,
              let data = String(output[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func createdIssueNumber(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: "/issues/", options: .backwards) else { continue }
            let digits = line[range.upperBound...].prefix(while: \.isNumber)
            if let number = Int(digits) { return number }
        }
        return nil
    }

    private static func summary(_ object: [String: Any]) throws -> GitHubIssueSummary {
        guard let number = object["number"] as? Int,
              let title = object["title"] as? String,
              let state = (object["state"] as? String).flatMap(GitHubIssueState.init(rawValue:)) else {
            throw GitHubIssueError.unreadableResponse
        }
        let reason = (object["stateReason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GitHubIssueSummary(
            number: number,
            title: title,
            state: state,
            stateReason: reason,
            labels: (object["labels"] as? [[String: Any]] ?? []).compactMap(label),
            assignees: (object["assignees"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String },
            author: (object["author"] as? [String: Any])?["login"] as? String,
            updatedAt: date(object["updatedAt"])
        )
    }

    private static func detail(_ object: [String: Any]) throws -> GitHubIssueDetail {
        let comments = (object["comments"] as? [[String: Any]] ?? []).enumerated().map { index, comment in
            GitHubIssueComment(
                id: comment["id"] as? String ?? "comment-\(index)",
                author: (comment["author"] as? [String: Any])?["login"] as? String,
                body: comment["body"] as? String ?? "",
                createdAt: date(comment["createdAt"])
            )
        }
        return GitHubIssueDetail(
            summary: try summary(object),
            body: object["body"] as? String ?? "",
            url: (object["url"] as? String).flatMap(URL.init(string:)),
            createdAt: date(object["createdAt"]),
            comments: comments
        )
    }

    private static func label(_ object: [String: Any]) -> GitHubLabel? {
        guard let name = object["name"] as? String else { return nil }
        let description = (object["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GitHubLabel(name: name, color: object["color"] as? String ?? "", description: description)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
