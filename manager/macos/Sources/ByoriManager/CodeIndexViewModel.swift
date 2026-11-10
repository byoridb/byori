import ByoriManagerCore
import Foundation

enum CodeIndexBrowseMode: String, CaseIterable, Identifiable {
    case files = "파일"
    case symbols = "심볼"
    var id: String { rawValue }
}

enum CodeIndexDetailMode: String, CaseIterable, Identifiable {
    case outgoing, incoming, impact
    var id: String { rawValue }
}

enum CodeIndexSelection: Equatable {
    case file(CodeIndexFile)
    case symbol(CodeIndexSymbol)

    var id: String {
        switch self { case let .file(file): return file.id; case let .symbol(symbol): return symbol.id }
    }
    var path: String {
        switch self { case let .file(file): return file.path; case let .symbol(symbol): return symbol.file }
    }
    var line: Int {
        switch self { case .file: return 1; case let .symbol(symbol): return symbol.startLine }
    }
    var title: String {
        switch self {
        case let .file(file): return file.path
        case let .symbol(symbol): return symbol.qualifiedName.isEmpty ? symbol.name : symbol.qualifiedName
        }
    }
    var isFile: Bool { if case .file = self { return true }; return false }
}

/// One presentation owns one checkout. Every async result also belongs to a
/// generation and snapshot, so searches and published indexes cannot mix pages.
@MainActor
final class CodeIndexViewModel: ObservableObject {
    let projectRoot: URL
    let space: String
    @Published private(set) var snapshot: CodeIndexSnapshot?
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingList = false
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var listErrorMessage: String?
    @Published private(set) var detailErrorMessage: String?
    @Published private(set) var snapshotNotice: String?
    @Published private(set) var files: [CodeIndexFile] = []
    @Published private(set) var symbols: [CodeIndexSymbol] = []
    @Published private(set) var selection: CodeIndexSelection?
    @Published private(set) var relations: [CodeIndexRelation] = []
    @Published private(set) var impacted: [CodeIndexImpact] = []
    @Published private(set) var detailSymbols: [String: CodeIndexSymbol] = [:]
    @Published private(set) var detailTruncated = false
    @Published private(set) var nextOffset: Int?
    @Published var browseMode: CodeIndexBrowseMode = .files
    @Published var searchText = ""
    @Published var language = ""
    @Published var detailMode: CodeIndexDetailMode = .outgoing
    @Published var impactDepth = 3

    private let provider: any CodeIndexProviding
    private var generation = UUID()
    private var listGeneration = UUID()
    private var detailGeneration = UUID()
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    init(provider: any CodeIndexProviding, projectRoot: URL, space: String) {
        self.provider = provider
        self.projectRoot = projectRoot
        self.space = space
    }

    func load() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        cancelRequests()
        let token = generation
        isLoading = true
        errorMessage = nil
        listErrorMessage = nil
        snapshotNotice = nil
        clearSelection()
        files = []; symbols = []; nextOffset = nil
        do {
            let response = try await query(.init(action: .status))
            guard generation == token, !Task.isCancelled else { return }
            snapshot = response.index
            hasLoaded = true
            isLoading = false
            if response.index != nil { await reloadResults() }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            snapshot = nil
            errorMessage = error.localizedDescription
            isLoading = false
            hasLoaded = true
        }
    }

    /// Called immediately when a filter changes, invalidating in-flight work
    /// before the debounce has elapsed.
    func scheduleSearch() {
        searchTask?.cancel()
        listGeneration = UUID()
        clearSelection()
        files = []; symbols = []; nextOffset = nil
        isLoadingList = snapshot != nil
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await reloadResults()
        }
    }

    func reloadResults() async {
        listGeneration = UUID()
        clearSelection()
        files = []; symbols = []; nextOffset = nil
        await loadPage(offset: 0)
    }

    func loadMore() async {
        guard let nextOffset, !isLoadingList else { return }
        await loadPage(offset: nextOffset)
    }

    private func loadPage(offset: Int) async {
        guard snapshot != nil else { isLoadingList = false; return }
        let token = listGeneration
        let epoch = generation
        let mode = browseMode
        isLoadingList = true
        listErrorMessage = nil
        let request = CodeIndexRequest(
            action: mode == .files ? .files : .symbols,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language.isEmpty ? nil : language,
            limit: 50,
            offset: offset
        )
        do {
            let response = try await query(request)
            guard generation == epoch, listGeneration == token, !Task.isCancelled else { return }
            if !sameSnapshot(response.index, snapshot) {
                snapshot = response.index
                clearSelection()
                files = []; symbols = []; nextOffset = nil
                snapshotNotice = "새 분석 결과가 저장되어 목록을 다시 불러왔습니다."
                if offset != 0 {
                    isLoadingList = false
                    await reloadResults()
                    return
                }
            }
            if mode == .files {
                let existing = Set(files.map(\.id))
                files += response.files.filter { !existing.contains($0.id) }
            } else {
                let existing = Set(symbols.map(\.id))
                symbols += response.symbols.filter { !existing.contains($0.id) }
            }
            nextOffset = response.nextOffset
            isLoadingList = false
        } catch {
            guard generation == epoch, listGeneration == token, !Task.isCancelled else { return }
            listErrorMessage = error.localizedDescription
            isLoadingList = false
        }
    }

    func selectFile(_ file: CodeIndexFile) {
        selection = .file(file)
        detailMode = .outgoing
        scheduleDetail()
    }

    func selectSymbol(_ symbol: CodeIndexSymbol) {
        selection = .symbol(symbol)
        detailMode = .outgoing
        scheduleDetail()
    }

    func scheduleDetail() {
        detailTask?.cancel()
        detailGeneration = UUID()
        relations = []; impacted = []; detailSymbols = [:]
        detailTruncated = false
        detailErrorMessage = nil
        isLoadingDetail = selection != nil
        detailTask = Task { [weak self] in await self?.reloadDetail() }
    }

    func reloadDetail() async {
        guard let selection, let expectedSnapshot = snapshot else { return }
        let epoch = generation
        let token = UUID()
        detailGeneration = token
        let mode = detailMode
        isLoadingDetail = true
        detailErrorMessage = nil
        let request = CodeIndexRequest(
            action: mode == .impact ? .impact : .relations,
            symbolID: selection.id,
            direction: mode == .incoming ? "incoming" : "outgoing",
            kind: selection.isFile ? "imports" : "calls",
            depth: impactDepth,
            limit: 100
        )
        do {
            let response = try await query(request)
            guard generation == epoch, detailGeneration == token, !Task.isCancelled else { return }
            guard sameSnapshot(response.index, expectedSnapshot) else {
                // The reload must not cancel the task that is performing it.
                detailTask = nil
                await reload()
                snapshotNotice = "분석 결과가 갱신되었습니다. 목록에서 항목을 다시 선택해 주세요."
                return
            }
            relations = response.relations
            impacted = response.impacted
            detailSymbols = Dictionary(response.symbols.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            detailTruncated = response.truncated
            isLoadingDetail = false
        } catch {
            guard generation == epoch, detailGeneration == token, !Task.isCancelled else { return }
            detailErrorMessage = error.localizedDescription
            isLoadingDetail = false
        }
    }

    func navigate(to key: String) {
        if let symbol = detailSymbols[key] { selectSymbol(symbol) }
        else if key.hasPrefix("file:") {
            selectFile(CodeIndexFile(id: key, path: String(key.dropFirst(5))))
        }
    }

    func displayName(for key: String) -> String {
        if let symbol = detailSymbols[key] {
            return symbol.qualifiedName.isEmpty ? symbol.name : symbol.qualifiedName
        }
        if key.hasPrefix("file:") { return String(key.dropFirst(5)) }
        return key
    }

    func location(for key: String) -> (path: String, line: Int)? {
        if let symbol = detailSymbols[key] { return (symbol.file, symbol.startLine) }
        if key.hasPrefix("file:") { return (String(key.dropFirst(5)), 1) }
        if let relation = relations.first(where: { $0.source == key }) { return (relation.file, relation.line) }
        return nil
    }

    func cancel() {
        cancelRequests()
        hasLoaded = false
        isLoading = false
        isLoadingList = false
        isLoadingDetail = false
    }

    private func clearSelection() {
        detailTask?.cancel()
        detailGeneration = UUID()
        selection = nil
        relations = []; impacted = []; detailSymbols = [:]
        detailErrorMessage = nil
        detailTruncated = false
        isLoadingDetail = false
    }

    private func cancelRequests() {
        generation = UUID()
        listGeneration = UUID()
        detailGeneration = UUID()
        searchTask?.cancel()
        detailTask?.cancel()
    }

    private func query(_ request: CodeIndexRequest) async throws -> CodeIndexResponse {
        try await provider.queryCodeIndex(request, projectRoot: projectRoot, space: space)
    }

    private func sameSnapshot(_ lhs: CodeIndexSnapshot?, _ rhs: CodeIndexSnapshot?) -> Bool {
        lhs?.checkoutID == rhs?.checkoutID && lhs?.snapshotID == rhs?.snapshotID
    }
}
