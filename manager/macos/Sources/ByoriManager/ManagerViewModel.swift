import AppKit
import ByoriManagerCore
import Foundation

enum ManagerSection: String, CaseIterable, Identifiable {
    case overview = "개요"
    case knowledgeGraph = "지식 그래프"
    case integrations = "에이전트 연결"
    case maintenance = "유지관리"
    case activity = "작업 기록"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .knowledgeGraph: return "point.3.connected.trianglepath.dotted"
        case .integrations: return "point.3.connected.trianglepath.dotted"
        case .maintenance: return "wrench.and.screwdriver"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

/// The three states the update button has to tell apart. `AvailableUpdate?`
/// could not: it collapsed "no check has succeeded yet" and "this is the newest
/// release" into the same `nil`, so a current app looked unchecked.
enum AppUpdateAvailability: Equatable {
    case unknown
    case upToDate(AppVersion)
    case available(AvailableUpdate)
}

/// A manager operation. The per-agent cases carry their `AgentKind`, and the
/// skill cases their `ManagedSkill`, instead of existing once per combination:
/// with five providers and more than one skill, a flat list meant every new CLI
/// or skill silently had no way to be installed, connected or synced from
/// Settings.
enum ManagerAction: Identifiable, Equatable {
    case installCLI(AgentKind)
    case connectMCP(AgentKind)
    case disconnectMCP(AgentKind)
    case syncSkill(AgentKind, ManagedSkill)
    case removeSkill(AgentKind, ManagedSkill)
    case installByori
    case updateByori
    case updateApp
    case installTmux
    case startByori
    case stopByori
    case restartByori

    var id: String {
        switch self {
        case let .installCLI(kind): return "install-cli:\(kind.rawValue)"
        case let .connectMCP(kind): return "connect-mcp:\(kind.rawValue)"
        case let .disconnectMCP(kind): return "disconnect-mcp:\(kind.rawValue)"
        case let .syncSkill(kind, skill): return "sync-skill:\(kind.rawValue):\(skill.rawValue)"
        case let .removeSkill(kind, skill): return "remove-skill:\(kind.rawValue):\(skill.rawValue)"
        case .installByori: return "install-byori"
        case .updateByori: return "update-byori"
        case .updateApp: return "update-app"
        case .installTmux: return "install-tmux"
        case .startByori: return "start-byori"
        case .stopByori: return "stop-byori"
        case .restartByori: return "restart-byori"
        }
    }

    var confirmationTitle: String {
        switch self {
        case let .installCLI(kind): return "\(kind.displayName)를 설치하거나 업데이트할까요?"
        case let .disconnectMCP(kind): return "\(kind.displayName)에서 Byori MCP 연결을 해제할까요?"
        case let .removeSkill(kind, skill):
            return "\(kind.displayName)에서 \(skill.rawValue) Skill을 제거할까요?"
        case .installByori: return "번들 자산으로 ByoriDB를 설치할까요?"
        case .updateByori: return "최신 ByoriDB 설치기를 내려받아 업데이트할까요?"
        case .updateApp: return "Byori 앱을 최신 버전으로 업데이트할까요?"
        case .installTmux: return "Homebrew로 tmux를 설치하거나 업그레이드할까요?"
        case .stopByori: return "ByoriDB 서비스를 중지할까요?"
        default: return "이 작업을 실행할까요?"
        }
    }

    var confirmationDetail: String {
        switch self {
        case let .installCLI(kind):
            return "\(kind.displayName)의 공식 설치 명령을 실행합니다. 로그인 정보는 Byori가 다루지 않습니다."
        case .updateByori:
            return "GitHub의 최신 Byori 릴리스 설치기를 실행합니다. 기존 데이터와 root 비밀번호는 보존됩니다."
        case .updateApp:
            return "최신 릴리스의 디스크 이미지를 내려받아 Apple 공증과 개발자 서명을 확인한 뒤 교체합니다. 확인에 실패하면 설치하지 않습니다. 교체를 위해 앱이 한 번 종료되었다가 다시 열립니다."
        case .installByori:
            return "앱에 포함된 MCP·Skill·서비스 자산을 사용하고, 호환되는 ByoriDB 엔진은 GitHub 릴리스에서 다운로드합니다. 기존 runtime은 먼저 백업합니다."
        case .installTmux:
            return "brew install tmux 또는 brew upgrade tmux를 실행합니다. Byori는 세션 유지에만 tmux를 사용하며, 사용자의 ~/.tmux.conf는 읽지도 변경하지도 않습니다."
        case .removeSkill:
            return "기존 파일은 ~/.byori-manager/backups에 백업한 뒤 제거합니다."
        default:
            return "완료 후 상태를 다시 검사합니다."
        }
    }

    var isDestructive: Bool {
        switch self {
        case .stopByori, .disconnectMCP, .removeSkill:
            return true
        default:
            return false
        }
    }

    var progressTitle: String {
        switch self {
        case let .installCLI(kind): return "\(kind.displayName) 설치·업데이트 중…"
        case let .connectMCP(kind): return "\(kind.displayName) MCP 연결 중…"
        case let .disconnectMCP(kind): return "\(kind.displayName) MCP 연결 해제 중…"
        case let .syncSkill(kind, skill):
            return "\(kind.displayName) \(skill.displayName) Skill 동기화 중…"
        case let .removeSkill(kind, skill):
            return "\(kind.displayName) \(skill.displayName) Skill 제거 중…"
        case .installByori: return "ByoriDB 설치·복구 중…"
        case .updateByori: return "ByoriDB 업데이트 중…"
        case .updateApp: return "앱 업데이트 확인·검증 중…"
        case .installTmux: return "tmux 설치·업그레이드 중…"
        case .startByori: return "ByoriDB 시작 중…"
        case .stopByori: return "ByoriDB 중지 중…"
        case .restartByori: return "ByoriDB 재시작 중…"
        }
    }

    /// Only runtime installs have a complete snapshot/rollback boundary.
    /// Other actions remain responsive, but must run to completion so a quit
    /// or late Cancel cannot leave an unverified partial configuration behind.
    var supportsSafeCancellation: Bool {
        switch self {
        case .installByori, .updateByori:
            return true
        default:
            return false
        }
    }

    var cancellationDetail: String {
        switch self {
        case .installByori, .updateByori:
            return "설치 프로세스를 종료하고 변경 전 ByoriDB 상태를 복구했습니다."
        default:
            return "취소 요청 후 최종 상태를 다시 확인했습니다."
        }
    }
}

struct ActivityEntry: Identifiable {
    enum Level { case info, success, failure }

    let id: UUID
    let date: Date
    let title: String
    let detail: String
    let level: Level

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        detail: String,
        level: Level
    ) {
        self.id = id
        self.date = date
        self.title = SafeDisplayText.strippingTerminalControls(title)
            .replacingOccurrences(of: "\n", with: " ")
        let safeDetail = SafeDisplayText.strippingTerminalControls(detail)
        self.detail = safeDetail.count > 12_000
            ? "…\n" + String(safeDetail.suffix(12_000))
            : safeDetail
        self.level = level
    }
}

struct IntegrationRemovalRequest: Identifiable {
    enum Target {
        case mcp(MCPServerSummary)
        case skill(UserSkillSummary)
    }

    let target: Target

    var id: String {
        switch target {
        case let .mcp(server): return "mcp:\(server.id)"
        case let .skill(skill): return "skill:\(skill.id)"
        }
    }

    var confirmationTitle: String {
        switch target {
        case let .mcp(server): return "\(server.name) MCP를 제거할까요?"
        case let .skill(skill): return "\(skill.name) Skill을 제거할까요?"
        }
    }

    var confirmationDetail: String {
        switch target {
        case let .mcp(server):
            return "\(server.agent.displayName)의 공식 CLI로 등록을 제거합니다. 변경 전 설정 파일은 백업합니다."
        case let .skill(skill):
            return "대상: \(skill.directoryPath)\n사용자 Skill 폴더 전체를 백업한 뒤 제거합니다. 심볼릭 링크와 허용 경로 밖의 폴더는 변경하지 않습니다."
        }
    }

    var progressTitle: String {
        switch target {
        case let .mcp(server): return "\(server.name) MCP 제거 중…"
        case let .skill(skill): return "\(skill.name) Skill 제거 중…"
        }
    }
}

@MainActor
final class ManagerViewModel: ObservableObject {
    @Published var selectedSection: ManagerSection? = .overview
    @Published private(set) var snapshot: ManagerSnapshot?
    @Published private(set) var isBusy = false
    @Published private(set) var canCancelCurrentOperation = false
    @Published private(set) var currentOperation = ""
    /// Non-nil only while an operation reports stages, so the shared activity
    /// strip can show a determinate bar instead of an endless spinner.
    @Published private(set) var operationProgress: Double?
    @Published var pendingAction: ManagerAction?
    @Published var pendingIntegrationRemoval: IntegrationRemovalRequest?
    @Published private(set) var activities: [ActivityEntry] = []
    @Published private(set) var integrationInventories: [AgentIntegrationInventory] = []
    @Published private(set) var agentCommandCatalog: [AgentCommandGroup] = []
    @Published private(set) var isRefreshingIntegrations = false
    /// CLIs the user registered themselves. Byori launches these and nothing
    /// more, so they are kept apart from the built-in providers rather than
    /// mixed into `snapshot.agents`, which carries MCP and Skill state that
    /// cannot exist for them.
    @Published private(set) var customProviders: [CustomAgentProvider] = []
    @Published var pendingCustomProviderRemoval: CustomAgentProvider?
    let claudeGatewaySettings: ClaudeGatewaySettingsController

    /// Absent when running outside an app bundle, which is also when the
    /// updater refuses to replace anything.
    let appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// What the last release check found. Byori only reports it — nothing is
    /// downloaded or installed until the user asks, because this app owns live
    /// agent sessions that a surprise relaunch would cut off.
    ///
    /// `unknown` and `upToDate` are kept apart because the button says different
    /// things: having failed to reach GitHub is not the same as being current.
    @Published private(set) var updateAvailability: AppUpdateAvailability = .unknown

    var availableUpdate: AvailableUpdate? {
        if case let .available(update) = updateAvailability { return update }
        return nil
    }

    let service: ManagerService
    private let customAgentStore: CustomAgentProviderStore
    private var operationTask: Task<Void, Never>?
    private var activeActivityID: UUID?
    private var lastOperationHadRollbackFailure = false
    private var updateCheckTask: Task<Void, Never>?
    private var terminateAfterCurrentOperation = false
    /// Set when the user stops ByoriDB in this launch, so autostart leaves it
    /// down. Starting it again from the UI clears it.
    private var didUserStopByori = false

    private static let updateCheckInterval: Duration = .seconds(6 * 60 * 60)

    var hasActiveOperation: Bool { operationTask != nil }

    convenience init(service: ManagerService = ManagerService()) {
        self.init(
            service: service,
            claudeGatewaySettings: ClaudeGatewaySettingsController()
        )
    }

    init(
        service: ManagerService,
        claudeGatewaySettings: ClaudeGatewaySettingsController
    ) {
        self.service = service
        self.claudeGatewaySettings = claudeGatewaySettings
        // Reads the same file the workspace's own store reads. That is safe
        // because the store keeps no state between calls: every read hits the
        // file, so a registration made here is visible to the next launch
        // without either side holding a stale list.
        customAgentStore = CustomAgentProviderStore(paths: service.paths)
        Task { [weak self] in
            await self?.refresh()
            await self?.refreshAgentCommands()
            await self?.startByoriIfStopped()
        }
        startUpdateChecks()
    }

    /// Brings ByoriDB back up when it is installed but not running.
    ///
    /// Every agent session reads and writes memory through ByoriDB. A stopped
    /// service does not fail loudly — the agents simply run without memory —
    /// so leaving it down is a silent downgrade the user has to notice on
    /// their own. The launch agent already has `RunAtLoad`/`KeepAlive`, which
    /// means a service that is down was booted out rather than crashed, and
    /// only a bootstrap brings it back.
    ///
    /// Skipped when the user stopped it themselves in this launch: an explicit
    /// stop that undoes itself is worse than one that sticks.
    private func startByoriIfStopped() async {
        guard !isBusy, let byori = snapshot?.byori else { return }
        guard ByoriAutostart.shouldStart(byori, userStoppedThisLaunch: didUserStopByori) else {
            return
        }
        execute(.startByori)
    }

    deinit {
        updateCheckTask?.cancel()
    }

    private func startUpdateChecks() {
        updateCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdateQuietly()
                try? await Task.sleep(for: Self.updateCheckInterval)
            }
        }
    }

    /// Being offline, rate-limited, or run from a dev build are all ordinary and
    /// none of them are worth an activity entry; the check simply reports
    /// nothing until it next succeeds.
    private func checkForUpdateQuietly() async {
        guard let status = try? await service.checkForAppUpdate() else { return }
        switch status {
        case let .upToDate(version):
            updateAvailability = .upToDate(version)
        case let .available(update):
            updateAvailability = .available(update)
        }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        currentOperation = "상태 확인 중"
        snapshot = await service.snapshot()
        isBusy = false
        currentOperation = ""
    }

    func refreshIntegrations() async {
        guard operationTask == nil, !isRefreshingIntegrations else { return }
        isRefreshingIntegrations = true
        async let inventories = service.integrationInventories()
        async let commands = service.agentCommandCatalog()
        let results = await (inventories, commands)
        if !Task.isCancelled {
            integrationInventories = results.0
            agentCommandCatalog = results.1
        }
        isRefreshingIntegrations = false
    }

    func integrationInventory(_ kind: AgentKind) -> AgentIntegrationInventory? {
        integrationInventories.first { $0.kind == kind }
    }

    func refreshCustomProviders() async {
        customProviders = await customAgentStore.providers()
    }

    /// Registers a user-supplied CLI and reports whether it was accepted, so the
    /// sheet closes only on success and an invalid entry stays on screen next to
    /// the reason it was refused.
    ///
    /// Not routed through `ManagerAction`: this writes one small file rather than
    /// running an installer, and taking over the shared progress bar for it would
    /// block the rest of Settings for no reason.
    func addCustomProvider(
        name: String,
        executablePath: String,
        argumentLine: String
    ) async -> String? {
        do {
            let provider = try await customAgentStore.add(
                displayName: name,
                executablePath: executablePath,
                // The same splitter the new-session sheet uses, so a quoted path
                // behaves identically in both places. Nothing is passed through a
                // shell either way.
                defaultArguments: TerminalLaunchDescriptorFactory.splitArguments(argumentLine)
            )
            customProviders = await customAgentStore.providers()
            activities.insert(ActivityEntry(
                date: Date(),
                title: "CLI 등록 완료: \(provider.displayName)",
                detail: "\(provider.executablePath)\n실행 전용 · MCP와 Skill은 연결하지 않습니다.",
                level: .success
            ), at: 0)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeCustomProvider(_ provider: CustomAgentProvider) {
        pendingCustomProviderRemoval = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await customAgentStore.remove(id: provider.id)
                customProviders = await customAgentStore.providers()
                activities.insert(ActivityEntry(
                    date: Date(),
                    title: "CLI 등록 해제: \(provider.displayName)",
                    detail: "실행 파일은 그대로 두고 Byori의 목록에서만 제거했습니다.",
                    level: .success
                ), at: 0)
            } catch {
                activities.insert(ActivityEntry(
                    date: Date(),
                    title: "CLI 등록 해제 실패",
                    detail: error.localizedDescription,
                    level: .failure
                ), at: 0)
                selectedSection = .activity
            }
        }
    }

    func commandGroups(for kind: AgentKind?) -> [AgentCommandGroup] {
        guard let kind else { return [] }
        return agentCommandCatalog.filter { $0.agent == kind }
    }

    private func refreshAgentCommands() async {
        let commands = await service.agentCommandCatalog()
        if !Task.isCancelled {
            agentCommandCatalog = commands
        }
    }

    func request(_ action: ManagerAction, confirmation: Bool = false) {
        if confirmation {
            pendingAction = action
        } else {
            execute(action)
        }
    }

    func execute(_ action: ManagerAction) {
        pendingAction = nil
        guard !isBusy else { return }
        // Remembered so autostart cannot immediately undo a deliberate stop,
        // and cleared as soon as the user asks for it to run again.
        switch action {
        case .stopByori: didUserStopByori = true
        case .startByori, .restartByori, .installByori: didUserStopByori = false
        default: break
        }
        isBusy = true
        canCancelCurrentOperation = action.supportsSafeCancellation
        lastOperationHadRollbackFailure = false
        currentOperation = action.progressTitle
        let activityID = UUID()
        activeActivityID = activityID
        activities.insert(ActivityEntry(
            id: activityID,
            date: Date(),
            title: currentOperation,
            detail: "",
            level: .info
        ), at: 0)
        operationTask = Task { [weak self] in
            await self?.perform(action, activityID: activityID)
        }
    }

    func requestRemoval(_ target: IntegrationRemovalRequest.Target) {
        pendingIntegrationRemoval = IntegrationRemovalRequest(target: target)
    }

    func executeRemoval(_ request: IntegrationRemovalRequest) {
        pendingIntegrationRemoval = nil
        guard !isBusy, !isRefreshingIntegrations else { return }
        isBusy = true
        canCancelCurrentOperation = false
        lastOperationHadRollbackFailure = false
        currentOperation = request.progressTitle
        let activityID = UUID()
        activeActivityID = activityID
        activities.insert(ActivityEntry(
            id: activityID,
            date: Date(),
            title: currentOperation,
            detail: "",
            level: .info
        ), at: 0)
        operationTask = Task { [weak self] in
            await self?.performRemoval(request, activityID: activityID)
        }
    }

    func cancelCurrentOperation() {
        guard canCancelCurrentOperation, let operationTask else { return }
        canCancelCurrentOperation = false
        currentOperation = "작업 취소 중…"
        if let activeActivityID {
            replaceActivity(
                id: activeActivityID,
                title: currentOperation,
                detail: "안전하게 중단하고 변경 전 상태를 복구하는 중입니다.",
                level: .info
            )
        }
        operationTask.cancel()
    }

    func cancelActiveOperationAndWait() async -> Bool {
        guard let operationTask else { return true }
        if canCancelCurrentOperation {
            cancelCurrentOperation()
        }
        await operationTask.value
        return !lastOperationHadRollbackFailure
    }

    func openLogs() {
        let url = service.paths.logs
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openBackups() {
        let url = service.paths.backups
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openAgentConfig(_ kind: AgentKind) {
        let url = kind == .claude ? service.paths.claudeConfig : service.paths.codexConfig
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
    }

    func openSkill(_ skill: UserSkillSummary) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await service.validatedUserSkillFile(skill)
                NSWorkspace.shared.open(url)
            } catch {
                activities.insert(ActivityEntry(
                    date: Date(),
                    title: "Skill 열기 실패",
                    detail: error.localizedDescription,
                    level: .failure
                ), at: 0)
            }
        }
    }

    private func perform(_ action: ManagerAction, activityID: UUID) async {
        let shouldRefreshIntegrations = selectedSection == .integrations
            || !integrationInventories.isEmpty
        defer {
            isBusy = false
            canCancelCurrentOperation = false
            currentOperation = ""
            operationProgress = nil
            operationTask = nil
            activeActivityID = nil
            if terminateAfterCurrentOperation {
                terminateAfterCurrentOperation = false
                // `operationTask` is nil by now, so the terminate handler sees
                // no operation to drain and can answer immediately.
                Task { @MainActor in
                    NSApplication.shared.terminate(nil)
                }
            }
        }

        do {
            let result: OperationResult
            // Only an update that actually staged a new bundle may quit the app.
            var relaunchForUpdate = false
            switch action {
            case let .installCLI(kind):
                result = try await service.installOrUpdateCLI(kind)
            case .installByori:
                result = try await service.installByoriBundled()
            case .updateByori:
                result = try await service.updateByoriOnline()
            case .updateApp:
                // Replacing the bundle needs the app to quit. Refuse before
                // downloading anything: verifying a release and then failing
                // silently inside the helper minutes later is the worst order
                // to discover that the app was never going to be able to quit.
                let lost = TerminalSessionController.shared.sessionsLostOnQuitCount
                guard lost == 0 else {
                    throw ManagerError.prerequisite(
                        "실행 중인 세션이 \(lost)개 있습니다. 업데이트는 앱을 종료한 뒤 교체하므로 "
                            + "세션을 먼저 끝내 주세요. tmux 로 실행된 세션은 종료 후에도 유지됩니다."
                    )
                }
                let outcome = try await service.updateApp { [weak self] stage in
                    Task { @MainActor in
                        self?.currentOperation = stage.message
                        self?.operationProgress = stage.fraction
                    }
                }
                result = outcome.result
                relaunchForUpdate = outcome.requiresRelaunch
                if case let .alreadyCurrent(version) = outcome {
                    updateAvailability = .upToDate(version)
                }
            case .installTmux:
                result = try await service.installTmux()
                // The controller probed tmux before this install and caches the
                // answer, so the next session would still be started without
                // persistence until the app was relaunched.
                await TerminalSessionController.shared.refreshSessionPersistence()
            case .startByori:
                result = try await service.startService()
            case .stopByori:
                result = try await service.stopService()
            case .restartByori:
                result = try await service.restartService()
            case let .connectMCP(kind):
                result = try await service.connectMCP(kind)
            case let .disconnectMCP(kind):
                result = try await service.disconnectMCP(kind)
            case let .syncSkill(kind, skill):
                result = try await service.syncSkill(kind, skill: skill)
            case let .removeSkill(kind, skill):
                result = try await service.removeSkill(kind, skill: skill)
            }
            // A returned OperationResult is the service's commit boundary.
            // Do not reinterpret a late Cancel as though the mutation failed.
            canCancelCurrentOperation = false
            replaceActivity(
                id: activityID,
                title: result.summary,
                detail: result.detail,
                level: .success
            )
            if relaunchForUpdate {
                // The helper is already waiting on this process: it cannot
                // replace the bundle until the app it belongs to has exited.
                //
                // Quitting has to happen *after* this operation finishes, never
                // from inside it. `applicationShouldTerminate` answers
                // `.terminateLater` while an operation is running and waits for
                // this very task, and `.terminateLater` spins a nested run loop
                // that never returns — the task, the terminate call, and the
                // helper would each wait on the other forever.
                terminateAfterCurrentOperation = true
            }
        } catch {
            let rollbackFailed = isRollbackFailure(error)
            if rollbackFailed {
                lastOperationHadRollbackFailure = true
            }
            if Task.isCancelled, !rollbackFailed {
                replaceActivity(
                    id: activityID,
                    title: "작업 취소됨",
                    detail: action.cancellationDetail,
                    level: .info
                )
            } else {
                replaceActivity(
                    id: activityID,
                    title: "작업 실패",
                    detail: error.localizedDescription,
                    level: .failure
                )
                selectedSection = .activity
            }
        }

        canCancelCurrentOperation = false
        currentOperation = "상태 다시 확인 중…"
        await refreshAfterOperation(includeIntegrations: shouldRefreshIntegrations)
    }

    private func performRemoval(_ request: IntegrationRemovalRequest, activityID: UUID) async {
        defer {
            isBusy = false
            canCancelCurrentOperation = false
            currentOperation = ""
            operationTask = nil
            activeActivityID = nil
        }

        do {
            let result: OperationResult
            switch request.target {
            case let .mcp(server):
                result = try await service.removeMCPRegistration(server)
            case let .skill(skill):
                result = try await service.removeUserSkill(skill)
            }
            replaceActivity(
                id: activityID,
                title: result.summary,
                detail: result.detail,
                level: .success
            )
        } catch {
            if isRollbackFailure(error) {
                lastOperationHadRollbackFailure = true
            }
            replaceActivity(
                id: activityID,
                title: "작업 실패",
                detail: error.localizedDescription,
                level: .failure
            )
            selectedSection = .activity
        }

        currentOperation = "MCP·Skill 목록 다시 확인 중…"
        await refreshAfterOperation(includeIntegrations: true)
    }

    private func refreshAfterOperation(includeIntegrations: Bool) async {
        let refresh = Task.detached(priority: .userInitiated) { [service] in
            let snapshot = await service.snapshot()
            let inventories = includeIntegrations
                ? await service.integrationInventories()
                : nil
            return (snapshot, inventories)
        }
        let refreshed = await refresh.value
        snapshot = refreshed.0
        if let inventories = refreshed.1 {
            integrationInventories = inventories
        }
    }

    private func isRollbackFailure(_ error: Error) -> Bool {
        guard let managerError = error as? ManagerError else { return false }
        if case .rollbackFailed = managerError { return true }
        return false
    }

    private func replaceActivity(
        id: UUID,
        title: String,
        detail: String,
        level: ActivityEntry.Level
    ) {
        let replacement = ActivityEntry(
            id: id,
            date: Date(),
            title: title,
            detail: detail,
            level: level
        )
        if let index = activities.firstIndex(where: { $0.id == id }) {
            activities[index] = replacement
        } else {
            // Defensive fallback: the final result must remain visible even if
            // an external UI reset removed its provisional row.
            activities.insert(replacement, at: 0)
        }
    }
}
