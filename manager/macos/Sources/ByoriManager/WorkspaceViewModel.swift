import ByoriManagerCore
import Combine
import Foundation

// MARK: - Runtime adapter boundary

/// The workspace UI intentionally depends on this narrow adapter instead of the
/// current foreground orchestration prototype. A PTY/session broker can conform
/// without making the presentation layer claim attach or persistence support.
@MainActor
protocol WorkspaceDataSource: AnyObject {
    func loadWorkspace() async throws -> WorkspacePresentationSnapshot
    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption]
    func loadInspector(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceInspectorSnapshot
    func loadContext(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceContextSnapshot
    func readFile(_ request: WorkspaceFileReadRequest) async throws -> WorkspaceFileDocument
    func writeFile(_ request: WorkspaceFileWriteRequest) async throws -> WorkspaceFileDocument
    func registerProject(at repositoryURL: URL) async throws
    func removeProject(id: String) async throws
    func branches(projectID: String) async throws -> [WorkspaceGitBranch]
    func createSourceTree(projectID: String, branch: String, startPoint: String?) async throws -> URL
    func hideSourceTree(projectID: String, sourceTreeID: String) async throws
    func restoreSourceTree(projectID: String, at url: URL) async throws
    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult
    func stopSession(id: String) async throws -> WorkspaceSessionItem
}

extension WorkspaceDataSource {
    func loadInspector(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceInspectorSnapshot {
        throw WorkspaceAdapterError.unsupported("Files and Git are not connected yet.")
    }

    func loadContext(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceContextSnapshot {
        throw WorkspaceAdapterError.unsupported("ByoriDB Context is not connected yet.")
    }

    func readFile(_ request: WorkspaceFileReadRequest) async throws -> WorkspaceFileDocument {
        throw WorkspaceAdapterError.unsupported("Opening files is not connected yet.")
    }

    func writeFile(_ request: WorkspaceFileWriteRequest) async throws -> WorkspaceFileDocument {
        throw WorkspaceAdapterError.unsupported("Saving files is not connected yet.")
    }

    func registerProject(at repositoryURL: URL) async throws {
        throw WorkspaceAdapterError.unsupported("Project registration is not connected yet.")
    }

    func removeProject(id: String) async throws {
        throw WorkspaceAdapterError.unsupported("Project removal is not connected yet.")
    }

    func branches(projectID: String) async throws -> [WorkspaceGitBranch] {
        throw WorkspaceAdapterError.unsupported("Branch listing is not connected yet.")
    }

    func createSourceTree(
        projectID: String,
        branch: String,
        startPoint: String?
    ) async throws -> URL {
        throw WorkspaceAdapterError.unsupported("Source tree creation is not connected yet.")
    }

    func hideSourceTree(projectID: String, sourceTreeID: String) async throws {
        throw WorkspaceAdapterError.unsupported("Source-tree removal is not connected yet.")
    }

    func restoreSourceTree(projectID: String, at url: URL) async throws {
        throw WorkspaceAdapterError.unsupported("Source-tree restore is not connected yet.")
    }

    func stopSession(id: String) async throws -> WorkspaceSessionItem {
        throw WorkspaceAdapterError.unsupported("Session stopping is not connected yet.")
    }


}

enum WorkspaceAdapterError: LocalizedError, Equatable {
    case unsupported(String)
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(message), let .invalidState(message):
            return message
        }
    }
}

/// An honest integration placeholder for previews or app wiring that lands
/// before a runtime adapter. It never manufactures projects or sessions.
@MainActor
final class UnavailableWorkspaceDataSource: WorkspaceDataSource {
    private let message: String

    init(message: String = "The workspace runtime adapter is not connected.") {
        self.message = message
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        throw WorkspaceAdapterError.unsupported(message)
    }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] {
        throw WorkspaceAdapterError.unsupported(message)
    }

    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported(message)
    }
}

// MARK: - Presentation models

struct WorkspacePresentationSnapshot: Hashable {
    var projects: [WorkspaceProjectItem]

    init(projects: [WorkspaceProjectItem]) {
        self.projects = projects
    }
}

struct WorkspaceProjectItem: Identifiable, Hashable {
    let id: String
    var name: String
    var repositoryURL: URL
    var memorySpace: String
    var registration: WorkspaceProjectRegistrationStatus
    var sourceTrees: [WorkspaceSourceTreeItem]
    var hiddenSourceTrees: [WorkspaceHiddenSourceTreeItem]

    var hasActiveWritingSession: Bool {
        sourceTrees.contains(where: \.hasActiveWritingSession)
    }
}

struct WorkspaceHiddenSourceTreeItem: Identifiable, Hashable {
    let projectID: String
    let url: URL

    var id: String { "\(projectID):\(url.path)" }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

enum WorkspaceProjectRegistrationStatus: Hashable {
    case trusted
    case approvalRequired
    case missing

    var label: String {
        switch self {
        case .trusted: return "Trusted"
        case .approvalRequired: return "Approval required"
        case .missing: return "Path missing"
        }
    }
}

struct WorkspaceSourceTreeItem: Identifiable, Hashable {
    let id: String
    let projectID: String
    var name: String
    var url: URL
    var kind: WorkspaceSourceTreeItemKind
    var branch: String
    var headRevision: String?
    var workingState: WorkspaceWorkingTreeStatus
    var tasks: [WorkspaceTaskItem]

    var hasActiveWritingSession: Bool {
        tasks.lazy.flatMap(\.sessions).contains(where: { $0.state.isActive })
    }
}

enum WorkspaceSourceTreeItemKind: String, Hashable {
    case primary
    case managedWorktree
    case externalCheckout

    var label: String {
        switch self {
        case .primary: return "Primary"
        case .managedWorktree: return "Worktree"
        case .externalCheckout: return "Checkout"
        }
    }
}

enum WorkspaceWorkingTreeStatus: Hashable {
    case clean
    case modified(changeCount: Int)
    case unavailable(reason: String)

    var accessibilityLabel: String {
        switch self {
        case .clean: return "Clean working tree"
        case let .modified(changeCount): return "Modified working tree, \(changeCount) changes"
        case let .unavailable(reason): return "Working tree unavailable: \(reason)"
        }
    }
}

struct WorkspaceTaskItem: Identifiable, Hashable {
    let id: String
    let sourceTreeID: String
    var title: String
    var status: WorkspaceTaskItemStatus
    var createdAt: Date
    var sessions: [WorkspaceSessionItem]
}

enum WorkspaceTaskItemStatus: String, Hashable {
    case open
    case active
    case completed
    case blocked
    case cancelled

    var allowsNewSession: Bool {
        self != .completed && self != .cancelled
    }

    var label: String {
        rawValue.capitalized
    }
}

struct WorkspaceSessionItem: Identifiable, Hashable {
    let id: String
    let taskID: String
    let name: String?
    let providerID: String
    let providerName: String
    let providerSystemImage: String
    let modelID: String
    let modelName: String
    var state: WorkspaceSessionItemStatus
    var statusDetail: String?
    var startedAt: Date?
    var endedAt: Date?
    var nativeSessionID: String?

    var displayName: String {
        guard let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedName.isEmpty else {
            return launchSelectionDisplayName
        }
        return normalizedName
    }

    var launchSelectionDisplayName: String { "\(providerName) · \(modelName)" }

    var hasCustomName: Bool {
        guard let name else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum WorkspaceSessionItemStatus: String, CaseIterable, Hashable {
    case preparing
    case running
    case waitingForUser
    case completed
    case failed
    case cancelled
    case timedOut

    var label: String {
        switch self {
        case .preparing: return "Preparing"
        case .running: return "Running"
        case .waitingForUser: return "Waiting for you"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .running, .waitingForUser: return true
        case .completed, .failed, .cancelled, .timedOut: return false
        }
    }
}

struct WorkspaceProviderOption: Identifiable, Hashable {
    let id: String
    var displayName: String
    var systemImage: String
    var availability: WorkspaceOptionAvailability
    var models: [WorkspaceModelOption]
}

struct WorkspaceModelOption: Identifiable, Hashable {
    let id: String
    var displayName: String
    var detail: String?
    var availability: WorkspaceOptionAvailability
    var acceptsCustomIdentifier = false
    var customIdentifierPlaceholder: String? = nil
}

enum WorkspaceOptionAvailability: Hashable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var unavailableReason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

enum WorkspaceContextDepth: String, CaseIterable, Identifiable, Hashable {
    case focused
    case related
    case broad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .focused: return "Focused"
        case .related: return "Related"
        case .broad: return "Broad"
        }
    }

    var detail: String {
        switch self {
        case .focused: return "Task/source-tree matches first; otherwise recent project records"
        case .related: return "Matches plus one-hop graph neighbors, then recent project records"
        case .broad: return "Matches plus two-hop graph neighbors, then a wider recent graph slice"
        }
    }
}

struct WorkspaceInspectorRequest: Hashable {
    let projectID: String
    let sourceTreeID: String
    let taskID: String?
    let sessionID: String?
    let contextDepth: WorkspaceContextDepth
}

struct WorkspaceInspectorSnapshot: Hashable {
    var files: [WorkspaceFileItem]
    var git: WorkspaceGitSummaryItem
}

struct WorkspaceFileReadRequest: Hashable {
    let projectID: String
    let sourceTreeID: String
    let relativePath: String
}

struct WorkspaceFileWriteRequest: Hashable {
    let projectID: String
    let sourceTreeID: String
    let relativePath: String
    let text: String
    /// The digest the editor was opened from. The adapter refuses the write if
    /// the file on disk no longer matches it.
    let expectedRevision: String
}

struct WorkspaceContextSnapshot: Hashable {
    var items: [WorkspaceContextItem]
    var isTruncated: Bool
}

struct WorkspaceFileItem: Identifiable, Hashable {
    let id: String
    var name: String
    var kind: WorkspaceFileItemKind
    var children: [WorkspaceFileItem]?
}

enum WorkspaceFileItemKind: String, Hashable {
    case folder
    case file
    case symlink
}

struct WorkspaceGitSummaryItem: Hashable {
    var branch: String
    var headRevision: String?
    var upstream: String?
    var aheadCount: Int
    var behindCount: Int
    var changes: [WorkspaceGitChangeItem]
}

struct WorkspaceGitChangeItem: Identifiable, Hashable {
    let id: String
    var path: String
    var status: WorkspaceGitChangeStatusItem
}

enum WorkspaceGitChangeStatusItem: String, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case untracked
    case conflicted

    var shortLabel: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .conflicted: return "!"
        }
    }
}

struct WorkspaceContextItem: Identifiable, Hashable {
    let id: String
    var kind: String
    var title: String
    var summary: String
    var provenance: String
    var updatedAt: Date?
    var tags: [String]
}

struct WorkspaceSessionLaunchRequest: Hashable {
    let projectID: String
    let sourceTreeID: String
    let existingTaskID: String?
    let newTaskTitle: String?
    let sessionName: String
    let providerID: String
    let modelChoice: WorkspaceLaunchModelChoice
    let contextDepth: WorkspaceContextDepth
    let additionalArguments: [String]
}

enum WorkspaceLaunchModelChoice: Hashable {
    case cliDefault
    case exact(String)
}

struct WorkspaceSessionLaunchResult: Hashable {
    let projectID: String
    let sourceTreeID: String
    let task: WorkspaceTaskItem
    let session: WorkspaceSessionItem
}

enum WorkspaceSelection: Hashable {
    case project(String)
    case sourceTree(String)
    case task(String)
    case session(String)

    var accessibilityDescription: String {
        switch self {
        case .project: return "Project"
        case .sourceTree: return "Source tree"
        case .task: return "Task"
        case .session: return "Session"
        }
    }
}

enum WorkspaceInspectorTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case git = "Git"
    case context = "Context"

    var id: String { rawValue }
}

enum WorkspacePresentationPhase: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

enum WorkspaceInspectorPhase: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

/// What the user is choosing when adding a source tree: an existing branch, or
/// a new one cut from a start point.
struct WorkspaceNewSourceTreeDraft: Equatable {
    var projectID: String = ""
    var mode: Mode = .existing
    var selectedBranch: String = ""
    var newBranchName: String = ""
    var startPoint: String = ""

    enum Mode: String, CaseIterable, Identifiable, Equatable {
        case existing
        case new

        var id: String { rawValue }
        var label: String { self == .existing ? "Existing Branch" : "New Branch" }
    }
}

enum WorkspaceSessionOptionsPhase: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

enum WorkspaceNewSessionTaskChoice: Hashable {
    case newTask
    case existing(String)
}

struct WorkspaceNewSessionTarget: Hashable {
    let projectID: String
    let sourceTreeID: String
    let existingTaskID: String?
}

private enum WorkspaceSessionNameGenerator {
    private static let adjectives = [
        "Amber", "Calm", "Clear", "Copper", "Gentle", "Lunar",
        "Mossy", "Quiet", "Silver", "Swift", "Verdant", "Warm",
    ]
    private static let nouns = [
        "Atlas", "Brook", "Comet", "Finch", "Harbor", "Lantern",
        "Meadow", "Orbit", "Pine", "River", "Summit", "Willow",
    ]

    static func make() -> String {
        let adjective = adjectives[Int.random(in: adjectives.indices)]
        let noun = nouns[Int.random(in: nouns.indices)]
        return "\(adjective) \(noun)"
    }
}

struct WorkspaceNewSessionDraft: Hashable {
    var projectID: String = ""
    var sourceTreeID: String = ""
    var taskChoice: WorkspaceNewSessionTaskChoice = .newTask
    var newTaskTitle: String = ""
    var sessionName: String = ""
    var providerID: String?
    var modelID: String?
    var customModelID = ""
    var contextDepth: WorkspaceContextDepth = .related
    var acceptsModifiedWorkingTree = false
    /// Free-form flags appended to the CLI invocation, e.g.
    /// `--dangerously-skip-permissions`. Byori does not interpret them.
    var additionalArguments = ""
}

struct WorkspaceAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// One file open for editing. `original` is kept beside `draft` so the sheet can
/// tell an untouched view from unsaved work without asking the disk again.
struct WorkspaceFileEditor: Equatable {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let projectID: String
    let sourceTreeID: String
    let relativePath: String
    var phase: Phase = .loading
    var original = ""
    var draft = ""
    var revision = ""
    var byteSize = 0
    var isSaving = false
    /// Set after a save, or when the file moved underneath the editor.
    var notice: String?

    var isDirty: Bool { phase == .ready && draft != original }

    var name: String {
        relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }
}

struct WorkspaceLineage {
    let project: WorkspaceProjectItem
    let sourceTree: WorkspaceSourceTreeItem?
    let task: WorkspaceTaskItem?
    let session: WorkspaceSessionItem?
}

// MARK: - View model

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published private(set) var phase: WorkspacePresentationPhase = .idle
    @Published private(set) var projects: [WorkspaceProjectItem] = []
    @Published private(set) var selection: WorkspaceSelection?
    @Published var inspectorTab: WorkspaceInspectorTab = .files
    @Published private(set) var contextDepth: WorkspaceContextDepth = .related
    @Published private(set) var inspectorPhase: WorkspaceInspectorPhase = .idle
    @Published private(set) var inspectorSnapshot: WorkspaceInspectorSnapshot?
    @Published private(set) var contextPhase: WorkspaceInspectorPhase = .idle
    @Published private(set) var contextSnapshot: WorkspaceContextSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRegisteringProject = false
    @Published var newSourceTreeDraft = WorkspaceNewSourceTreeDraft()
    @Published private(set) var isPresentingNewSourceTree = false
    @Published private(set) var availableBranches: [WorkspaceGitBranch] = []
    @Published private(set) var branchesPhase: WorkspaceSessionOptionsPhase = .idle
    @Published private(set) var isCreatingSourceTree = false
    @Published private(set) var isMutatingWorkspace = false
    @Published private(set) var stoppingSessionIDs: Set<String> = []

    @Published var fileEditor: WorkspaceFileEditor?

    @Published var isPresentingNewSession = false
    @Published var newSessionDraft = WorkspaceNewSessionDraft()
    @Published private(set) var sessionOptions: [WorkspaceProviderOption] = []
    @Published private(set) var sessionOptionsPhase: WorkspaceSessionOptionsPhase = .idle
    @Published private(set) var isStartingSession = false
    @Published private(set) var newSessionError: String?
    @Published var alert: WorkspaceAlert?

    private let dataSource: any WorkspaceDataSource
    private var inspectorRequestToken = UUID()
    private var contextRequestToken = UUID()

    init(dataSource: any WorkspaceDataSource) {
        self.dataSource = dataSource
    }

    var selectedLineage: WorkspaceLineage? {
        guard let selection else { return nil }
        return lineage(for: selection)
    }

    var selectedProject: WorkspaceProjectItem? { selectedLineage?.project }
    var selectedSourceTree: WorkspaceSourceTreeItem? { selectedLineage?.sourceTree }
    var selectedTask: WorkspaceTaskItem? { selectedLineage?.task }
    var selectedSession: WorkspaceSessionItem? { selectedLineage?.session }

    var availableModels: [WorkspaceModelOption] {
        guard let providerID = newSessionDraft.providerID,
              let provider = sessionOptions.first(where: { $0.id == providerID }) else {
            return []
        }
        return provider.models
    }

    var sessionNameValidationMessage: String? {
        let name = normalizedSessionName
        guard !name.isEmpty else { return "Enter a session name." }
        guard name.unicodeScalars.count <= WorkspaceSession.maximumNameScalarCount,
              name.utf8.count <= WorkspaceSession.maximumNameUTF8Bytes else {
            return "Keep the session name within \(WorkspaceSession.maximumNameScalarCount) characters."
        }
        guard !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return "Remove line breaks or control characters from the session name."
        }
        return nil
    }

    var canStartSession: Bool {
        guard !isStartingSession,
              !newSessionDraft.projectID.isEmpty,
              !newSessionDraft.sourceTreeID.isEmpty,
              sessionNameValidationMessage == nil,
              launchConstraintMessage == nil,
              let providerID = newSessionDraft.providerID,
              let modelID = newSessionDraft.modelID,
              let provider = sessionOptions.first(where: { $0.id == providerID }),
              provider.availability.isAvailable,
              let model = provider.models.first(where: { $0.id == modelID }),
              model.availability.isAvailable else {
            return false
        }
        if model.acceptsCustomIdentifier,
           newSessionDraft.customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        if case .newTask = newSessionDraft.taskChoice {
            return !newSessionDraft.newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var launchConstraintMessage: String? {
        guard let project = projects.first(where: { $0.id == newSessionDraft.projectID }) else {
            return "The selected project is no longer registered."
        }
        switch project.registration {
        case .trusted:
            break
        case .approvalRequired:
            return "Approve this project as trusted before launching a coding process."
        case .missing:
            return "The selected project folder is missing."
        }

        guard let sourceTree = project.sourceTrees.first(where: { $0.id == newSessionDraft.sourceTreeID }) else {
            return "The selected source tree is no longer available."
        }
        if case let .existing(taskID) = newSessionDraft.taskChoice {
            guard let task = sourceTree.tasks.first(where: { $0.id == taskID }) else {
                return "The selected task is no longer available in this source tree."
            }
            guard task.status.allowsNewSession else {
                return "This task is \(task.status.label.lowercased()) and cannot start another session."
            }
        }
        if case let .unavailable(reason) = sourceTree.workingState {
            return reason
        }
        if sourceTree.hasActiveWritingSession {
            return "This source tree already has an active writing session. Choose another source tree."
        }
        if case .modified = sourceTree.workingState, !newSessionDraft.acceptsModifiedWorkingTree {
            return "Confirm that you want to start in a modified working tree."
        }
        return nil
    }

    func load(force: Bool = false) async {
        guard phase != .loading, !isRefreshing else { return }
        guard force || phase == .idle || isFailure(phase) else { return }

        if projects.isEmpty {
            phase = .loading
        } else {
            isRefreshing = true
        }

        do {
            let snapshot = try await dataSource.loadWorkspace()
            let previousSelection = selection
            projects = snapshot.projects
            if let previousSelection, lineage(for: previousSelection) != nil {
                selection = previousSelection
            } else {
                selection = defaultSelection()
            }
            phase = .ready
            isRefreshing = false
            await loadInspector()
        } catch {
            isRefreshing = false
            let message = error.localizedDescription
            if projects.isEmpty {
                phase = .failed(message)
            } else {
                alert = WorkspaceAlert(title: "Workspace refresh failed", message: message)
            }
        }
    }

    func select(_ newSelection: WorkspaceSelection?) {
        guard selection != newSelection else { return }
        selection = newSelection
        Task { await loadInspector() }
    }

    func setContextDepth(_ depth: WorkspaceContextDepth) {
        guard contextDepth != depth else { return }
        contextDepth = depth
        Task { await loadContext() }
    }

    func refreshInspector() async {
        await loadInspector()
    }

    // MARK: - File editing

    func openFile(_ item: WorkspaceFileItem) {
        guard item.kind == .file,
              let lineage = selectedLineage,
              let sourceTree = lineage.sourceTree else { return }
        let editor = WorkspaceFileEditor(
            projectID: lineage.project.id,
            sourceTreeID: sourceTree.id,
            relativePath: item.id
        )
        fileEditor = editor
        Task { await loadOpenFile() }
    }

    func closeFileEditor() {
        fileEditor = nil
    }

    /// Re-reads the file and discards the draft. Reloading is how a conflicted
    /// save is resolved, so the sheet confirms first when there are unsaved
    /// edits to lose.
    func reloadOpenFile() async {
        await loadOpenFile()
    }

    private func loadOpenFile() async {
        guard var editor = fileEditor else { return }
        editor.phase = .loading
        editor.notice = nil
        fileEditor = editor
        let request = WorkspaceFileReadRequest(
            projectID: editor.projectID,
            sourceTreeID: editor.sourceTreeID,
            relativePath: editor.relativePath
        )
        do {
            let document = try await dataSource.readFile(request)
            // The sheet may have been dismissed, or another file opened, while
            // the read was in flight.
            guard var current = fileEditor, current.relativePath == editor.relativePath else { return }
            current.phase = .ready
            current.original = document.text
            current.revision = document.revision
            current.byteSize = document.byteSize
            current.draft = document.text
            fileEditor = current
        } catch {
            guard var current = fileEditor, current.relativePath == editor.relativePath else { return }
            current.phase = .failed(error.localizedDescription)
            fileEditor = current
        }
    }

    func saveOpenFile() async {
        guard var editor = fileEditor, editor.phase == .ready, !editor.isSaving else { return }
        editor.isSaving = true
        editor.notice = nil
        fileEditor = editor
        let request = WorkspaceFileWriteRequest(
            projectID: editor.projectID,
            sourceTreeID: editor.sourceTreeID,
            relativePath: editor.relativePath,
            text: editor.draft,
            expectedRevision: editor.revision
        )
        do {
            let document = try await dataSource.writeFile(request)
            guard var current = fileEditor, current.relativePath == editor.relativePath else { return }
            current.isSaving = false
            current.original = document.text
            current.revision = document.revision
            current.byteSize = document.byteSize
            current.notice = "Saved."
            fileEditor = current
            // The Git tab counts this file among the working-tree changes now.
            await loadInspector()
        } catch {
            guard var current = fileEditor, current.relativePath == editor.relativePath else { return }
            current.isSaving = false
            current.notice = error.localizedDescription
            fileEditor = current
        }
    }

    func registerProject(at repositoryURL: URL) async {
        guard !isRegisteringProject else { return }
        isRegisteringProject = true
        defer { isRegisteringProject = false }

        do {
            try await dataSource.registerProject(at: repositoryURL)
            await load(force: true)
        } catch {
            alert = WorkspaceAlert(
                title: "Project could not be added",
                message: error.localizedDescription
            )
        }
    }

    func removeProject(_ project: WorkspaceProjectItem) async {
        guard !isMutatingWorkspace, !project.hasActiveWritingSession else {
            if project.hasActiveWritingSession {
                alert = WorkspaceAlert(
                    title: "Project could not be removed",
                    message: "Stop its active writing session first. No files or history were changed."
                )
            }
            return
        }
        isMutatingWorkspace = true
        defer { isMutatingWorkspace = false }
        do {
            try await dataSource.removeProject(id: project.id)
            selection = nil
            await load(force: true)
        } catch {
            alert = WorkspaceAlert(
                title: "Project could not be removed",
                message: error.localizedDescription
            )
        }
    }

    func hideSourceTree(_ sourceTree: WorkspaceSourceTreeItem) async {
        guard !isMutatingWorkspace, !sourceTree.hasActiveWritingSession else {
            if sourceTree.hasActiveWritingSession {
                alert = WorkspaceAlert(
                    title: "Source tree could not be removed",
                    message: "Stop its active writing session first. No files or history were changed."
                )
            }
            return
        }
        guard sourceTree.kind != .primary else {
            alert = WorkspaceAlert(
                title: "Remove the project instead",
                message: "The primary source tree represents its registered project."
            )
            return
        }
        isMutatingWorkspace = true
        defer { isMutatingWorkspace = false }
        do {
            try await dataSource.hideSourceTree(
                projectID: sourceTree.projectID,
                sourceTreeID: sourceTree.id
            )
            selection = .project(sourceTree.projectID)
            await load(force: true)
        } catch {
            alert = WorkspaceAlert(
                title: "Source tree could not be removed",
                message: error.localizedDescription
            )
        }
    }

    func restoreSourceTree(_ sourceTree: WorkspaceHiddenSourceTreeItem) async {
        guard !isMutatingWorkspace else { return }
        isMutatingWorkspace = true
        defer { isMutatingWorkspace = false }
        do {
            try await dataSource.restoreSourceTree(projectID: sourceTree.projectID, at: sourceTree.url)
            selection = .project(sourceTree.projectID)
            await load(force: true)
        } catch {
            alert = WorkspaceAlert(
                title: "Source tree could not be restored",
                message: error.localizedDescription
            )
        }
    }

    func prepareNewSession() async {
        guard !isPresentingNewSession, !isStartingSession else { return }
        guard let target = newSessionTarget() else {
            alert = WorkspaceAlert(
                title: "Choose a source tree",
                message: "Select a source tree or a task before starting a session."
            )
            return
        }

        await presentNewSession(for: target)
    }

    func prepareNewSession(target requestedTarget: WorkspaceNewSessionTarget) async {
        guard !isPresentingNewSession, !isStartingSession else { return }
        guard let target = newSessionTarget(matching: requestedTarget) else {
            alert = WorkspaceAlert(
                title: "Session target is unavailable",
                message: "Refresh the workspace and choose that source tree or task again."
            )
            return
        }

        await presentNewSession(for: target)
    }

    func prepareNewSession(after session: WorkspaceSessionItem) async {
        guard let lineage = endedSessionLineage(for: session),
              let sourceTree = lineage.sourceTree,
              let task = lineage.task else {
            alert = WorkspaceAlert(
                title: "Session target is unavailable",
                message: "Select that ended session again, then start a new session from its task."
            )
            return
        }

        await prepareNewSession(target: WorkspaceNewSessionTarget(
            projectID: lineage.project.id,
            sourceTreeID: sourceTree.id,
            existingTaskID: task.id
        ))
    }



    func prepareNewSourceTree(projectID: String) async {
        guard !isPresentingNewSourceTree, !isCreatingSourceTree else { return }
        newSourceTreeDraft = WorkspaceNewSourceTreeDraft(projectID: projectID)
        availableBranches = []
        branchesPhase = .loading
        isPresentingNewSourceTree = true
        await loadBranches()
    }

    func loadBranches() async {
        let projectID = newSourceTreeDraft.projectID
        guard !projectID.isEmpty else { return }
        branchesPhase = .loading
        do {
            let branches = try await dataSource.branches(projectID: projectID)
            guard newSourceTreeDraft.projectID == projectID else { return }
            availableBranches = branches
            // Default to something the user can actually act on.
            if newSourceTreeDraft.selectedBranch.isEmpty {
                newSourceTreeDraft.selectedBranch = branches.first { !$0.isCheckedOut }?.name ?? ""
            }
            if newSourceTreeDraft.startPoint.isEmpty {
                newSourceTreeDraft.startPoint = branches.first { $0.isCheckedOut }?.name
                    ?? branches.first?.name ?? ""
            }
            branchesPhase = .ready
        } catch {
            branchesPhase = .failed(error.localizedDescription)
        }
    }

    func dismissNewSourceTree() {
        guard !isCreatingSourceTree else { return }
        isPresentingNewSourceTree = false
    }

    var newSourceTreeValidationMessage: String? {
        switch newSourceTreeDraft.mode {
        case .existing:
            if newSourceTreeDraft.selectedBranch.isEmpty {
                return "Choose a branch that is not already checked out."
            }
        case .new:
            let name = newSourceTreeDraft.newBranchName.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return "Name the new branch." }
            if availableBranches.contains(where: { !$0.isRemote && $0.name == name }) {
                return "A branch named \(name) already exists."
            }
            if newSourceTreeDraft.startPoint.isEmpty { return "Choose where the branch starts." }
        }
        return nil
    }

    func createSourceTree() async {
        guard !isCreatingSourceTree, newSourceTreeValidationMessage == nil else { return }
        let draft = newSourceTreeDraft
        isCreatingSourceTree = true
        defer { isCreatingSourceTree = false }
        do {
            let branch: String
            let startPoint: String?
            switch draft.mode {
            case .existing:
                branch = draft.selectedBranch
                startPoint = nil
            case .new:
                branch = draft.newBranchName.trimmingCharacters(in: .whitespaces)
                startPoint = draft.startPoint
            }
            _ = try await dataSource.createSourceTree(
                projectID: draft.projectID,
                branch: branch,
                startPoint: startPoint
            )
            isPresentingNewSourceTree = false
            // The new checkout is discovered by the ordinary load.
            await load(force: true)
        } catch {
            alert = WorkspaceAlert(
                title: "Source tree could not be created",
                message: error.localizedDescription
            )
        }
    }

    private func presentNewSession(for target: (
        project: WorkspaceProjectItem,
        sourceTree: WorkspaceSourceTreeItem,
        task: WorkspaceTaskItem?
    )) async {
        newSessionDraft = WorkspaceNewSessionDraft(
            projectID: target.project.id,
            sourceTreeID: target.sourceTree.id,
            taskChoice: target.task.map { .existing($0.id) } ?? .newTask,
            sessionName: WorkspaceSessionNameGenerator.make(),
            contextDepth: contextDepth,
            acceptsModifiedWorkingTree: false
        )
        sessionOptions = []
        sessionOptionsPhase = .loading
        newSessionError = nil
        isPresentingNewSession = true
        await loadSessionOptions(projectID: target.project.id)
    }

    func retrySessionOptions() async {
        guard !newSessionDraft.projectID.isEmpty else { return }
        await loadSessionOptions(projectID: newSessionDraft.projectID)
    }

    func dismissNewSession() {
        guard !isStartingSession else { return }
        isPresentingNewSession = false
        newSessionError = nil
    }

    func chooseProvider(_ providerID: String?) {
        guard newSessionDraft.providerID != providerID else { return }
        newSessionDraft.providerID = providerID
        newSessionDraft.modelID = nil
    }

    func chooseModel(_ modelID: String?) {
        newSessionDraft.modelID = modelID
        newSessionDraft.customModelID = ""
    }

    func startSession() async {
        guard canStartSession,
              let providerID = newSessionDraft.providerID,
              let modelID = newSessionDraft.modelID,
              let selectedModel = availableModels.first(where: { $0.id == modelID }) else {
            newSessionError = "Name the session, choose an available provider and model, then complete the task details."
            return
        }

        let sessionName = normalizedSessionName
        let trimmedTitle = newSessionDraft.newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingTaskID: String?
        let newTaskTitle: String?
        switch newSessionDraft.taskChoice {
        case .newTask:
            existingTaskID = nil
            newTaskTitle = trimmedTitle
        case let .existing(taskID):
            existingTaskID = taskID
            newTaskTitle = nil
        }

        let modelChoice: WorkspaceLaunchModelChoice = selectedModel.acceptsCustomIdentifier
            ? .exact(newSessionDraft.customModelID.trimmingCharacters(in: .whitespacesAndNewlines))
            : .cliDefault
        let request = WorkspaceSessionLaunchRequest(
            projectID: newSessionDraft.projectID,
            sourceTreeID: newSessionDraft.sourceTreeID,
            existingTaskID: existingTaskID,
            newTaskTitle: newTaskTitle,
            sessionName: sessionName,
            providerID: providerID,
            modelChoice: modelChoice,
            contextDepth: newSessionDraft.contextDepth,
            additionalArguments: TerminalLaunchDescriptorFactory
                .splitArguments(newSessionDraft.additionalArguments)
        )

        isStartingSession = true
        newSessionError = nil
        do {
            let result = try await dataSource.startSession(request)
            upsert(result)
            selection = .session(result.session.id)
            contextDepth = request.contextDepth
            isStartingSession = false
            isPresentingNewSession = false
            await loadInspector()
        } catch {
            isStartingSession = false
            newSessionError = error.localizedDescription
        }
    }

    func stopSession(_ session: WorkspaceSessionItem) async {
        guard session.state.isActive, !stoppingSessionIDs.contains(session.id) else { return }
        stoppingSessionIDs.insert(session.id)
        defer { stoppingSessionIDs.remove(session.id) }

        do {
            let updated = try await dataSource.stopSession(id: session.id)
            replaceSession(updated)
        } catch {
            alert = WorkspaceAlert(title: "Session could not be stopped", message: error.localizedDescription)
        }
    }

    func dismissAlert() {
        alert = nil
    }

    func sourceTrees(for projectID: String) -> [WorkspaceSourceTreeItem] {
        projects.first(where: { $0.id == projectID })?.sourceTrees ?? []
    }

    func tasks(for sourceTreeID: String) -> [WorkspaceTaskItem] {
        for project in projects {
            if let sourceTree = project.sourceTrees.first(where: { $0.id == sourceTreeID }) {
                return sourceTree.tasks
            }
        }
        return []
    }

    private func loadSessionOptions(projectID: String) async {
        sessionOptionsPhase = .loading
        do {
            let options = try await dataSource.loadSessionOptions(projectID: projectID)
            sessionOptions = options
            sessionOptionsPhase = .ready
        } catch {
            sessionOptions = []
            sessionOptionsPhase = .failed(error.localizedDescription)
        }
    }

    private func loadInspector() async {
        guard phase == .ready,
              let lineage = selectedLineage,
              let sourceTree = lineage.sourceTree else {
            inspectorRequestToken = UUID()
            contextRequestToken = UUID()
            inspectorSnapshot = nil
            contextSnapshot = nil
            inspectorPhase = .idle
            contextPhase = .idle
            return
        }

        let request = WorkspaceInspectorRequest(
            projectID: lineage.project.id,
            sourceTreeID: sourceTree.id,
            taskID: lineage.task?.id,
            sessionID: lineage.session?.id,
            contextDepth: contextDepth
        )
        let token = UUID()
        let contextToken = UUID()
        inspectorRequestToken = token
        contextRequestToken = contextToken
        inspectorPhase = .loading
        contextPhase = .loading
        let inspectorTask = Task { try await dataSource.loadInspector(request) }
        let contextTask = Task { try await dataSource.loadContext(request) }

        do {
            let snapshot = try await inspectorTask.value
            guard inspectorRequestToken == token else { return }
            inspectorSnapshot = snapshot
            inspectorPhase = .ready
        } catch {
            guard inspectorRequestToken == token else { return }
            inspectorSnapshot = nil
            inspectorPhase = .failed(error.localizedDescription)
        }

        do {
            let snapshot = try await contextTask.value
            guard contextRequestToken == contextToken else { return }
            contextSnapshot = snapshot
            contextPhase = .ready
        } catch {
            guard contextRequestToken == contextToken else { return }
            contextSnapshot = nil
            contextPhase = .failed(error.localizedDescription)
        }
    }

    private func loadContext() async {
        guard phase == .ready,
              let lineage = selectedLineage,
              let sourceTree = lineage.sourceTree else {
            contextRequestToken = UUID()
            contextSnapshot = nil
            contextPhase = .idle
            return
        }
        let request = WorkspaceInspectorRequest(
            projectID: lineage.project.id,
            sourceTreeID: sourceTree.id,
            taskID: lineage.task?.id,
            sessionID: lineage.session?.id,
            contextDepth: contextDepth
        )
        let token = UUID()
        contextRequestToken = token
        contextPhase = .loading
        do {
            let snapshot = try await dataSource.loadContext(request)
            guard contextRequestToken == token else { return }
            contextSnapshot = snapshot
            contextPhase = .ready
        } catch {
            guard contextRequestToken == token else { return }
            contextSnapshot = nil
            contextPhase = .failed(error.localizedDescription)
        }
    }

    private func newSessionTarget() -> (
        project: WorkspaceProjectItem,
        sourceTree: WorkspaceSourceTreeItem,
        task: WorkspaceTaskItem?
    )? {
        if let lineage = selectedLineage, let sourceTree = lineage.sourceTree {
            return (lineage.project, sourceTree, lineage.task)
        }
        if let project = selectedProject, let sourceTree = project.sourceTrees.first {
            return (project, sourceTree, nil)
        }
        if let project = projects.first, let sourceTree = project.sourceTrees.first {
            return (project, sourceTree, nil)
        }
        return nil
    }

    private func newSessionTarget(
        matching target: WorkspaceNewSessionTarget
    ) -> (
        project: WorkspaceProjectItem,
        sourceTree: WorkspaceSourceTreeItem,
        task: WorkspaceTaskItem?
    )? {
        guard let project = projects.first(where: { $0.id == target.projectID }),
              let sourceTree = project.sourceTrees.first(where: { $0.id == target.sourceTreeID }) else {
            return nil
        }
        guard let taskID = target.existingTaskID else {
            return (project, sourceTree, nil)
        }
        guard let task = sourceTree.tasks.first(where: { $0.id == taskID }) else {
            return nil
        }
        return (project, sourceTree, task)
    }

    private func endedSessionLineage(for session: WorkspaceSessionItem) -> WorkspaceLineage? {
        guard !session.state.isActive,
              selection == .session(session.id),
              let lineage = selectedLineage,
              lineage.session?.id == session.id else {
            return nil
        }
        return lineage
    }

    private var normalizedSessionName: String {
        newSessionDraft.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func defaultSelection() -> WorkspaceSelection? {
        for project in projects {
            for sourceTree in project.sourceTrees {
                for task in sourceTree.tasks {
                    if let session = task.sessions.first(where: { $0.state.isActive }) {
                        return .session(session.id)
                    }
                }
            }
        }

        if let project = projects.first {
            if let sourceTree = project.sourceTrees.first {
                if let task = sourceTree.tasks.first {
                    if let session = task.sessions.first { return .session(session.id) }
                    return .task(task.id)
                }
                return .sourceTree(sourceTree.id)
            }
            return .project(project.id)
        }
        return nil
    }

    private func lineage(for selection: WorkspaceSelection) -> WorkspaceLineage? {
        for project in projects {
            if selection == .project(project.id) {
                return WorkspaceLineage(project: project, sourceTree: nil, task: nil, session: nil)
            }
            for sourceTree in project.sourceTrees {
                if selection == .sourceTree(sourceTree.id) {
                    return WorkspaceLineage(project: project, sourceTree: sourceTree, task: nil, session: nil)
                }
                for task in sourceTree.tasks {
                    if selection == .task(task.id) {
                        return WorkspaceLineage(project: project, sourceTree: sourceTree, task: task, session: nil)
                    }
                    if let session = task.sessions.first(where: { selection == .session($0.id) }) {
                        return WorkspaceLineage(project: project, sourceTree: sourceTree, task: task, session: session)
                    }
                }
            }
        }
        return nil
    }

    private func upsert(_ result: WorkspaceSessionLaunchResult) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == result.projectID }),
              let sourceTreeIndex = projects[projectIndex].sourceTrees.firstIndex(where: { $0.id == result.sourceTreeID }) else {
            return
        }

        var task = result.task
        if let sessionIndex = task.sessions.firstIndex(where: { $0.id == result.session.id }) {
            task.sessions[sessionIndex] = result.session
        } else {
            task.sessions.append(result.session)
        }

        if let taskIndex = projects[projectIndex].sourceTrees[sourceTreeIndex].tasks.firstIndex(where: { $0.id == task.id }) {
            projects[projectIndex].sourceTrees[sourceTreeIndex].tasks[taskIndex] = task
        } else {
            projects[projectIndex].sourceTrees[sourceTreeIndex].tasks.append(task)
        }
    }

    private func replaceSession(_ updated: WorkspaceSessionItem) {
        for projectIndex in projects.indices {
            for sourceTreeIndex in projects[projectIndex].sourceTrees.indices {
                for taskIndex in projects[projectIndex].sourceTrees[sourceTreeIndex].tasks.indices {
                    if let sessionIndex = projects[projectIndex]
                        .sourceTrees[sourceTreeIndex]
                        .tasks[taskIndex]
                        .sessions
                        .firstIndex(where: { $0.id == updated.id }) {
                        projects[projectIndex]
                            .sourceTrees[sourceTreeIndex]
                            .tasks[taskIndex]
                            .sessions[sessionIndex] = updated
                        return
                    }
                }
            }
        }
    }

    private func replaceTask(_ updated: WorkspaceTaskItem) {
        for projectIndex in projects.indices {
            for sourceTreeIndex in projects[projectIndex].sourceTrees.indices {
                if let taskIndex = projects[projectIndex]
                    .sourceTrees[sourceTreeIndex]
                    .tasks
                    .firstIndex(where: { $0.id == updated.id }) {
                    projects[projectIndex]
                        .sourceTrees[sourceTreeIndex]
                        .tasks[taskIndex] = updated
                    return
                }
            }
        }
    }

    private func taskLocation(taskID: String) -> (
        project: WorkspaceProjectItem,
        sourceTree: WorkspaceSourceTreeItem,
        task: WorkspaceTaskItem
    )? {
        for project in projects {
            for sourceTree in project.sourceTrees {
                if let task = sourceTree.tasks.first(where: { $0.id == taskID }) {
                    return (project, sourceTree, task)
                }
            }
        }
        return nil
    }

    private func fallbackSelection(
        projectID: String,
        sourceTreeID: String,
        taskID: String
    ) -> WorkspaceSelection? {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return defaultSelection()
        }
        guard let sourceTree = project.sourceTrees.first(where: { $0.id == sourceTreeID }) else {
            return .project(project.id)
        }
        guard sourceTree.tasks.contains(where: { $0.id == taskID }) else {
            return .sourceTree(sourceTree.id)
        }
        return .task(taskID)
    }

    private func isFailure(_ phase: WorkspacePresentationPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }
}
