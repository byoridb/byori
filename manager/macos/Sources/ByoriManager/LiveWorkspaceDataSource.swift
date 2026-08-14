import ByoriManagerCore
import Foundation

/// Serializes workspace metadata snapshots with session mutations across their
/// suspension points. Main-actor isolation alone is insufficient because an
/// `await` in a launch can otherwise let a refresh reconcile its transient
/// `created`/`active` session as stale before the PTY has been retained.
@MainActor
private final class WorkspaceOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<T>(
        _ operation: @MainActor () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

@MainActor
final class LiveWorkspaceDataSource: WorkspaceDataSource {
    static let cliDefaultModelID = "cli-default"
    static let cliDefaultModelName = "CLI default"
    static let customModelOptionID = "custom-model"

    var workspaceChanged: (() -> Void)?

    private let projectRegistry: WorkspaceProjectRegistry
    private let checkoutVisibilityStore: WorkspaceCheckoutVisibilityStore
    private let taskStore: WorkspaceTaskStore
    private let git: WorkspaceGitService
    private let workspaceHome: URL
    private let files: LocalWorkspaceFileTreeService
    private let documents: LocalWorkspaceFileDocumentService
    private let managerService: ManagerService
    private let launchFactory: TerminalLaunchDescriptorFactory
    private let terminalController: TerminalSessionController
    private let claudeGatewaySettings: ClaudeGatewaySettingsController
    private let operationGate = WorkspaceOperationGate()
    private let customProviders: CustomAgentProviderStore

    private struct CheckoutKey: Hashable {
        let projectID: String
        let checkoutID: String
    }

    private struct RegisteredCheckout {
        let url: URL
        let kind: WorkspaceCheckoutKind
        let isManaged: Bool
    }

    /// One of the two ways a session can be started, resolved once so the launch
    /// path never has to re-derive it from a raw string.
    private enum ResolvedProvider {
        case builtIn(AgentKind)
        case custom(CustomAgentProvider)
    }

    private var coreProjects: [String: ByoriManagerCore.WorkspaceProject] = [:]
    private var coreTasks: [String: ByoriManagerCore.WorkspaceTask] = [:]
    private var checkouts: [CheckoutKey: RegisteredCheckout] = [:]
    private var taskIDBySessionID: [String: String] = [:]
    private var lastTerminalStatus: [String: TerminalSessionStatus] = [:]
    /// Terminal ids tmux still holds, as of the last workspace load.
    private var detachedSessionIDs: Set<UUID> = []

    init(
        managerService: ManagerService,
        terminalController: TerminalSessionController,
        claudeGatewaySettings: ClaudeGatewaySettingsController,
        workspaceHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".byori", isDirectory: true)
    ) {
        let git = WorkspaceGitService()
        let checkoutVisibilityStore = WorkspaceCheckoutVisibilityStore(home: workspaceHome)
        self.projectRegistry = WorkspaceProjectRegistry(
            home: workspaceHome,
            git: git,
            visibilityStore: checkoutVisibilityStore
        )
        self.checkoutVisibilityStore = checkoutVisibilityStore
        self.taskStore = WorkspaceTaskStore(home: workspaceHome)
        self.git = git
        self.workspaceHome = workspaceHome
        self.files = LocalWorkspaceFileTreeService()
        self.documents = LocalWorkspaceFileDocumentService()
        self.managerService = managerService
        self.claudeGatewaySettings = claudeGatewaySettings
        self.launchFactory = TerminalLaunchDescriptorFactory(paths: managerService.paths)
        self.customProviders = CustomAgentProviderStore(paths: managerService.paths)
        self.terminalController = terminalController
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        try await operationGate.perform { [self] in
            try await loadWorkspaceLocked()
        }
    }

    private func loadWorkspaceLocked() async throws -> WorkspacePresentationSnapshot {
        let projects = try await projectRegistry.projects()
        var projectItems: [WorkspaceProjectItem] = []
        var nextProjects: [String: ByoriManagerCore.WorkspaceProject] = [:]
        var nextTasks: [String: ByoriManagerCore.WorkspaceTask] = [:]
        var nextCheckouts: [CheckoutKey: RegisteredCheckout] = [:]
        var nextTaskBySession: [String: String] = [:]
        // Asked once per load: it spawns a tmux process, and the answer applies
        // to every session in the snapshot.
        let liveDetachedIDs = await terminalController.liveDetachedSessionIDs()
        detachedSessionIDs = liveDetachedIDs

        for project in projects {
            nextProjects[project.id] = project
            let loadedTasks = try await taskStore.tasks(projectID: project.id, limit: 500).tasks
            var reconciledTasks: [ByoriManagerCore.WorkspaceTask] = []
            for task in loadedTasks {
                let reconciled = try await reconcileStaleSessions(
                    in: task,
                    liveDetachedIDs: liveDetachedIDs
                )
                reconciledTasks.append(reconciled)
                nextTasks[reconciled.id] = reconciled
                for session in reconciled.sessions {
                    nextTaskBySession[session.id] = reconciled.id
                }
            }

            var sourceItems: [WorkspaceSourceTreeItem] = []
            for sourceTree in project.sourceTrees {
                let primaryURL = URL(fileURLWithPath: sourceTree.path, isDirectory: true)
                let primaryKey = CheckoutKey(projectID: project.id, checkoutID: sourceTree.id)
                guard nextCheckouts[primaryKey] == nil else {
                    throw WorkspaceAdapterError.invalidState(
                        "Project \(project.name) contains duplicate checkout ID \(sourceTree.id)."
                    )
                }
                nextCheckouts[primaryKey] = RegisteredCheckout(
                    url: primaryURL,
                    kind: .sourceTree,
                    isManaged: false
                )
                sourceItems.append(await makeSourceTreeItem(
                    id: sourceTree.id,
                    projectID: project.id,
                    url: primaryURL,
                    kind: .primary,
                    tasks: reconciledTasks.filter {
                        $0.checkout.kind == .sourceTree && $0.checkout.id == sourceTree.id
                    },
                ))

                for worktree in sourceTree.worktrees {
                    let worktreeURL = URL(fileURLWithPath: worktree.path, isDirectory: true)
                    let worktreeKey = CheckoutKey(projectID: project.id, checkoutID: worktree.id)
                    guard nextCheckouts[worktreeKey] == nil else {
                        throw WorkspaceAdapterError.invalidState(
                            "Project \(project.name) contains duplicate checkout ID \(worktree.id)."
                        )
                    }
                    nextCheckouts[worktreeKey] = RegisteredCheckout(
                        url: worktreeURL,
                        kind: .worktree,
                        isManaged: worktree.isManaged
                    )
                    sourceItems.append(await makeSourceTreeItem(
                        id: worktree.id,
                        projectID: project.id,
                        url: worktreeURL,
                        kind: worktree.isManaged ? .managedWorktree : .externalCheckout,
                        tasks: reconciledTasks.filter {
                            $0.checkout.kind == .worktree && $0.checkout.id == worktree.id
                        },
                        branchFallback: worktree.branch,
                        ))
                }
            }

            let rootURL = URL(fileURLWithPath: project.rootPath, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: rootURL.path)
            let hiddenSourceTrees = try await checkoutVisibilityStore
                .hiddenCheckoutPaths(projectID: project.id)
                .sorted()
                .map { path in
                    WorkspaceHiddenSourceTreeItem(
                        projectID: project.id,
                        url: URL(fileURLWithPath: path, isDirectory: true)
                    )
                }
            projectItems.append(WorkspaceProjectItem(
                id: project.id,
                name: project.name,
                repositoryURL: rootURL,
                memorySpace: project.memorySpace,
                registration: exists ? .trusted : .missing,
                sourceTrees: sourceItems,
                hiddenSourceTrees: hiddenSourceTrees
            ))
        }

        coreProjects = nextProjects
        coreTasks = nextTasks
        checkouts = nextCheckouts
        taskIDBySessionID = nextTaskBySession
        return WorkspacePresentationSnapshot(projects: projectItems)
    }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] {
        guard coreProjects[projectID] != nil else {
            throw WorkspaceAdapterError.invalidState("The selected project is no longer registered.")
        }
        let snapshot = await managerService.snapshot()
        let builtIn = AgentKind.allCases.map { kind in
            let descriptor = kind.descriptor
            let status = snapshot.agent(kind)
            let availability: WorkspaceOptionAvailability = status?.isInstalled == true
                ? .available
                : .unavailable(reason: descriptor.canInstall
                    ? "CLI not installed"
                    : "CLI not installed — Byori does not install this one")

            let defaultModelDetail: String
            if kind == .claude, claudeGatewaySettings.activeConfiguration.isEnabled {
                defaultModelDetail = "Byori gateway · \(claudeGatewaySettings.activeConfiguration.normalizedModel)"
            } else {
                defaultModelDetail = "Resolved by the agent CLI when this session starts"
            }
            var models = [
                WorkspaceModelOption(
                    id: Self.cliDefaultModelID,
                    displayName: Self.cliDefaultModelName,
                    detail: defaultModelDetail,
                    availability: availability
                ),
            ]
            // Offering a model box for a CLI that takes no model flag would only
            // produce a session that refuses to launch.
            if descriptor.supportsModelFlag {
                models.append(WorkspaceModelOption(
                    id: Self.customModelOptionID,
                    displayName: "Custom identifier",
                    detail: "Use an exact model identifier accepted by this CLI",
                    availability: availability,
                    acceptsCustomIdentifier: true,
                    customIdentifierPlaceholder: "Provider model identifier"
                ))
            }

            return WorkspaceProviderOption(
                id: kind.rawValue,
                displayName: descriptor.displayName,
                systemImage: descriptor.systemImage,
                availability: availability,
                models: models
            )
        }

        // Registered CLIs are offered alongside the built-in ones, but never
        // with a model list: Byori does not know their interfaces and would only
        // be inventing a flag.
        let custom = await customProviders.providers().map { provider in
            let isExecutable = FileManager.default.isExecutableFile(atPath: provider.executablePath)
            let availability: WorkspaceOptionAvailability = isExecutable
                ? .available
                : .unavailable(reason: "Registered executable is missing")
            return WorkspaceProviderOption(
                id: provider.id,
                displayName: provider.displayName,
                systemImage: "terminal",
                availability: availability,
                models: [
                    WorkspaceModelOption(
                        id: Self.cliDefaultModelID,
                        displayName: Self.cliDefaultModelName,
                        detail: "Byori does not pass a model to a registered CLI",
                        availability: availability
                    ),
                ]
            )
        }
        return builtIn + custom
    }

    func registerProject(at repositoryURL: URL) async throws {
        try await operationGate.perform { [self] in
            try await registerProjectLocked(at: repositoryURL)
        }
    }

    func inspectProjectFolder(at folderURL: URL) async throws -> WorkspaceProjectFolderStatus {
        let directory = try Self.existingDirectory(folderURL)
        do {
            return .gitRepository(try await git.repositoryRoot(at: directory))
        } catch let error as WorkspaceError {
            if case .notGitRepository = error {
                return .requiresInitialization(directory)
            }
            throw error
        }
    }

    func initializeAndRegisterProject(at folderURL: URL) async throws {
        try await operationGate.perform { [self] in
            let directory = try Self.existingDirectory(folderURL)
            let root: URL
            do {
                root = try await git.initializeRepository(at: directory)
            } catch {
                throw WorkspaceAdapterError.invalidState(
                    "Git could not be initialized in \(directory.path). \(error.localizedDescription)"
                )
            }
            do {
                try await registerProjectLocked(at: root)
            } catch {
                throw WorkspaceAdapterError.invalidState(
                    "Git was initialized in \(root.path), but Byori could not register it. You can open the folder again. \(error.localizedDescription)"
                )
            }
        }
    }

    func createProject(named name: String, in parentDirectoryURL: URL) async throws {
        try await operationGate.perform { [self] in
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validateProjectName(normalizedName)
            let parent = try Self.existingDirectory(parentDirectoryURL)
            let destination = parent
                .appendingPathComponent(normalizedName, isDirectory: true)
                .standardizedFileURL
            guard destination.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL else {
                throw WorkspaceAdapterError.invalidState("Choose a project name inside the selected location.")
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw WorkspaceAdapterError.invalidState(
                    "A file or folder already exists at \(destination.path). Choose another project name."
                )
            }

            do {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            } catch {
                throw WorkspaceAdapterError.invalidState(
                    "The project folder could not be created at \(destination.path). \(error.localizedDescription)"
                )
            }

            let root: URL
            do {
                root = try await git.initializeRepository(at: destination)
            } catch {
                throw WorkspaceAdapterError.invalidState(
                    "The folder was created at \(destination.path), but Git initialization failed. The folder was left in place. \(error.localizedDescription)"
                )
            }
            do {
                try await registerProjectLocked(at: root)
            } catch {
                throw WorkspaceAdapterError.invalidState(
                    "The project and Git repository were created at \(root.path), but Byori could not register them. Open the folder again to retry. \(error.localizedDescription)"
                )
            }
        }
    }

    private func registerProjectLocked(at repositoryURL: URL) async throws {
        _ = try await projectRegistry.registerProject(at: repositoryURL, memorySpace: nil)
    }

    private static func existingDirectory(_ url: URL) throws -> URL {
        let directory = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceAdapterError.invalidState(
                "Choose an existing local folder. \(directory.path) is not available."
            )
        }
        return directory
    }

    private static func validateProjectName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw WorkspaceAdapterError.invalidState(
                "Use a non-empty project name without slashes, colons, or control characters."
            )
        }
    }

    func removeProject(id: String) async throws {
        try await operationGate.perform { [self] in
            guard coreProjects[id] != nil else {
                throw WorkspaceAdapterError.invalidState(
                    "Refresh the workspace before removing this project from Byori."
                )
            }
            try await requireNoActiveWritingSession(projectID: id, checkout: nil)
            _ = try await projectRegistry.removeProject(id: id)
        }
    }

    func archiveTask(id: String) async throws {
        try await operationGate.perform { [self] in
            guard let task = coreTasks[id] else {
                throw WorkspaceAdapterError.invalidState(
                    "Refresh the workspace before removing this task from Byori."
                )
            }
            guard task.sessions.allSatisfy({ $0.status.isTerminal }) else {
                throw WorkspaceAdapterError.invalidState(
                    "Stop the active session before removing this task from Byori."
                )
            }
            _ = try await taskStore.archiveTask(id: id)
        }
    }

    func branches(projectID: String) async throws -> [WorkspaceGitBranch] {
        try await operationGate.perform { [self] in
            guard let project = coreProjects[projectID] else {
                throw WorkspaceAdapterError.invalidState(
                    "Refresh the workspace before listing this project's branches."
                )
            }
            return try await git.branches(at: URL(fileURLWithPath: project.rootPath))
        }
    }

    /// Creates the checkout and lets the ordinary project load discover it, so
    /// there is one code path that decides what a source tree is.
    func createSourceTree(
        projectID: String,
        branch: String,
        startPoint: String?
    ) async throws -> URL {
        try await operationGate.perform { [self] in
            guard let project = coreProjects[projectID] else {
                throw WorkspaceAdapterError.invalidState(
                    "Refresh the workspace before adding a source tree."
                )
            }
            let destination = Self.worktreeDestination(
                home: workspaceHome,
                projectID: projectID,
                branch: branch
            )
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try await git.addWorktree(
                repositoryRoot: URL(fileURLWithPath: project.rootPath),
                at: destination,
                branch: branch,
                creatingFrom: startPoint
            )
            return destination
        }
    }

    /// Worktrees live under Byori's own directory rather than beside the
    /// repository, so creating one never drops an untracked sibling into a
    /// folder the user is working in.
    static func worktreeDestination(home: URL, projectID: String, branch: String) -> URL {
        home
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent(slug(branch), isDirectory: true)
    }

    /// A branch name may contain slashes and characters that are awkward in a
    /// path; the directory only has to be stable, unique, and readable.
    static func slug(_ branch: String) -> String {
        let mapped = branch.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(scalar)
                : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = collapsed.isEmpty ? "branch" : collapsed
        return String(trimmed.prefix(60))
    }

    func hideSourceTree(projectID: String, sourceTreeID: String) async throws {
        try await operationGate.perform { [self] in
            let key = CheckoutKey(projectID: projectID, checkoutID: sourceTreeID)
            guard coreProjects[projectID] != nil, let checkout = checkouts[key] else {
                throw WorkspaceAdapterError.invalidState(
                    "Refresh the workspace before removing this source tree from Byori."
                )
            }
            guard checkout.kind == .worktree else {
                throw WorkspaceAdapterError.invalidState(
                    "The primary source tree represents the project. Remove the project from Byori instead."
                )
            }
            try await requireNoActiveWritingSession(
                projectID: projectID,
                checkout: WorkspaceCheckoutReference(kind: .worktree, id: sourceTreeID)
            )
            try await checkoutVisibilityStore.hideCheckout(projectID: projectID, at: checkout.url)
        }
    }

    func deleteManagedSourceTree(
        projectID: String,
        sourceTreeID: String,
        deletingBranch: Bool
    ) async throws -> WorkspaceGitWorktreeRemovalResult {
        try await operationGate.perform { [self] in
            let key = CheckoutKey(projectID: projectID, checkoutID: sourceTreeID)
            guard let project = coreProjects[projectID], let checkout = checkouts[key] else {
                throw WorkspaceAdapterError.invalidState(
                    "Refresh the workspace before deleting this worktree."
                )
            }
            guard checkout.kind == .worktree, checkout.isManaged else {
                throw WorkspaceAdapterError.invalidState(
                    "Only a worktree created and managed by Byori can be deleted here."
                )
            }

            let taskList = try await taskStore.tasks(projectID: projectID, limit: 1_000)
            guard !taskList.isTruncated else {
                throw WorkspaceAdapterError.invalidState(
                    "Byori could not safely inspect all task records. The worktree was left unchanged."
                )
            }
            let checkoutReference = WorkspaceCheckoutReference(kind: .worktree, id: sourceTreeID)
            guard !taskList.tasks.contains(where: { $0.checkout == checkoutReference }) else {
                throw WorkspaceAdapterError.invalidState(
                    "Remove this worktree's tasks from Byori before deleting the Git worktree."
                )
            }

            let result = try await git.removeWorktree(
                repositoryRoot: URL(fileURLWithPath: project.rootPath, isDirectory: true),
                at: checkout.url,
                deletingBranch: deletingBranch
            )
            // A checkout may have been hidden and restored before deletion.
            // Stale visibility metadata is cleanup-only and must not turn a
            // successful Git deletion into a reported failure.
            try? await checkoutVisibilityStore.unhideCheckout(
                projectID: projectID,
                at: checkout.url
            )
            return result
        }
    }

    func restoreSourceTree(projectID: String, at url: URL) async throws {
        try await operationGate.perform { [self] in
            guard coreProjects[projectID] != nil else {
                throw WorkspaceAdapterError.invalidState(
                    "Refresh the workspace before restoring this source tree."
                )
            }
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            let hiddenPaths = try await checkoutVisibilityStore.hiddenCheckoutPaths(projectID: projectID)
            guard hiddenPaths.contains(canonicalPath) else {
                throw WorkspaceAdapterError.invalidState(
                    "This source tree is no longer hidden. Refresh the workspace and try again."
                )
            }
            try await checkoutVisibilityStore.unhideCheckout(projectID: projectID, at: url)
        }
    }

    private func requireNoActiveWritingSession(
        projectID: String,
        checkout: WorkspaceCheckoutReference?
    ) async throws {
        let taskList = try await taskStore.tasks(projectID: projectID, limit: 1_000)
        guard !taskList.isTruncated else {
            throw WorkspaceAdapterError.invalidState(
                "Byori could not safely inspect all task records. The project was left unchanged."
            )
        }
        let hasActiveSession = taskList.tasks.contains { task in
            (checkout == nil || task.checkout == checkout)
                && task.sessions.contains(where: { !$0.status.isTerminal })
        }
        guard !hasActiveSession else {
            throw WorkspaceAdapterError.invalidState(
                "Stop the active writing session before removing this item from Byori."
            )
        }
    }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        try await operationGate.perform { [self] in
            try await startSessionLocked(request)
        }
    }

    private func startSessionLocked(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        let checkoutKey = CheckoutKey(
            projectID: request.projectID,
            checkoutID: request.sourceTreeID
        )
        guard let project = coreProjects[request.projectID],
              let checkout = checkouts[checkoutKey] else {
            throw WorkspaceAdapterError.invalidState("Refresh the workspace and choose a valid source tree.")
        }
        // A provider id is either a built-in kind or a CLI the user registered.
        // Nothing else may start a session: an unknown id must not fall through
        // to some default executable.
        let resolvedProvider: ResolvedProvider
        if let agent = AgentKind(rawValue: request.providerID) {
            resolvedProvider = .builtIn(agent)
        } else if let custom = await customProviders.provider(id: request.providerID) {
            resolvedProvider = .custom(custom)
        } else {
            throw WorkspaceAdapterError.invalidState("The selected coding provider is not supported.")
        }
        // Validate before creating a new task so an invalid session identity
        // cannot leave behind an empty task record.
        let sessionName = try ByoriManagerCore.WorkspaceSession.normalizedName(request.sessionName)

        let task: ByoriManagerCore.WorkspaceTask
        if let taskID = request.existingTaskID {
            guard let existing = try await taskStore.task(id: taskID),
                  existing.projectID == project.id,
                  existing.checkout == WorkspaceCheckoutReference(
                      kind: checkout.kind,
                      id: request.sourceTreeID
                  ) else {
                throw WorkspaceAdapterError.invalidState("The selected task no longer belongs to this source tree.")
            }
            task = existing
        } else {
            let title = request.newTaskTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else {
                throw WorkspaceAdapterError.invalidState("Enter a task title before starting the session.")
            }
            task = try await taskStore.createTask(
                projectID: project.id,
                checkout: WorkspaceCheckoutReference(
                    kind: checkout.kind,
                    id: request.sourceTreeID
                ),
                title: title
            )
        }

        let explicitModel: String?
        switch request.modelChoice {
        case .cliDefault:
            explicitModel = nil
        case let .exact(identifier):
            explicitModel = identifier
        }
        let gatewayDefaultModel: String?
        if case .builtIn(.claude) = resolvedProvider,
           claudeGatewaySettings.activeConfiguration.isEnabled {
            let configuredModel = claudeGatewaySettings.activeConfiguration.normalizedModel
            gatewayDefaultModel = configuredModel.isEmpty ? nil : configuredModel
        } else {
            gatewayDefaultModel = nil
        }
        // A gateway-backed "CLI default" is not unknown: Byori injects the
        // configured model. Record and pass that exact identity so session
        // history, accessibility, and the actual launch all agree.
        let launchModel = explicitModel ?? gatewayDefaultModel
        let persistedModel = launchModel ?? Self.cliDefaultModelName
        let session = try await taskStore.createSession(
            taskID: task.id,
            name: sessionName,
            provider: WorkspaceProvider(rawValue: request.providerID),
            model: persistedModel
        )
        let terminalID = UUID()
        var didActivateSession = false

        do {
            let descriptor = try makeLaunchDescriptor(
                provider: resolvedProvider,
                model: launchModel,
                workingDirectory: checkout.url,
                terminalID: terminalID,
                environment: ["BYORIDB_MEMORY_SPACE": project.memorySpace],
                additionalArguments: request.additionalArguments
            )
            _ = try await taskStore.updateSessionStatus(
                taskID: task.id,
                sessionID: session.id,
                status: ByoriManagerCore.WorkspaceSessionStatus.active,
                nativeSessionID: terminalID.uuidString.lowercased()
            )
            didActivateSession = true
            lastTerminalStatus[session.id] = .starting
            try await terminalController.start(
                descriptor,
                callbacks: TerminalSessionCallbacks(statusChanged: { [weak self] snapshot in
                    self?.terminalStatusChanged(
                        coreSessionID: session.id,
                        taskID: task.id,
                        snapshot: snapshot
                    )
                })
            )
            if case let .failed(message) = terminalController.snapshot(for: terminalID)?.status {
                throw WorkspaceAdapterError.invalidState(message)
            }
        } catch {
            _ = try? await taskStore.updateSessionStatus(
                taskID: task.id,
                sessionID: session.id,
                status: didActivateSession ? .failed : .cancelled,
                nativeSessionID: terminalID.uuidString.lowercased()
            )
            throw error
        }

        guard let updatedTask = try await taskStore.task(id: task.id),
              let updatedSession = updatedTask.sessions.first(where: { $0.id == session.id }) else {
            throw WorkspaceAdapterError.invalidState("The session started but its metadata could not be reloaded.")
        }
        coreTasks[updatedTask.id] = updatedTask
        taskIDBySessionID[updatedSession.id] = updatedTask.id
        let taskItem = makeTaskItem(updatedTask, sourceTreeID: request.sourceTreeID)
        guard let sessionItem = taskItem.sessions.first(where: { $0.id == updatedSession.id }) else {
            throw WorkspaceAdapterError.invalidState("The session started but could not be selected.")
        }
        return WorkspaceSessionLaunchResult(
            projectID: project.id,
            sourceTreeID: request.sourceTreeID,
            task: taskItem,
            session: sessionItem
        )
    }

    func stopSession(id: String) async throws -> WorkspaceSessionItem {
        try await operationGate.perform { [self] in
            try await stopSessionLocked(id: id)
        }
    }



    func sessionPersistenceWarning() async -> String? {
        switch await terminalController.sessionPersistence() {
        case .available:
            return nil
        case let .unavailable(reason):
            return reason.message
        }
    }

    /// The one place a session's argv is built, so a reattach cannot drift from
    /// the launch it is meant to resume.
    private func makeLaunchDescriptor(
        provider: ResolvedProvider,
        model: String?,
        workingDirectory: URL,
        terminalID: UUID,
        environment: [String: String],
        additionalArguments: [String]
    ) throws -> TerminalLaunchDescriptor {
        switch provider {
        case let .builtIn(agent):
            var launchEnvironment = environment
            var environmentRemovals: Set<String> = []
            if agent == .claude {
                environmentRemovals = claudeGatewaySettings
                    .activeConfiguration
                    .environmentKeysToReplace
                launchEnvironment.merge(try claudeGatewaySettings.launchEnvironment()) { _, gateway in
                    gateway
                }
            }
            return try launchFactory.codingAgent(
                agent,
                model: model,
                workingDirectory: workingDirectory,
                sessionID: terminalID,
                environmentOverrides: launchEnvironment,
                environmentRemovals: environmentRemovals,
                additionalArguments: additionalArguments
            )
        case let .custom(custom):
            return try launchFactory.customAgent(
                custom,
                workingDirectory: workingDirectory,
                sessionID: terminalID,
                environmentOverrides: environment,
                additionalArguments: additionalArguments
            )
        }
    }

    func reattachSession(id: String) async throws -> WorkspaceSessionLaunchResult {
        try await operationGate.perform { [self] in
            try await reattachSessionLocked(id: id)
        }
    }

    /// Reopens a terminal onto a CLI tmux is still running.
    ///
    /// Reuses the session's original terminal id, which is what makes this a
    /// reattach: the tmux session is named after it, so `new-session -A` finds
    /// the running one instead of starting a second CLI beside it.
    private func reattachSessionLocked(id: String) async throws -> WorkspaceSessionLaunchResult {
        guard let taskID = taskIDBySessionID[id],
              let task = try await taskStore.task(id: taskID),
              let session = task.sessions.first(where: { $0.id == id }),
              let project = coreProjects[task.projectID] else {
            throw WorkspaceAdapterError.invalidState("The selected session could not be found.")
        }
        guard let nativeSessionID = session.nativeSessionID,
              let terminalID = UUID(uuidString: nativeSessionID) else {
            throw WorkspaceAdapterError.invalidState("This session has no terminal to reattach to.")
        }
        guard terminalController.snapshot(for: terminalID) == nil else {
            throw WorkspaceAdapterError.invalidState("This session is already open.")
        }
        // Re-checked rather than trusting the last load: the CLI may have
        // exited since. Reattaching then would silently start a *new* CLI under
        // the same name, which reads as the old conversation coming back.
        guard await terminalController.liveDetachedSessionIDs().contains(terminalID) else {
            detachedSessionIDs.remove(terminalID)
            throw WorkspaceAdapterError.invalidState(
                "이 세션은 더 이상 실행 중이 아닙니다. 새 세션을 시작해 주세요."
            )
        }
        let checkoutKey = CheckoutKey(projectID: task.projectID, checkoutID: task.checkout.id)
        guard let checkout = checkouts[checkoutKey] else {
            throw WorkspaceAdapterError.invalidState("Refresh the workspace and choose a valid source tree.")
        }

        let resolvedProvider: ResolvedProvider
        if let agent = AgentKind(rawValue: session.provider.rawValue) {
            resolvedProvider = .builtIn(agent)
        } else if let custom = await customProviders.provider(id: session.provider.rawValue) {
            resolvedProvider = .custom(custom)
        } else {
            throw WorkspaceAdapterError.invalidState("The session's coding provider is no longer available.")
        }

        let descriptor = try makeLaunchDescriptor(
            provider: resolvedProvider,
            model: session.model == Self.cliDefaultModelName ? nil : session.model,
            workingDirectory: checkout.url,
            terminalID: terminalID,
            environment: ["BYORIDB_MEMORY_SPACE": project.memorySpace],
            additionalArguments: []
        )
        lastTerminalStatus[session.id] = .starting
        try await terminalController.start(
            descriptor,
            callbacks: TerminalSessionCallbacks(statusChanged: { [weak self] snapshot in
                self?.terminalStatusChanged(
                    coreSessionID: session.id,
                    taskID: task.id,
                    snapshot: snapshot
                )
            })
        )
        if case let .failed(message) = terminalController.snapshot(for: terminalID)?.status {
            throw WorkspaceAdapterError.invalidState(message)
        }
        detachedSessionIDs.remove(terminalID)

        coreTasks[task.id] = task
        let taskItem = makeTaskItem(task, sourceTreeID: task.checkout.id)
        guard let sessionItem = taskItem.sessions.first(where: { $0.id == session.id }) else {
            throw WorkspaceAdapterError.invalidState("The session reattached but could not be selected.")
        }
        return WorkspaceSessionLaunchResult(
            projectID: task.projectID,
            sourceTreeID: task.checkout.id,
            task: taskItem,
            session: sessionItem
        )
    }

    private func stopSessionLocked(id: String) async throws -> WorkspaceSessionItem {
        guard let taskID = taskIDBySessionID[id],
              let task = try await taskStore.task(id: taskID),
              let session = task.sessions.first(where: { $0.id == id }) else {
            throw WorkspaceAdapterError.invalidState("The selected session could not be found.")
        }
        if let nativeSessionID = session.nativeSessionID,
           let terminalID = UUID(uuidString: nativeSessionID),
           terminalController.snapshot(for: terminalID)?.status.isActive == true {
            try await terminalController.stop(terminalID)
        }
        let updated = try await taskStore.updateSessionStatus(
            taskID: taskID,
            sessionID: id,
            status: ByoriManagerCore.WorkspaceSessionStatus.cancelled,
            nativeSessionID: session.nativeSessionID
        )
        return makeSessionItem(updated, taskID: taskID)
    }



    func loadInspector(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceInspectorSnapshot {
        let checkoutKey = CheckoutKey(
            projectID: request.projectID,
            checkoutID: request.sourceTreeID
        )
        guard coreProjects[request.projectID] != nil,
              let checkout = checkouts[checkoutKey] else {
            throw WorkspaceAdapterError.invalidState("Refresh the workspace before loading the inspector.")
        }
        async let fileSnapshot = files.tree(
            at: checkout.url,
            // Keep the initial inspector broad enough to show the whole repository
            // root. Deeper navigation can be added lazily without letting one large
            // generated directory consume the entire bounded snapshot.
            options: WorkspaceFileTreeOptions(maxEntries: 800, maxDepth: 1)
        )
        async let gitSnapshot = git.status(at: checkout.url, maxChanges: 400)

        let loadedFiles = try await fileSnapshot
        let loadedGit = try await gitSnapshot
        return WorkspaceInspectorSnapshot(
            files: makeFileItems(loadedFiles.nodes),
            git: makeGitItem(loadedGit)
        )
    }

    func loadHistory(projectID: String, sourceTreeID: String) async throws -> WorkspaceGitGraph {
        let url = try checkoutURL(projectID: projectID, sourceTreeID: sourceTreeID)
        let history = try await git.log(at: url, limit: 300)
        return WorkspaceGitGraph.layout(commits: history.commits, isTruncated: history.isTruncated)
    }

    func checkout(projectID: String, sourceTreeID: String, ref: String) async throws {
        let url = try checkoutURL(projectID: projectID, sourceTreeID: sourceTreeID)
        try await operationGate.perform {
            try await git.checkout(at: url, ref: ref)
        }
    }

    func readFile(_ request: WorkspaceFileReadRequest) async throws -> WorkspaceFileDocument {
        try await documents.read(
            at: checkoutURL(projectID: request.projectID, sourceTreeID: request.sourceTreeID),
            relativePath: request.relativePath
        )
    }

    func writeFile(_ request: WorkspaceFileWriteRequest) async throws -> WorkspaceFileDocument {
        try await documents.write(
            at: checkoutURL(projectID: request.projectID, sourceTreeID: request.sourceTreeID),
            relativePath: request.relativePath,
            text: request.text,
            expectedRevision: request.expectedRevision
        )
    }

    /// The source tree's root is the containment boundary every file and Git
    /// operation is resolved against, so it is looked up from the registry
    /// rather than passed in from the view.
    private func checkoutURL(projectID: String, sourceTreeID: String) throws -> URL {
        let key = CheckoutKey(projectID: projectID, checkoutID: sourceTreeID)
        guard coreProjects[projectID] != nil, let checkout = checkouts[key] else {
            throw WorkspaceAdapterError.invalidState(
                "Refresh the workspace before reading this source tree."
            )
        }
        return checkout.url
    }

    func loadContext(_ request: WorkspaceInspectorRequest) async throws -> WorkspaceContextSnapshot {
        let checkoutKey = CheckoutKey(
            projectID: request.projectID,
            checkoutID: request.sourceTreeID
        )
        guard let project = coreProjects[request.projectID],
              checkouts[checkoutKey] != nil else {
            throw WorkspaceAdapterError.invalidState("Refresh the workspace before loading context.")
        }
        let context = await projectContext(
            project: project,
            sourceTreeID: request.sourceTreeID,
            taskID: request.taskID,
            depth: request.contextDepth
        )
        return WorkspaceContextSnapshot(items: context.items, isTruncated: context.isTruncated)
    }

    /// Marks sessions that did not survive as terminal.
    ///
    /// `liveDetachedIDs` is what tmux still holds. Without consulting it, every
    /// session that outlived a quit would be marked failed on the next launch —
    /// the running CLI would still be there, but Byori would have recorded it
    /// as dead and offered no way back to it.
    private func reconcileStaleSessions(
        in task: ByoriManagerCore.WorkspaceTask,
        liveDetachedIDs: Set<UUID>
    ) async throws -> ByoriManagerCore.WorkspaceTask {
        for session in task.sessions where !session.status.isTerminal {
            let attached: Bool
            if let nativeID = session.nativeSessionID,
               let terminalID = UUID(uuidString: nativeID),
               terminalController.snapshot(for: terminalID) != nil || liveDetachedIDs.contains(terminalID) {
                attached = true
            } else {
                attached = false
            }
            guard !attached else { continue }
            let terminalStatus: ByoriManagerCore.WorkspaceSessionStatus = session.status == .created
                ? .cancelled
                : .failed
            _ = try await taskStore.updateSessionStatus(
                taskID: task.id,
                sessionID: session.id,
                status: terminalStatus,
                nativeSessionID: session.nativeSessionID
            )
        }
        return try await taskStore.task(id: task.id) ?? task
    }

    private func makeSourceTreeItem(
        id: String,
        projectID: String,
        url: URL,
        kind: WorkspaceSourceTreeItemKind,
        tasks: [ByoriManagerCore.WorkspaceTask],
        branchFallback: String? = nil,
    ) async -> WorkspaceSourceTreeItem {
        do {
            let status = try await git.status(at: url, maxChanges: 400)
            return WorkspaceSourceTreeItem(
                id: id,
                projectID: projectID,
                name: status.branch,
                url: url,
                kind: kind,
                branch: status.branch,
                headRevision: status.headRevision,
                workingState: status.isClean ? .clean : .modified(changeCount: status.changes.count),
                tasks: tasks.map {
                    makeTaskItem($0, sourceTreeID: id)
                }
            )
        } catch {
            let fallback = branchFallback ?? url.lastPathComponent
            return WorkspaceSourceTreeItem(
                id: id,
                projectID: projectID,
                name: fallback,
                url: url,
                kind: kind,
                branch: fallback,
                headRevision: nil,
                workingState: .unavailable(reason: error.localizedDescription),
                tasks: tasks.map {
                    makeTaskItem($0, sourceTreeID: id)
                }
            )
        }
    }

    private func makeTaskItem(
        _ task: ByoriManagerCore.WorkspaceTask,
        sourceTreeID: String
    ) -> WorkspaceTaskItem {
        return WorkspaceTaskItem(
            id: task.id,
            sourceTreeID: sourceTreeID,
            title: task.title,
            status: taskItemStatus(task.status),
            createdAt: task.createdAt,
            sessions: task.sessions.map { makeSessionItem($0, taskID: task.id) }
        )
    }

    private func taskItemStatus(
        _ status: ByoriManagerCore.WorkspaceTaskStatus
    ) -> WorkspaceTaskItemStatus {
        switch status {
        case .open: return .open
        case .active: return .active
        case .completed: return .completed
        case .blocked: return .blocked
        case .cancelled: return .cancelled
        }
    }

    private func makeSessionItem(
        _ session: ByoriManagerCore.WorkspaceSession,
        taskID: String
    ) -> WorkspaceSessionItem {
        let kind = AgentKind(rawValue: session.provider.rawValue)
        let terminalID = session.nativeSessionID.flatMap(UUID.init(uuidString:))
        let terminalSnapshot = terminalID.flatMap { terminalController.snapshot(for: $0) }
        // Detached only while this app holds no terminal: once reattached the
        // session is an ordinary running one again.
        let isDetached = terminalSnapshot == nil
            && terminalID.map(detachedSessionIDs.contains) == true
        var presentation = presentationStatus(core: session.status, terminal: terminalSnapshot?.status)
        if isDetached {
            presentation = (.running, "Detached — running in tmux")
        }
        return WorkspaceSessionItem(
            id: session.id,
            taskID: taskID,
            name: session.name,
            providerID: session.provider.rawValue,
            providerName: kind?.displayName ?? session.provider.rawValue,
            providerSystemImage: kind?.descriptor.systemImage ?? "terminal",
            modelID: session.model == Self.cliDefaultModelName ? Self.cliDefaultModelID : session.model,
            modelName: session.model,
            state: presentation.status,
            statusDetail: presentation.detail,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            nativeSessionID: session.nativeSessionID,
            isDetached: isDetached
        )
    }

    private func presentationStatus(
        core: ByoriManagerCore.WorkspaceSessionStatus,
        terminal: TerminalSessionStatus?
    ) -> (status: WorkspaceSessionItemStatus, detail: String?) {
        if let terminal {
            switch terminal {
            case .starting: return (.preparing, "Starting PTY")
            case .running: return (.running, nil)
            case .stopping: return (.running, "Stopping…")
            case .stopped: return (.cancelled, nil)
            case let .exited(code):
                return code == 0 ? (.completed, nil) : (.failed, code.map { "Exit code \($0)" })
            case let .failed(message): return (.failed, message)
            }
        }
        switch core {
        case .created: return (.preparing, nil)
        case .active: return (.failed, "Session process is not attached to this app instance.")
        case .completed: return (.completed, nil)
        case .failed: return (.failed, nil)
        case .cancelled: return (.cancelled, nil)
        }
    }

    private func terminalStatusChanged(
        coreSessionID: String,
        taskID: String,
        snapshot: TerminalSessionSnapshot
    ) {
        guard lastTerminalStatus[coreSessionID] != snapshot.status else { return }
        lastTerminalStatus[coreSessionID] = snapshot.status
        let next = terminalCompletionStatus(snapshot.status)
        guard let next else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await taskStore.updateSessionStatus(
                taskID: taskID,
                sessionID: coreSessionID,
                status: next,
                nativeSessionID: snapshot.id.uuidString.lowercased()
            )
            workspaceChanged?()
        }
    }

    private func terminalCompletionStatus(
        _ status: TerminalSessionStatus
    ) -> ByoriManagerCore.WorkspaceSessionStatus? {
        switch status {
        case .starting, .running, .stopping:
            return nil
        case .stopped:
            return .cancelled
        case let .exited(code):
            return code == 0 ? .completed : .failed
        case .failed:
            return .failed
        }
    }

    private func projectContext(
        project: ByoriManagerCore.WorkspaceProject,
        sourceTreeID: String,
        taskID: String?,
        depth: WorkspaceContextDepth
    ) async -> (items: [WorkspaceContextItem], isTruncated: Bool) {
        let limit: Int
        switch depth {
        case .focused: limit = 8
        case .related: limit = 18
        case .broad: limit = 40
        }
        do {
            let graph = try await managerService.loadKnowledgeGraph(
                space: project.memorySpace,
                limit: 200
            )

            var anchorTerms = [project.id, project.name, sourceTreeID]
            for sourceTree in project.sourceTrees {
                if sourceTree.id == sourceTreeID {
                    anchorTerms.append(URL(fileURLWithPath: sourceTree.path).lastPathComponent)
                }
                if let worktree = sourceTree.worktrees.first(where: { $0.id == sourceTreeID }) {
                    if let branch = worktree.branch { anchorTerms.append(branch) }
                    anchorTerms.append(URL(fileURLWithPath: worktree.path).lastPathComponent)
                }
            }
            if let taskID { anchorTerms.append(taskID) }
            anchorTerms = Array(Set(anchorTerms.compactMap { term in
                let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.count >= 3 ? normalized : nil
            }))

            let anchorIDs = Set(graph.nodes.compactMap { node -> Int64? in
                let name = node.name.lowercased()
                return anchorTerms.contains(where: name.contains) ? node.id : nil
            })
            var adjacency: [Int64: Set<Int64>] = [:]
            for edge in graph.edges {
                adjacency[edge.source, default: []].insert(edge.target)
                adjacency[edge.target, default: []].insert(edge.source)
            }
            let maximumHops: Int
            switch depth {
            case .focused: maximumHops = 0
            case .related: maximumHops = 1
            case .broad: maximumHops = 2
            }
            var distances = Dictionary(uniqueKeysWithValues: anchorIDs.map { ($0, 0) })
            var frontier = anchorIDs
            if maximumHops > 0 {
                for hop in 1...maximumHops {
                    var next: Set<Int64> = []
                    for nodeID in frontier {
                        for neighbor in adjacency[nodeID, default: []] where distances[neighbor] == nil {
                            distances[neighbor] = hop
                            next.insert(neighbor)
                        }
                    }
                    frontier = next
                    if frontier.isEmpty { break }
                }
            }

            var nodes = graph.nodes.sorted { lhs, rhs in
                let leftDistance = distances[lhs.id] ?? (maximumHops + 1)
                let rightDistance = distances[rhs.id] ?? (maximumHops + 1)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
                return lhs.id < rhs.id
            }
            if nodes.count > limit { nodes = Array(nodes.prefix(limit)) }

            let bodyNodes = Array(nodes.prefix(min(nodes.count, 18)))
            let managerService = self.managerService
            let memorySpace = project.memorySpace
            let bodies = await withTaskGroup(
                of: (Int64, String?).self,
                returning: [Int64: String].self
            ) { group in
                for node in bodyNodes {
                    group.addTask {
                        let body = try? await managerService.loadKnowledgeBody(
                            nodeID: node.id,
                            tag: node.tag,
                            space: memorySpace
                        )
                        return (node.id, body)
                    }
                }
                var result: [Int64: String] = [:]
                for await (nodeID, body) in group {
                    if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result[nodeID] = body
                    }
                }
                return result
            }

            let items = nodes.map { node in
                let hop = distances[node.id]
                let relation = hop.map { $0 == 0 ? "match" : "\($0)-hop" } ?? "recent"
                return WorkspaceContextItem(
                    id: String(node.id),
                    kind: node.kind.replacingOccurrences(of: "_", with: " ").capitalized,
                    title: node.name,
                    summary: boundedContext(bodies[node.id] ?? node.name),
                    provenance: "ByoriDB · \(project.memorySpace) · \(relation)",
                    updatedAt: node.updatedAt,
                    tags: [node.tag, relation]
                )
            }
            return (
                items,
                graph.nodesTruncated || graph.edgesTruncated || graph.nodes.count > items.count
            )
        } catch {
            return ([WorkspaceContextItem(
                id: "byoridb-unavailable",
                kind: "Unavailable",
                title: "ByoriDB context unavailable",
                summary: error.localizedDescription,
                provenance: "Project space · \(project.memorySpace)",
                updatedAt: nil,
                tags: ["Operational status"]
            )], false)
        }
    }

    private func makeFileItems(
        _ nodes: [ByoriManagerCore.WorkspaceFileNode]
    ) -> [WorkspaceFileItem] {
        var index = 0
        func level(_ depth: Int) -> [WorkspaceFileItem] {
            var result: [WorkspaceFileItem] = []
            while index < nodes.count, nodes[index].depth == depth {
                let node = nodes[index]
                index += 1
                let kind: WorkspaceFileItemKind
                switch node.kind {
                case .directory: kind = .folder
                case .symbolicLink: kind = .symlink
                case .file, .other: kind = .file
                }
                let children: [WorkspaceFileItem]?
                if kind == .folder, index < nodes.count, nodes[index].depth > depth {
                    let nested = level(depth + 1)
                    children = nested.isEmpty ? nil : nested
                } else {
                    children = nil
                }
                result.append(WorkspaceFileItem(
                    id: node.relativePath,
                    name: node.name,
                    kind: kind,
                    children: children
                ))
            }
            return result
        }
        return level(0)
    }

    private func makeGitItem(
        _ snapshot: WorkspaceGitStatusSnapshot
    ) -> WorkspaceGitSummaryItem {
        WorkspaceGitSummaryItem(
            branch: snapshot.branch,
            headRevision: snapshot.headRevision.map { String($0.prefix(12)) },
            upstream: nil,
            aheadCount: 0,
            behindCount: 0,
            changes: snapshot.changes.map { change in
                WorkspaceGitChangeItem(
                    id: change.id,
                    path: change.path,
                    status: gitChangeStatus(change.status)
                )
            }
        )
    }

    private func gitChangeStatus(_ raw: String) -> WorkspaceGitChangeStatusItem {
        if raw == "??" { return .untracked }
        if raw.contains("U") || ["AA", "DD"].contains(raw) { return .conflicted }
        if raw.contains("R") { return .renamed }
        if raw.contains("D") { return .deleted }
        if raw.contains("A") { return .added }
        return .modified
    }

    private func boundedContext(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 700 else { return normalized }
        return String(normalized.prefix(700)) + "…"
    }
}
