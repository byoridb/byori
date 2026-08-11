import AppKit
import ByoriManagerCore
import SwiftUI

private enum WorkspaceRemovalRequest: Identifiable {
    case project(WorkspaceProjectItem)
    case sourceTree(WorkspaceSourceTreeItem)

    var id: String {
        switch self {
        case let .project(project): return "project:\(project.id)"
        case let .sourceTree(sourceTree): return "source-tree:\(sourceTree.id)"
        }
    }

    var title: String {
        switch self {
        case .project: return "Remove Project from Byori?"
        case .sourceTree: return "Remove Source Tree from Byori?"
        }
    }

    var actionTitle: String {
        switch self {
        case .project: return "Remove Project"
        case .sourceTree: return "Remove from Byori"
        }
    }

    var disabledReason: String? {
        switch self {
        case let .project(project) where project.hasActiveWritingSession:
            return "Stop the project's active writing session first."
        case let .sourceTree(sourceTree) where sourceTree.hasActiveWritingSession:
            return "Stop this source tree's active writing session first."
        default:
            return nil
        }
    }

    var message: String {
        switch self {
        case let .project(project):
            let workState = project.sourceTrees.contains { sourceTree in
                if case .modified = sourceTree.workingState { return true }
                return false
            } ? " One or more source trees have uncommitted changes; they will be left untouched." : ""
            return "\(project.name) will disappear from this app. Its repository folder, branches, source trees, task/session history, and ByoriDB context will be kept. Re-adding the same folder restores the project identity.\(workState)"
        case let .sourceTree(sourceTree):
            let workState: String
            switch sourceTree.workingState {
            case .clean:
                workState = ""
            case let .modified(changeCount):
                workState = " Its \(changeCount) uncommitted changes will be left untouched."
            case .unavailable:
                workState = " Its folder is currently unavailable; only Byori's visibility record will change."
            }
            return "\(sourceTree.name) will be hidden from this project. Its folder, Git worktree and branch, task/session history, and ByoriDB context will be kept. Restore it later from the project menu.\(workState)"
        }
    }
}

/// Source-tree-first workspace presentation. The terminal content is supplied
/// by the app's real PTY/session broker; this view never renders simulated output.
struct WorkspaceView<TerminalHost: View>: View {
    @ObservedObject private var model: WorkspaceViewModel
    @State private var removalRequest: WorkspaceRemovalRequest?
    private let openSettings: () -> Void
    private let terminalHost: (WorkspaceSessionItem) -> TerminalHost

    init(
        model: WorkspaceViewModel,
        openSettings: @escaping () -> Void,
        @ViewBuilder terminalHost: @escaping (WorkspaceSessionItem) -> TerminalHost
    ) {
        self.model = model
        self.openSettings = openSettings
        self.terminalHost = terminalHost
    }

    var body: some View {
        HSplitView {
            WorkspaceSidebar(
                model: model,
                addProject: chooseProject,
                openSettings: openSettings,
                requestRemoval: { removalRequest = $0 },
                restoreSourceTree: { sourceTree in
                    Task { await model.restoreSourceTree(sourceTree) }
                }
            )
            .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)

            workspaceCenter
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

            WorkspaceInspector(model: model)
                .frame(minWidth: 286, idealWidth: 320, maxWidth: 380)
        }
        .frame(minWidth: 1_000)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.prepareNewSession() }
                } label: {
                    Label("New Session", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.projects.isEmpty || model.phase != .ready)
                .accessibilityHint("Creates one session with a recorded launch provider and model")

                Button {
                    Task { await model.load(force: true) }
                } label: {
                    Label("Refresh Workspace", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isRefreshing || model.phase == .loading)
            }
        }
        .task { await model.load() }
        .sheet(isPresented: newSessionPresentation) {
            NewWorkspaceSessionSheet(model: model)
        }
        .sheet(isPresented: newSourceTreePresentation) {
            NewWorkspaceSourceTreeSheet(model: model)
        }
        .sheet(isPresented: historyPresentation) {
            WorkspaceHistorySheet(model: model)
        }
        .sheet(isPresented: fileEditorPresentation) {
            WorkspaceFileEditorSheet(model: model)
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) { model.dismissAlert() }
            )
        }
        .confirmationDialog(
            removalRequest?.title ?? "Remove from Byori?",
            isPresented: removalPresentation,
            titleVisibility: .visible
        ) {
            if let request = removalRequest {
                Button(request.actionTitle, role: .destructive) {
                    performRemoval(request)
                }
                .disabled(request.disabledReason != nil || model.isMutatingWorkspace)
            }
            Button("Cancel", role: .cancel) { removalRequest = nil }
        } message: {
            if let request = removalRequest {
                Text(request.disabledReason ?? request.message)
            }
        }
    }

    @ViewBuilder
    private var workspaceCenter: some View {
        switch model.phase {
        case .idle, .loading:
            WorkspaceUnavailableView(
                icon: "folder.badge.gearshape",
                title: "Loading workspace",
                detail: "Reading registered projects, source trees, tasks, and sessions.",
                showsProgress: true
            )
        case let .failed(message):
            WorkspaceUnavailableView(
                icon: "exclamationmark.triangle",
                title: "Workspace unavailable",
                detail: message,
                primaryTitle: "Try Again",
                primaryAction: { Task { await model.load(force: true) } },
                secondaryTitle: "Settings",
                secondaryAction: openSettings
            )
        case .ready:
            readyCenter
        }
    }

    @ViewBuilder
    private var readyCenter: some View {
        if model.projects.isEmpty {
            WorkspaceUnavailableView(
                icon: "folder.badge.plus",
                title: "Add a Git project",
                detail: "Byori only opens sessions in projects you explicitly register and trust.",
                primaryTitle: "Add Git Project…",
                primaryAction: chooseProject,
                secondaryTitle: "Settings",
                secondaryAction: openSettings
            )
        } else if let session = model.selectedSession,
                  let lineage = model.selectedLineage,
                  let sourceTree = lineage.sourceTree,
                  let task = lineage.task {
            WorkspaceTerminalPane(
                project: lineage.project,
                sourceTree: sourceTree,
                task: task,
                session: session,
                isStopping: model.stoppingSessionIDs.contains(session.id),
                isReattaching: model.reattachingSessionIDs.contains(session.id),
                stop: { Task { await model.stopSession(session) } },
                reattach: { Task { await model.reattachSession(session) } },
                newSession: { Task { await model.prepareNewSession(after: session) } },
                terminalHost: terminalHost
            )
        } else if let project = model.selectedProject,
                  project.registration == .missing {
            WorkspaceUnavailableView(
                icon: "folder.badge.questionmark",
                title: "Project folder is missing",
                detail: "Byori cannot find \(project.repositoryURL.path). Locate or re-register the project before opening a session.",
                primaryTitle: "Add Git Project…",
                primaryAction: chooseProject,
                secondaryTitle: "Settings",
                secondaryAction: openSettings
            )
        } else if let sourceTree = model.selectedSourceTree {
            WorkspaceUnavailableView(
                icon: "terminal",
                title: model.selectedTask == nil ? "No task selected" : "No session selected",
                detail: sessionEmptyDetail(for: sourceTree),
                primaryTitle: "New Session",
                primaryAction: { Task { await model.prepareNewSession() } }
            )
        } else if let project = model.selectedProject, project.sourceTrees.isEmpty {
            WorkspaceUnavailableView(
                icon: "arrow.triangle.branch",
                title: "No source tree available",
                detail: "The runtime adapter did not return a primary checkout or worktree for this project.",
                secondaryTitle: "Refresh",
                secondaryAction: { Task { await model.load(force: true) } }
            )
        } else {
            WorkspaceUnavailableView(
                icon: "sidebar.left",
                title: "Choose a source tree",
                detail: "Select a source tree, task, or session from the project outline."
            )
        }
    }

    private var newSourceTreePresentation: Binding<Bool> {
        Binding(
            get: { model.isPresentingNewSourceTree },
            set: { if !$0 { model.dismissNewSourceTree() } }
        )
    }

    private var newSessionPresentation: Binding<Bool> {
        Binding(
            get: { model.isPresentingNewSession },
            set: { isPresented in
                if !isPresented { model.dismissNewSession() }
            }
        )
    }

    private var historyPresentation: Binding<Bool> {
        Binding(
            get: { model.history != nil },
            set: { if !$0 { model.dismissHistory() } }
        )
    }

    private var fileEditorPresentation: Binding<Bool> {
        Binding(
            get: { model.fileEditor != nil },
            set: { isPresented in
                if !isPresented { model.closeFileEditor() }
            }
        )
    }

    private var removalPresentation: Binding<Bool> {
        Binding(
            get: { removalRequest != nil },
            set: { isPresented in
                if !isPresented { removalRequest = nil }
            }
        )
    }

    private func performRemoval(_ request: WorkspaceRemovalRequest) {
        removalRequest = nil
        Task {
            switch request {
            case let .project(project):
                await model.removeProject(project)
            case let .sourceTree(sourceTree):
                await model.hideSourceTree(sourceTree)
            }
        }
    }

    private func sessionEmptyDetail(for sourceTree: WorkspaceSourceTreeItem) -> String {
        switch sourceTree.workingState {
        case .clean:
            return "Start one interactive coding session in \(sourceTree.name)."
        case let .modified(changeCount):
            return "This source tree has \(changeCount) uncommitted changes. Review them before starting a writing session."
        case let .unavailable(reason):
            return reason
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Add Git Project"
        panel.message = "Choose a local Git repository you trust Byori to use."
        panel.prompt = "Add Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.registerProject(at: url) }
        }
    }
}

// MARK: - Project outline

private struct WorkspaceSidebar: View {
    @ObservedObject var model: WorkspaceViewModel
    let addProject: () -> Void
    let openSettings: () -> Void
    let requestRemoval: (WorkspaceRemovalRequest) -> Void
    let restoreSourceTree: (WorkspaceHiddenSourceTreeItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Projects")
                    .font(.headline)
                Spacer()
                if model.isRegisteringProject {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Adding project")
                }
                Button(action: addProject) {
                    Label("Add Git Project", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.isRegisteringProject)
                .help("Add Git Project…")
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Divider()

            sidebarContent

            Divider()

            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .accessibilityHint("Opens agent, ByoriDB, and diagnostic settings")
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
        case .ready:
            List(selection: selectionBinding) {
                ForEach(sidebarNodes) { node in
                    WorkspaceSidebarBranch(
                        node: node,
                        newSession: { target in
                            Task { await model.prepareNewSession(target: target) }
                        },
                        addSourceTree: { projectID in
                            Task { await model.prepareNewSourceTree(projectID: projectID) }
                        },
                        requestRemoval: requestRemoval,
                        restoreSourceTree: restoreSourceTree,
                        isMutatingWorkspace: model.isMutatingWorkspace,
                    )
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Project, source tree, task, and session outline")
        }
    }

    private var selectionBinding: Binding<WorkspaceSelection?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    private var sidebarNodes: [WorkspaceSidebarNode] {
        model.projects.map { project in
            let sourceTrees = project.sourceTrees.map { sourceTree in
                let activeSessionReason = sourceTree.hasActiveWritingSession
                    ? "A writing session is already active in this source tree."
                    : nil
                let tasks = sourceTree.tasks.map { task in
                    let taskDisabledReason = activeSessionReason ?? (!task.status.allowsNewSession
                        ? "This \(task.status.label.lowercased()) task cannot start another session."
                        : nil)
                    // An ended session has nothing left to show: the PTY is gone
                    // and no transcript is kept, so its row would only ever open
                    // an "ended" placeholder. Keep the selected one so the pane
                    // the user is reading does not vanish under them.
                    let sessions = task.sessions.filter {
                        $0.state.isActive || model.selection == .session($0.id)
                    }.map { session in
                        WorkspaceSidebarNode(
                            id: "session:\(session.id)",
                            selection: .session(session.id),
                            kind: .session(session),
                            title: session.displayName,
                            children: nil
                        )
                    }
                    return WorkspaceSidebarNode(
                        id: "task:\(task.id)",
                        selection: .task(task.id),
                        kind: .task(task),
                        title: task.title,
                        children: sessions.isEmpty ? nil : sessions,
                        quickSessionTarget: WorkspaceNewSessionTarget(
                            projectID: project.id,
                            sourceTreeID: sourceTree.id,
                            existingTaskID: task.id
                        ),
                        quickSessionDisabledReason: taskDisabledReason
                    )
                }
                return WorkspaceSidebarNode(
                    id: "source-tree:\(sourceTree.id)",
                    selection: .sourceTree(sourceTree.id),
                    kind: .sourceTree(sourceTree),
                    title: sourceTree.name,
                    children: tasks.isEmpty ? nil : tasks,
                    quickSessionTarget: WorkspaceNewSessionTarget(
                        projectID: project.id,
                        sourceTreeID: sourceTree.id,
                        existingTaskID: nil
                    ),
                    quickSessionDisabledReason: activeSessionReason,
                    removalRequest: sourceTree.kind == .primary
                        ? .project(project)
                        : .sourceTree(sourceTree)
                )
            }
            return WorkspaceSidebarNode(
                id: "project:\(project.id)",
                selection: .project(project.id),
                kind: .project(project),
                title: project.name,
                // Source trees hang directly off the project. The old "Source
                // Trees" group added a level that named a category rather than
                // a thing, and gave every project a disclosure arrow even when
                // it had nothing to disclose.
                children: sourceTrees.isEmpty ? nil : sourceTrees,
                removalRequest: .project(project),
                restorableSourceTrees: project.hiddenSourceTrees,
                addSourceTreeProjectID: project.id
            )
        }
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
    let children: [WorkspaceSidebarNode]?
    let quickSessionTarget: WorkspaceNewSessionTarget?
    let quickSessionDisabledReason: String?
    let removalRequest: WorkspaceRemovalRequest?
    let restorableSourceTrees: [WorkspaceHiddenSourceTreeItem]
    /// Set on projects: the row's + opens the branch picker instead of a session.
    let addSourceTreeProjectID: String?

    init(
        id: String,
        selection: WorkspaceSelection?,
        kind: Kind,
        title: String,
        children: [WorkspaceSidebarNode]?,
        quickSessionTarget: WorkspaceNewSessionTarget? = nil,
        quickSessionDisabledReason: String? = nil,
        removalRequest: WorkspaceRemovalRequest? = nil,
        restorableSourceTrees: [WorkspaceHiddenSourceTreeItem] = [],
        addSourceTreeProjectID: String? = nil
    ) {
        self.id = id
        self.selection = selection
        self.kind = kind
        self.title = title
        self.children = children
        self.quickSessionTarget = quickSessionTarget
        self.quickSessionDisabledReason = quickSessionDisabledReason
        self.removalRequest = removalRequest
        self.restorableSourceTrees = restorableSourceTrees
        self.addSourceTreeProjectID = addSourceTreeProjectID
    }
}

private struct WorkspaceSidebarBranch: View {
    let node: WorkspaceSidebarNode
    let newSession: (WorkspaceNewSessionTarget) -> Void
    let addSourceTree: (String) -> Void
    let requestRemoval: (WorkspaceRemovalRequest) -> Void
    let restoreSourceTree: (WorkspaceHiddenSourceTreeItem) -> Void
    let isMutatingWorkspace: Bool

    @State private var isExpanded = true

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { child in
                    WorkspaceSidebarBranch(
                        node: child,
                        newSession: newSession,
                        addSourceTree: addSourceTree,
                        requestRemoval: requestRemoval,
                        restoreSourceTree: restoreSourceTree,
                        isMutatingWorkspace: isMutatingWorkspace,
                    )
                }
            } label: {
                taggedRow
            }
        } else {
            taggedRow
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
            newSession: newSession,
            addSourceTree: addSourceTree,
            requestRemoval: requestRemoval,
            restoreSourceTree: restoreSourceTree,
            isMutatingWorkspace: isMutatingWorkspace,
        )
    }
}

private struct WorkspaceSidebarRow: View {
    let node: WorkspaceSidebarNode
    let newSession: (WorkspaceNewSessionTarget) -> Void
    let addSourceTree: (String) -> Void
    let requestRemoval: (WorkspaceRemovalRequest) -> Void
    let restoreSourceTree: (WorkspaceHiddenSourceTreeItem) -> Void
    let isMutatingWorkspace: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(node.title)
                .font(rowFont)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .accessibilityLabel(accessibilityLabel)

            Spacer(minLength: 4)

            if let projectID = node.addSourceTreeProjectID {
                Button {
                    addSourceTree(projectID)
                } label: {
                    Label("Add Source Tree", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isMutatingWorkspace)
                .help("Check out a branch for this project")
                .accessibilityHint("Opens the branch picker for \(node.title)")
            }

            if let quickSessionTarget = node.quickSessionTarget {
                Button {
                    newSession(quickSessionTarget)
                } label: {
                    Label(quickActionLabel, systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(node.quickSessionDisabledReason != nil)
                .help(node.quickSessionDisabledReason ?? quickActionHelp)
                .accessibilityHint(node.quickSessionDisabledReason ?? quickActionHelp)
            }

            if hasRowActions {
                Menu {
                    rowActions
                } label: {
                    Label("More Actions", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isMutatingWorkspace)
                .help("Actions for \(node.title)")
                .accessibilityLabel("More actions for \(node.title)")
            }

            if let metadata {
                Text(metadata)
                    .font(.caption2.monospaced())
                    .foregroundStyle(metadataColor)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }

            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .contextMenu {
            if hasRowActions {
                rowActions
            }
        }
    }

    private var hasRowActions: Bool {
        node.removalRequest != nil || !node.restorableSourceTrees.isEmpty
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

        if !node.restorableSourceTrees.isEmpty, node.removalRequest != nil {
            Divider()
        }

        if let request = node.removalRequest {
            Button(role: .destructive) {
                requestRemoval(request)
            } label: {
                Label(removalMenuTitle(for: request), systemImage: "minus.circle")
            }
            .disabled(isMutatingWorkspace || request.disabledReason != nil)
            .help(request.disabledReason ?? "Keeps files, Git branches, history, and ByoriDB context")
        }
    }


    private func removalMenuTitle(for request: WorkspaceRemovalRequest) -> String {
        switch request {
        case .project: return "Remove Project from Byori…"
        case .sourceTree: return "Remove from Byori…"
        }
    }

    private var icon: String {
        switch node.kind {
        case .project: return "folder"
        case .sourceTree: return "arrow.triangle.branch"
        case .task: return "scope"
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

    private var iconColor: Color {
        return .primary
    }

    private var rowFont: Font {
        return .body
    }

    private var textColor: Color {
        return .primary
    }

    private var metadata: String? {
        switch node.kind {
        case let .project(project):
            return project.registration == .trusted ? nil : project.registration.label
        case .sourceTree, .task, .session:
            return nil
        }
    }

    private var metadataColor: Color {
        switch node.kind {
        case let .project(project) where project.registration != .trusted: return .orange
        case let .sourceTree(sourceTree):
            if case .modified = sourceTree.workingState { return .orange }
            return .secondary
        default: return .secondary
        }
    }

    private var statusColor: Color? {
        switch node.kind {
        case let .sourceTree(sourceTree):
            switch sourceTree.workingState {
            case .clean: return WorkspacePalette.running
            case .modified: return .orange
            case .unavailable: return .red
            }
        case let .session(session):
            return WorkspacePalette.statusColor(session.state)
        default:
            return nil
        }
    }

    private var accessibilityLabel: String {
        switch node.kind {
        case let .project(project):
            return "Project \(project.name), \(project.registration.label)"
        case let .sourceTree(sourceTree):
            return "\(sourceTree.kind.label) \(sourceTree.name), branch \(sourceTree.branch), \(sourceTree.workingState.accessibilityLabel)"
        case let .task(task):
            return "Task \(task.title)"
        case let .session(session):
            if session.hasCustomName {
                return "Session \(session.displayName), launched with \(session.launchSelectionDisplayName), \(session.state.label)"
            }
            return "Session \(session.displayName), \(session.state.label)"
        }
    }
}

// MARK: - Terminal pane

private struct WorkspaceTerminalPane<TerminalHost: View>: View {
    let project: WorkspaceProjectItem
    let sourceTree: WorkspaceSourceTreeItem
    let task: WorkspaceTaskItem
    let session: WorkspaceSessionItem
    let isStopping: Bool
    let isReattaching: Bool
    let stop: () -> Void
    let reattach: () -> Void
    let newSession: () -> Void
    let terminalHost: (WorkspaceSessionItem) -> TerminalHost

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                breadcrumb(project.name)
                breadcrumb(sourceTree.name)
                Text(task.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 12)
                sessionStatus
                if session.isDetached {
                    Divider().frame(height: 18)
                    Button(action: reattach) {
                        if isReattaching {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Reattaching session")
                        } else {
                            Label("다시 연결", systemImage: "arrow.uturn.backward.circle")
                        }
                    }
                    .disabled(isReattaching)
                    .help("tmux에서 실행 중인 세션에 다시 연결")
                    Button(action: stop) {
                        if isStopping {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Stopping session")
                        } else {
                            Label("Stop", systemImage: "stop.circle")
                        }
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(isStopping)
                    .help("Stop Session")
                } else if session.state.isActive {
                    Divider().frame(height: 18)
                    Button(action: stop) {
                        if isStopping {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Stopping session")
                        } else {
                            Label("Stop", systemImage: "stop.circle")
                        }
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(isStopping)
                    .help("Stop Session")
                } else {
                    Divider().frame(height: 18)
                    Button(action: newSession) {
                        Label("New Session", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help("Start another session for \(task.title)")
                    .accessibilityLabel("New session for task \(task.title)")
                    .accessibilityHint(
                        "Opens session setup for this task and keeps the ended session in history"
                    )

                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: 8) {
                Image(systemName: session.providerSystemImage)
                Text(session.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if session.hasCustomName {
                    Text(session.launchSelectionDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Byori launch selection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let detail = session.statusDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            terminalContent
        }
    }

    @ViewBuilder
    private var terminalContent: some View {
        if session.isDetached {
            // The CLI is running, but under the tmux server rather than this
            // app, so there is no terminal view to mount until it reattaches.
            detachedSessionView
        } else if session.state.isActive {
            terminalHost(session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WorkspacePalette.terminalBackground)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(terminalAccessibilityLabel)
                .accessibilityHint("Byori keeps the original launch selection; changes made inside the provider terminal are provider-controlled")
        } else {
            endedSessionView
        }
    }

    private var detachedSessionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("세션이 계속 실행 중입니다")
                .font(.title3.weight(.semibold))
            Text("Byori를 닫는 동안에도 이 CLI는 tmux에서 실행되고 있었습니다. 다시 연결하면 중단된 지점 그대로 이어집니다.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button(action: reattach) {
                if isReattaching {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("연결 중…")
                    }
                } else {
                    Label("세션에 다시 연결", systemImage: "arrow.uturn.backward.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isReattaching)
            .padding(.top, 4)
            .accessibilityLabel("Reattach to session \(session.displayName)")
            .accessibilityHint("Reopens the terminal for the CLI still running in tmux")
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspacePalette.terminalBackground)
    }

    private var endedSessionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Terminal session ended")
                .font(.title3.weight(.semibold))
            Text("The terminal process is no longer active. Its provider, model, and task history are preserved.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 8) {
                Button(action: newSession) {
                    Label("New Session", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("New session for task \(task.title)")
                .accessibilityHint(
                    "Opens session setup for this task and keeps the ended session in history"
                )

            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspacePalette.terminalBackground)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ended terminal session \(session.displayName)")
    }

    private func breadcrumb(_ text: String) -> some View {
        Group {
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var terminalAccessibilityLabel: String {
        guard session.hasCustomName else {
            return "Interactive terminal for \(session.displayName)"
        }
        return "Interactive terminal for \(session.displayName), launched with \(session.launchSelectionDisplayName)"
    }

    private var sessionStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(WorkspacePalette.statusColor(session.state))
                .frame(width: 7, height: 7)
            Text(session.state.label)
                .font(.callout.weight(.medium))
                .foregroundStyle(WorkspacePalette.statusColor(session.state))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session status: \(session.state.label)")
    }
}

// MARK: - Inspector

private struct WorkspaceInspector: View {
    @ObservedObject var model: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.inspectorTab) {
                ForEach(WorkspaceInspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .frame(height: 48)
            .accessibilityLabel("Inspector section")

            Divider()

            inspectorContent

            if model.inspectorTab != .context {
                Divider()
                Button {
                    model.inspectorTab = .context
                } label: {
                    HStack {
                        Label("ByoriDB context", systemImage: "cylinder.split.1x2")
                        Spacer()
                        if case .ready = model.contextPhase {
                            Text("\(model.contextSnapshot?.items.count ?? 0)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .accessibilityHint("Opens project knowledge for the selected work")
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if model.selectedSourceTree == nil {
            WorkspaceUnavailableView(
                icon: "sidebar.right",
                title: "No source tree",
                detail: "Select a source tree to inspect its files, Git state, and context."
            )
        } else if model.inspectorTab == .context {
            contextContent
        } else {
            switch model.inspectorPhase {
            case .idle, .loading:
                WorkspaceUnavailableView(
                    icon: inspectorIcon,
                    title: "Loading \(model.inspectorTab.rawValue.lowercased())",
                    detail: "Reading local workspace data.",
                    showsProgress: true
                )
            case let .failed(message):
                WorkspaceUnavailableView(
                    icon: "exclamationmark.triangle",
                    title: "Inspector unavailable",
                    detail: message,
                    primaryTitle: "Try Again",
                    primaryAction: { Task { await model.refreshInspector() } }
                )
            case .ready:
                if let snapshot = model.inspectorSnapshot {
                    switch model.inspectorTab {
                    case .files:
                        WorkspaceFilesInspector(files: snapshot.files) { model.openFile($0) }
                    case .git:
                        WorkspaceGitInspector(summary: snapshot.git) { model.showHistory() }
                    case .context:
                        EmptyView()
                    }
                } else {
                    WorkspaceUnavailableView(
                        icon: inspectorIcon,
                        title: "No inspector data",
                        detail: "Refresh the selected source tree to try again."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var contextContent: some View {
        switch model.contextPhase {
        case .idle, .loading:
            WorkspaceUnavailableView(
                icon: "cylinder.split.1x2",
                title: "Loading context",
                detail: "Following project-scoped ByoriDB relationships.",
                showsProgress: true
            )
        case let .failed(message):
            WorkspaceUnavailableView(
                icon: "exclamationmark.triangle",
                title: "Context unavailable",
                detail: message,
                primaryTitle: "Try Again",
                primaryAction: { Task { await model.refreshInspector() } }
            )
        case .ready:
            if let snapshot = model.contextSnapshot {
                WorkspaceContextInspector(
                    records: snapshot.items,
                    isTruncated: snapshot.isTruncated,
                    depth: model.contextDepth,
                    setDepth: model.setContextDepth
                )
            } else {
                WorkspaceUnavailableView(
                    icon: "cylinder.split.1x2",
                    title: "No context data",
                    detail: "Refresh the selected source tree to try again."
                )
            }
        }
    }

    private var inspectorIcon: String {
        switch model.inspectorTab {
        case .files: return "doc.on.doc"
        case .git: return "arrow.triangle.branch"
        case .context: return "cylinder.split.1x2"
        }
    }
}

private struct WorkspaceFilesInspector: View {
    let files: [WorkspaceFileItem]
    let open: (WorkspaceFileItem) -> Void

    var body: some View {
        if files.isEmpty {
            WorkspaceUnavailableView(
                icon: "folder",
                title: "No files returned",
                detail: "The runtime adapter did not return a file outline for this source tree."
            )
        } else {
            List {
                OutlineGroup(files, children: \.children) { item in
                    row(item)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Files in selected source tree")
        }
    }

    /// Only regular files open. Folders keep the outline's own disclosure
    /// behaviour, and symlinks are not followed here for the same reason the
    /// tree walker does not follow them.
    @ViewBuilder
    private func row(_ item: WorkspaceFileItem) -> some View {
        let label = Label(item.name, systemImage: icon(item.kind))
            .lineLimit(1)
            .accessibilityLabel("\(item.kind.rawValue.capitalized) \(item.name)")
        if item.kind == .file {
            Button { open(item) } label: {
                label.frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(item.name)")
            .accessibilityHint("Opens the file for editing")
        } else {
            label
        }
    }

    private func icon(_ kind: WorkspaceFileItemKind) -> String {
        switch kind {
        case .folder: return "folder"
        case .file: return "doc"
        case .symlink: return "link"
        }
    }
}

private struct WorkspaceGitInspector: View {
    let summary: WorkspaceGitSummaryItem
    let showHistory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Branch", value: summary.branch)
                if let revision = summary.headRevision {
                    LabeledContent("HEAD") {
                        Text(revision)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let upstream = summary.upstream {
                    LabeledContent("Upstream", value: upstream)
                }
                if summary.aheadCount > 0 || summary.behindCount > 0 {
                    Text("Ahead \(summary.aheadCount) · Behind \(summary.behindCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button(action: showHistory) {
                    Label("Show History", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .controlSize(.small)
                .accessibilityHint("Opens the commit graph for this source tree")
            }
            .padding(14)

            Divider()

            if summary.changes.isEmpty {
                WorkspaceUnavailableView(
                    icon: "checkmark.circle",
                    title: "Working tree clean",
                    detail: "No local changes were returned for this source tree."
                )
            } else {
                List(summary.changes) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(change.status.shortLabel)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(changeColor(change.status))
                            .frame(width: 15)
                        Text(change.path)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(change.status.rawValue) \(change.path)")
                }
            }
        }
    }

    private func changeColor(_ status: WorkspaceGitChangeStatusItem) -> Color {
        switch status {
        case .added: return .green
        case .modified, .renamed, .untracked: return .orange
        case .deleted, .conflicted: return .red
        }
    }
}

private struct WorkspaceContextInspector: View {
    let records: [WorkspaceContextItem]
    let isTruncated: Bool
    let depth: WorkspaceContextDepth
    let setDepth: (WorkspaceContextDepth) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Context depth", selection: depthBinding) {
                    ForEach(WorkspaceContextDepth.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Controls how far ByoriDB follows project relationships")

                Text(depth.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isTruncated {
                    Label("Only a bounded part of the project graph is shown.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)

            Divider()

            if records.isEmpty {
                WorkspaceUnavailableView(
                    icon: "circle.hexagongrid",
                    title: "No durable context",
                    detail: "No decisions, module notes, or task checkpoints were returned at this depth."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(records) { record in
                            WorkspaceContextRecordRow(record: record)
                        }
                    }
                    .padding(12)
                }
                .accessibilityLabel("ByoriDB context records")
            }
        }
    }

    private var depthBinding: Binding<WorkspaceContextDepth> {
        Binding(get: { depth }, set: { setDepth($0) })
    }
}

private struct WorkspaceContextRecordRow: View {
    let record: WorkspaceContextItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(WorkspacePalette.running)
                Text(record.kind)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let updatedAt = record.updatedAt {
                    Text(updatedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(record.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(record.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Text(record.provenance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !record.tags.isEmpty {
                Text(record.tags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.kind), \(record.title), \(record.summary), source \(record.provenance)")
    }

    private var icon: String {
        switch record.kind.lowercased() {
        case "decision": return "doc.text"
        case "module": return "shippingbox"
        case "task_checkpoint", "task checkpoint": return "bookmark"
        case "bug", "incident": return "ladybug"
        default: return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - New session

private struct NewWorkspaceSessionSheet: View {
    @ObservedObject var model: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Session")
                        .font(.title2.weight(.semibold))
                    Text("Choose the provider and model Byori will use to launch this session.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                Form {
                    Section("Session") {
                        TextField("Session Name", text: $model.newSessionDraft.sessionName)
                            .accessibilityHint("Names this session in the task history")

                        Text("A short name helps distinguish sessions that use the same agent and model. Up to \(WorkspaceSession.maximumNameScalarCount) characters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let message = model.sessionNameValidationMessage {
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Section("Location") {
                        LabeledContent("Project", value: projectName)

                        Picker("Source Tree", selection: sourceTreeBinding) {
                            ForEach(model.sourceTrees(for: model.newSessionDraft.projectID)) { sourceTree in
                                Text(sourceTree.name == sourceTree.branch
                                     ? sourceTree.name
                                     : "\(sourceTree.name) — \(sourceTree.branch)")
                                    .tag(sourceTree.id)
                            }
                        }
                        .accessibilityHint("The agent process uses this working directory")

                        Picker("Task", selection: $model.newSessionDraft.taskChoice) {
                            Text("New Task").tag(WorkspaceNewSessionTaskChoice.newTask)
                            ForEach(model.tasks(for: model.newSessionDraft.sourceTreeID)) { task in
                                Text(task.status.allowsNewSession
                                     ? task.title
                                     : "\(task.title) — \(task.status.label)")
                                    .tag(WorkspaceNewSessionTaskChoice.existing(task.id))
                                    .disabled(!task.status.allowsNewSession)
                            }
                        }

                        if case .newTask = model.newSessionDraft.taskChoice {
                            TextField("Task Title", text: $model.newSessionDraft.newTaskTitle)
                                .accessibilityHint("Names the work represented by this session")
                        }

                        if let warning = sourceTreeWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if sourceTreeIsModified {
                            Toggle(
                                "Start in this modified working tree",
                                isOn: $model.newSessionDraft.acceptsModifiedWorkingTree
                            )
                            .accessibilityHint("Confirms that existing uncommitted changes may be affected")
                        }

                        if let constraint = model.launchConstraintMessage {
                            Label(constraint, systemImage: "xmark.octagon")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Section("Agent") {
                        sessionOptions

                        if let warning = model.sessionPersistenceWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityHint("Sessions started now will end when Byori quits")
                        }
                    }

                    Section("ByoriDB Context") {
                        Picker("Depth", selection: $model.newSessionDraft.contextDepth) {
                            ForEach(WorkspaceContextDepth.allCases) { depth in
                                Text(depth.label).tag(depth)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(model.newSessionDraft.contextDepth.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("This controls the Context inspector after launch. The agent accesses project memory through its configured ByoriDB MCP and Memory Skill.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Label(
                        "After launch, type directly in the real agent terminal. Byori does not place prompt text in process arguments.",
                        systemImage: "terminal"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let error = model.newSessionError {
                        Label(error, systemImage: "xmark.octagon")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 8)
            }

            Divider()

            HStack {
                Text("Byori does not alter the launch provider or model. Provider-side terminal commands remain outside Byori's control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.dismissNewSession() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isStartingSession)
                Button {
                    Task { await model.startSession() }
                } label: {
                    if model.isStartingSession {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Starting…")
                        }
                    } else {
                        Text("Start Session")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartSession)
            }
            .padding(16)
        }
        .frame(width: 560)
        .frame(minHeight: 510, idealHeight: 580)
        .interactiveDismissDisabled(model.isStartingSession)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New coding session")
    }

    @ViewBuilder
    private var sessionOptions: some View {
        switch model.sessionOptionsPhase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading installed provider models…")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try Again") {
                    Task { await model.retrySessionOptions() }
                }
            }
        case .ready where model.sessionOptions.isEmpty:
            Label("No installed provider is available. Open Settings to connect one.", systemImage: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            Picker("Provider", selection: providerBinding) {
                Text("Choose Provider").tag(String?.none)
                ForEach(model.sessionOptions) { provider in
                    Text(providerLabel(provider)).tag(String?.some(provider.id))
                }
            }
            .accessibilityHint("This provider is used for the Byori launch request")

            Picker("Model", selection: modelBinding) {
                Text("Choose Model").tag(String?.none)
                ForEach(model.availableModels) { option in
                    Text(modelLabel(option)).tag(String?.some(option.id))
                }
            }
            .disabled(model.newSessionDraft.providerID == nil)
            .accessibilityHint("This model is used for the Byori launch request")

            if let selectedModelOption, selectedModelOption.acceptsCustomIdentifier {
                TextField(
                    selectedModelOption.customIdentifierPlaceholder ?? "Provider model identifier",
                    text: $model.newSessionDraft.customModelID
                )
                .accessibilityLabel("Custom model identifier")
                .accessibilityHint("Enter the exact model identifier accepted by the selected provider")

                Text("The concrete identifier entered here is recorded as this session's Byori launch selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField(
                "Additional CLI arguments (optional)",
                text: $model.newSessionDraft.additionalArguments
            )
            .accessibilityLabel("Additional CLI arguments")
            .accessibilityHint("Passed to the CLI as written, for example --dangerously-skip-permissions")

            Text("Appended to the CLI invocation exactly as typed, after Byori's own arguments. Quote values containing spaces; no shell expansion is performed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let availabilityMessage {
                Label(availabilityMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var projectName: String {
        model.projects.first(where: { $0.id == model.newSessionDraft.projectID })?.name ?? "Unknown Project"
    }

    private var sourceTreeBinding: Binding<String> {
        Binding(
            get: { model.newSessionDraft.sourceTreeID },
            set: { sourceTreeID in
                model.newSessionDraft.sourceTreeID = sourceTreeID
                model.newSessionDraft.taskChoice = .newTask
                model.newSessionDraft.acceptsModifiedWorkingTree = false
            }
        )
    }

    private var providerBinding: Binding<String?> {
        Binding(get: { model.newSessionDraft.providerID }, set: { model.chooseProvider($0) })
    }

    private var modelBinding: Binding<String?> {
        Binding(get: { model.newSessionDraft.modelID }, set: { model.chooseModel($0) })
    }

    private var selectedModelOption: WorkspaceModelOption? {
        guard let modelID = model.newSessionDraft.modelID else { return nil }
        return model.availableModels.first(where: { $0.id == modelID })
    }

    private var sourceTreeWarning: String? {
        guard let sourceTree = model
            .sourceTrees(for: model.newSessionDraft.projectID)
            .first(where: { $0.id == model.newSessionDraft.sourceTreeID }) else {
            return nil
        }
        switch sourceTree.workingState {
        case .clean: return nil
        case let .modified(changeCount):
            return "This working tree already has \(changeCount) uncommitted changes."
        case let .unavailable(reason):
            return reason
        }
    }

    private var sourceTreeIsModified: Bool {
        guard let sourceTree = model
            .sourceTrees(for: model.newSessionDraft.projectID)
            .first(where: { $0.id == model.newSessionDraft.sourceTreeID }) else {
            return false
        }
        if case .modified = sourceTree.workingState { return true }
        return false
    }

    private var availabilityMessage: String? {
        if let providerID = model.newSessionDraft.providerID,
           let provider = model.sessionOptions.first(where: { $0.id == providerID }),
           let reason = provider.availability.unavailableReason {
            return reason
        }
        if let modelID = model.newSessionDraft.modelID,
           let option = model.availableModels.first(where: { $0.id == modelID }),
           let reason = option.availability.unavailableReason {
            return reason
        }
        return nil
    }

    private func providerLabel(_ provider: WorkspaceProviderOption) -> String {
        if let reason = provider.availability.unavailableReason {
            return "\(provider.displayName) — \(reason)"
        }
        return provider.displayName
    }

    private func modelLabel(_ model: WorkspaceModelOption) -> String {
        if let reason = model.availability.unavailableReason {
            return "\(model.displayName) — \(reason)"
        }
        return model.detail.map { "\(model.displayName) — \($0)" } ?? model.displayName
    }
}

// MARK: - Shared state presentation

private struct WorkspaceUnavailableView: View {
    let icon: String
    let title: String
    let detail: String
    var showsProgress = false
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel(title)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .textSelection(.enabled)

            if primaryTitle != nil || secondaryTitle != nil {
                HStack(spacing: 8) {
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                    }
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum WorkspacePalette {
    static let running = Color(nsColor: .systemTeal)
    static let terminalBackground = Color(
        red: 0.055,
        green: 0.063,
        blue: 0.068
    )

    static func statusColor(_ status: WorkspaceSessionItemStatus) -> Color {
        switch status {
        case .preparing: return .blue
        case .running, .waitingForUser: return running
        case .completed: return .green
        case .failed, .timedOut: return .red
        case .cancelled: return .secondary
        }
    }
}

/// Checking out a branch used to mean leaving Byori for a terminal. This picks a
/// branch — existing or new — and Byori creates the worktree under its own
/// directory, then lets the ordinary workspace load discover it.
private struct NewWorkspaceSourceTreeSheet: View {
    @ObservedObject var model: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Source Tree")
                        .font(.title2.weight(.semibold))
                    Text("Byori checks the branch out into its own worktree, leaving your existing folders untouched.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            content
                .frame(minHeight: 210)

            Divider()

            HStack {
                if let message = model.newSourceTreeValidationMessage,
                   model.branchesPhase == .ready {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.dismissNewSourceTree() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCreatingSourceTree)
                Button {
                    Task { await model.createSourceTree() }
                } label: {
                    if model.isCreatingSourceTree {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Creating…")
                        }
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.isCreatingSourceTree
                        || model.branchesPhase != .ready
                        || model.newSourceTreeValidationMessage != nil
                )
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    @ViewBuilder
    private var content: some View {
        switch model.branchesPhase {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading branches…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 10) {
                Label("Branches unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await model.loadBranches() } }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            Form {
                Picker("", selection: $model.newSourceTreeDraft.mode) {
                    ForEach(WorkspaceNewSourceTreeDraft.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.newSourceTreeDraft.mode {
                case .existing:
                    Picker("Branch", selection: $model.newSourceTreeDraft.selectedBranch) {
                        ForEach(selectableBranches) { branch in
                            Text(branch.isRemote ? "\(branch.name) (remote)" : branch.name)
                                .tag(branch.name)
                        }
                    }
                    if selectableBranches.isEmpty {
                        Text("Every branch is already checked out. Create a new one instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .new:
                    TextField("Branch Name", text: $model.newSourceTreeDraft.newBranchName)
                    Picker("Start From", selection: $model.newSourceTreeDraft.startPoint) {
                        ForEach(model.availableBranches) { branch in
                            Text(branch.isRemote ? "\(branch.name) (remote)" : branch.name)
                                .tag(branch.name)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Git refuses a second worktree for a branch that is already checked out,
    /// so those are not offered rather than failing after the fact.
    private var selectableBranches: [WorkspaceGitBranch] {
        model.availableBranches.filter { !$0.isCheckedOut }
    }
}

/// A single-file editor for the small corrections that do not deserve a context
/// switch into another app.
///
/// It runs as a sheet rather than inside the inspector column because the
/// inspector is narrow enough that editing code in it would be worse than not
/// offering the feature at all.
private struct WorkspaceFileEditorSheet: View {
    @ObservedObject var model: WorkspaceViewModel
    @State private var pendingDiscard: DiscardIntent?

    /// Both ways of losing a draft, so the confirmation can say which one it is.
    private enum DiscardIntent: String, Identifiable {
        case close
        case reload

        var id: String { rawValue }

        var actionTitle: String { self == .close ? "Discard and Close" : "Discard and Reload" }
        var message: String {
            self == .close
                ? "The edits in this file have not been saved."
                : "Reloading replaces your unsaved edits with the file on disk."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(minHeight: 320)
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 560)
        .confirmationDialog(
            "Discard unsaved edits?",
            isPresented: discardPresentation,
            titleVisibility: .visible
        ) {
            if let intent = pendingDiscard {
                Button(intent.actionTitle, role: .destructive) {
                    pendingDiscard = nil
                    switch intent {
                    case .close: model.closeFileEditor()
                    case .reload: Task { await model.reloadOpenFile() }
                    }
                }
            }
            Button("Keep Editing", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text(pendingDiscard?.message ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.fileEditor?.name ?? "File")
                    .font(.title3.weight(.semibold))
                Text(model.fileEditor?.relativePath ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer()
            if let editor = model.fileEditor, editor.phase == .ready {
                Text(editor.isDirty ? "Unsaved" : "\(editor.byteSize) bytes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(editor.isDirty ? .orange : .secondary)
                    .accessibilityLabel(editor.isDirty ? "Unsaved changes" : "\(editor.byteSize) bytes")
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch model.fileEditor?.phase {
        case .loading, nil:
            WorkspaceUnavailableView(
                icon: "doc.text",
                title: "Opening file",
                detail: "Reading the file from the source tree.",
                showsProgress: true
            )
        case let .failed(message):
            WorkspaceUnavailableView(
                icon: "exclamationmark.triangle",
                title: "File cannot be opened",
                detail: message,
                primaryTitle: "Try Again",
                primaryAction: { Task { await model.reloadOpenFile() } }
            )
        case .ready:
            TextEditor(text: draft)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .disabled(model.fileEditor?.isSaving == true)
                .accessibilityLabel("File contents")
        }
    }

    private var footer: some View {
        HStack {
            if let notice = model.fileEditor?.notice {
                Label(notice, systemImage: noticeIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Reload") {
                if model.fileEditor?.isDirty == true {
                    pendingDiscard = .reload
                } else {
                    Task { await model.reloadOpenFile() }
                }
            }
            .disabled(model.fileEditor?.isSaving == true)
            Button("Close") { closeRequested() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.fileEditor?.isSaving == true)
            Button {
                Task { await model.saveOpenFile() }
            } label: {
                if model.fileEditor?.isSaving == true {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Text("Save")
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(model.fileEditor?.isDirty != true || model.fileEditor?.isSaving == true)
        }
        .padding(20)
    }

    /// A conflict is the one notice worth an alarming icon: the save did not
    /// happen and the user has to decide what to keep.
    private var noticeIcon: String {
        model.fileEditor?.notice == "Saved." ? "checkmark.circle" : "exclamationmark.circle"
    }

    private func closeRequested() {
        if model.fileEditor?.isDirty == true {
            pendingDiscard = .close
        } else {
            model.closeFileEditor()
        }
    }

    private var draft: Binding<String> {
        Binding(
            get: { model.fileEditor?.draft ?? "" },
            set: { model.fileEditor?.draft = $0 }
        )
    }

    private var discardPresentation: Binding<Bool> {
        Binding(
            get: { pendingDiscard != nil },
            set: { if !$0 { pendingDiscard = nil } }
        )
    }
}

// MARK: - History

/// The commit graph, with checkout.
///
/// It is a sheet rather than a panel in the inspector because the inspector is
/// under 380pt wide: lanes plus a subject plus refs do not fit there without
/// truncating the one thing people read.
private struct WorkspaceHistorySheet: View {
    @ObservedObject var model: WorkspaceViewModel

    private static let rowHeight: CGFloat = 30
    private static let laneWidth: CGFloat = 15
    private static let maxDrawnLanes = 8

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 520, idealHeight: 640)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("History")
                    .font(.title3.weight(.semibold))
                Text(model.history?.sourceTreeName ?? "")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.history?.graph.isTruncated == true {
                Text("Showing the most recent commits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch model.history?.phase {
        case .loading, nil:
            WorkspaceUnavailableView(
                icon: "clock.arrow.circlepath",
                title: "Reading history",
                detail: "Walking commits in this source tree.",
                showsProgress: true
            )
        case let .failed(message):
            WorkspaceUnavailableView(
                icon: "exclamationmark.triangle",
                title: "History unavailable",
                detail: message,
                primaryTitle: "Try Again",
                primaryAction: { Task { await model.reloadHistory() } }
            )
        case .ready:
            if let history = model.history, history.graph.rows.isEmpty {
                WorkspaceUnavailableView(
                    icon: "tray",
                    title: "No commits yet",
                    detail: "This repository has no history to show."
                )
            } else {
                graph
            }
        }
    }

    private var graph: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.history?.graph.rows ?? [], id: \.commit.sha) { row in
                    WorkspaceHistoryRow(
                        row: row,
                        laneCount: drawnLaneCount,
                        rowHeight: Self.rowHeight,
                        laneWidth: Self.laneWidth,
                        isSelected: model.history?.selectedSHA == row.commit.sha,
                        canCheckOut: model.history?.canCheckOut == true,
                        checkingOutRef: model.history?.checkingOutRef,
                        select: { model.selectCommit(row.commit.sha) },
                        checkout: { ref in Task { await model.checkout(ref) } }
                    )
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// Very wide graphs are clamped: beyond a handful of lanes the lines stop
    /// carrying information and start eating the subject column.
    private var drawnLaneCount: Int {
        min(model.history?.graph.laneCount ?? 0, Self.maxDrawnLanes)
    }

    private var footer: some View {
        HStack {
            if let notice = model.history?.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let reason = model.history?.activeSessionBlockReason {
                // Said up front, not after a click: the buttons are already
                // disabled and an unexplained disabled control is worse than no
                // control.
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Reload") { Task { await model.reloadHistory() } }
                .disabled(model.history?.checkingOutRef != nil)
            Button("Done") { model.dismissHistory() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.history?.checkingOutRef != nil)
        }
        .padding(20)
    }
}

private struct WorkspaceHistoryRow: View {
    let row: WorkspaceGitGraphRow
    let laneCount: Int
    let rowHeight: CGFloat
    let laneWidth: CGFloat
    let isSelected: Bool
    let canCheckOut: Bool
    let checkingOutRef: String?
    let select: () -> Void
    let checkout: (WorkspaceGitRef) -> Void

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceGitLaneStrip(row: row, laneCount: laneCount, laneWidth: laneWidth)
                .frame(width: CGFloat(max(laneCount, 1)) * laneWidth, height: rowHeight)

            Text(row.commit.subject)
                .lineLimit(1)
                .truncationMode(.tail)

            ForEach(row.commit.refs) { ref in
                WorkspaceGitRefBadge(ref: ref)
            }

            Spacer(minLength: 8)

            if let ref = checkoutTarget {
                Button {
                    checkout(ref)
                } label: {
                    if checkingOutRef == ref.name {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check Out")
                    }
                }
                .controlSize(.small)
                .disabled(!canCheckOut)
                .help(canCheckOut ? "Check out \(ref.name)" : "Checkout is unavailable right now")
            }

            Text(row.commit.authorName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)

            Text(relativeDate)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            Text(row.commit.shortSHA)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.commit.subject), \(row.commit.authorName), \(row.commit.shortSHA)")
    }

    /// A commit carries at most one sensible checkout target: a local branch
    /// sitting on it. Tags and remote-tracking refs would detach HEAD.
    ///
    /// The branch HEAD is already attached to gets no button, but a detached
    /// HEAD does — reattaching is exactly what someone wants there.
    private var checkoutTarget: WorkspaceGitRef? {
        guard !row.commit.refs.contains(where: { $0.kind == .head }) else { return nil }
        return row.commit.refs.first(where: \.isCheckoutable)
    }

    private var relativeDate: String {
        guard let date = row.commit.authorDate else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct WorkspaceGitRefBadge: View {
    let ref: WorkspaceGitRef

    var body: some View {
        Text(ref.name)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("\(kindLabel) \(ref.name)")
    }

    private var color: Color {
        switch ref.kind {
        case .head, .detachedHead: return .accentColor
        case .localBranch: return .green
        case .remoteBranch: return .blue
        case .tag: return .orange
        }
    }

    private var kindLabel: String {
        switch ref.kind {
        case .head: return "HEAD"
        case .detachedHead: return "Detached HEAD"
        case .localBranch: return "Branch"
        case .remoteBranch: return "Remote branch"
        case .tag: return "Tag"
        }
    }
}

/// Draws one row of the commit graph: the lines passing through it, the lines
/// leaving it toward its parents, and its own node.
private struct WorkspaceGitLaneStrip: View {
    let row: WorkspaceGitGraphRow
    let laneCount: Int
    let laneWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2

            // Lanes that only pass by are drawn first so a commit's own node and
            // its outgoing edges sit on top of them.
            for lane in row.passingLanes where lane < laneCount {
                var line = Path()
                line.move(to: CGPoint(x: x(lane), y: 0))
                line.addLine(to: CGPoint(x: x(lane), y: size.height))
                context.stroke(line, with: .color(color(lane).opacity(0.55)), lineWidth: 1.5)
            }

            for edge in row.outgoing where edge.fromLane < laneCount && edge.toLane < laneCount {
                var line = Path()
                line.move(to: CGPoint(x: x(edge.fromLane), y: midY))
                if edge.fromLane == edge.toLane {
                    line.addLine(to: CGPoint(x: x(edge.toLane), y: size.height))
                } else {
                    // A curve rather than a diagonal, so a branch reads as
                    // leaving its lane instead of cutting across the column.
                    line.addCurve(
                        to: CGPoint(x: x(edge.toLane), y: size.height),
                        control1: CGPoint(x: x(edge.fromLane), y: size.height * 0.75),
                        control2: CGPoint(x: x(edge.toLane), y: midY + 2)
                    )
                }
                context.stroke(line, with: .color(color(edge.toLane)), lineWidth: 1.5)
            }

            // The incoming half of this commit's own lane.
            var incoming = Path()
            incoming.move(to: CGPoint(x: x(row.lane), y: 0))
            incoming.addLine(to: CGPoint(x: x(row.lane), y: midY))
            context.stroke(incoming, with: .color(color(row.lane).opacity(0.55)), lineWidth: 1.5)

            guard row.lane < laneCount else { return }
            let radius: CGFloat = row.commit.isMerge ? 3.5 : 4.5
            let node = Path(ellipseIn: CGRect(
                x: x(row.lane) - radius,
                y: midY - radius,
                width: radius * 2,
                height: radius * 2
            ))
            // A merge is drawn hollow so the two shapes are distinguishable
            // without relying on colour alone.
            if row.commit.isMerge {
                context.stroke(node, with: .color(color(row.lane)), lineWidth: 2)
            } else {
                context.fill(node, with: .color(color(row.lane)))
            }
        }
        .accessibilityHidden(true)
    }

    private func x(_ lane: Int) -> CGFloat {
        CGFloat(lane) * laneWidth + laneWidth / 2
    }

    /// Lane colour is positional, which is what makes a line followable down the
    /// page even though the same branch may change lanes.
    private func color(_ lane: Int) -> Color {
        let palette: [Color] = [.accentColor, .orange, .purple, .teal, .pink, .yellow, .mint, .indigo]
        return palette[lane % palette.count]
    }
}
