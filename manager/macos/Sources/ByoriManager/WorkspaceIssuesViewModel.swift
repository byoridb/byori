import ByoriManagerCore
import Foundation

/// The Issues inspector tab for one project (#22).
///
/// Every change goes through gh and is shown only after the issue has been read
/// back: GitHub is the record, and a view updated ahead of it would show a
/// close or a label that a failed command never made.
@MainActor
final class WorkspaceIssuesViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var repository: String?
    @Published private(set) var listPhase: Phase = .idle
    @Published private(set) var issues: [GitHubIssueSummary] = []
    @Published var filter: GitHubIssueListFilter = .open
    @Published var search = ""

    @Published private(set) var selectedNumber: Int?
    @Published private(set) var detailPhase: Phase = .idle
    @Published private(set) var detail: GitHubIssueDetail?

    /// A write is in flight; every write control is disabled until it settles.
    @Published private(set) var isWorking = false
    @Published var actionError: String?
    @Published var commentDraft = ""

    @Published var isPresentingNewIssue = false
    @Published var newIssueTitle = ""
    @Published var newIssueBody = ""
    @Published private(set) var newIssueError: String?

    @Published private(set) var availableLabels: [GitHubLabel] = []
    @Published private(set) var assignableUsers: [String] = []

    private let makeProvider: () async throws -> any GitHubIssueProviding
    private var provider: (any GitHubIssueProviding)?
    private var listToken = UUID()
    private var detailToken = UUID()
    private var editOptionsLoaded = false

    init(makeProvider: @escaping () async throws -> any GitHubIssueProviding) {
        self.makeProvider = makeProvider
    }

    // MARK: - Reading

    func loadIfNeeded() async {
        guard listPhase == .idle else { return }
        await reloadList()
    }

    func reloadList() async {
        let token = UUID()
        listToken = token
        listPhase = .loading
        do {
            let provider = try await resolvedProvider()
            let repository = try await provider.repository()
            let issues = try await provider.issues(filter: filter, search: search)
            guard listToken == token else { return }
            self.repository = repository.nameWithOwner
            self.issues = issues
            listPhase = .ready
        } catch {
            guard listToken == token else { return }
            issues = []
            listPhase = .failed(error.localizedDescription)
        }
    }

    func setFilter(_ filter: GitHubIssueListFilter) {
        guard self.filter != filter else { return }
        self.filter = filter
        Task { await reloadList() }
    }

    func select(_ number: Int) async {
        selectedNumber = number
        detail = nil
        actionError = nil
        commentDraft = ""
        await reloadDetail()
        await loadEditOptionsIfNeeded()
    }

    func showList() {
        detailToken = UUID()
        selectedNumber = nil
        detail = nil
        detailPhase = .idle
        actionError = nil
    }

    func reloadDetail() async {
        guard let number = selectedNumber else { return }
        let token = UUID()
        detailToken = token
        detailPhase = .loading
        do {
            let detail = try await resolvedProvider().issue(number: number)
            guard detailToken == token else { return }
            self.detail = detail
            detailPhase = .ready
        } catch {
            guard detailToken == token else { return }
            detailPhase = .failed(error.localizedDescription)
        }
    }

    /// Labels and assignable users feed the edit menus. A failure leaves the
    /// menus empty rather than blocking the issue itself.
    private func loadEditOptionsIfNeeded() async {
        guard !editOptionsLoaded, let provider = try? await resolvedProvider() else { return }
        editOptionsLoaded = true
        availableLabels = (try? await provider.labels()) ?? []
        assignableUsers = (try? await provider.assignableUsers()) ?? []
    }

    // MARK: - Writing

    func close(reason: GitHubIssueCloseReason) async {
        guard let number = selectedNumber else { return }
        await change { try await $0.close(number: number, reason: reason) }
    }

    func reopen() async {
        guard let number = selectedNumber else { return }
        await change { try await $0.reopen(number: number) }
    }

    func postComment() async {
        let body = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = selectedNumber, !body.isEmpty else { return }
        if await change({ try await $0.comment(number: number, body: body) }) {
            commentDraft = ""
        }
    }

    func toggleLabel(_ name: String) async {
        guard let detail else { return }
        let has = detail.summary.labels.contains { $0.name == name }
        await change {
            try await $0.edit(
                number: detail.summary.number,
                addLabels: has ? [] : [name],
                removeLabels: has ? [name] : [],
                addAssignees: [],
                removeAssignees: []
            )
        }
    }

    func toggleAssignee(_ login: String) async {
        guard let detail else { return }
        let has = detail.summary.assignees.contains(login)
        await change {
            try await $0.edit(
                number: detail.summary.number,
                addLabels: [],
                removeLabels: [],
                addAssignees: has ? [] : [login],
                removeAssignees: has ? [login] : []
            )
        }
    }

    var canCreateIssue: Bool {
        !isWorking && !newIssueTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func prepareNewIssue() {
        newIssueTitle = ""
        newIssueBody = ""
        newIssueError = nil
        isPresentingNewIssue = true
    }

    func createIssue() async {
        guard canCreateIssue else { return }
        let title = newIssueTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = newIssueBody
        isWorking = true
        newIssueError = nil
        defer { isWorking = false }
        do {
            let number = try await resolvedProvider().createIssue(title: title, body: body)
            isPresentingNewIssue = false
            await reloadList()
            await select(number)
        } catch {
            newIssueError = error.localizedDescription
        }
    }

    /// Runs one write, then reads the issue and the list back.
    @discardableResult
    private func change(_ write: (any GitHubIssueProviding) async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await write(try await resolvedProvider())
        } catch {
            actionError = error.localizedDescription
            return false
        }
        await reloadDetail()
        await reloadList()
        return true
    }

    private func resolvedProvider() async throws -> any GitHubIssueProviding {
        if let provider { return provider }
        let made = try await makeProvider()
        provider = made
        return made
    }
}
