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

    var body: some View {
        VStack(spacing: 0) {
            projectSearch
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 12)

            HStack(spacing: 8) {
                Text("프로젝트")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                if isSearching {
                    Text("\(model.filteredProjects.count) / \(model.projects.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("전체 \(model.projects.count)개 중 \(model.filteredProjects.count)개 프로젝트")
                }
                Spacer()
                if model.isRegisteringProject {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Adding project")
                }
                Menu {
                    Button(action: createProject) {
                        Label("Create New Project…", systemImage: "folder.badge.plus")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    Button(action: openProject) {
                        Label("Open Folder…", systemImage: "folder")
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Add Project")
                .disabled(model.isRegisteringProject || model.isCreatingProject)
                .help("Create or open a project")
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
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .frame(height: 34)
                .accessibilityHint("Opens agent, ByoriDB, and diagnostic settings")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .background(WorkspacePalette.sidebarBackground)
    }

    private var isSearching: Bool {
        !model.projectSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var projectSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("프로젝트 이름 검색", text: $model.projectSearchQuery)
                .textFieldStyle(.plain)
                .accessibilityLabel("프로젝트 이름 검색")
                .accessibilityHint("프로젝트 이름으로 목록을 좁힙니다. 열려 있는 세션은 유지됩니다")
            if !model.projectSearchQuery.isEmpty {
                Button { model.projectSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("검색 지우기")
                .accessibilityLabel("프로젝트 검색 지우기")
            }
        }
        .font(.body)
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
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
                Text("Loading projects…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text("Projects unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready where model.projects.isEmpty:
            VStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No projects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready where model.filteredProjects.isEmpty:
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                Text("일치하는 프로젝트가 없습니다").font(.callout)
                Button("검색 지우기") { model.projectSearchQuery = "" }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            List(selection: selectionBinding) {
                ForEach(sidebarNodes) { node in
                    WorkspaceSidebarBranch(
                        node: node,
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
                        requestRemoval: requestRemoval,
                        restoreSourceTree: restoreSourceTree,
                        isMutatingWorkspace: model.isMutatingWorkspace,
                        selection: model.selection,
                        manualExpansions: $manualExpansions
                    )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Projects, tasks, and sessions")
        }
    }

    private var selectionBinding: Binding<WorkspaceSelection?> {
        Binding(get: { model.selection }, set: { selection in
            // Filtering rows must not detach the session currently being read.
            if selection != nil || model.projectSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.select(selection)
            }
        })
    }

    /// Projects group tasks and sessions; a task's checkout is supporting
    /// information rather than another level to navigate.
    private var sidebarNodes: [WorkspaceSidebarNode] {
        model.filteredProjects.map { project in
            let taskNodes = project.sourceTrees.flatMap { sourceTree -> [WorkspaceSidebarNode] in
                let activeSessionReason = sourceTree.hasActiveWritingSession
                    ? "A writing session is already active in this checkout."
                    : nil
                // Branches describe where the task runs, including the primary
                // checkout; they do not add another navigation level.
                let locationLabel = sourceTree.branch
                return sourceTree.tasks.map { task in
                    let taskDisabledReason = activeSessionReason ?? (!task.status.allowsNewSession
                        ? "This \(task.status.label.lowercased()) task cannot start another session."
                        : nil)
                    // An ended session has nothing left to show: the PTY is gone
                    // and no transcript is kept, so its row would only ever open
                    // an "ended" placeholder. Keep the selected one so the pane
                    // the user is reading does not vanish under them.
                    let visibleSessions = task.sessions.filter {
                        $0.state.isActive || model.selection == .session($0.id)
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
                addSourceTreeProjectID: project.id
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
        addSourceTreeProjectID: String? = nil
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
    }
}

private struct WorkspaceSidebarBranch: View {
    let node: WorkspaceSidebarNode
    let newSession: (WorkspaceNewSessionTarget) -> Void
    let newTerminal: (WorkspaceNewSessionTarget) -> Void
    let buildMemory: (String) -> Void
    let showCodeIndex: (String) -> Void
    let addSourceTree: (String) -> Void
    let requestRemoval: (WorkspaceRemovalRequest) -> Void
    let restoreSourceTree: (WorkspaceHiddenSourceTreeItem) -> Void
    let isMutatingWorkspace: Bool
    let selection: WorkspaceSelection?

    /// Preserve explicit expansion until a new selection needs to reveal its
    /// path. Unrelated projects stay collapsed by default.
    @Binding var manualExpansions: [String: Bool]

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(children) { child in
                    WorkspaceSidebarBranch(
                        node: child,
                        newSession: newSession,
                        newTerminal: newTerminal,
                        buildMemory: buildMemory,
                        showCodeIndex: showCodeIndex,
                        addSourceTree: addSourceTree,
                        requestRemoval: requestRemoval,
                        restoreSourceTree: restoreSourceTree,
                        isMutatingWorkspace: isMutatingWorkspace,
                        selection: selection,
                        manualExpansions: $manualExpansions
                    )
                }
            } label: {
                taggedRow
            }
            .onChange(of: selection) { newSelection in
                if node.contains(newSelection) {
                    manualExpansions[node.id] = nil
                }
            }
        } else {
            taggedRow
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { manualExpansions[node.id] ?? node.contains(selection) },
            set: { manualExpansions[node.id] = $0 }
        )
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
            newSession: newSession,
            newTerminal: newTerminal,
            buildMemory: buildMemory,
            showCodeIndex: showCodeIndex,
            addSourceTree: addSourceTree,
            requestRemoval: requestRemoval,
            restoreSourceTree: restoreSourceTree,
            isMutatingWorkspace: isMutatingWorkspace,
            isSelected: node.selection != nil && node.selection == selection
        )
    }
}

private struct WorkspaceSidebarRow: View {
    let node: WorkspaceSidebarNode
    let newSession: (WorkspaceNewSessionTarget) -> Void
    let newTerminal: (WorkspaceNewSessionTarget) -> Void
    let buildMemory: (String) -> Void
    let showCodeIndex: (String) -> Void
    let addSourceTree: (String) -> Void
    let requestRemoval: (WorkspaceRemovalRequest) -> Void
    let restoreSourceTree: (WorkspaceHiddenSourceTreeItem) -> Void
    let isMutatingWorkspace: Bool
    let isSelected: Bool

    @State private var isHovered = false

    private static let actionSlotWidth: CGFloat = 48
    private static let statusSlotWidth: CGFloat = 7

    var body: some View {
        HStack(spacing: 8) {
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
        .frame(minHeight: 36)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(rowHelp)
        .onHover { isHovered = $0 }
        .contextMenu { actionMenuItems }
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
                Label("More Actions", systemImage: "ellipsis")
                    .frame(width: 22, height: 24)
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions for \(node.title)")
            .accessibilityLabel("More actions for \(node.title)")
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
            Button("Add Source Tree…") { addSourceTree(projectID) }
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
                Label("Restore Source Tree", systemImage: "arrow.uturn.backward.circle")
            }
        }

        if !node.restorableSourceTrees.isEmpty, !node.removalRequests.isEmpty {
            Divider()
        }

        ForEach(node.removalRequests) { request in
            Button(role: .destructive) {
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


    private func removalMenuTitle(for request: WorkspaceRemovalRequest) -> String {
        switch request {
        case .project: return "Remove Project from Byori…"
        case let .sourceTree(sourceTree): return "Hide \(sourceTree.kind.removalLabel) from Byori…"
        case .task: return "Remove Task from Byori…"
        case .managedWorktree: return "Delete Managed Worktree…"
        }
    }

    private func removalMenuIcon(for request: WorkspaceRemovalRequest) -> String {
        switch request {
        case .project, .sourceTree, .task: return "minus.circle"
        case .managedWorktree: return "trash"
        }
    }

    private func removalMenuHelp(for request: WorkspaceRemovalRequest) -> String {
        switch request {
        case .project, .sourceTree:
            return "Keeps files, Git branches, history, and ByoriDB context"
        case .task:
            return "Archives task and session metadata without changing Git files"
        case .managedWorktree:
            return "Deletes this clean Byori-managed worktree after confirmation"
        }
    }

    private var icon: String {
        switch node.kind {
        case .project: return "folder"
        case .sourceTree: return "arrow.triangle.branch"
        // A task is a piece of work with sessions under it; the crosshair read as
        // a target or a locator, neither of which a task is.
        case .task: return "checklist"
        case let .session(session): return session.providerSystemImage
        }
    }

    private var quickActionLabel: String {
        if case .sourceTree = node.kind { return "New Task and Session" }
        return "New Session"
    }

    private var quickActionHelp: String {
        switch node.kind {
        case let .sourceTree(sourceTree):
            return "Create a new task and session in \(sourceTree.name)"
        case let .task(task):
            return "Start a new session for \(task.title)"
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
            details.append(session.isDetached ? "Reattach to this session" : session.state.label)
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

