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
    func loadHistory(projectID: String, sourceTreeID: String) async throws -> WorkspaceGitGraph
    func checkout(projectID: String, sourceTreeID: String, ref: String) async throws

    func readFile(_ request: WorkspaceFileReadRequest) async throws -> WorkspaceFileDocument
    func writeFile(_ request: WorkspaceFileWriteRequest) async throws -> WorkspaceFileDocument
    func inspectProjectFolder(at folderURL: URL) async throws -> WorkspaceProjectFolderStatus
    func registerProject(at repositoryURL: URL) async throws
    func initializeAndRegisterProject(at folderURL: URL) async throws
    func createProject(named name: String, in parentDirectoryURL: URL) async throws
    func removeProject(id: String) async throws
    func archiveTask(id: String) async throws
    func archivedTasks(projectID: String?) async throws -> WorkspaceArchivedTaskList
    func restoreTask(id: String) async throws
    func branches(projectID: String) async throws -> [WorkspaceGitBranch]
    func createSourceTree(projectID: String, branch: String, startPoint: String?) async throws -> URL
    func createBranch(projectID: String, sourceTreeID: String, name: String, startPoint: String) async throws
    func hideSourceTree(projectID: String, sourceTreeID: String) async throws
    func deleteManagedSourceTree(
        projectID: String,
        sourceTreeID: String,
        deletingBranch: Bool
    ) async throws -> WorkspaceGitWorktreeRemovalResult
    func restoreSourceTree(projectID: String, at url: URL) async throws
    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult
    func stopSession(id: String) async throws -> WorkspaceSessionItem
    /// Reopens a terminal onto a session the CLI is still running in.
    func reattachSession(id: String) async throws -> WorkspaceSessionLaunchResult
    /// Why sessions started now will not outlive the app, or nil when they will.
    func sessionPersistenceWarning() async -> String?
    /// Builds this project's starting memory from its own Git history, returning
    /// what was written.
    func buildProjectMemory(projectID: String) async throws -> String
    func buildProjectMemory(projectID: String, sourceTreeID: String) async throws -> String
    func readCodeIndex(
        _ request: CodeIndexRequest, projectID: String, sourceTreeID: String
    ) async throws -> CodeIndexResponse
    func resumeCheckpoint(projectID: String, sourceTreeID: String, taskID: String) async throws -> TaskResume
    func saveCheckpoint(projectID: String, sourceTreeID: String, taskID: String, draft: TaskCheckpointDraft) async throws
    func updateMemoryPolicy(scope: WorkspaceMemoryScope, change: WorkspaceMemoryChange) async throws
    func loadTaskWorkflow(scope: WorkspaceTaskWorkScope) async throws -> TaskWorkflowPlan?
    func saveTaskWorkflow(scope: WorkspaceTaskWorkScope, plan: TaskWorkflowPlan) async throws
    func loadTaskVerification(scope: WorkspaceTaskWorkScope) async throws -> VerificationSnapshot
    func saveTaskVerificationCommands(scope: WorkspaceTaskWorkScope, commands: [VerificationCommand]) async throws
    func runTaskVerification(scope: WorkspaceTaskWorkScope, commandID: String) async throws -> VerificationReceipt
}

extension WorkspaceDataSource {
    func loadTaskWorkflow(scope: WorkspaceTaskWorkScope) async throws -> TaskWorkflowPlan? {
        throw WorkspaceAdapterError.unsupported("작업 절차 저장소가 연결되지 않았습니다.")
    }
    func saveTaskWorkflow(scope: WorkspaceTaskWorkScope, plan: TaskWorkflowPlan) async throws {
        throw WorkspaceAdapterError.unsupported("작업 절차 저장소가 연결되지 않았습니다.")
    }
    func loadTaskVerification(scope: WorkspaceTaskWorkScope) async throws -> VerificationSnapshot {
        throw WorkspaceAdapterError.unsupported("작업 검증이 연결되지 않았습니다.")
    }
    func saveTaskVerificationCommands(scope: WorkspaceTaskWorkScope, commands: [VerificationCommand]) async throws {
        throw WorkspaceAdapterError.unsupported("작업 검증이 연결되지 않았습니다.")
    }
    func runTaskVerification(scope: WorkspaceTaskWorkScope, commandID: String) async throws -> VerificationReceipt {
        throw WorkspaceAdapterError.unsupported("작업 검증이 연결되지 않았습니다.")
    }
    func resumeCheckpoint(projectID: String, sourceTreeID: String, taskID: String) async throws -> TaskResume {
        throw WorkspaceAdapterError.unsupported("체크포인트 조회가 연결되지 않았습니다.")
    }
    func saveCheckpoint(projectID: String, sourceTreeID: String, taskID: String, draft: TaskCheckpointDraft) async throws {
        throw WorkspaceAdapterError.unsupported("체크포인트 저장이 연결되지 않았습니다.")
    }
    func updateMemoryPolicy(scope: WorkspaceMemoryScope, change: WorkspaceMemoryChange) async throws {
        throw WorkspaceAdapterError.unsupported("기억 관리가 연결되지 않았습니다.")
    }
    func loadInspector(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceInspectorSnapshot {
        throw WorkspaceAdapterError.unsupported("Files and Git are not connected yet.")
    }

    func loadContext(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceContextSnapshot {
        throw WorkspaceAdapterError.unsupported("ByoriDB Context is not connected yet.")
    }

    func loadHistory(projectID: String, sourceTreeID: String) async throws -> WorkspaceGitGraph {
        throw WorkspaceAdapterError.unsupported("Git history is not connected yet.")
    }

    func checkout(projectID: String, sourceTreeID: String, ref: String) async throws {
        throw WorkspaceAdapterError.unsupported("Checkout is not connected yet.")
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

    func inspectProjectFolder(at folderURL: URL) async throws -> WorkspaceProjectFolderStatus {
        .gitRepository(folderURL)
    }

    func initializeAndRegisterProject(at folderURL: URL) async throws {
        throw WorkspaceAdapterError.unsupported("Git initialization is not connected yet.")
    }

    func createProject(named name: String, in parentDirectoryURL: URL) async throws {
        throw WorkspaceAdapterError.unsupported("Project creation is not connected yet.")
    }

    func removeProject(id: String) async throws {
        throw WorkspaceAdapterError.unsupported("Project removal is not connected yet.")
    }

    func archiveTask(id: String) async throws {
        throw WorkspaceAdapterError.unsupported("Task removal is not connected yet.")
    }

    func archivedTasks(projectID: String?) async throws -> WorkspaceArchivedTaskList {
        throw WorkspaceAdapterError.unsupported("보관한 작업 조회가 연결되지 않았습니다.")
    }

    func restoreTask(id: String) async throws {
        throw WorkspaceAdapterError.unsupported("작업 복원이 연결되지 않았습니다.")
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

    func createBranch(projectID: String, sourceTreeID: String, name: String, startPoint: String) async throws {
        throw WorkspaceAdapterError.unsupported("Branch creation is not connected yet.")
    }

    func hideSourceTree(projectID: String, sourceTreeID: String) async throws {
        throw WorkspaceAdapterError.unsupported("Source-tree removal is not connected yet.")
    }

    func deleteManagedSourceTree(
        projectID: String,
        sourceTreeID: String,
        deletingBranch: Bool
    ) async throws -> WorkspaceGitWorktreeRemovalResult {
        throw WorkspaceAdapterError.unsupported("Managed worktree deletion is not connected yet.")
    }

    func restoreSourceTree(projectID: String, at url: URL) async throws {
        throw WorkspaceAdapterError.unsupported("Source-tree restore is not connected yet.")
    }

    func stopSession(id: String) async throws -> WorkspaceSessionItem {
        throw WorkspaceAdapterError.unsupported("Session stopping is not connected yet.")
    }

    func reattachSession(id: String) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Session reattach is not connected yet.")
    }

    func sessionPersistenceWarning() async -> String? { nil }

    func buildProjectMemory(projectID: String) async throws -> String {
        throw WorkspaceAdapterError.unsupported("Building project memory is not connected yet.")
    }

    func buildProjectMemory(projectID: String, sourceTreeID: String) async throws -> String {
        throw WorkspaceAdapterError.unsupported("이 작업 트리의 분석이 연결되지 않았습니다.")
    }

    func readCodeIndex(
        _ request: CodeIndexRequest, projectID: String, sourceTreeID: String
    ) async throws -> CodeIndexResponse {
        throw WorkspaceAdapterError.unsupported("코드 인덱스 조회가 연결되지 않았습니다.")
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
    var truncatedTaskProjectIDs: Set<String>

    init(projects: [WorkspaceProjectItem], truncatedTaskProjectIDs: Set<String> = []) {
        self.projects = projects
        self.truncatedTaskProjectIDs = truncatedTaskProjectIDs
    }
}

enum WorkspaceProjectFolderStatus: Equatable {
    case gitRepository(URL)
    case requiresInitialization(URL)
}

struct WorkspacePendingProjectInitialization: Identifiable, Equatable {
    let folderURL: URL

    var id: String { folderURL.standardizedFileURL.path }
    var displayName: String {
        folderURL.lastPathComponent.isEmpty ? folderURL.path : folderURL.lastPathComponent
    }
}

/// A project that was just added and whose graph is empty.
///
/// The offer is made here because this is the one moment the user is certainly
/// looking: they just pointed Byori at a repository and are waiting to see what it
/// does with it. Waiting for them to find the Context tab meant the product's whole
/// point stayed invisible on the first run.
struct WorkspaceProjectMemoryOffer: Identifiable, Equatable {
    let projectID: String
    let projectName: String

    var id: String { projectID }
}

struct WorkspaceNewProjectDraft: Equatable {
    var name = ""
    var parentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
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

    /// Whether an agent is writing in this checkout. A running shell does not
    /// count: it is the terminal a person keeps beside their work, and treating it
    /// as a writer would block the next agent or push it into a new worktree.
    var hasActiveWritingSession: Bool {
        tasks.lazy.flatMap(\.sessions).contains { $0.state.isActive && $0.isWritingSession }
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
        case .externalCheckout: return "External"
        }
    }

    /// Used where the checkout type changes the user's decision, such as the
    /// launch sheet. A branch name alone cannot distinguish the original folder
    /// from another worktree checked out at the same revision.
    var locationLabel: String {
        switch self {
        case .primary: return "Primary checkout"
        case .managedWorktree: return "Byori worktree"
        case .externalCheckout: return "External checkout"
        }
    }

    var removalLabel: String {
        switch self {
        case .primary: return "Primary Checkout"
        case .managedWorktree: return "Worktree"
        case .externalCheckout: return "External Checkout"
        }
    }

    var sessionLocationDetail: String {
        switch self {
        case .primary:
            return "The agent will work in the original project folder."
        case .managedWorktree:
            return "The agent will work in a Byori-managed Git worktree, not the original project folder."
        case .externalCheckout:
            return "The agent will work in a Git checkout managed outside Byori."
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
    /// The CLI is still running under tmux but this app holds no terminal for
    /// it — the state a session is in after Byori was quit and reopened.
    var isDetached: Bool = false

    var displayName: String {
        guard let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedName.isEmpty else {
            return launchSelectionDisplayName
        }
        return normalizedName
    }

    var launchSelectionDisplayName: String {
        isWritingSession ? "\(providerName) · \(modelName)" : providerName
    }

    /// A shell session is not an agent writing in the checkout. Kept on the item
    /// so the presentation layer does not have to know the provider id.
    var isWritingSession: Bool {
        providerID != ByoriManagerCore.WorkspaceProvider.shell.rawValue
    }

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
    var memoryView: MemoryView = .current
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
    var memoryRecord: MemoryRecord? = nil
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
    var workflowPreset: TaskWorkflowPreset? = nil
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
    var locationStrategy: WorkspaceSessionLocationStrategy = .currentCheckout
    var newBranchName: String = ""
    var startPoint: String = ""
    var workflowPreset: TaskWorkflowPreset? = nil
    var sessionName: String = ""
    var providerID: String?
    var modelID: String?
    var customModelID = ""
    var contextDepth: WorkspaceContextDepth = .related
    var acceptsModifiedWorkingTree = false
    /// Free-form flags appended to the CLI invocation. Byori does not interpret
    /// them; it is the escape hatch for anything the option controls do not cover.
    var additionalArguments = ""
    /// Chosen launch options, keyed by `AgentLaunchOption.id`. A flag stores its
    /// own flag string; a choice stores the selected value. Absent means
    /// untouched, which contributes no argument at all.
    var launchOptionSelections: [String: String] = [:]
}

extension WorkspaceViewModel {
    func composedLaunchArguments() -> [String] {
        AgentLaunchArgumentComposer.arguments(
            options: launchOptions,
            selections: newSessionDraft.launchOptionSelections,
            typed: TerminalLaunchDescriptorFactory
                .splitArguments(newSessionDraft.additionalArguments)
        )
    }

    /// Named in the confirmation and in the row so a loosened permission is
    /// never something the user has to infer from a flag string.
    /// Empty until a provider is chosen, and for custom providers, whose flags
    /// Byori does not know.
    var launchOptions: [AgentLaunchOption] {
        guard let providerID = newSessionDraft.providerID else { return [] }
        return AgentLaunchOptionCatalog.options(for: providerID)
    }

    var selectedDangerousLaunchOptions: [AgentLaunchOption] {
        launchOptions.filter {
            $0.isDangerous && newSessionDraft.launchOptionSelections[$0.id] != nil
        }
    }
}

struct WorkspaceAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// The history sheet's state. It is tied to one source tree because a checkout
/// only ever means "switch *this* working tree", never the project as a whole.
struct WorkspaceHistoryPresentation: Equatable {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let projectID: String
    let sourceTreeID: String
    let sourceTreeName: String
    /// Captured when the sheet opens: a checkout under a running agent is
    /// refused, and the reason has to be sayable before anything is attempted.
    let activeSessionBlockReason: String?
    var phase: Phase = .loading
    var graph: WorkspaceGitGraph = .empty
    var selectedSHA: String?
    var checkingOutRef: String?
    var notice: String?

    var canCheckOut: Bool { activeSessionBlockReason == nil && checkingOutRef == nil }
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
    @Published var projectSearchQuery = ""
    @Published var isPresentingSessionCleanup = false
    @Published var cleanupProjectID: String? {
        didSet {
            if oldValue != cleanupProjectID { clearCleanupSelections() }
        }
    }
    @Published var cleanupThreshold: WorkspaceCleanupThreshold = .thirtyDays {
        didSet {
            if oldValue != cleanupThreshold { clearCleanupSelections() }
        }
    }
    @Published var selectedCleanupTaskIDs: Set<String> = []
    @Published var selectedArchivedTaskIDs: Set<String> = []
    @Published private(set) var cleanupProjects: [WorkspaceCleanupProject] = []
    @Published private(set) var cleanupPhase: WorkspaceSessionOptionsPhase = .idle
    @Published private(set) var cleanupArchivedPhase: WorkspaceSessionOptionsPhase = .idle
    @Published private(set) var isCleaningSessions = false
    @Published private(set) var cleanupError: String?
    @Published private(set) var cleanupResultSummary: String?
    @Published private(set) var cleanupArchiveListIsTruncated = false
    @Published private var cleanupSnapshot = WorkspacePresentationSnapshot(projects: [])
    @Published private var cleanupArchivedRows: [WorkspaceArchivedTaskItem] = []
    private var cleanupReferenceDate = Date()
    private var cleanupRequestToken = UUID()
    @Published var inspectorTab: WorkspaceInspectorTab = .files
    @Published private(set) var contextDepth: WorkspaceContextDepth = .related
    @Published private(set) var memoryView: MemoryView = .current
    @Published private(set) var memoryScope: WorkspaceMemoryScope?
    @Published private(set) var inspectorPhase: WorkspaceInspectorPhase = .idle
    @Published private(set) var inspectorSnapshot: WorkspaceInspectorSnapshot?
    @Published private(set) var contextPhase: WorkspaceInspectorPhase = .idle
    @Published private(set) var contextSnapshot: WorkspaceContextSnapshot?
    /// Set while `byori init` is reading history and indexing source, so the affordance
    /// that started it can show progress instead of looking ignored.
    @Published private(set) var isBuildingProjectMemory = false
    @Published private(set) var lastProjectMemorySummary: String?
    private var lastProjectMemoryProjectID: String?

    var selectedProjectMemorySummary: String? {
        guard selectedLineage?.project.id == lastProjectMemoryProjectID else { return nil }
        return lastProjectMemorySummary
    }
    /// Set right after a repository is added, when its graph turns out to be empty.
    @Published private(set) var projectMemoryOffer: WorkspaceProjectMemoryOffer?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRegisteringProject = false
    @Published private(set) var pendingProjectInitialization: WorkspacePendingProjectInitialization?
    @Published var newProjectDraft = WorkspaceNewProjectDraft()
    @Published private(set) var isPresentingNewProject = false
    @Published private(set) var isCreatingProject = false
    @Published private(set) var newProjectError: String?
    @Published var newSourceTreeDraft = WorkspaceNewSourceTreeDraft()
    @Published private(set) var isPresentingNewSourceTree = false
    @Published private(set) var availableBranches: [WorkspaceGitBranch] = []
    @Published private(set) var branchesPhase: WorkspaceSessionOptionsPhase = .idle
    @Published private(set) var isCreatingSourceTree = false
    @Published private(set) var isMutatingWorkspace = false
    @Published private(set) var stoppingSessionIDs: Set<String> = []
    @Published private(set) var reattachingSessionIDs: Set<String> = []
    /// Sessions whose automatic reattach failed. Kept so a session tmux has
    /// already lost is not re-attempted on every load, and so the failure is
    /// reported the one way that asked for it: the manual button.
    private var autoReattachFailedSessionIDs: Set<String> = []
    /// Set when a session started now would die with the app. Shown before the
    /// user commits to a session, not after the work is already lost.
    @Published private(set) var sessionPersistenceWarning: String?

    @Published var fileEditor: WorkspaceFileEditor?

    @Published var history: WorkspaceHistoryPresentation?
    @Published private(set) var codeIndexScope: WorkspaceCodeIndexScope?
    @Published private(set) var taskWorkScope: WorkspaceTaskWorkScope?

    @Published var isPresentingNewSession = false
    @Published var newSessionDraft = WorkspaceNewSessionDraft() {
        didSet {
            if oldValue.newTaskTitle != newSessionDraft.newTaskTitle
                || oldValue.taskChoice != newSessionDraft.taskChoice
                || oldValue.workflowPreset != newSessionDraft.workflowPreset {
                refreshSessionPlanSuggestions()
            }
        }
    }
    @Published private(set) var sessionBranches: [WorkspaceGitBranch] = []
    @Published private(set) var sessionBranchesPhase: WorkspaceSessionOptionsPhase = .idle
    private var sessionPlanRequestToken = UUID()
    private var sessionStrategyWasEdited = false
    private var sessionBranchWasEdited = false
    private var sessionStartPointWasEdited = false
    private var lastSuggestedSessionBranch = ""
    private var lastSuggestedSessionStartPoint = ""
    private var sessionPlanBaseBranch: String?
    private var sessionPlanBaseRevision: String?
    private var pendingSessionLocation: (projectID: String, sourceTreeID: String?, url: URL?, branch: String)?
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

    var newProjectNameValidationMessage: String? {
        let name = normalizedNewProjectName
        guard !name.isEmpty else { return "Enter a project name." }
        guard name != ".", name != ".." else { return "Choose a regular folder name." }
        guard name.utf8.count <= 255 else { return "Keep the project name within 255 bytes." }
        guard !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return "Remove slashes, colons, or control characters from the project name."
        }
        return nil
    }

    var newProjectDestinationURL: URL? {
        guard newProjectNameValidationMessage == nil else { return nil }
        return newProjectDraft.parentDirectoryURL
            .appendingPathComponent(normalizedNewProjectName, isDirectory: true)
            .standardizedFileURL
    }

    var newProjectValidationMessage: String? {
        if let message = newProjectNameValidationMessage { return message }
        let parent = newProjectDraft.parentDirectoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "Choose an existing location for the project."
        }
        guard let destination = newProjectDestinationURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            return "A file or folder with this name already exists in the selected location."
        }
        return nil
    }

    var canCreateProject: Bool {
        !isCreatingProject && newProjectValidationMessage == nil
    }

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

    /// Why Start Session refuses, or nil when it does not.
    ///
    /// A disabled button is the sheet saying no, and it used to say it silently:
    /// every requirement collapsed into `canStartSession`, and the sentence naming
    /// the unmet one sat inside `startSession()` behind a guard the disabled button
    /// made unreachable — so it could never be read. The requirement most often
    /// unmet is also the one furthest down: the Agent section scrolls out of view on
    /// a short window, which leaves a sheet that looks complete, a dead button, and
    /// nothing on screen to explain either.
    ///
    /// Ordered the way the sheet reads, top to bottom, so the reason names the first
    /// thing still to do rather than the last thing checked.
    var startSessionBlockedReason: String? {
        guard !newSessionDraft.projectID.isEmpty else {
            return "Choose the project this session runs in."
        }
        if let message = sessionNameValidationMessage { return message }
        if let message = launchConstraintMessage { return message }
        if case .newTask = newSessionDraft.taskChoice,
           newSessionDraft.newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the new task a title."
        }

        // The provider list is read when the sheet opens, so "nothing is chosen"
        // and "there is nothing to choose from yet" are different sentences. Only
        // the first one asks the user for anything.
        switch sessionOptionsPhase {
        case .idle, .loading:
            return "Reading the installed provider models…"
        case let .failed(message):
            return message
        case .ready:
            break
        }
        guard !sessionOptions.isEmpty else {
            return "No installed provider is available. Open Settings to connect one."
        }
        guard let providerID = newSessionDraft.providerID else {
            return "Choose the launch provider under Agent."
        }
        guard let provider = sessionOptions.first(where: { $0.id == providerID }) else {
            return "That provider is no longer installed. Choose another under Agent."
        }
        if let reason = provider.availability.unavailableReason { return reason }
        guard let modelID = newSessionDraft.modelID else {
            return "Choose the model under Agent."
        }
        guard let model = provider.models.first(where: { $0.id == modelID }) else {
            return "\(provider.displayName) no longer offers that model. Choose another under Agent."
        }
        if let reason = model.availability.unavailableReason { return reason }
        if model.acceptsCustomIdentifier,
           newSessionDraft.customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the model identifier for \(model.displayName)."
        }
        return nil
    }

    /// A launch in progress is not a refusal to explain — the button says
    /// "Starting…" for itself — so it gates here rather than in the reason.
    var canStartSession: Bool {
        !isStartingSession && startSessionBlockedReason == nil
    }

    var plannedSessionLocation: String {
        if let pending = pendingSessionLocation {
            return "생성 완료 · \(pending.branch) (위치 확인 후 이어서 시작)"
        }
        switch newSessionDraft.locationStrategy {
        case .newWorktree:
            return "새 워크트리 · \(newSessionDraft.newBranchName) ← \(newSessionDraft.startPoint)"
        case .newBranch:
            return "새 브랜치 · \(newSessionDraft.newBranchName) ← \(newSessionDraft.startPoint)"
        case .currentCheckout:
            guard let tree = sessionPlanSourceTree else { return "작업 위치를 확인해 주세요." }
            return "\(tree.branch) · \(tree.kind.locationLabel)"
        }
    }

    var launchConstraintMessage: String? {
        guard let project = projects.first(where: { $0.id == newSessionDraft.projectID }) else {
            return "The selected project is no longer registered."
        }
        switch project.registration {
        case .trusted: break
        case .approvalRequired:
            return "Approve this project as trusted before launching a coding process."
        case .missing:
            return "The selected project folder is missing."
        }
        return sessionPlanValidationMessage
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
            // A relaunch lands here: defaultSelection() prefers an active session,
            // which after a relaunch is a session tmux is still running.
            await autoReattachSelectedSessionIfNeeded()
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
        Task {
            await loadInspector()
            await autoReattachSelectedSessionIfNeeded()
        }
    }

    func setContextDepth(_ depth: WorkspaceContextDepth) {
        guard contextDepth != depth else { return }
        contextDepth = depth
        Task { await loadContext() }
    }

    func setMemoryView(_ view: MemoryView) {
        guard memoryView != view else { return }
        memoryView = view
        Task { await loadContext() }
    }

    func showMemory(_ record: MemoryRecord? = nil) {
        guard let lineage = selectedLineage, let tree = contextSourceTree(for: lineage) else { return }
        memoryScope = WorkspaceMemoryScope(project: lineage.project, tree: tree, task: lineage.task, record: record)
    }
    func dismissMemory() { memoryScope = nil }
    func showTaskWork(taskID: String? = nil) {
        let lineage: WorkspaceLineage?
        if let taskID { lineage = self.lineage(for: .task(taskID)) }
        else { lineage = selectedLineage }
        guard let lineage, let tree = lineage.sourceTree, let task = lineage.task else { return }
        taskWorkScope = WorkspaceTaskWorkScope(projectID: lineage.project.id, sourceTreeID: tree.id,
            taskID: task.id, taskTitle: task.title, title: "\(lineage.project.name) · \(task.title)", root: tree.url)
    }
    func dismissTaskWork() { taskWorkScope = nil }
    func taskWorkProvider(for scope: WorkspaceTaskWorkScope) -> any WorkspaceTaskWorkProviding {
        WorkspaceTaskWorkProvider(dataSource: dataSource, scope: scope)
    }
    func resumeCheckpoint(scope: WorkspaceMemoryScope) async throws -> TaskResume {
        try await dataSource.resumeCheckpoint(projectID: scope.projectID, sourceTreeID: scope.sourceTreeID, taskID: scope.taskID)
    }
    func saveCheckpoint(scope: WorkspaceMemoryScope, draft: TaskCheckpointDraft) async throws {
        try await dataSource.saveCheckpoint(projectID: scope.projectID, sourceTreeID: scope.sourceTreeID, taskID: scope.taskID, draft: draft)
    }
    func updateMemoryPolicy(scope: WorkspaceMemoryScope, change: WorkspaceMemoryChange) async throws {
        try await dataSource.updateMemoryPolicy(scope: scope, change: change)
        await loadContext()
    }

    func refreshInspector() async {
        await loadInspector()
    }

    // MARK: - Persistent code index

    func showCodeIndex(projectID: String? = nil) {
        let lineage: WorkspaceLineage?
        if let projectID {
            lineage = self.lineage(for: .project(projectID))
        } else {
            lineage = selectedLineage
        }
        guard let lineage, let sourceTree = contextSourceTree(for: lineage) else { return }
        codeIndexScope = WorkspaceCodeIndexScope(project: lineage.project, sourceTree: sourceTree)
    }

    func dismissCodeIndex() { codeIndexScope = nil }

    func codeIndexProvider(for scope: WorkspaceCodeIndexScope) -> any CodeIndexProviding {
        WorkspaceCodeIndexProvider(dataSource: dataSource, scope: scope)
    }

    func readIndexedSource(
        _ relativePath: String, scope: WorkspaceCodeIndexScope
    ) async throws -> WorkspaceFileDocument {
        try await dataSource.readFile(WorkspaceFileReadRequest(
            projectID: scope.projectID, sourceTreeID: scope.sourceTreeID, relativePath: relativePath
        ))
    }

    func analyzeCodeIndex(scope: WorkspaceCodeIndexScope) async throws {
        guard !isBuildingProjectMemory else {
            throw WorkspaceAdapterError.invalidState("진행 중인 프로젝트 분석이 끝난 뒤 다시 실행해 주세요.")
        }
        isBuildingProjectMemory = true
        defer { isBuildingProjectMemory = false }
        let summary = try await dataSource.buildProjectMemory(
            projectID: scope.projectID, sourceTreeID: scope.sourceTreeID
        )
        lastProjectMemorySummary = summary
        lastProjectMemoryProjectID = scope.projectID
        await loadContext()
    }

    // MARK: - History and checkout

    func showHistory() {
        guard let lineage = selectedLineage, let sourceTree = lineage.sourceTree else { return }
        history = WorkspaceHistoryPresentation(
            projectID: lineage.project.id,
            sourceTreeID: sourceTree.id,
            sourceTreeName: sourceTree.name,
            // Swapping the branch out from under a running agent would mix its
            // work into a tree it never saw. The same guard already blocks
            // removing a project with a live writing session.
            activeSessionBlockReason: sourceTree.hasActiveWritingSession
                ? "Stop this source tree's active writing session before checking out."
                : nil
        )
        Task { await loadHistory() }
    }

    func dismissHistory() {
        history = nil
    }

    func selectCommit(_ sha: String?) {
        history?.selectedSHA = sha
    }

    private func loadHistory() async {
        guard var presentation = history else { return }
        presentation.phase = .loading
        presentation.notice = nil
        history = presentation
        do {
            let graph = try await dataSource.loadHistory(
                projectID: presentation.projectID,
                sourceTreeID: presentation.sourceTreeID
            )
            guard var current = history, current.sourceTreeID == presentation.sourceTreeID else { return }
            current.phase = .ready
            current.graph = graph
            history = current
        } catch {
            guard var current = history, current.sourceTreeID == presentation.sourceTreeID else { return }
            current.phase = .failed(error.localizedDescription)
            history = current
        }
    }

    func reloadHistory() async {
        await loadHistory()
    }

    func checkout(_ ref: WorkspaceGitRef) async {
        guard var presentation = history, presentation.canCheckOut, ref.isCheckoutable else { return }
        presentation.checkingOutRef = ref.name
        presentation.notice = nil
        history = presentation
        do {
            try await dataSource.checkout(
                projectID: presentation.projectID,
                sourceTreeID: presentation.sourceTreeID,
                ref: ref.name
            )
            guard var current = history, current.sourceTreeID == presentation.sourceTreeID else { return }
            current.checkingOutRef = nil
            current.notice = "Checked out \(ref.name)."
            history = current
            // Branch, HEAD and the working-tree summary all moved.
            await load(force: true)
            await loadHistory()
            await loadInspector()
        } catch {
            guard var current = history, current.sourceTreeID == presentation.sourceTreeID else { return }
            current.checkingOutRef = nil
            current.notice = error.localizedDescription
            history = current
        }
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

    func addProjectFolder(at folderURL: URL) async {
        guard !isRegisteringProject else { return }
        isRegisteringProject = true
        defer { isRegisteringProject = false }

        do {
            switch try await dataSource.inspectProjectFolder(at: folderURL) {
            case let .gitRepository(repositoryURL):
                try await dataSource.registerProject(at: repositoryURL)
                await load(force: true)
                await offerProjectMemory(for: repositoryURL)
            case let .requiresInitialization(directoryURL):
                pendingProjectInitialization = WorkspacePendingProjectInitialization(
                    folderURL: directoryURL
                )
            }
        } catch {
            alert = WorkspaceAlert(
                title: "Project could not be added",
                message: error.localizedDescription
            )
        }
    }

    func cancelProjectInitialization() {
        pendingProjectInitialization = nil
    }

    /// Acts on the request the dialog presented rather than reading it back from
    /// state. Dismissing a confirmation dialog clears
    /// `pendingProjectInitialization` synchronously, and a button's `Task` body
    /// runs after that — so the version that re-read the state found nothing and
    /// returned having initialized nothing, registered nothing, and, because it
    /// never reached the `catch`, said nothing either.
    func initializePendingProject(_ request: WorkspacePendingProjectInitialization) async {
        guard !isRegisteringProject else { return }
        pendingProjectInitialization = nil
        isRegisteringProject = true
        defer { isRegisteringProject = false }
        do {
            try await dataSource.initializeAndRegisterProject(at: request.folderURL)
            await load(force: true)
        } catch {
            alert = WorkspaceAlert(
                title: "Project could not be initialized",
                message: error.localizedDescription
            )
        }
    }

    func presentNewProject() {
        guard !isCreatingProject else { return }
        newProjectDraft = WorkspaceNewProjectDraft()
        newProjectError = nil
        isPresentingNewProject = true
    }

    func dismissNewProject() {
        guard !isCreatingProject else { return }
        isPresentingNewProject = false
    }

    func clearNewProjectError() {
        newProjectError = nil
    }

    func createProject() async {
        guard canCreateProject else { return }
        let name = normalizedNewProjectName
        let parentDirectoryURL = newProjectDraft.parentDirectoryURL
        newProjectError = nil
        isCreatingProject = true
        defer { isCreatingProject = false }
        do {
            try await dataSource.createProject(named: name, in: parentDirectoryURL)
            isPresentingNewProject = false
            await load(force: true)
        } catch {
            newProjectError = error.localizedDescription
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

    func archiveTask(_ task: WorkspaceTaskItem) async {
        guard !isMutatingWorkspace,
              let location = taskLocation(taskID: task.id) else { return }
        guard !task.sessions.contains(where: { $0.state.isActive }) else {
            alert = WorkspaceAlert(
                title: "Task could not be removed",
                message: "Stop its active session first. The task and its files were left unchanged."
            )
            return
        }

        isMutatingWorkspace = true
        defer { isMutatingWorkspace = false }
        do {
            try await dataSource.archiveTask(id: task.id)
            selection = .sourceTree(location.sourceTree.id)
            await load(force: true)
        } catch {
            alert = WorkspaceAlert(
                title: "Task could not be removed",
                message: error.localizedDescription
            )
        }
    }

    func deleteManagedSourceTree(
        _ sourceTree: WorkspaceSourceTreeItem,
        deletingBranch: Bool
    ) async {
        guard !isMutatingWorkspace else { return }
        guard sourceTree.kind == .managedWorktree else {
            alert = WorkspaceAlert(
                title: "Worktree could not be deleted",
                message: "Only a worktree created and managed by Byori can be deleted here."
            )
            return
        }
        guard !sourceTree.hasActiveWritingSession else {
            alert = WorkspaceAlert(
                title: "Worktree could not be deleted",
                message: "Stop its active session first. No Git files were changed."
            )
            return
        }
        guard sourceTree.tasks.isEmpty else {
            alert = WorkspaceAlert(
                title: "Worktree could not be deleted",
                message: "Remove this worktree's tasks from Byori first. No Git files were changed."
            )
            return
        }

        isMutatingWorkspace = true
        defer { isMutatingWorkspace = false }
        do {
            let result = try await dataSource.deleteManagedSourceTree(
                projectID: sourceTree.projectID,
                sourceTreeID: sourceTree.id,
                deletingBranch: deletingBranch
            )
            selection = .project(sourceTree.projectID)
            await load(force: true)
            if let failure = result.branchDeletionFailure {
                alert = WorkspaceAlert(
                    title: "Worktree deleted, branch kept",
                    message: failure
                )
            }
        } catch {
            alert = WorkspaceAlert(
                title: "Worktree could not be deleted",
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
            // Default to something the user can actually act on. A local branch
            // first: a remote-tracking branch is a legitimate choice, but it turns
            // into a new local branch, so it must not be what the sheet quietly
            // starts on — and a remote whose local name is taken cannot be used
            // at all.
            if newSourceTreeDraft.selectedBranch.isEmpty {
                newSourceTreeDraft.selectedBranch = branches
                    .first { !$0.isRemote && !$0.isCheckedOut }?.name
                    ?? branches.first { branch in
                        branch.isRemote && Self.usableLocalBranchName(
                            forRemote: branch.name,
                            avoiding: branches
                        ) != nil
                    }?.name
                    ?? ""
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

    /// The listed branch the picker's selection names. A local branch wins a name
    /// collision: the picker tags entries by name alone, and a local branch is the
    /// one that can be checked out as it is.
    private var selectedExistingBranch: WorkspaceGitBranch? {
        let name = newSourceTreeDraft.selectedBranch
        guard !name.isEmpty else { return nil }
        return availableBranches.first { !$0.isRemote && $0.name == name }
            ?? availableBranches.first { $0.name == name }
    }

    /// `origin/feature/x` → `feature/x`. The remote name is the first component;
    /// the rest is the branch as the remote knows it.
    static func localBranchName(forRemote name: String) -> String? {
        guard let separator = name.firstIndex(of: "/") else { return nil }
        let local = String(name[name.index(after: separator)...])
        return local.isEmpty ? nil : local
    }

    /// The local branch a remote-tracking pick becomes, or nil when it cannot
    /// become one: a ref with no branch component, or a local name already taken.
    static func usableLocalBranchName(
        forRemote name: String,
        avoiding branches: [WorkspaceGitBranch]
    ) -> String? {
        guard let local = localBranchName(forRemote: name),
              !branches.contains(where: { !$0.isRemote && $0.name == local }) else {
            return nil
        }
        return local
    }

    var newSourceTreeValidationMessage: String? {
        // No refs at all means no commits: neither mode can work, and "choose a
        // branch" from an empty picker explains nothing.
        if availableBranches.isEmpty {
            return "This project has no commits yet. Make the first commit, then add a checkout."
        }
        switch newSourceTreeDraft.mode {
        case .existing:
            guard let selected = selectedExistingBranch else {
                return "Choose a branch that is not already checked out."
            }
            if selected.isRemote {
                guard let local = Self.localBranchName(forRemote: selected.name) else {
                    return "\(selected.name) carries no branch name to check out."
                }
                if availableBranches.contains(where: { !$0.isRemote && $0.name == local }) {
                    return "A local branch named \(local) already exists. Choose it instead."
                }
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
                guard let selected = selectedExistingBranch else { return }
                if selected.isRemote {
                    // A worktree cannot sit on a remote-tracking ref — Git would
                    // detach HEAD and the work would belong to no branch. Cutting
                    // a local branch from it is what picking a colleague's branch
                    // means, and starting from the remote ref records the upstream.
                    guard let local = Self.usableLocalBranchName(
                        forRemote: selected.name,
                        avoiding: availableBranches
                    ) else { return }
                    branch = local
                    startPoint = selected.name
                } else {
                    branch = selected.name
                    startPoint = nil
                }
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
        sourceTree: WorkspaceSourceTreeItem?,
        task: WorkspaceTaskItem?
    )) async {
        sessionPlanRequestToken = UUID()
        sessionStrategyWasEdited = false
        sessionBranchWasEdited = false
        sessionStartPointWasEdited = false
        lastSuggestedSessionBranch = ""
        lastSuggestedSessionStartPoint = ""
        pendingSessionLocation = nil
        sessionBranches = []
        sessionBranchesPhase = .loading
        sessionPlanBaseBranch = target.sourceTree?.branch
        sessionPlanBaseRevision = target.sourceTree?.headRevision
        newSessionDraft = WorkspaceNewSessionDraft(
            projectID: target.project.id,
            // Keep the selected checkout as the base even when it is busy.
            // Opening or cancelling a sheet never creates Git state.
            sourceTreeID: target.sourceTree?.id ?? "",
            taskChoice: target.task.map { .existing($0.id) } ?? .newTask,
            sessionName: WorkspaceSessionNameGenerator.make(),
            contextDepth: contextDepth,
            acceptsModifiedWorkingTree: false
        )
        sessionOptions = []
        sessionOptionsPhase = .loading
        newSessionError = nil
        isPresentingNewSession = true
        refreshSessionPlanSuggestions()
        sessionPersistenceWarning = await dataSource.sessionPersistenceWarning()
        await retrySessionBranches()
        await loadSessionOptions(projectID: target.project.id)
    }

    func retrySessionOptions() async {
        guard !newSessionDraft.projectID.isEmpty else { return }
        await loadSessionOptions(projectID: newSessionDraft.projectID)
    }

    func dismissNewSession() {
        guard !isStartingSession else { return }
        isPresentingNewSession = false
        sessionPlanRequestToken = UUID()
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
            // Reached only by a caller that did not check first — the button
            // cannot be pressed while this refuses. It still names the reason
            // rather than a generic list, so a keyboard shortcut or a test is
            // told the same thing the footer shows.
            newSessionError = startSessionBlockedReason
                ?? "Choose an available provider and model, then start the session again."
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

        isStartingSession = true
        newSessionError = nil
        // Execute exactly the reviewed plan, after checking live checkout state.
        // Creating a branch or worktree waits for this confirmation.
        let sourceTreeID: String
        do {
            sourceTreeID = try await resolveSessionLocationPlan()
        } catch {
            isStartingSession = false
            newSessionError = error.localizedDescription
            return
        }

        let request = WorkspaceSessionLaunchRequest(
            projectID: newSessionDraft.projectID,
            sourceTreeID: sourceTreeID,
            existingTaskID: existingTaskID,
            newTaskTitle: newTaskTitle,
            sessionName: sessionName,
            providerID: providerID,
            modelChoice: modelChoice,
            contextDepth: newSessionDraft.contextDepth,
            additionalArguments: composedLaunchArguments(),
            workflowPreset: existingTaskID == nil ? newSessionDraft.workflowPreset : nil
        )

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

    /// Builds this project's memory from its own Git history.
    ///
    /// Offered where the absence is visible — an empty Context tab — because that is
    /// the moment someone wonders why there is nothing there. The pass is
    /// deterministic and every memory it writes carries the commit, pull request or
    /// document it came from, so this is not the app inventing project knowledge.
    /// Opens a repository named from outside the app — `byori open` in a checkout, a
    /// folder dropped on the icon, `open -a Byori <folder>`.
    ///
    /// The CLI registers the project itself, so the usual path here is a reload that
    /// finds it. A root that is not registered yet still opens: registration goes
    /// through the app's own validated path rather than being refused for arriving
    /// from Finder. Either way it ends where `byori init` is one click away.
    func openProject(at root: URL) async {
        guard !isRegisteringProject else { return }
        await load(force: true)
        let wanted = root.standardizedFileURL.path
        if !projects.contains(where: { $0.repositoryURL.standardizedFileURL.path == wanted }) {
            isRegisteringProject = true
            do {
                try await dataSource.registerProject(at: root)
                await load(force: true)
            } catch {
                isRegisteringProject = false
                alert = WorkspaceAlert(
                    title: "프로젝트를 열지 못했습니다",
                    message: error.localizedDescription
                )
                return
            }
            isRegisteringProject = false
        }
        guard projects.contains(where: { $0.repositoryURL.standardizedFileURL.path == wanted }) else {
            alert = WorkspaceAlert(
                title: "프로젝트를 열지 못했습니다",
                message: "\(root.path)를 등록된 프로젝트에서 찾지 못했습니다."
            )
            return
        }
        await offerProjectMemory(for: root)
    }

    /// Selects a freshly added repository, opens the Context tab on it, and offers to
    /// read its history — but only when the graph really is empty.
    ///
    /// A project that already has memories is never asked: re-adding a repository
    /// should not read as "start over". Nothing is offered when the read failed
    /// either, because `byori init` needs the same engine that just did not answer.
    private func offerProjectMemory(for repositoryURL: URL) async {
        let wanted = repositoryURL.standardizedFileURL.path
        guard let project = projects.first(where: {
            $0.repositoryURL.standardizedFileURL.path == wanted
        }) else { return }

        selection = .project(project.id)
        inspectorTab = .context
        await loadInspector()
        guard case .ready = contextPhase,
              contextSnapshot?.items.isEmpty ?? true,
              selection == .project(project.id) else { return }
        projectMemoryOffer = WorkspaceProjectMemoryOffer(
            projectID: project.id,
            projectName: project.name
        )
    }

    func declineProjectMemoryOffer() {
        projectMemoryOffer = nil
    }

    /// Acts on the offer the dialog presented, for the reason spelled out on
    /// `initializePendingProject(_:)`.
    func acceptProjectMemoryOffer(_ offer: WorkspaceProjectMemoryOffer) async {
        projectMemoryOffer = nil
        select(.project(offer.projectID))
        await buildProjectMemory()
    }

    func buildProjectMemory() async {
        guard !isBuildingProjectMemory, let project = selectedLineage?.project else { return }
        isBuildingProjectMemory = true
        lastProjectMemorySummary = nil
        lastProjectMemoryProjectID = nil
        defer { isBuildingProjectMemory = false }
        do {
            let summary = try await dataSource.buildProjectMemory(projectID: project.id)
            lastProjectMemorySummary = summary
            lastProjectMemoryProjectID = project.id
            await loadContext()
        } catch {
            alert = WorkspaceAlert(
                title: "프로젝트 기억을 만들지 못했습니다",
                message: error.localizedDescription
            )
        }
    }

    /// Opens a plain login shell, with no sheet and nothing to fill in.
    ///
    /// A terminal is not a launch to configure — there is no provider, model or
    /// flag to choose — so asking would be four decisions for a thing that has
    /// one shape. It runs in the checkout the target names (an agent's own
    /// checkout when started from its task), is recorded like any other session
    /// so it survives quitting Byori and reattaches, and does not count as a
    /// writing session, so it never blocks an agent or forces a worktree.
    func startShellSession(target requestedTarget: WorkspaceNewSessionTarget? = nil) async {
        guard !isStartingSession else { return }
        let resolved: (project: WorkspaceProjectItem, sourceTree: WorkspaceSourceTreeItem?, task: WorkspaceTaskItem?)?
        if let requestedTarget {
            resolved = newSessionTarget(matching: requestedTarget)
        } else {
            resolved = newSessionTarget()
        }
        guard let target = resolved else {
            alert = WorkspaceAlert(
                title: "터미널을 열 수 없습니다",
                message: "먼저 프로젝트를 선택해 주세요."
            )
            return
        }

        isStartingSession = true
        defer { isStartingSession = false }

        // A shell wants the checkout the user is looking at, not a fresh worktree:
        // it is where their files and their build already are. Only when no
        // checkout exists at all does the ordinary resolution run.
        let sourceTreeID: String
        if let sourceTree = target.sourceTree ?? target.project.sourceTrees.first {
            sourceTreeID = sourceTree.id
        } else {
            do {
                sourceTreeID = try await resolvedSessionSourceTreeID(
                    projectID: target.project.id,
                    existingTaskID: target.task?.id,
                    taskTitle: Self.shellTaskTitle
                )
            } catch {
                alert = WorkspaceAlert(
                    title: "터미널을 열 수 없습니다",
                    message: error.localizedDescription
                )
                return
            }
        }

        // Reuse the shell task of that checkout when the caller named no task, so
        // opening a terminal five times does not leave five tasks behind.
        let existingTaskID = target.task?.id
            ?? existingShellTaskID(projectID: target.project.id, sourceTreeID: sourceTreeID)

        let request = WorkspaceSessionLaunchRequest(
            projectID: target.project.id,
            sourceTreeID: sourceTreeID,
            existingTaskID: existingTaskID,
            newTaskTitle: existingTaskID == nil ? Self.shellTaskTitle : nil,
            sessionName: Self.shellSessionName,
            providerID: ByoriManagerCore.WorkspaceProvider.shell.rawValue,
            modelChoice: .cliDefault,
            contextDepth: contextDepth,
            additionalArguments: []
        )

        do {
            let result = try await dataSource.startSession(request)
            upsert(result)
            selection = .session(result.session.id)
            await loadInspector()
        } catch {
            alert = WorkspaceAlert(
                title: "터미널을 열지 못했습니다",
                message: error.localizedDescription
            )
        }
    }

    static let shellTaskTitle = "터미널"
    private static let shellSessionName = "터미널"

    /// The open shell task in that checkout, if there is one.
    private func existingShellTaskID(projectID: String, sourceTreeID: String) -> String? {
        projects
            .first { $0.id == projectID }?
            .sourceTrees
            .first { $0.id == sourceTreeID }?
            .tasks
            .first { task in
                task.title == Self.shellTaskTitle
                    && task.status.allowsNewSession
                    && task.sessions.allSatisfy { !$0.isWritingSession }
            }?
            .id
    }

    /// Reopens a terminal onto a session still running under tmux.
    func reattachSession(_ session: WorkspaceSessionItem) async {
        await reattach(session, automatically: false)
    }

    /// Reopens the selected session's terminal without being asked.
    ///
    /// Reattaching is not a decision a person needs to make: the CLI kept running
    /// under tmux while Byori was closed, and opening the app to a session whose
    /// only content is a button to show that session is a step with no
    /// alternative. Only the selected session is attached, not every detached one
    /// — each attach spawns a tmux client and a terminal view, and the sessions
    /// nobody is looking at can stay where they are until selected.
    func autoReattachSelectedSessionIfNeeded() async {
        guard let session = selectedSession,
              session.isDetached,
              !reattachingSessionIDs.contains(session.id),
              !autoReattachFailedSessionIDs.contains(session.id) else {
            return
        }
        await reattach(session, automatically: true)
    }

    private func reattach(_ session: WorkspaceSessionItem, automatically: Bool) async {
        guard session.isDetached, !reattachingSessionIDs.contains(session.id) else { return }
        reattachingSessionIDs.insert(session.id)
        defer { reattachingSessionIDs.remove(session.id) }

        do {
            let result = try await dataSource.reattachSession(id: session.id)
            autoReattachFailedSessionIDs.remove(session.id)
            upsert(result)
            selection = .session(result.session.id)
            await loadInspector()
        } catch {
            // A session that ended while Byori was closed lands here. Reload so
            // the row stops offering a reattach that cannot succeed.
            if automatically {
                // Nobody asked for this attempt, so it does not get to raise a
                // dialog. Remember the failure instead: it must not be retried on
                // every refresh, and the manual button stays as the way to see
                // the error on purpose.
                autoReattachFailedSessionIDs.insert(session.id)
            } else {
                alert = WorkspaceAlert(
                    title: "세션에 다시 연결하지 못했습니다",
                    message: error.localizedDescription
                )
            }
            await load()
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
        guard phase == .ready, let lineage = selectedLineage else {
            inspectorRequestToken = UUID()
            contextRequestToken = UUID()
            inspectorSnapshot = nil
            contextSnapshot = nil
            inspectorPhase = .idle
            contextPhase = .idle
            return
        }

        let token = UUID()
        inspectorRequestToken = token
        // Files and Git describe a checkout, so they need one named. A project row
        // does not name one, and inventing a checkout for it would show files that
        // are not what the selection means.
        let inspectorTask: Task<WorkspaceInspectorSnapshot, Error>?
        if let sourceTree = lineage.sourceTree {
            let request = inspectorRequest(for: lineage, sourceTree: sourceTree)
            inspectorPhase = .loading
            inspectorTask = Task { try await dataSource.loadInspector(request) }
        } else {
            inspectorSnapshot = nil
            inspectorPhase = .idle
            inspectorTask = nil
        }

        let contextToken = UUID()
        contextRequestToken = contextToken
        let contextTask: Task<WorkspaceContextSnapshot, Error>?
        if let sourceTree = contextSourceTree(for: lineage) {
            let request = inspectorRequest(for: lineage, sourceTree: sourceTree)
            contextPhase = .loading
            contextTask = Task { try await dataSource.loadContext(request) }
        } else {
            contextSnapshot = nil
            contextPhase = .idle
            contextTask = nil
        }

        if let inspectorTask {
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
        }

        if let contextTask {
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
    }

    private func inspectorRequest(
        for lineage: WorkspaceLineage,
        sourceTree: WorkspaceSourceTreeItem
    ) -> WorkspaceInspectorRequest {
        WorkspaceInspectorRequest(
            projectID: lineage.project.id,
            sourceTreeID: sourceTree.id,
            taskID: lineage.task?.id,
            sessionID: lineage.session?.id,
            contextDepth: contextDepth,
            memoryView: memoryView
        )
    }

    /// Which checkout a context read is made from.
    ///
    /// A memory space belongs to the project, not to a checkout, so the project row
    /// is a perfectly good place to ask what Byori remembers. Gating the read on a
    /// selected source tree meant clicking a project answered with a spinner that
    /// never resolved — and the empty-graph affordance behind it was never reached.
    private func contextSourceTree(for lineage: WorkspaceLineage) -> WorkspaceSourceTreeItem? {
        lineage.sourceTree
            ?? lineage.project.sourceTrees.first(where: { $0.kind == .primary })
            ?? lineage.project.sourceTrees.first
    }

    private func loadContext() async {
        guard phase == .ready,
              let lineage = selectedLineage,
              let sourceTree = contextSourceTree(for: lineage) else {
            contextRequestToken = UUID()
            contextSnapshot = nil
            contextPhase = .idle
            return
        }
        let request = inspectorRequest(for: lineage, sourceTree: sourceTree)
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
        sourceTree: WorkspaceSourceTreeItem?,
        task: WorkspaceTaskItem?
    )? {
        if let lineage = selectedLineage,
           let sourceTree = lineage.sourceTree,
           lineage.task != nil,
           !sourceTree.hasActiveWritingSession {
            // Continuing an existing task: it lives in that checkout, so there is
            // nothing to choose.
            return (lineage.project, sourceTree, lineage.task)
        }
        // The selected task is already writing. Asking for a session there used to
        // dead-end on "this checkout already has an active writing session",
        // which is a wall built out of an implementation detail — the answer is
        // another checkout, and Byori is the one that knows how to get one.
        if let lineage = selectedLineage {
            return (lineage.project, lineage.sourceTree ?? primarySourceTree(in: lineage.project), nil)
        }
        if let project = selectedProject ?? selectedLineage?.project ?? projects.first {
            return (project, primarySourceTree(in: project), nil)
        }
        return nil
    }

    private func newSessionTarget(
        matching target: WorkspaceNewSessionTarget
    ) -> (
        project: WorkspaceProjectItem,
        sourceTree: WorkspaceSourceTreeItem?,
        task: WorkspaceTaskItem?
    )? {
        guard let project = projects.first(where: { $0.id == target.projectID }) else { return nil }
        // Project-row + deliberately has no checkout ID; a missing named
        // checkout is still rejected rather than replaced behind the user.
        if target.sourceTreeID.isEmpty, target.existingTaskID == nil {
            return (project, primarySourceTree(in: project), nil)
        }
        guard let sourceTree = project.sourceTrees.first(where: { $0.id == target.sourceTreeID }) else {
            // An explicit target must never silently become a different checkout.
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

    /// The project's default base when no exact checkout was selected.
    private func primarySourceTree(in project: WorkspaceProjectItem) -> WorkspaceSourceTreeItem? {
        project.sourceTrees.first { $0.kind == .primary } ?? project.sourceTrees.first
    }

    /// Legacy shell fallback: prefer a free primary checkout before creating one.
    private func freeSourceTree(in project: WorkspaceProjectItem) -> WorkspaceSourceTreeItem? {
        let usable = project.sourceTrees.filter { sourceTree in
            if case .unavailable = sourceTree.workingState { return false }
            return !sourceTree.hasActiveWritingSession
        }
        return usable.first { $0.kind == .primary } ?? usable.first
    }

    /// The checkout a session will run in, creating one when nothing is free.
    ///
    /// Called when the user confirms, not when the sheet opens: cutting a branch
    /// and a directory is a side effect, and a cancelled sheet must not leave one.
    private func resolvedSessionSourceTreeID(
        projectID: String,
        existingTaskID: String?,
        taskTitle: String?
    ) async throws -> String {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw WorkspaceAdapterError.invalidState(
                "Refresh the workspace and start the session again."
            )
        }
        if let existingTaskID {
            guard let owner = project.sourceTrees.first(where: { sourceTree in
                sourceTree.tasks.contains { $0.id == existingTaskID }
            }) else {
                throw WorkspaceAdapterError.invalidState(
                    "That task is no longer in this project."
                )
            }
            return owner.id
        }
        if !newSessionDraft.sourceTreeID.isEmpty,
           let planned = project.sourceTrees.first(where: { $0.id == newSessionDraft.sourceTreeID }),
           !planned.hasActiveWritingSession {
            return planned.id
        }
        if let free = freeSourceTree(in: project) { return free.id }
        return try await createSessionWorktree(in: project, taskTitle: taskTitle)
    }

    /// Cuts the worktree a second concurrent session needs, and returns it.
    ///
    /// The branch is named after the task so the checkout is recognizable in Git
    /// without Byori's UI, and it starts from whatever the project's primary
    /// checkout has checked out — the same base the user would have branched from.
    private func createSessionWorktree(
        in project: WorkspaceProjectItem,
        taskTitle: String?
    ) async throws -> String {
        let branches = try await dataSource.branches(projectID: project.id)
        // A repository with no commits has no branch to start from, and Git cannot
        // cut a worktree from an unborn HEAD. Byori's own new projects get a root
        // commit, so this is a folder that arrived without one: name what is
        // missing instead of passing Git's refusal through.
        guard let startPoint = branches.first(where: { $0.isCheckedOut })?.name else {
            throw WorkspaceAdapterError.invalidState(
                "\(project.name) has no commits yet, so a second checkout cannot be created. "
                    + "Make the first commit, then start the session again."
            )
        }
        let existingNames = Set(branches.filter { !$0.isRemote }.map(\.name))
        let branch = Self.availableBranchName(
            for: taskTitle,
            avoiding: existingNames
        )
        _ = try await dataSource.createSourceTree(
            projectID: project.id,
            branch: branch,
            startPoint: startPoint
        )
        await load(force: true)
        guard let created = projects
            .first(where: { $0.id == project.id })?
            .sourceTrees
            .first(where: { $0.branch == branch }) else {
            throw WorkspaceAdapterError.invalidState(
                "Byori created a checkout for \(branch) but could not find it. Refresh and try again."
            )
        }
        return created.id
    }

    /// `byori/<task-slug>`, suffixed until it is free. Prefixed so these branches
    /// are obviously Byori's and never collide with a hand-made branch name.
    static func availableBranchName(
        for taskTitle: String?,
        avoiding existingNames: Set<String>
    ) -> String {
        let slug = slugifiedBranchComponent(taskTitle)
        let base = existingNames.contains("byori") ? "byori-\(slug)" : "byori/\(slug)"
        guard existingNames.contains(where: { branchNamesConflict(base, $0) }) else { return base }
        for suffix in 2...99 {
            let candidate = "\(base)-\(suffix)"
            if !existingNames.contains(where: { branchNamesConflict(candidate, $0) }) { return candidate }
        }
        return "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func slugifiedBranchComponent(_ title: String?) -> String {
        let scalars = (title ?? "").lowercased().unicodeScalars.map { scalar -> Character in
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
            return isAllowed ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let bounded = String(collapsed.prefix(40))
        // Git rejects a component that ends in a dot or is empty, and a bare
        // "session" is more readable than a generated id for an untitled task.
        let trimmed = bounded.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "session" : trimmed
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

    private var normalizedNewProjectName: String {
        newProjectDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Reviewed session location plan

extension WorkspaceViewModel {
    var sessionPlanSourceTree: WorkspaceSourceTreeItem? {
        projects.first { $0.id == newSessionDraft.projectID }?
            .sourceTrees.first { $0.id == newSessionDraft.sourceTreeID }
    }

    var sessionPlanHasPendingLocation: Bool { pendingSessionLocation != nil }

    var sessionLocationIsLocked: Bool {
        if pendingSessionLocation != nil { return true }
        if case .existing = newSessionDraft.taskChoice { return true }
        return false
    }

    func sessionLocationStrategyLabel(_ strategy: WorkspaceSessionLocationStrategy) -> String {
        switch strategy {
        case .currentCheckout: return "\(sessionPlanSourceTree?.branch ?? "현재 브랜치")에서 직접 작업"
        case .newBranch: return "새 브랜치"
        case .newWorktree: return "새 워크트리 + 브랜치"
        }
    }

    var sessionLocationRecommendation: WorkspaceSessionLocationRecommendation {
        if pendingSessionLocation != nil {
            return .init(strategy: newSessionDraft.locationStrategy, reason: "이미 생성한 작업 위치를 확인하고 이어서 시작합니다. 브랜치나 워크트리를 다시 만들지 않습니다.")
        }
        if sessionLocationIsLocked {
            return .init(strategy: .currentCheckout, reason: "기존 작업의 파일과 이력을 이어가기 위해 같은 위치를 사용합니다.")
        }
        guard let tree = sessionPlanSourceTree else {
            return .init(strategy: .newWorktree, reason: "새 작업을 위한 별도 작업 폴더를 만듭니다.")
        }
        if tree.hasActiveWritingSession {
            return .init(strategy: .newWorktree, reason: "이 위치에서 다른 세션이 작업 중입니다. 파일이 섞이지 않도록 별도 워크트리를 권장합니다.")
        }
        if case .modified = tree.workingState {
            return .init(strategy: .currentCheckout, reason: "아직 커밋하지 않은 변경이 있어 현재 위치에서 이어가도록 제안합니다. 시작 전에 변경 사용을 확인해 주세요.")
        }
        if tree.headRevision == nil {
            return .init(strategy: .currentCheckout, reason: "첫 커밋 전에는 현재 위치에서 작업을 시작합니다.")
        }
        if newSessionDraft.workflowPreset == .codeReview {
            return .init(strategy: .currentCheckout, reason: "코드 리뷰는 선택한 브랜치에서 바로 시작하도록 제안합니다.")
        }
        if ["main", "master"].contains(tree.branch) {
            return .init(strategy: .newBranch, reason: "새 작업의 변경을 \(tree.branch)와 분리하도록 새 브랜치를 제안합니다.")
        }
        return .init(strategy: .currentCheckout, reason: "이미 작업 브랜치 \(tree.branch)에 있으므로 이 위치에서 이어가도록 제안합니다.")
    }

    /// Called by the draft observer as task inputs change. A user's explicit
    /// choice or edited field survives every automatic suggestion refresh.
    func refreshSessionPlanSuggestions() {
        guard isPresentingNewSession, !isStartingSession, pendingSessionLocation == nil else { return }
        if sessionLocationIsLocked || !sessionStrategyWasEdited {
            newSessionDraft.locationStrategy = sessionLocationRecommendation.strategy
        }
        let names = Set(sessionBranches.filter { !$0.isRemote }.map(\.name))
        let suggestedBranch = Self.availableBranchName(for: newSessionDraft.newTaskTitle, avoiding: names)
        if !sessionBranchWasEdited,
           newSessionDraft.newBranchName.isEmpty || newSessionDraft.newBranchName == lastSuggestedSessionBranch {
            newSessionDraft.newBranchName = suggestedBranch
        }
        lastSuggestedSessionBranch = suggestedBranch
        let suggestedBase = sessionPlanSourceTree.map { tree in
            sessionBranches.contains(where: { !$0.isRemote && $0.name == tree.branch })
                ? tree.branch : (tree.headRevision ?? tree.branch)
        } ?? ""
        if !sessionStartPointWasEdited,
           newSessionDraft.startPoint.isEmpty || newSessionDraft.startPoint == lastSuggestedSessionStartPoint {
            newSessionDraft.startPoint = suggestedBase
        }
        lastSuggestedSessionStartPoint = suggestedBase
    }

    func chooseSessionLocationStrategy(_ strategy: WorkspaceSessionLocationStrategy) {
        guard !isStartingSession, !sessionLocationIsLocked else { return }
        sessionStrategyWasEdited = true
        newSessionDraft.locationStrategy = strategy
        newSessionDraft.acceptsModifiedWorkingTree = false
        if strategy == .newBranch {
            sessionStartPointWasEdited = false
            newSessionDraft.startPoint = lastSuggestedSessionStartPoint
        }
        newSessionError = nil
    }

    func updateSessionBranchName(_ name: String) {
        guard !isStartingSession, pendingSessionLocation == nil else { return }
        sessionBranchWasEdited = true
        newSessionDraft.newBranchName = name
    }

    func updateSessionStartPoint(_ ref: String) {
        guard !isStartingSession, pendingSessionLocation == nil, newSessionDraft.locationStrategy == .newWorktree else { return }
        sessionStartPointWasEdited = true
        newSessionDraft.startPoint = ref
    }

    func applySessionLocationRecommendation() {
        guard !isStartingSession, pendingSessionLocation == nil else { return }
        sessionStrategyWasEdited = false
        sessionBranchWasEdited = false
        sessionStartPointWasEdited = false
        newSessionDraft.newBranchName = ""
        newSessionDraft.startPoint = ""
        newSessionDraft.acceptsModifiedWorkingTree = false
        refreshSessionPlanSuggestions()
    }

    func retrySessionBranches() async {
        let projectID = newSessionDraft.projectID
        guard !projectID.isEmpty, !isStartingSession else { return }
        let token = UUID()
        sessionPlanRequestToken = token
        sessionBranchesPhase = .loading
        do {
            let branches = try await dataSource.branches(projectID: projectID)
            guard sessionPlanRequestToken == token, isPresentingNewSession,
                  newSessionDraft.projectID == projectID else { return }
            sessionBranches = branches
            sessionBranchesPhase = .ready
            refreshSessionPlanSuggestions()
        } catch {
            guard sessionPlanRequestToken == token, isPresentingNewSession,
                  newSessionDraft.projectID == projectID else { return }
            sessionBranchesPhase = .failed(error.localizedDescription)
        }
    }

    var sessionPlanValidationMessage: String? {
        // A successful Git operation whose discovery failed is retried by finding
        // that exact result, never by making another branch or worktree.
        if pendingSessionLocation != nil { return nil }
        guard let tree = sessionPlanSourceTree else {
            return "The selected source tree is no longer available."
        }
        if case let .unavailable(reason) = tree.workingState { return reason }
        if case let .existing(taskID) = newSessionDraft.taskChoice {
            guard let task = tree.tasks.first(where: { $0.id == taskID }) else {
                return "The selected task is no longer available in this source tree."
            }
            guard task.status.allowsNewSession else {
                return "This task is \(task.status.label.lowercased()) and cannot start another session."
            }
            if newSessionDraft.locationStrategy != .currentCheckout {
                return "기존 작업은 현재 작업 위치에서 이어가야 합니다."
            }
        }
        if newSessionDraft.locationStrategy != .newWorktree, tree.hasActiveWritingSession {
            return "This source tree already has an active writing session. Choose another source tree."
        }
        switch newSessionDraft.locationStrategy {
        case .currentCheckout:
            if case .modified = tree.workingState, !newSessionDraft.acceptsModifiedWorkingTree {
                return "Confirm that you want to start in a modified working tree."
            }
            return nil
        case .newBranch:
            if case .modified = tree.workingState {
                return "새 브랜치를 만들기 전에 현재 변경을 커밋하거나 보관해 주세요."
            }
        case .newWorktree:
            if let project = projects.first(where: { $0.id == newSessionDraft.projectID }),
               let primary = primarySourceTree(in: project) {
                if case let .unavailable(reason) = primary.workingState { return reason }
            }
        }
        switch sessionBranchesPhase {
        case .idle, .loading: return "브랜치 목록을 확인하는 중입니다…"
        case let .failed(message): return "브랜치 목록을 확인하지 못했습니다: \(message)"
        case .ready: break
        }
        guard tree.headRevision != nil, !sessionBranches.isEmpty else {
            return "첫 커밋이 있어야 새 브랜치나 워크트리를 만들 수 있습니다."
        }
        return sessionBranchFieldsValidationMessage(branches: sessionBranches, tree: tree)
    }

    private func sessionBranchFieldsValidationMessage(
        branches: [WorkspaceGitBranch], tree: WorkspaceSourceTreeItem
    ) -> String? {
        let name = newSessionDraft.newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSessionBranchName(name) else { return "유효한 새 브랜치 이름을 입력해 주세요." }
        if branches.contains(where: { !$0.isRemote && Self.branchNamesConflict(name, $0.name) }) {
            return "브랜치 \(name)이 이미 있거나 기존 브랜치 경로와 겹칩니다. 다른 이름을 입력해 주세요."
        }
        let base = newSessionDraft.startPoint
        guard !base.isEmpty, branches.contains(where: { $0.name == base }) || base == tree.headRevision else {
            return "시작할 기준 브랜치를 선택해 주세요."
        }
        if newSessionDraft.locationStrategy == .newBranch,
           base != tree.branch && base != tree.headRevision {
            return "현재 작업 폴더의 HEAD에서 새 브랜치를 만들어 주세요. 다른 기준은 워크트리에서 선택할 수 있습니다."
        }
        return nil
    }

    private static func branchNamesConflict(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func isValidSessionBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != "@", name != "HEAD", !name.hasPrefix("-"),
              !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.contains(".."), !name.contains("@{"), !name.contains("//"),
              !name.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127
                      || "~^:?*[\\".unicodeScalars.contains($0)
              }) else { return false }
        return name.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }

    private func resolveSessionLocationPlan() async throws -> String {
        let projectID = newSessionDraft.projectID
        // This read is separate from the normal UI refresh gate: a launch cannot
        // rely on the snapshot from when a sheet was opened.
        projects = try await dataSource.loadWorkspace().projects
        if pendingSessionLocation != nil {
            return try adoptPendingSessionLocation()
        }
        guard let tree = sessionPlanSourceTree else {
            throw WorkspaceAdapterError.invalidState("The selected source tree is no longer available.")
        }
        guard tree.branch == sessionPlanBaseBranch, tree.headRevision == sessionPlanBaseRevision else {
            throw WorkspaceAdapterError.invalidState("작업 위치의 브랜치나 커밋이 바뀌었습니다. 창을 다시 열어 작업 위치를 확인해 주세요.")
        }
        if let message = launchConstraintMessage {
            throw WorkspaceAdapterError.invalidState(message)
        }
        if newSessionDraft.locationStrategy == .currentCheckout { return tree.id }
        let branches = try await dataSource.branches(projectID: projectID)
        sessionBranches = branches
        if let message = sessionBranchFieldsValidationMessage(branches: branches, tree: tree) {
            throw WorkspaceAdapterError.invalidState(message)
        }
        let branch = newSessionDraft.newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = newSessionDraft.startPoint
        if newSessionDraft.locationStrategy == .newBranch {
            try await dataSource.createBranch(projectID: projectID, sourceTreeID: tree.id, name: branch, startPoint: base)
            pendingSessionLocation = (projectID, tree.id, nil, branch)
        } else {
            let url = try await dataSource.createSourceTree(projectID: projectID, branch: branch, startPoint: base)
            pendingSessionLocation = (projectID, nil, url.standardizedFileURL.resolvingSymlinksInPath(), branch)
        }
        projects = try await dataSource.loadWorkspace().projects
        return try adoptPendingSessionLocation()
    }

    private func adoptPendingSessionLocation() throws -> String {
        guard let pending = pendingSessionLocation,
              let tree = projects.first(where: { $0.id == pending.projectID })?.sourceTrees.first(where: {
                  $0.branch == pending.branch && (pending.sourceTreeID == $0.id
                      || pending.url == $0.url.standardizedFileURL.resolvingSymlinksInPath())
              }) else {
            throw WorkspaceAdapterError.invalidState("작업 위치는 생성됐지만 아직 조회하지 못했습니다. 다시 시작하면 생성된 위치를 확인합니다.")
        }
        newSessionDraft.sourceTreeID = tree.id
        newSessionDraft.locationStrategy = .currentCheckout
        sessionStrategyWasEdited = true
        sessionPlanBaseBranch = tree.branch
        sessionPlanBaseRevision = tree.headRevision
        pendingSessionLocation = nil
        if let message = launchConstraintMessage { throw WorkspaceAdapterError.invalidState(message) }
        return tree.id
    }
}

// MARK: - Project search and reversible session cleanup

extension WorkspaceViewModel {
    var filteredProjects: [WorkspaceProjectItem] {
        let query = projectSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }
        return projects.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var cleanupScopedProjects: [WorkspaceProjectItem] {
        cleanupSnapshot.projects.filter {
            $0.registration != .approvalRequired && (cleanupProjectID == nil || $0.id == cleanupProjectID)
        }
    }

    var cleanupCandidates: [WorkspaceCleanupTaskItem] {
        cleanupScopedProjects.flatMap { project in
            project.sourceTrees.flatMap { tree in
                tree.tasks.compactMap {
                    WorkspaceCleanupEligibility.candidate(
                        task: $0, project: project, threshold: cleanupThreshold,
                        referenceDate: cleanupReferenceDate
                    )
                }
            }
        }.sorted {
            let left = $0.latestEndedAt ?? .distantFuture
            let right = $1.latestEndedAt ?? .distantFuture
            return left != right ? left < right : $0.id < $1.id
        }
    }

    var cleanupActiveExclusionCount: Int {
        cleanupScopedProjects.reduce(0) { sum, project in
            sum + project.sourceTrees.reduce(0) { count, tree in
                count + tree.tasks.filter(WorkspaceCleanupEligibility.hasActiveSession).count
            }
        }
    }

    var cleanupActiveListIsTruncated: Bool {
        cleanupScopedProjects.contains { cleanupSnapshot.truncatedTaskProjectIDs.contains($0.id) }
    }

    var archivedCleanupTasks: [WorkspaceArchivedTaskItem] {
        cleanupArchivedRows.filter { cleanupProjectID == nil || $0.projectID == cleanupProjectID }
    }

    private func clearCleanupSelections() {
        selectedCleanupTaskIDs = []
        selectedArchivedTaskIDs = []
    }

    func prepareSessionCleanup(projectID: String? = nil, now: Date = Date()) async {
        guard !isPresentingSessionCleanup, !isCleaningSessions else { return }
        cleanupProjectID = projectID
        cleanupThreshold = .thirtyDays
        cleanupReferenceDate = now
        clearCleanupSelections()
        cleanupError = nil
        cleanupResultSummary = nil
        cleanupSnapshot = .init(projects: [])
        cleanupArchivedRows = []
        cleanupArchiveListIsTruncated = false
        isPresentingSessionCleanup = true
        await loadCleanupData()
    }

    func dismissSessionCleanup() {
        guard !isCleaningSessions else { return }
        isPresentingSessionCleanup = false
        cleanupRequestToken = UUID()
    }

    func refreshSessionCleanup() async {
        guard isPresentingSessionCleanup, !isCleaningSessions else { return }
        cleanupError = nil
        await loadCleanupData()
    }

    private func loadCleanupData() async {
        let token = UUID()
        cleanupRequestToken = token
        cleanupPhase = .loading
        cleanupArchivedPhase = .loading
        do {
            let snapshot = try await dataSource.loadWorkspace()
            guard isPresentingSessionCleanup, token == cleanupRequestToken else { return }
            cleanupSnapshot = snapshot
            cleanupProjects = snapshot.projects.filter { $0.registration != .approvalRequired }
                .map { WorkspaceCleanupProject(id: $0.id, name: $0.name) }
            cleanupPhase = .ready
            selectedCleanupTaskIDs.formIntersection(Set(cleanupCandidates.map(\.id)))
        } catch {
            guard isPresentingSessionCleanup, token == cleanupRequestToken else { return }
            cleanupPhase = .failed(error.localizedDescription)
            cleanupSnapshot = .init(projects: [])
            cleanupProjects = []
            cleanupArchivedRows = []
            cleanupArchiveListIsTruncated = false
            cleanupArchivedPhase = .failed("프로젝트 목록을 확인한 뒤 보관함을 다시 읽어 주세요.")
            clearCleanupSelections()
            return
        }
        do {
            let archived = try await dataSource.archivedTasks(projectID: cleanupProjectID)
            guard isPresentingSessionCleanup, token == cleanupRequestToken else { return }
            let registeredIDs = Set(cleanupProjects.map(\.id))
            cleanupArchivedRows = archived.items.filter { registeredIDs.contains($0.projectID) }
            cleanupArchiveListIsTruncated = archived.isTruncated
            cleanupArchivedPhase = .ready
            selectedArchivedTaskIDs.formIntersection(Set(archivedCleanupTasks.filter {
                $0.restoreUnavailableReason == nil
            }.map(\.id)))
        } catch {
            guard isPresentingSessionCleanup, token == cleanupRequestToken else { return }
            cleanupArchivedPhase = .failed(error.localizedDescription)
            cleanupArchivedRows = []
            selectedArchivedTaskIDs = []
        }
    }

    func archiveSelectedCleanupTasks() async {
        guard isPresentingSessionCleanup, !isCleaningSessions, cleanupPhase == .ready else { return }
        let selected = cleanupCandidates.filter { selectedCleanupTaskIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let threshold = cleanupThreshold
        let referenceDate = cleanupReferenceDate
        isCleaningSessions = true
        cleanupError = nil
        cleanupResultSummary = nil
        var successes: Set<String> = []
        var failures: [String] = []
        for item in selected {
            do {
                // Each record is re-read immediately before its own mutation,
                // so a running session or newly added session cannot be swept up
                // merely because the task was selected earlier in this sheet.
                let latest = try await dataSource.loadWorkspace()
                guard let project = latest.projects.first(where: {
                    $0.id == item.projectID && $0.registration != .approvalRequired
                }), let tree = project.sourceTrees.first(where: { $0.id == item.sourceTreeID }),
                      let task = tree.tasks.first(where: { $0.id == item.id }),
                      let current = WorkspaceCleanupEligibility.candidate(
                        task: task, project: project, threshold: threshold, referenceDate: referenceDate
                      ), current.sessionIDs == item.sessionIDs else {
                    failures.append("\(item.title): 상태나 세션 구성이 바뀌어 보관하지 않았습니다.")
                    continue
                }
                try await dataSource.archiveTask(id: item.id)
                successes.insert(item.id)
                if selectedLineage?.task?.id == item.id {
                    selection = .sourceTree(item.sourceTreeID)
                }
            } catch {
                failures.append("\(item.title): \(error.localizedDescription)")
            }
        }
        selectedCleanupTaskIDs.subtract(successes)
        await load(force: true)
        await loadCleanupData()
        cleanupResultSummary = "\(successes.count)개 작업을 보관했습니다."
            + (failures.isEmpty ? "" : " \(failures.count)개는 보관하지 않았습니다.")
        cleanupError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        isCleaningSessions = false
    }

    func restoreSelectedCleanupTasks() async {
        guard isPresentingSessionCleanup, !isCleaningSessions, cleanupArchivedPhase == .ready else { return }
        let selected = archivedCleanupTasks.filter {
            selectedArchivedTaskIDs.contains($0.id) && $0.restoreUnavailableReason == nil
        }
        guard !selected.isEmpty else { return }
        isCleaningSessions = true
        cleanupError = nil
        cleanupResultSummary = nil
        var successes: Set<String> = []
        var failures: [String] = []
        for item in selected {
            do {
                let latest = try await dataSource.loadWorkspace()
                guard latest.projects.contains(where: {
                    $0.id == item.projectID && $0.registration != .approvalRequired
                        && $0.sourceTrees.contains(where: { $0.id == item.sourceTreeID })
                }) else {
                    failures.append("\(item.title): 프로젝트나 원래 작업 위치를 먼저 복원해 주세요.")
                    continue
                }
                // The live adapter validates the exact archived task and its
                // checkout again. Restore only moves metadata; it never starts
                // a terminal or resumes an agent process.
                try await dataSource.restoreTask(id: item.id)
                successes.insert(item.id)
            } catch {
                failures.append("\(item.title): \(error.localizedDescription)")
            }
        }
        selectedArchivedTaskIDs.subtract(successes)
        await load(force: true)
        await loadCleanupData()
        cleanupResultSummary = "\(successes.count)개 작업을 복원했습니다."
            + (failures.isEmpty ? "" : " \(failures.count)개는 복원하지 않았습니다.")
        cleanupError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        isCleaningSessions = false
    }
}
