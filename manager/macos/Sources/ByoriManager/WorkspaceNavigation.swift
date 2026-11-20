import AppKit
import Foundation
import SwiftUI

enum WorkspaceListFilter: String, CaseIterable, Identifiable {
    case all
    case openSessions

    var id: String { rawValue }
    var title: String { self == .all ? "전체" : "열린 세션" }
}

/// UI preferences only. A nil store is deliberately isolated for previews and
/// tests; the application supplies its own UserDefaults at composition time.
@MainActor
final class WorkspaceNavigationPreferencesStore {
    struct Preferences: Equatable {
        var pinnedProjectIDs: Set<String> = []
        var filter: WorkspaceListFilter = .all
    }

    private let defaults: UserDefaults?
    private var memory = Preferences()
    private let key = "workspace.navigation.v1"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    func load() -> Preferences {
        guard let defaults else { return memory }
        guard let values = defaults.dictionary(forKey: key) else { return Preferences() }
        let pins = (values["pinnedProjectIDs"] as? [String] ?? []).filter { !$0.isEmpty }
        return Preferences(
            pinnedProjectIDs: Set(pins.prefix(2_000)),
            filter: (values["filter"] as? String).flatMap(WorkspaceListFilter.init(rawValue:)) ?? .all
        )
    }

    func save(_ preferences: Preferences) {
        memory = preferences
        let values: [String: Any] = [
            "pinnedProjectIDs": Array(preferences.pinnedProjectIDs.sorted().prefix(2_000)),
            "filter": preferences.filter.rawValue
        ]
        defaults?.set(values, forKey: key)
    }
}

struct WorkspaceQuickSwitchResult: Identifiable, Hashable {
    let id: String
    let selection: WorkspaceSelection
    let title: String
    let subtitle: String
    let systemImage: String
    let isOpenSession: Bool
}

/// Search reads the presentation snapshot without pruning the actual model.
/// Launch validation and selection still see the original projects and tasks.
enum WorkspaceNavigation {
    static func matches(_ query: String, fields: [String]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    static func isOpen(_ session: WorkspaceSessionItem) -> Bool {
        session.state.isActive || session.isDetached
    }

    static func hasOpenSession(_ task: WorkspaceTaskItem) -> Bool {
        task.sessions.contains(where: isOpen)
    }

    static func taskMatches(
        _ task: WorkspaceTaskItem, tree: WorkspaceSourceTreeItem,
        project: WorkspaceProjectItem, query: String, filter: WorkspaceListFilter
    ) -> Bool {
        guard filter == .all || hasOpenSession(task) else { return false }
        return matches(query, fields: [project.name, tree.name, tree.branch, task.title]
            + task.sessions.flatMap { [$0.displayName, $0.providerName, $0.modelName] })
    }

    static func filteredProjects(
        _ projects: [WorkspaceProjectItem], query: String,
        filter: WorkspaceListFilter, pins: Set<String>
    ) -> [WorkspaceProjectItem] {
        let included = projects.filter { project in
            if filter == .all, matches(query, fields: [project.name]) { return true }
            return project.sourceTrees.contains { tree in
                if filter == .all, matches(query, fields: [project.name, tree.name, tree.branch]) { return true }
                return tree.tasks.contains {
                    taskMatches($0, tree: tree, project: project, query: query, filter: filter)
                }
            }
        }
        // Keep the registration order within each group. Sessions changing state
        // must not continuously rearrange the user's navigation landmarks.
        return included.filter { pins.contains($0.id) } + included.filter { !pins.contains($0.id) }
    }

    static func quickSwitchResults(
        projects: [WorkspaceProjectItem], query: String,
        openSessionsOnly: Bool, pins: Set<String>
    ) -> [WorkspaceQuickSwitchResult] {
        let ordered = projects.filter { pins.contains($0.id) } + projects.filter { !pins.contains($0.id) }
        return ordered.flatMap { project -> [WorkspaceQuickSwitchResult] in
            var results: [WorkspaceQuickSwitchResult] = []
            if !openSessionsOnly, matches(query, fields: [project.name]) {
                results.append(.init(id: "project:\(project.id)", selection: .project(project.id),
                    title: project.name, subtitle: "프로젝트", systemImage: "folder", isOpenSession: false))
            }
            for tree in project.sourceTrees {
                if !openSessionsOnly, matches(query, fields: [project.name, tree.name, tree.branch]) {
                    results.append(.init(id: "tree:\(tree.id)", selection: .sourceTree(tree.id),
                        title: tree.branch, subtitle: "\(project.name) · 작업 위치",
                        systemImage: "arrow.triangle.branch", isOpenSession: false))
                }
                for task in tree.tasks {
                    let sessions = task.sessions.filter(isOpen)
                    if sessions.isEmpty {
                        guard !openSessionsOnly,
                              taskMatches(task, tree: tree, project: project, query: query, filter: .all) else { continue }
                        results.append(.init(id: "task:\(task.id)", selection: .task(task.id), title: task.title,
                            subtitle: "\(project.name) · \(tree.branch) · 작업",
                            systemImage: "checklist", isOpenSession: false))
                    } else {
                        var matchedOpenSession = false
                        for session in sessions {
                            guard matches(query, fields: [project.name, tree.name, tree.branch, task.title,
                                session.displayName, session.providerName, session.modelName]) else { continue }
                            matchedOpenSession = true
                            results.append(.init(id: "session:\(session.id)", selection: .session(session.id),
                                title: task.title,
                                subtitle: "\(project.name) · \(tree.branch) · \(session.providerName) · \(session.displayName)",
                                systemImage: session.providerSystemImage, isOpenSession: true))
                        }
                        // An old session name can still locate its task without
                        // pretending an ended terminal is running again.
                        if !openSessionsOnly, !matchedOpenSession,
                           taskMatches(task, tree: tree, project: project, query: query, filter: .all) {
                            results.append(.init(id: "task:\(task.id)", selection: .task(task.id), title: task.title,
                                subtitle: "\(project.name) · \(tree.branch) · 작업",
                                systemImage: "checklist", isOpenSession: false))
                        }
                    }
                }
            }
            return results
        }
    }
}

struct WorkspaceQuickSwitchSheet: View {
    @ObservedObject var model: WorkspaceViewModel
    @State private var selectedID: String?

    private var allResults: [WorkspaceQuickSwitchResult] { model.quickSwitchResults }
    private var results: [WorkspaceQuickSwitchResult] { Array(allResults.prefix(200)) }
    private var resultIDs: [String] { results.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("빠른 전환").font(.title3.weight(.semibold))
                    Spacer()
                    Toggle("열린 세션만", isOn: $model.quickSwitchOnlyOpen)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
                WorkspaceQuickSwitchSearchField(
                    text: $model.quickSwitchQuery,
                    move: moveSelection,
                    submit: openSelection,
                    cancel: { model.isPresentingQuickSwitch = false }
                )
                    .frame(height: 24)
                    .accessibilityLabel("빠른 전환 검색")
            }
            .padding(20)
            Divider()
            if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                    Text(model.quickSwitchOnlyOpen ? "일치하는 열린 세션이 없습니다" : "일치하는 작업이 없습니다")
                    Text("프로젝트 이름이나 작업 제목, 브랜치로 검색해 보세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selectedID) {
                        ForEach(results) { result in
                            HStack(spacing: 10) {
                                Image(systemName: result.systemImage)
                                    .frame(width: 20).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.title).lineLimit(1)
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if result.isOpenSession {
                                    Text("열림").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .tag(result.id)
                            .id(result.id)
                            .onTapGesture(count: 2) { model.chooseQuickSwitchResult(result) }
                        }
                    }
                    .onChange(of: selectedID) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack {
                Text(allResults.count > 200 ? "결과 200개 표시 · 검색어를 더 입력하세요" : "↑↓ 이동 · Return 열기")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("취소") { model.isPresentingQuickSwitch = false }
                    .keyboardShortcut(.cancelAction)
                Button("열기", action: openSelection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!resultIDs.contains(selectedID ?? ""))
            }
            .padding(16)
        }
        .frame(width: 600, height: 460)
        .onAppear {
            selectedID = results.first?.id
        }
        .onChange(of: resultIDs) { ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first }
        }
        .onMoveCommand { direction in
            guard !results.isEmpty else { return }
            switch direction {
            case .up: moveSelection(-1)
            case .down: moveSelection(1)
            default: break
            }
        }
    }

    private func openSelection() {
        guard let result = results.first(where: { $0.id == selectedID }) else { return }
        model.chooseQuickSwitchResult(result)
    }

    private func moveSelection(_ offset: Int) {
        guard !resultIDs.isEmpty else { return }
        let current = resultIDs.firstIndex(of: selectedID ?? "") ?? 0
        selectedID = resultIDs[min(resultIDs.count - 1, max(0, current + offset))]
    }
}

/// Keep arrows navigating results while the native search field owns focus.
/// A plain TextField consumes those keys in its field editor on macOS.
private struct WorkspaceQuickSwitchSearchField: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "프로젝트, 작업, 브랜치, 세션 검색"
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityLabel("빠른 전환 검색")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if !context.coordinator.requestedFocus {
            context.coordinator.requestedFocus = true
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: WorkspaceQuickSwitchSearchField
        var requestedFocus = false
        init(_ parent: WorkspaceQuickSwitchSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Do not steal arrows/Return while a Korean (or other IME) composition
            // is selecting candidates or committing marked text.
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
