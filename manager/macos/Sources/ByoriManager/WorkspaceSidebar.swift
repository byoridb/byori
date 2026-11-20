import AppKit
import ByoriManagerCore
import SwiftUI

struct WorkspaceSidebar: View {
    @ObservedObject var model: WorkspaceViewModel
    let createProject: () -> Void
    let openProject: () -> Void
    let openSettings: () -> Void
    let requestRemoval: (WorkspaceRemovalRequest) -> Void
    let restoreSourceTree: (WorkspaceHiddenSourceTreeItem) -> Void
    @State private var manualExpansions: [String: Bool] = [:]
    @State private var filteredExpansions: [String: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            projectSearch
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Picker("프로젝트 보기", selection: $model.workspaceListFilter) {
                ForEach(WorkspaceListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Text("프로젝트")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                if model.isFilteringWorkspace {
                    Text("\(model.filteredProjects.count) / \(model.projects.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("전체 \(model.projects.count)개 중 \(model.filteredProjects.count)개 프로젝트")
                }
                Spacer()
                if model.isRegisteringProject {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("프로젝트 추가 중")
                }
                Menu {
                    Button(action: createProject) {
                        Label("새 프로젝트…", systemImage: "folder.badge.plus")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    Button(action: openProject) {
                        Label("폴더 열기…", systemImage: "folder")
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("프로젝트 추가")
                .disabled(model.isRegisteringProject || model.isCreatingProject)
                .help("프로젝트 만들기 또는 열기")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            sidebarContent

            Divider()
                .padding(.horizontal, 14)

            VStack(spacing: 2) {
                Button {
                    Task { await model.prepareSessionCleanup() }
                } label: {
                    Label("보관함 · 정리", systemImage: "archivebox")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: 34)
                .help("종료된 작업 정리 및 보관한 작업 복원")
                .accessibilityHint("종료된 작업을 확인하여 보관하거나 보관한 작업을 복원합니다")
                .disabled(model.projects.isEmpty || model.phase != .ready)

                Button(action: openSettings) {
                    Label("설정", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .frame(height: 34)
                .accessibilityHint("에이전트, ByoriDB, 진단 설정을 엽니다")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .background(WorkspacePalette.sidebarBackground)
        .onChange(of: model.projectSearchQuery) { _ in filteredExpansions = [:] }
        .onChange(of: model.workspaceListFilter) { _ in filteredExpansions = [:] }
    }

    private var isSearching: Bool {
        !model.projectSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var projectSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("프로젝트·작업·브랜치 검색", text: $model.projectSearchQuery)
                .textFieldStyle(.plain)
                .accessibilityLabel("프로젝트·작업·브랜치·세션 검색")
                .accessibilityHint("목록을 좁혀도 현재 터미널은 유지됩니다. Command-K로 빠르게 전환할 수 있습니다")
            if !model.projectSearchQuery.isEmpty {
                Button { model.projectSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("검색 지우기")
                .accessibilityLabel("검색 지우기")
            }
        }
        .font(.body)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        switch model.phase {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("프로젝트 불러오는 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text("프로젝트를 불러오지 못했습니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready where model.projects.isEmpty:
            VStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("등록된 프로젝트가 없습니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready where model.filteredProjects.isEmpty:
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                Text(isSearching ? "일치하는 작업이 없습니다" : "열린 세션이 없습니다").font(.callout)
                if isSearching {
                    Button("검색 지우기") { model.projectSearchQuery = "" }
                }
                if model.workspaceListFilter == .openSessions {
                    Button("전체 프로젝트 보기") { model.workspaceListFilter = .all }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            List(selection: selectionBinding) {
                ForEach(sidebarNodes) { node in
                    WorkspaceSidebarBranch(
                        node: node,
                        depth: 0,
                        newSession: { target in
                            Task { await model.prepareNewSession(target: target) }
                        },
                        newTerminal: { target in
                            Task { await model.startShellSession(target: target) }
                        },
                        buildMemory: { projectID in
                            Task {
                                model.select(.project(projectID))
                                await model.buildProjectMemory()
                            }
                        },
                        showCodeIndex: { model.showCodeIndex(projectID: $0) },
                        addSourceTree: { projectID in
                            Task { await model.prepareNewSourceTree(projectID: projectID) }
                        },
                        toggleProjectPin: model.toggleProjectPin,
                        requestRemoval: requestRemoval,
                        restoreSourceTree: restoreSourceTree,
                        isMutatingWorkspace: model.isMutatingWorkspace,
                        selection: model.selection,
                        automaticallyExpand: model.isFilteringWorkspace,
                        manualExpansions: outlineExpansions
                    )
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 1)
            .onMoveCommand(perform: moveInOutline)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("프로젝트, 작업, 세션")
        }
    }

    /// ← and → fold the outline the way Finder's does, since the rows no
    /// longer come from an outline view that would: → opens the selected row
    /// and then steps into it, ← closes it and then steps out to its parent.
    private func moveInOutline(_ direction: MoveCommandDirection) {
        guard let path = Self.path(to: model.selection, in: sidebarNodes), let node = path.last else { return }
        let hasChildren = !(node.children?.isEmpty ?? true)
        let isExpanded = hasChildren && (outlineExpansions.wrappedValue[node.id]
            ?? (model.isFilteringWorkspace || node.contains(model.selection)))
        switch direction {
        case .right:
            if hasChildren, !isExpanded {
                withAnimation(.easeInOut(duration: 0.15)) { outlineExpansions.wrappedValue[node.id] = true }
            } else if isExpanded, let first = node.children?.first?.selection {
                model.select(first)
            }
        case .left:
            if isExpanded {
                withAnimation(.easeInOut(duration: 0.15)) { outlineExpansions.wrappedValue[node.id] = false }
            } else if path.count > 1, let parent = path[path.count - 2].selection {
                model.select(parent)
            }
        default:
            break
        }
    }

    /// The nodes from a project down to the row showing `selection`.
    private static func path(
        to selection: WorkspaceSelection?,
        in nodes: [WorkspaceSidebarNode]
    ) -> [WorkspaceSidebarNode]? {
        guard let selection else { return nil }
        for node in nodes {
            if node.selection == selection { return [node] }
            if let rest = path(to: selection, in: node.children ?? []) { return [node] + rest }
        }
        return nil
    }

    private var selectionBinding: Binding<WorkspaceSelection?> {
        Binding(get: { model.selection }, set: { selection in
            // Filtering rows must not detach the session currently being read.
            if selection != nil || !model.isFilteringWorkspace {
                model.select(selection)
            }
        })
    }

    /// Search can reveal matching descendants without changing the user's
    /// ordinary disclosure choices. Returning to the full list restores them.
    private var outlineExpansions: Binding<[String: Bool]> {
        Binding(
            get: { model.isFilteringWorkspace ? filteredExpansions : manualExpansions },
            set: { value in
                if model.isFilteringWorkspace { filteredExpansions = value }
                else { manualExpansions = value }
            }
        )
    }

    /// Projects group tasks and sessions; a task's checkout is supporting
    /// information rather than another level to navigate.
    private var sidebarNodes: [WorkspaceSidebarNode] {
        model.filteredProjects.map { project in
            let taskNodes = project.sourceTrees.flatMap { sourceTree -> [WorkspaceSidebarNode] in
                let activeSessionReason = sourceTree.hasActiveWritingSession
                    ? "이 작업 위치에서 이미 에이전트 세션이 실행 중입니다."
                    : nil
                // Branches describe where the task runs, including the primary
                // checkout; they do not add another navigation level.
                let locationLabel = sourceTree.branch
                return sourceTree.tasks.filter {
                    model.sidebarTaskIsVisible($0, in: sourceTree, project: project)
                }.map { task in
                    let taskDisabledReason = activeSessionReason ?? (!task.status.allowsNewSession
                        ? "완료되거나 취소된 작업에서는 새 세션을 시작할 수 없습니다."
                        : nil)
                    // An ended session has nothing left to show: the PTY is gone
                    // and no transcript is kept, so its row would only ever open
                    // an "ended" placeholder. Keep the selected one so the pane
                    // the user is reading does not vanish under them.
                    let visibleSessions = task.sessions.filter {
                        WorkspaceNavigation.isOpen($0)
                            || (model.workspaceListFilter == .all && model.selection == .session($0.id))
                    }
                    // A task holds at most one open session. Nesting a single
                    // visible session under its own task row
                    // spent a level of the outline on a container that could
                    // never gain a sibling; the pair shares a line instead.
                    // Removing the last task of a worktree Byori cut leaves an
                    // empty checkout nobody asked for, so that worktree's own
                    // removal is offered on the row that produced it.
                    var removalRequests: [WorkspaceRemovalRequest] = [.task(task)]
                    if sourceTree.kind == .managedWorktree, sourceTree.tasks.count == 1 {
                        removalRequests.append(.managedWorktree(sourceTree))
                    }
                    if visibleSessions.count == 1, let session = visibleSessions.first {
                        return WorkspaceSidebarNode(
                            id: "task-session:\(task.id)",
                            selection: .session(session.id),
                            kind: .session(session),
                            title: task.title,
                            subtitle: sidebarSubtitle(
                                title: task.title,
                                details: [locationLabel, session.providerName]
                            ),
                            children: nil,
                            quickSessionTarget: WorkspaceNewSessionTarget(
                                projectID: project.id,
                                sourceTreeID: sourceTree.id,
                                existingTaskID: task.id
                            ),
                            quickSessionDisabledReason: taskDisabledReason,
                            removalRequests: removalRequests
                        )
                    }
                    let sessions = visibleSessions.map { session in
                        WorkspaceSidebarNode(
                            id: "session:\(session.id)",
                            selection: .session(session.id),
                            kind: .session(session),
                            title: session.displayName,
                            subtitle: sidebarSubtitle(
                                title: session.displayName,
                                details: [locationLabel, session.providerName]
                            ),
                            children: nil
                        )
                    }
                    return WorkspaceSidebarNode(
                        id: "task:\(task.id)",
                        selection: .task(task.id),
                        kind: .task(task),
                        title: task.title,
                        subtitle: sidebarSubtitle(title: task.title, details: [locationLabel]),
                        children: sessions.isEmpty ? nil : sessions,
                        quickSessionTarget: WorkspaceNewSessionTarget(
                            projectID: project.id,
                            sourceTreeID: sourceTree.id,
                            existingTaskID: task.id
                        ),
                        quickSessionDisabledReason: taskDisabledReason,
                        removalRequests: removalRequests
                    )
                }
            }
            return WorkspaceSidebarNode(
                id: "project:\(project.id)",
                selection: .project(project.id),
                kind: .project(project),
                title: project.name,
                subtitle: projectSubtitle(project),
                children: taskNodes.isEmpty ? nil : taskNodes,
                // Starting a session on the project row is the ordinary path now:
                // Byori resolves the checkout, so the row does not name one.
                quickSessionTarget: WorkspaceNewSessionTarget(
                    projectID: project.id,
                    sourceTreeID: "",
                    existingTaskID: nil
                ),
                removalRequests: [.project(project)],
                restorableSourceTrees: project.hiddenSourceTrees,
                addSourceTreeProjectID: project.id,
                isPinnedProject: model.pinnedProjectIDs.contains(project.id)
            )
        }
    }

    private func projectSubtitle(_ project: WorkspaceProjectItem) -> String? {
        let activeCount = project.sourceTrees.flatMap(\.tasks).flatMap(\.sessions)
            .filter { $0.state.isActive || $0.isDetached }.count
        return sidebarSubtitle(
            title: project.name,
            details: [
                project.sourceTrees.first(where: { $0.kind == .primary })?.branch,
                activeCount > 0 ? "열린 세션 \(activeCount)" : nil,
                project.registration == .trusted ? nil : project.registration.label
            ]
        )
    }

    /// Keep a row's title and supporting information distinct, including shells
    /// whose task and provider are both named "터미널".
    private func sidebarSubtitle(title: String, details: [String?]) -> String? {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        var seen = Set(title.components(separatedBy: " · ").map(normalized))
        let components = details.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

}

private struct WorkspaceSidebarNode: Identifiable {
    enum Kind {
        case project(WorkspaceProjectItem)
        case sourceTree(WorkspaceSourceTreeItem)
        case task(WorkspaceTaskItem)
        case session(WorkspaceSessionItem)
    }

    let id: String
    let selection: WorkspaceSelection?
    let kind: Kind
    let title: String
    /// Branch and agent context shown beneath the title.
    let subtitle: String?
    let children: [WorkspaceSidebarNode]?
    let quickSessionTarget: WorkspaceNewSessionTarget?
    let quickSessionDisabledReason: String?
    let removalRequests: [WorkspaceRemovalRequest]
    let restorableSourceTrees: [WorkspaceHiddenSourceTreeItem]
    /// Set on projects to offer checkout management in the overflow menu.
    let addSourceTreeProjectID: String?
    let isPinnedProject: Bool

    /// Whether the selected row is this one or somewhere beneath it. Drives which
    /// branches open on their own, so the outline shows the path being worked in
    /// rather than every path at once.
    func contains(_ selection: WorkspaceSelection?) -> Bool {
        guard let selection else { return false }
        if self.selection == selection { return true }
        // Source trees are flattened out of the visible hierarchy. Their
        // selection still belongs to the project, as does a merged task row.
        if case let .project(project) = kind {
            switch selection {
            case let .sourceTree(id):
                return project.sourceTrees.contains { $0.id == id }
            case let .task(id):
                return project.sourceTrees.contains { $0.tasks.contains { $0.id == id } }
            default: break
            }
        }
        if case let .session(session) = kind, selection == .task(session.taskID) { return true }
        return children?.contains { $0.contains(selection) } ?? false
    }

    init(
        id: String,
        selection: WorkspaceSelection?,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        children: [WorkspaceSidebarNode]?,
        quickSessionTarget: WorkspaceNewSessionTarget? = nil,
        quickSessionDisabledReason: String? = nil,
        removalRequests: [WorkspaceRemovalRequest] = [],
        restorableSourceTrees: [WorkspaceHiddenSourceTreeItem] = [],
        addSourceTreeProjectID: String? = nil,
        isPinnedProject: Bool = false
    ) {
        self.id = id
        self.selection = selection
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.children = children
        self.quickSessionTarget = quickSessionTarget
        self.quickSessionDisabledReason = quickSessionDisabledReason
        self.removalRequests = removalRequests
        self.restorableSourceTrees = restorableSourceTrees
        self.addSourceTreeProjectID = addSourceTreeProjectID
        self.isPinnedProject = isPinnedProject
    }
}

/// One node and, when expanded, its descendants as sibling rows.
///
/// The outline draws its own disclosure control instead of using
/// `DisclosureGroup`: the sidebar list puts that triangle in the gutter left
/// of the icon and only on rows that have children, so projects with and
/// without tasks started at different places and the triangle floated apart
/// from the row it opened.
private struct WorkspaceSidebarBranch: View {
    let node: WorkspaceSidebarNode
    let depth: Int
    let newSession: (WorkspaceNewSessionTarget) -> Void
    let newTerminal: (WorkspaceNewSessionTarget) -> Void
    let buildMemory: (String) -> Void
    let showCodeIndex: (String) -> Void
    let addSourceTree: (String) -> Void
    let toggleProjectPin: (String) -> Void
    let requestRemoval: (WorkspaceRemovalRequest) -> Void
    let restoreSourceTree: (WorkspaceHiddenSourceTreeItem) -> Void
    let isMutatingWorkspace: Bool
    let selection: WorkspaceSelection?
    let automaticallyExpand: Bool

    /// Preserve explicit expansion until a new selection needs to reveal its
    /// path. Unrelated projects stay collapsed by default.
    @Binding var manualExpansions: [String: Bool]

    var body: some View {
        taggedRow
            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            .onChange(of: selection) { newSelection in
                if hasChildren, node.contains(newSelection) {
                    manualExpansions[node.id] = nil
                }
            }
        if isExpanded, let children = node.children {
            ForEach(children) { child in
                WorkspaceSidebarBranch(
                    node: child,
                    depth: depth + 1,
                    newSession: newSession,
                    newTerminal: newTerminal,
                    buildMemory: buildMemory,
                    showCodeIndex: showCodeIndex,
                    addSourceTree: addSourceTree,
                    toggleProjectPin: toggleProjectPin,
                    requestRemoval: requestRemoval,
                    restoreSourceTree: restoreSourceTree,
                    isMutatingWorkspace: isMutatingWorkspace,
                    selection: selection,
                    automaticallyExpand: automaticallyExpand,
                    manualExpansions: $manualExpansions
                )
            }
        }
    }

    private var hasChildren: Bool { !(node.children?.isEmpty ?? true) }

    private var isExpanded: Bool {
        hasChildren && (manualExpansions[node.id] ?? (automaticallyExpand || node.contains(selection)))
    }

    private func toggleExpansion() {
        withAnimation(.easeInOut(duration: 0.15)) {
            manualExpansions[node.id] = !isExpanded
        }
    }

    @ViewBuilder
    private var taggedRow: some View {
        if let selection = node.selection {
            row.tag(selection)
        } else {
            row
        }
    }

    private var row: some View {
        WorkspaceSidebarRow(
            node: node,
            depth: depth,
            disclosure: hasChildren ? isExpanded : nil,
            toggleExpansion: toggleExpansion,
            newSession: newSession,
            newTerminal: newTerminal,
            buildMemory: buildMemory,
            showCodeIndex: showCodeIndex,
            addSourceTree: addSourceTree,
            toggleProjectPin: toggleProjectPin,
            requestRemoval: requestRemoval,
            restoreSourceTree: restoreSourceTree,
            isMutatingWorkspace: isMutatingWorkspace,
            isSelected: node.selection != nil && node.selection == selection
        )
    }
}

private struct WorkspaceSidebarRow: View {
    let node: WorkspaceSidebarNode
    let depth: Int
    /// Whether the row's children are shown; nil when it has none.
    let disclosure: Bool?
    let toggleExpansion: () -> Void
    let newSession: (WorkspaceNewSessionTarget) -> Void
    let newTerminal: (WorkspaceNewSessionTarget) -> Void
    let buildMemory: (String) -> Void
    let showCodeIndex: (String) -> Void
    let addSourceTree: (String) -> Void
    let toggleProjectPin: (String) -> Void
    let requestRemoval: (WorkspaceRemovalRequest) -> Void
    let restoreSourceTree: (WorkspaceHiddenSourceTreeItem) -> Void
    let isMutatingWorkspace: Bool
    let isSelected: Bool

    @State private var isHovered = false

    private static let actionSlotWidth: CGFloat = 48
    private static let statusSlotWidth: CGFloat = 7
    private static let disclosureSlotWidth: CGFloat = 12
    /// A child's chevron lines up under its parent's icon.
    private static let indentWidth: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            disclosureControl
                .padding(.leading, CGFloat(depth) * Self.indentWidth)

            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 17)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(node.title)
                    .font(rowFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)

            // Two controls have a stable slot; longer titles never push actions
            // into neighbouring rows and hover does not reflow the text.
            HStack(spacing: 4) {
                if showsActions {
                    actions
                }
            }
            .frame(width: Self.actionSlotWidth, alignment: .trailing)

            Circle()
                .fill(statusColor ?? .clear)
                .frame(width: Self.statusSlotWidth, height: Self.statusSlotWidth)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 32)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(rowHelp)
        .onHover { isHovered = $0 }
        .contextMenu { actionMenuItems }
    }

    /// Every row keeps the slot, so icons and titles of rows with and without
    /// children start at the same place.
    @ViewBuilder
    private var disclosureControl: some View {
        if let isExpanded = disclosure {
            Button(action: toggleExpansion) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Self.disclosureSlotWidth, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "접기" : "펼치기")
            .accessibilityLabel(isExpanded ? "\(node.title) 접기" : "\(node.title) 펼치기")
        } else {
            Color.clear
                .frame(width: Self.disclosureSlotWidth, height: 1)
                .accessibilityHidden(true)
        }
    }

    /// Selection makes the same actions available when navigating by keyboard.
    private var showsActions: Bool { isHovered || isSelected }

    @ViewBuilder
    private var actions: some View {
        if let quickSessionTarget = node.quickSessionTarget {
            Button {
                newSession(quickSessionTarget)
            } label: {
                Label(quickActionLabel, systemImage: "plus")
                    .frame(width: 22, height: 24)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isMutatingWorkspace || node.quickSessionDisabledReason != nil)
            .help(node.quickSessionDisabledReason ?? quickActionHelp)
            .accessibilityHint(node.quickSessionDisabledReason ?? quickActionHelp)
        }

        if hasMenuActions {
            Menu {
                actionMenuItems
            } label: {
                Label("더 보기", systemImage: "ellipsis")
                    .frame(width: 22, height: 24)
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(node.title) 작업 메뉴")
            .accessibilityLabel("\(node.title) 더 보기")
        }
    }

    private var hasMenuActions: Bool {
        node.quickSessionTarget != nil || node.addSourceTreeProjectID != nil || hasRowActions
    }

    @ViewBuilder
    private var actionMenuItems: some View {
        if node.quickSessionTarget != nil || node.addSourceTreeProjectID != nil {
            primaryActionMenuItems
            if hasRowActions { Divider() }
        }
        if hasRowActions { rowActions }
    }

    /// The revealed buttons are the fast path, not the only one: right-clicking
    /// a row reaches the same actions without hunting for the moment they appear.
    @ViewBuilder
    private var primaryActionMenuItems: some View {
        if let quickSessionTarget = node.quickSessionTarget {
            Button(quickActionLabel) { newSession(quickSessionTarget) }
                .disabled(isMutatingWorkspace || node.quickSessionDisabledReason != nil)
                .help(node.quickSessionDisabledReason ?? quickActionHelp)
            Button("터미널") { newTerminal(quickSessionTarget) }
                .disabled(isMutatingWorkspace)
                .help(terminalActionHelp)
                .accessibilityHint(terminalActionHelp)
        }
        if let projectID = node.addSourceTreeProjectID {
            Divider()
            Button {
                toggleProjectPin(projectID)
            } label: {
                Label(node.isPinnedProject ? "고정 해제" : "프로젝트 고정",
                    systemImage: node.isPinnedProject ? "pin.slash" : "pin")
            }
            Button("작업 위치 추가…") { addSourceTree(projectID) }
                .disabled(isMutatingWorkspace)
            Button("프로젝트 분석") { buildMemory(projectID) }
                .disabled(isMutatingWorkspace)
            Button("코드 인덱스 보기") { showCodeIndex(projectID) }
        }
    }

    private var hasRowActions: Bool {
        !node.removalRequests.isEmpty || !node.restorableSourceTrees.isEmpty
    }

    @ViewBuilder
    private var rowActions: some View {
        if !node.restorableSourceTrees.isEmpty {
            Menu {
                ForEach(node.restorableSourceTrees) { sourceTree in
                    Button {
                        restoreSourceTree(sourceTree)
                    } label: {
                        Label(sourceTree.name, systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(isMutatingWorkspace)
                    .help(sourceTree.url.path)
                }
            } label: {
                Label("숨긴 작업 위치 복원", systemImage: "arrow.uturn.backward.circle")
            }
        }

        if !node.restorableSourceTrees.isEmpty, !node.removalRequests.isEmpty {
            Divider()
        }

        ForEach(node.removalRequests) { request in
            Button(role: removalRole(for: request)) {
                requestRemoval(request)
            } label: {
                Label(
                    removalMenuTitle(for: request),
                    systemImage: removalMenuIcon(for: request)
                )
            }
            .disabled(isMutatingWorkspace || request.disabledReason != nil)
            .help(request.disabledReason ?? removalMenuHelp(for: request))
        }
    }

    private func removalRole(for request: WorkspaceRemovalRequest) -> ButtonRole? {
        if case .managedWorktree = request { return .destructive }
        return nil
    }


    private func removalMenuTitle(for request: WorkspaceRemovalRequest) -> String {
        switch request {
        case .project: return "프로젝트 보관…"
        case .sourceTree: return "작업 위치 숨기기…"
        case .task: return "작업 보관…"
        case .managedWorktree: return "관리 워크트리 삭제…"
        }
    }

    private func removalMenuIcon(for request: WorkspaceRemovalRequest) -> String {
        switch request {
        case .project, .task: return "archivebox"
        case .sourceTree: return "eye.slash"
        case .managedWorktree: return "trash"
        }
    }

    private func removalMenuHelp(for request: WorkspaceRemovalRequest) -> String {
        switch request {
        case .project, .sourceTree:
            return "파일, Git 브랜치와 이력, 프로젝트 기억은 유지합니다"
        case .task:
            return "파일은 변경하지 않고 작업과 세션 기록을 보관합니다"
        case .managedWorktree:
            return "확인 후 변경 사항이 없는 Byori 관리 워크트리를 삭제합니다"
        }
    }

    private var icon: String {
        switch node.kind {
        case .project: return node.isPinnedProject ? "pin.fill" : "folder"
        case .sourceTree: return "arrow.triangle.branch"
        // A task is a piece of work with sessions under it; the crosshair read as
        // a target or a locator, neither of which a task is.
        case .task: return "checklist"
        case let .session(session): return session.providerSystemImage
        }
    }

    private var quickActionLabel: String {
        if case .sourceTree = node.kind { return "새 작업과 세션" }
        return "새 세션"
    }

    private var quickActionHelp: String {
        switch node.kind {
        case let .sourceTree(sourceTree):
            return "\(sourceTree.name)에서 새 작업과 세션을 만듭니다"
        case let .task(task):
            return "\(task.title)에서 새 세션을 시작합니다"
        default:
            return quickActionLabel
        }
    }

    private var terminalActionHelp: String {
        switch node.kind {
        case let .task(task):
            return "\(task.title)의 체크아웃에서 셸을 엽니다"
        case let .session(session):
            return "\(session.displayName)와 같은 체크아웃에서 셸을 엽니다"
        default:
            return "이 프로젝트의 체크아웃에서 셸을 엽니다"
        }
    }

    private var rowFont: Font {
        if case .project = node.kind { return .body.weight(.semibold) }
        return .body
    }

    private var rowHelp: String {
        var details = [node.title, node.subtitle].compactMap { $0 }
        if case let .session(session) = node.kind {
            if !details.contains(session.launchSelectionDisplayName) {
                details.append(session.launchSelectionDisplayName)
            }
            details.append(session.isDetached ? "세션 다시 연결" : session.state.label)
        }
        return details.joined(separator: "\n")
    }

    private var statusColor: Color? {
        switch node.kind {
        case let .sourceTree(sourceTree):
            return WorkspacePalette.workingTreeColor(sourceTree.workingState)
        case let .session(session):
            return WorkspacePalette.statusColor(session.state)
        default:
            return nil
        }
    }

    private var accessibilityLabel: String {
        switch node.kind {
        case let .project(project):
            return ["Project \(project.name)", node.subtitle, project.registration.label]
                .compactMap { $0 }.joined(separator: ", ")
        case let .sourceTree(sourceTree):
            return "\(sourceTree.kind.label) \(sourceTree.name), branch \(sourceTree.branch), \(sourceTree.workingState.accessibilityLabel)"
        case let .task(task):
            return ["Task \(task.title)", node.subtitle].compactMap { $0 }.joined(separator: ", ")
        case let .session(session):
            if let subtitle = node.subtitle {
                return "\(node.title), \(subtitle), \(session.launchSelectionDisplayName), \(session.state.label)"
            }
            if session.hasCustomName {
                return "Session \(session.displayName), launched with \(session.launchSelectionDisplayName), \(session.state.label)"
            }
            return "Session \(session.displayName), \(session.state.label)"
        }
    }
}

