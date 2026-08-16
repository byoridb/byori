/*
 THESIS: The real agent terminal owns attention; Byori keeps lineage, commands, and durable context within reach without interpreting CLI output.
 OWN-WORLD: Native macOS light chrome, one uninterrupted near-black terminal, 1px separators, system UI type, and restrained semantic state accents.
 STORY: Choose a project and checkout, work directly in its agent terminal, insert an installed Skill or plugin command when useful, then inspect Files, Git, or shared ByoriDB knowledge.
 FIRST VIEWPORT: A 290pt project/checkout outline at left, the selected session's terminal in the center, and a 320pt tabbed inspector at right.
 FORM: Source-tree-first native Operate workspace, option 3 of 3 combined with option 1 Context depth; seed key direct-c+a-20260806.
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md
 */
import AppKit
import ByoriManagerCore
import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var managerModel: ManagerViewModel
    @EnvironmentObject private var workspaceModel: WorkspaceViewModel
    @EnvironmentObject private var terminalController: TerminalSessionController
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceView(
                model: workspaceModel,
                openSettings: openSettings,
                commandGroups: { session in
                    managerModel.commandGroups(for: AgentKind(rawValue: session.providerID))
                },
                insertTerminalText: { session, text in
                    guard let id = session.nativeSessionID.flatMap(UUID.init(uuidString:)) else {
                        return
                    }
                    do {
                        try terminalController.insert(text, into: id)
                    } catch {
                        NSSound.beep()
                    }
                }
            ) { session in
                if let nativeID = session.nativeSessionID.flatMap(UUID.init(uuidString:)),
                   terminalController.snapshot(for: nativeID) != nil {
                    TerminalSessionHost(
                        sessionID: nativeID,
                        controller: terminalController
                    )
                } else {
                    TerminalUnavailableView(session: session)
                }
            }

            Divider()

            WorkspaceStatusBar(
                workspace: workspaceModel,
                manager: managerModel,
                terminals: terminalController,
                openSettings: openSettings
            )
        }
        .accessibilityIdentifier("direct-c+a-20260806")
    }
}

private struct WorkspaceStatusBar: View {
    @ObservedObject var workspace: WorkspaceViewModel
    @ObservedObject var manager: ManagerViewModel
    @ObservedObject var terminals: TerminalSessionController
    let openSettings: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            HStack(spacing: 9) {
                if manager.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                    Text(manager.currentOperation)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    if manager.canCancelCurrentOperation {
                        Button("취소") {
                            manager.cancelCurrentOperation()
                        }
                        .controlSize(.mini)
                    }
                } else {
                    Button(action: openSettings) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(databaseColor)
                                .frame(width: 6, height: 6)
                            Text(databaseLabel)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open Settings")

                    statusDivider

                    if let project = workspace.selectedProject {
                        Label(project.name, systemImage: "folder")
                            .lineLimit(1)
                            .frame(maxWidth: 150, alignment: .leading)
                    } else {
                        Label("No project", systemImage: "folder")
                            .foregroundStyle(.secondary)
                    }

                    if let sourceTree = workspace.selectedSourceTree {
                        statusDivider
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(sourceTree.branch)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // No dot for a clean tree: the label beside it
                            // already says so, and the outline reports the same
                            // fact the same way.
                            if let workingTreeColor = WorkspacePalette
                                .workingTreeColor(sourceTree.workingState) {
                                Circle()
                                    .fill(workingTreeColor)
                                    .frame(width: 6, height: 6)
                            }
                            Text(workingTreeLabel(sourceTree.workingState))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 235, alignment: .leading)
                    }

                    statusDivider

                    Label(
                        "\(terminals.activeSessionCount) active",
                        systemImage: "terminal"
                    )

                    if let contextLabel {
                        statusDivider
                        Label(contextLabel, systemImage: "cylinder.split.1x2")
                            .foregroundStyle(contextColor)
                    }

                    Spacer(minLength: 12)

                    if let session = workspace.selectedSession {
                        Text(sessionSummary(session, now: timeline.date))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task {
                            async let managerRefresh: Void = manager.refresh()
                            async let workspaceRefresh: Void = workspace.load(force: true)
                            _ = await (managerRefresh, workspaceRefresh)
                        }
                    } label: {
                        Label("Refresh status", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(manager.isBusy || workspace.isRefreshing)
                    .help("Refresh workspace and ByoriDB status")
                }
            }
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Workspace status")
        }
    }

    private var statusDivider: some View {
        Divider().frame(height: 13)
    }

    private var databaseLabel: String {
        guard let status = manager.snapshot?.byori else { return "ByoriDB checking" }
        if status.isHealthy { return "ByoriDB ready" }
        if status.serviceLoaded { return "ByoriDB unavailable" }
        return status.isInstalled ? "ByoriDB stopped" : "ByoriDB setup"
    }

    private var databaseColor: Color {
        guard let status = manager.snapshot?.byori else { return .secondary }
        if status.isHealthy { return .green }
        if status.serviceLoaded { return .red }
        return status.isInstalled ? .orange : .red
    }

    private var contextLabel: String? {
        switch workspace.contextPhase {
        case .idle:
            return nil
        case .loading:
            return "Context loading"
        case .ready:
            return "\(workspace.contextSnapshot?.items.count ?? 0) context"
        case .failed:
            return "Context unavailable"
        }
    }

    private var contextColor: Color {
        if case .failed = workspace.contextPhase { return .orange }
        return .secondary
    }

    private func workingTreeLabel(_ state: WorkspaceWorkingTreeStatus) -> String {
        switch state {
        case .clean: return "Clean"
        case let .modified(changeCount): return "\(changeCount) change\(changeCount == 1 ? "" : "s")"
        case .unavailable: return "Git unavailable"
        }
    }

    private func sessionSummary(_ session: WorkspaceSessionItem, now: Date) -> String {
        guard let startedAt = session.startedAt else {
            return "\(session.launchSelectionDisplayName) · \(session.state.label)"
        }
        let duration = max(0, Int((session.endedAt ?? now).timeIntervalSince(startedAt)))
        let hours = duration / 3_600
        let minutes = (duration % 3_600) / 60
        let elapsed = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return "\(session.launchSelectionDisplayName) · \(elapsed)"
    }
}

private struct TerminalUnavailableView: View {
    let session: WorkspaceSessionItem

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Terminal is not attached")
                .font(.title3.weight(.semibold))
            Text(terminalDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.055, green: 0.063, blue: 0.068))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    private var terminalDetail: String {
        if session.state.isActive {
            return "This session belongs to an earlier app process and cannot be reattached. Start a new session from this source tree."
        }
        return "This session has ended. Its provider and model metadata remain in the task history."
    }
}

struct ManagerSettingsView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        SettingsRootView(selection: settingsSelection) { section in
            switch section {
            case .general:
                return AnyView(OverviewView())
            case .agents:
                return AnyView(IntegrationsView())
            case .byoriDB:
                return AnyView(ByoriDatabaseView())
            case .diagnostics:
                return AnyView(ActivityView())
            }
        }
        .alert(item: $model.pendingAction) { action in
            Alert(
                title: Text(action.confirmationTitle),
                message: Text(action.confirmationDetail),
                primaryButton: action.isDestructive
                    ? .destructive(Text("실행")) { model.execute(action) }
                    : .default(Text("실행")) { model.execute(action) },
                secondaryButton: .cancel(Text("취소"))
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isBusy {
                SettingsOperationBar()
                    .environmentObject(model)
            }
        }
        .task { await model.refresh() }
    }

    private var settingsSelection: Binding<WorkspaceSettingsSection> {
        Binding(
            get: {
                switch model.selectedSection ?? .overview {
                case .overview: return .general
                case .integrations: return .agents
                case .knowledgeGraph, .maintenance: return .byoriDB
                case .activity: return .diagnostics
                }
            },
            set: { section in
                switch section {
                case .general: model.selectedSection = .overview
                case .agents: model.selectedSection = .integrations
                case .byoriDB: model.selectedSection = .maintenance
                case .diagnostics: model.selectedSection = .activity
                }
            }
        )
    }
}

private struct SettingsOperationBar: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                // A bare spinner cannot distinguish slow from stuck, so show a
                // determinate bar whenever the operation reports its stages.
                if let progress = model.operationProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(width: 120)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentOperation)
                        .font(.callout.weight(.medium))
                    Text(operationDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if model.canCancelCurrentOperation {
                    Button("취소") {
                        model.cancelCurrentOperation()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var operationDetail: String {
        if model.canCancelCurrentOperation {
            return "Settings 창을 닫아도 계속됩니다. 취소하면 변경 전 runtime을 복구합니다."
        }
        return model.currentOperation == "작업 취소 중…"
            ? "실행 중인 프로세스를 종료하고 변경 전 상태를 복구하고 있습니다."
            : "이 작업은 완료 경계를 보존한 뒤 상태를 다시 확인합니다."
    }
}

/// Names the settings page the sidebar selected.
///
/// `.title2` rather than `.largeTitle`: this is an administration surface inside
/// Byori, and a marketing-sized heading claimed more authority here than the
/// workspace's own panes have.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Says what the last check found, not just what the click will do. Being
/// current used to be indistinguishable from never having checked, and running
/// the update anyway reported it as a failed operation.
private struct AppUpdateButton: View {
    let availability: AppUpdateAvailability
    let action: () -> Void

    var body: some View {
        switch availability {
        case .unknown:
            Button("업데이트 확인 후 설치", action: action)
        case .upToDate:
            Button(action: action) {
                Label("이미 최신 버전", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .help("다시 확인하려면 누르세요.")
        case let .available(update):
            // The version goes in parentheses rather than into the sentence:
            // Korean particles change with the preceding sound, and this one is
            // interpolated.
            Button("업데이트 설치 (\(update.version.description))", action: action)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "설정 개요",
                    subtitle: "Byori 앱과 워크스페이스가 의존하는 로컬 구성 요소의 상태입니다."
                )

                // The app's own version belongs on the first screen Settings
                // opens. It previously sat under the ByoriDB section, which is
                // about the knowledge engine — nobody looking for the app
                // version would think to open it.
                GroupBox("Byori 앱") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("현재 버전") {
                            Text(model.appVersion ?? "알 수 없음")
                        }
                        if let update = model.availableUpdate {
                            LabeledContent("사용 가능") {
                                Text(update.version.description)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Divider()
                        HStack {
                            AppUpdateButton(availability: model.updateAvailability) {
                                model.request(.updateApp, confirmation: true)
                            }
                            Spacer()
                            Text("Developer ID 서명과 Apple 공증을 확인한 뒤에만 교체합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                }

                // One row per requirement, in the order they are needed. This
                // replaced a status-card grid that put every agent CLI on the
                // first screen at equal weight: the cards restated what the
                // Agents page already lists, and a card grid is not part of this
                // app's native pane grammar.
                GroupBox("로컬 요건") {
                    if let snapshot = model.snapshot {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsRequirementRow(
                                title: "ByoriDB",
                                state: byoriStatusLabel(snapshot.byori),
                                detail: byoriDetail(snapshot.byori),
                                isSatisfied: snapshot.byori.isHealthy,
                                action: byoriAction(snapshot.byori)
                            )
                            Divider().padding(.leading, 26)
                            SettingsRequirementRow(
                                title: "tmux",
                                state: snapshot.tmux.stateLabel,
                                detail: snapshot.tmux.detail,
                                isSatisfied: snapshot.tmux.isAvailable,
                                action: snapshot.tmux.actionTitle.map { title in
                                    .init(title: title, isProminent: false) {
                                        model.request(.installTmux, confirmation: true)
                                    }
                                }
                            )
                            Divider().padding(.leading, 26)
                            SettingsRequirementRow(
                                title: "Python 3",
                                state: snapshot.byori.pythonAvailable ? "사용 가능" : "필요",
                                detail: snapshot.byori.pythonAvailable
                                    ? "ByoriDB MCP 런타임이 사용합니다."
                                    : "ByoriDB MCP 런타임에 필요합니다. Python 3를 설치한 뒤 다시 확인하세요.",
                                isSatisfied: snapshot.byori.pythonAvailable,
                                action: nil
                            )
                            Divider()
                                .padding(.top, 10)
                            Text("ByoriDB를 먼저 설치한 뒤, 사용할 에이전트의 MCP와 Skill을 연결하세요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                        }
                        .padding(10)
                        .disabled(model.isBusy)
                    } else {
                        ProgressView("로컬 상태 확인 중…")
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("보안 경계") {
                    Text("Byori는 에이전트 로그인이나 토큰을 읽지 않습니다. 에이전트 설치는 공식 설치 명령만 실행하고, MCP 설정은 지원되는 벤더 CLI를 통해 변경합니다. MCP 설정·Skill·runtime 변경 전에는 백업을 남깁니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
            .padding(24)
        }
    }

    private func byoriStatusLabel(_ status: ByoriStatus) -> String {
        if status.isHealthy { return "실행 중" }
        if status.serviceLoaded { return "응답 없음" }
        return status.isInstalled ? "중지됨" : "설치 필요"
    }

    /// The consequence, not the install path. A stopped engine does not fail
    /// loudly — the agents simply run without memory — so the row has to say so.
    private func byoriDetail(_ status: ByoriStatus) -> String {
        if status.isHealthy {
            return "에이전트가 프로젝트 메모리를 읽고 쓰는 로컬 지식 엔진입니다."
        }
        guard status.isInstalled else {
            return "설치해야 에이전트가 프로젝트 메모리를 사용할 수 있습니다."
        }
        return "지금은 에이전트가 메모리 없이 동작합니다. ByoriDB 페이지에서 서비스를 시작하세요."
    }

    /// An uninstalled engine is the one thing this page should be able to fix
    /// itself. Once it exists, every remaining action belongs to the ByoriDB
    /// page, so the row points there instead of duplicating those controls.
    private func byoriAction(_ status: ByoriStatus) -> SettingsRequirementRow.Action {
        guard status.isInstalled else {
            return .init(title: "설치", isProminent: true) {
                model.request(.installByori, confirmation: true)
            }
        }
        return .init(title: "자세히", isProminent: false) {
            model.selectedSection = .maintenance
        }
    }
}

/// One local dependency: its name, the bounded state Byori verified, and at most
/// one action that changes that state.
private struct SettingsRequirementRow: View {
    struct Action {
        let title: String
        let isProminent: Bool
        let perform: () -> Void
    }

    let title: String
    let state: String
    let detail: String
    let isSatisfied: Bool
    let action: Action?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSatisfied ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isSatisfied ? .green : .orange)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(.body.weight(.medium))
                    Text(state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Combined so the state is read with the name it belongs to, and
            // scoped to the text so the row's action stays its own element.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title) \(state)")
            .accessibilityHint(detail)

            Spacer(minLength: 16)

            if let action {
                if action.isProminent {
                    Button(action.title, action: action.perform)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action.title, action: action.perform)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 9)
    }
}

private struct IntegrationsView: View {
    @EnvironmentObject private var model: ManagerViewModel
    @State private var selectedAgent: AgentKind = .claude

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "에이전트 · Skill",
                    subtitle: "에이전트별 사용자 MCP 등록과 Skill을 확인하고 관리합니다."
                )

                HStack(spacing: 12) {
                    Picker("에이전트", selection: $selectedAgent) {
                        ForEach(AgentKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 340)

                    Spacer()

                    if model.isRefreshingIntegrations {
                        ProgressView()
                            .controlSize(.small)
                        Text("MCP·Skill 확인 중…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.refreshIntegrations() }
                    } label: {
                        Label("목록 새로고침", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy || model.isRefreshingIntegrations)
                }

                AgentInventoryPane(
                    kind: selectedAgent,
                    status: model.snapshot?.agent(selectedAgent),
                    inventory: model.integrationInventory(selectedAgent)
                )
            }
            .padding(24)
        }
        .task {
            if model.integrationInventories.isEmpty {
                await model.refreshIntegrations()
            }
        }
        .alert(item: $model.pendingIntegrationRemoval) { request in
            Alert(
                title: Text(request.confirmationTitle),
                message: Text(request.confirmationDetail),
                primaryButton: .destructive(Text("제거")) {
                    model.executeRemoval(request)
                },
                secondaryButton: .cancel(Text("취소"))
            )
        }
    }
}

private struct AgentInventoryPane: View {
    @EnvironmentObject private var model: ManagerViewModel
    let kind: AgentKind
    let status: AgentStatus?
    let inventory: AgentIntegrationInventory?

    private var descriptor: AgentProviderDescriptor { kind.descriptor }
    private var installAction: ManagerAction { .installCLI(kind) }
    private var connectAction: ManagerAction { .connectMCP(kind) }
    private var disconnectAction: ManagerAction { .disconnectMCP(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: descriptor.systemImage)
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(descriptor.displayName)
                            .font(.title3.weight(.semibold))
                        Label(
                            status?.isInstalled == true ? "설치됨" : "설치 필요",
                            systemImage: status?.isInstalled == true
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(status?.isInstalled == true ? .green : .orange)
                    }
                    Text(status?.version ?? status?.executablePath ?? "CLI가 설치되어 있지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 16)
                // Installation stays capability-driven so a future launch-only
                // provider never receives a button that can only refuse.
                if descriptor.canInstall {
                    Button(status?.isInstalled == true ? "공식 명령으로 업데이트" : "CLI 설치") {
                        model.request(installAction, confirmation: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.isRefreshingIntegrations)
                }
            }
            .padding(.vertical, 12)

            if let limitations = descriptor.limitations {
                Label(limitations, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }

            if kind == .claude {
                ClaudeGatewaySettingsView(settings: model.claudeGatewaySettings)
                    .padding(.vertical, 12)
                Divider()
            }

            InventorySectionHeader(
                title: "MCP 서버",
                count: inventory?.mcpServers.count,
                actionTitle: "설정 파일 편집",
                action: { model.openAgentConfig(kind) }
            )

            ByoriMCPInventoryRow(
                connected: status?.mcpConnected == true,
                connect: { model.request(connectAction) },
                disconnect: { model.request(disconnectAction, confirmation: true) }
            )

            ForEach(otherMCPServers) { server in
                Divider().padding(.leading, 36)
                MCPInventoryRow(server: server)
            }

            if let inventory {
                if inventory.mcpState != .ready {
                    Divider().padding(.leading, 36)
                    InventoryMessageRow(
                        icon: inventory.mcpState == .cliMissing
                            ? "terminal.fill" : "exclamationmark.triangle.fill",
                        title: inventory.mcpState == .cliMissing
                            ? "CLI 설치 후 MCP 목록을 확인할 수 있습니다."
                            : "MCP 목록을 확인하지 못했습니다.",
                        detail: inventory.mcpState == .unavailable
                            ? "에이전트 CLI가 응답하지 않았습니다. 새로고침해 다시 시도하세요."
                            : nil
                    )
                } else if otherMCPServers.isEmpty {
                    Divider().padding(.leading, 36)
                    InventoryMessageRow(
                        icon: "tray",
                        title: "다른 MCP 등록이 없습니다.",
                        detail: kind == .claude
                            ? "claude.ai 커넥터는 발견되면 읽기 전용으로 표시됩니다."
                            : nil
                    )
                }
            } else {
                Divider().padding(.leading, 36)
                InventoryMessageRow(
                    icon: "arrow.clockwise",
                    title: "MCP 목록을 불러오는 중입니다.",
                    detail: nil
                )
            }

            Divider()
                .padding(.top, 12)

            InventorySectionHeader(
                title: "사용자 Skill",
                count: inventory?.skills.count,
                actionTitle: nil,
                action: {}
            )

            ForEach(Array(ManagedSkill.allCases.enumerated()), id: \.element.id) { index, definition in
                if index > 0 { Divider().padding(.leading, 36) }
                let installedSkill = managedSkills.first { $0.name == definition.rawValue }
                ManagedSkillInventoryRow(
                    kind: kind,
                    definition: definition,
                    skill: installedSkill,
                    state: status?.state(for: definition),
                    sync: { model.request(syncAction(for: definition)) },
                    remove: { model.request(removeAction(for: definition), confirmation: true) }
                )
            }

            ForEach(otherSkills) { skill in
                Divider().padding(.leading, 36)
                UserSkillInventoryRow(skill: skill)
            }

            if inventory?.skillsWereTruncated == true {
                Divider().padding(.leading, 36)
                InventoryMessageRow(
                    icon: "ellipsis.circle",
                    title: "안전을 위해 처음 200개 Skill만 표시합니다.",
                    detail: nil
                )
            }
            if inventory?.skillsState == .unavailable {
                Divider().padding(.leading, 36)
                InventoryMessageRow(
                    icon: "exclamationmark.triangle.fill",
                    title: "일부 Skill 폴더를 안전하게 읽지 못했습니다.",
                    detail: "심볼릭 링크 또는 접근 권한을 확인한 뒤 새로고침하세요."
                )
            }
        }
        .disabled(model.isBusy || model.isRefreshingIntegrations)
    }

    private var otherMCPServers: [MCPServerSummary] {
        inventory?.mcpServers.filter { $0.management != .byoriManaged } ?? []
    }

    private var managedSkills: [UserSkillSummary] {
        inventory?.skills.filter(\.isByoriManaged) ?? []
    }

    private var otherSkills: [UserSkillSummary] {
        inventory?.skills.filter { !$0.isByoriManaged } ?? []
    }

    private func syncAction(for skill: ManagedSkill) -> ManagerAction {
        .syncSkill(kind, skill)
    }

    private func removeAction(for skill: ManagedSkill) -> ManagerAction {
        .removeSkill(kind, skill)
    }
}

/// Optional gateway configuration for Claude sessions.
///
/// Collapsed by default with its active state in the label: this is a long form
/// that most users never touch, and inline it pushed the MCP and Skill inventory
/// — the reason the Agents page exists — below the fold. It opens already
/// expanded when a gateway is in effect, because that is a state worth seeing.
private struct ClaudeGatewaySettingsView: View {
    @ObservedObject var settings: ClaudeGatewaySettingsController
    @State private var isExpanded: Bool
    @State private var isShowingAdvanced = false
    @State private var isConfirmingCredentialDeletion = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    init(settings: ClaudeGatewaySettingsController) {
        self.settings = settings
        _isExpanded = State(initialValue: settings.activeConfiguration.isEnabled)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("새 Claude Code 세션을 호환 게이트웨이로 실행")
                            .font(.body.weight(.medium))
                        Text("Claude 설정 파일은 변경하지 않으며, 저장 후 새로 여는 세션에만 적용됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    Toggle("사용", isOn: $settings.draft.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("커스텀 Claude 모델 API 사용")
                }

                if settings.draft.isEnabled {
                    Divider()

                    Picker("연결 방식", selection: presetBinding) {
                        ForEach(ClaudeGatewayPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }

                    compatibilityNotice

                    LabeledContent("게이트웨이 URL") {
                        TextField("https://gateway.example.com", text: $settings.draft.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 300)
                            .disabled(settings.draft.preset == .upstageSolar)
                            .accessibilityHint("Anthropic Messages API 형식을 제공하는 게이트웨이 주소")
                    }

                    LabeledContent("기본 모델") {
                        TextField("게이트웨이 모델 이름", text: $settings.draft.model)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 300)
                    }

                    LabeledContent("인증") {
                        Picker("인증", selection: $settings.draft.authentication) {
                            ForEach(ClaudeGatewayAuthentication.allCases) { authentication in
                                Text(authentication.displayName).tag(authentication)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 220)
                        .disabled(settings.draft.preset == .upstageSolar)
                    }

                    if settings.draft.authentication.requiresCredential {
                        LabeledContent(credentialLabel) {
                            VStack(alignment: .leading, spacing: 4) {
                                SecureField(credentialPlaceholder, text: $settings.credentialInput)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 300)
                                Text(credentialDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    DisclosureGroup("고급 모델 매핑", isExpanded: $isShowingAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(
                                "Opus·Sonnet·Haiku·Fable 요청을 기본 모델로 라우팅",
                                isOn: $settings.draft.routeAllModelFamilies
                            )
                            .disabled(settings.draft.preset == .upstageSolar)
                            LabeledContent("빠른 모델") {
                                TextField(
                                    "빠른 모델 이름 (선택)",
                                    text: $settings.draft.fastModel
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 300)
                            }
                            Text("모델 이름은 게이트웨이가 노출하는 정확한 식별자여야 합니다. 새 세션에서 모델을 직접 고르면 그 선택이 기본 모델보다 우선합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }

                    if settings.draft.usesUnencryptedTransport {
                        Label(
                            "HTTP 연결에서는 프롬프트와 코드가 암호화되지 않습니다. 로컬 게이트웨이가 아니라면 HTTPS를 사용하세요.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } else {
                    Label(
                        "Claude 기본 로그인과 기존 사용자 설정을 그대로 사용합니다.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: 8) {
                    if let savedMessage {
                        Text(savedMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 16)

                    if settings.hasStoredCredential {
                        Button("저장된 키 삭제", role: .destructive) {
                            isConfirmingCredentialDeletion = true
                        }
                    }
                    if settings.activeConfiguration.isEnabled {
                        Button("Claude 기본값 사용") {
                            perform { try settings.restoreClaudeDefault() }
                        }
                    }
                    if hasUnsavedChanges {
                        Button("변경 취소") {
                            settings.discardDraft()
                            savedMessage = nil
                        }
                    }
                    Button("설정 저장") {
                        perform {
                            try settings.save()
                            savedMessage = settings.activeConfiguration.isEnabled
                                ? "새 세션부터 적용됩니다."
                                : "Claude 기본값을 사용합니다."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasUnsavedChanges)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 7) {
                Text("Claude 모델 API").font(.headline)
                Circle()
                    .fill(settings.activeConfiguration.isEnabled ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(activeStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Claude 모델 API. \(activeStatus)")
        }
        .alert("설정을 적용하지 못했습니다", isPresented: errorPresentation) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
        .confirmationDialog(
            "Keychain에서 저장된 Gateway credential을 삭제할까요?",
            isPresented: $isConfirmingCredentialDeletion,
            titleVisibility: .visible
        ) {
            Button("저장된 키 삭제", role: .destructive) {
                perform { try settings.deleteStoredCredential() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("활성 설정이 이 키를 사용 중이면 Claude 기본값으로 함께 복원됩니다.")
        }
    }

    @ViewBuilder
    private var compatibilityNotice: some View {
        switch settings.draft.preset {
        case .custom:
            Label(
                "Anthropic Messages API 형식을 구현한 게이트웨이만 사용할 수 있습니다. OpenAI 호환 URL을 직접 입력하는 기능은 아닙니다.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .upstageSolar:
            VStack(alignment: .leading, spacing: 4) {
                Label("Upstage 공식 Claude Code 연결", systemImage: "checkmark.seal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                Text("Upstage의 Claude Code 통합과 동일하게 api.upstage.ai, Solar Pro 4, 전체 Claude 모델 별칭을 사용합니다. API 키는 이 세션의 Authorization 헤더에만 전달됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var presetBinding: Binding<ClaudeGatewayPreset> {
        Binding(
            get: { settings.draft.preset },
            set: {
                settings.selectPreset($0)
                savedMessage = nil
            }
        )
    }

    private var credentialPlaceholder: String {
        settings.hasStoredCredential ? "저장된 키 유지" : credentialLabel
    }

    private var credentialLabel: String {
        settings.draft.preset == .upstageSolar ? "Upstage API 키" : "게이트웨이 인증 키"
    }

    private var credentialDetail: String {
        settings.hasStoredCredential
            ? "비워 두면 Keychain에 저장된 키를 계속 사용합니다."
            : "키는 macOS Keychain에 저장되며 설정 파일과 화면에는 다시 표시되지 않습니다."
    }

    private var activeStatus: String {
        if settings.activeConfiguration.isEnabled {
            return "적용 중 · \(settings.activeConfiguration.preset.displayName) · 새 세션만"
        }
        return "Claude 기본값 · Byori 환경 주입 없음"
    }

    private var hasUnsavedChanges: Bool {
        settings.draft != settings.activeConfiguration || !settings.credentialInput.isEmpty
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
        } catch {
            savedMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct InventorySectionHeader: View {
    let title: String
    let count: Int?
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Text(title).font(.headline)
            if let count {
                Text("\(count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.top, 15)
        .padding(.bottom, 7)
    }
}

private struct ByoriMCPInventoryRow: View {
    let connected: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? .green : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("byoridb").font(.body.weight(.medium))
                Text(connected ? "연결됨 · Byori 관리" : "미연결 · Byori 관리")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if connected {
                Button("연결 해제", action: disconnect)
                    .controlSize(.small)
            }
            Button(connected ? "다시 연결" : "연결", action: connect)
                .controlSize(.small)
        }
        .padding(.vertical, 8)
    }
}

private struct MCPInventoryRow: View {
    @EnvironmentObject private var model: ManagerViewModel
    let server: MCPServerSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(statusLabel) · \(managementLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if server.management.canRemove {
                Button(role: .destructive) {
                    model.requestRemoval(.mcp(server))
                } label: {
                    Label("MCP 제거", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("\(server.name) MCP 제거")
            } else {
                Text("claude.ai에서 관리")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var statusLabel: String {
        switch server.status {
        case .connected: return "연결됨"
        case .configured: return "구성됨"
        case .authenticationRequired: return "인증 필요"
        case .disabled: return "비활성"
        case .pendingApproval: return "승인 대기"
        case .unavailable: return "연결 실패"
        case .unknown: return "상태 미확인"
        }
    }

    private var statusIcon: String {
        switch server.status {
        case .connected: return "checkmark.circle.fill"
        case .configured: return "circle.fill"
        case .authenticationRequired: return "person.crop.circle.badge.exclamationmark"
        case .disabled: return "pause.circle"
        case .pendingApproval: return "clock"
        case .unavailable: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .connected: return .green
        case .configured, .unknown, .disabled: return .secondary
        case .authenticationRequired, .pendingApproval: return .orange
        case .unavailable: return .red
        }
    }

    private var managementLabel: String {
        switch server.management {
        case .byoriManaged: return "Byori 관리"
        case .unmanaged: return "사용자 등록"
        case .claudeCloudReadOnly: return "claude.ai · 읽기 전용"
        }
    }
}

private struct ManagedSkillInventoryRow: View {
    @EnvironmentObject private var model: ManagerViewModel
    let kind: AgentKind
    let definition: ManagedSkill
    let skill: UserSkillSummary?
    let state: ManagedFileState?
    let sync: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: stateIcon)
                .foregroundStyle(stateColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(definition.rawValue).font(.body.weight(.medium))
                    Text(managedSkillMetadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(skill.map { displayPath($0.skillFilePath) } ?? skillDetail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(skill?.skillFilePath ?? skillDetail)
            }
            Spacer(minLength: 16)
            if let skill {
                Button("편집") { model.openSkill(skill) }
                    .controlSize(.small)
            }
            if state != .missing {
                Button("제거", action: remove)
                    .controlSize(.small)
            }
            Button(state == .current ? "다시 동기화" : "설치/업데이트", action: sync)
                .controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    private var skillStateLabel: String {
        switch state {
        case .current: return "최신 · Byori 관리"
        case .outdated: return "업데이트 필요 · Byori 관리"
        case .legacy: return "이전 경로 · Byori 관리"
        default: return "미설치 · Byori 관리"
        }
    }

    private var skillDetail: String {
        kind == .claude ? "~/.claude/skills/\(definition.rawValue)/SKILL.md"
            : "~/.agents/skills/\(definition.rawValue)/SKILL.md"
    }

    private var stateIcon: String {
        switch state {
        case .current: return "checkmark.circle.fill"
        case .outdated: return "arrow.triangle.2.circlepath.circle.fill"
        case .legacy: return "clock.arrow.circlepath"
        default: return "puzzlepiece.extension"
        }
    }

    private var stateColor: Color {
        switch state {
        case .current: return .green
        case .outdated, .legacy: return .orange
        default: return .secondary
        }
    }

    private var managedSkillMetadata: String {
        guard let skill else { return skillStateLabel }
        let origin: String
        switch skill.origin {
        case .claudeUser: origin = "Claude 사용자"
        case .codexShared: origin = "공유 사용자"
        case .codexLegacy: origin = "Codex 이전 경로"
        }
        return "\(skillStateLabel) · \(origin)"
    }
}

private struct UserSkillInventoryRow: View {
    @EnvironmentObject private var model: ManagerViewModel
    let skill: UserSkillSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(skill.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(originLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(displayPath(skill.skillFilePath))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(skill.skillFilePath)
            }
            Spacer(minLength: 16)
            Button("편집") { model.openSkill(skill) }
                .controlSize(.small)
            Button(role: .destructive) {
                model.requestRemoval(.skill(skill))
            } label: {
                Label("Skill 제거", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .help("\(skill.name) Skill 제거")
        }
        .padding(.vertical, 8)
    }

    private var originLabel: String {
        switch skill.origin {
        case .claudeUser: return "Claude 사용자"
        case .codexShared: return "공유 사용자"
        case .codexLegacy: return "Codex 이전 경로"
        }
    }
}

private struct InventoryMessageRow: View {
    let icon: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
    }
}

private func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

/// The engine's own page.
///
/// Split into what Byori observed, what runs the service, and what installs it.
/// These were one row of five equally weighted buttons, where an ordinary
/// restart and a destructive stop looked like the same kind of thing.
private struct ByoriDatabaseView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "ByoriDB",
                    subtitle: "지식 엔진의 로컬 서비스와 설치를 관리합니다."
                )

                GroupBox("상태") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("설치") {
                            Text(model.snapshot?.byori.isInstalled == true ? "설치됨" : "설치 필요")
                        }
                        LabeledContent("서버 응답") {
                            Text(model.snapshot?.byori.isHealthy == true ? "정상" : "응답 없음")
                        }
                        LabeledContent("launchd") {
                            Text(model.snapshot?.byori.serviceLoaded == true ? "로드됨" : "중지됨")
                        }
                        LabeledContent("Python 3") {
                            Text(model.snapshot?.byori.pythonAvailable == true ? "사용 가능" : "필요")
                        }
                        // The engine binary answers no version question, so this
                        // is what the installer recorded. "기록 없음" is a real
                        // state, not a failure: engines installed before Byori
                        // began recording it have no entry.
                        LabeledContent("엔진 빌드") {
                            if let identity = model.snapshot?.byori.serverVersion {
                                Text(identity)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                            } else {
                                Text("기록 없음")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if model.snapshot?.byori.serverVersion == nil {
                            Text("설치·업데이트를 한 번 실행하면 어떤 엔진이 설치되어 있는지 기록합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                }

                GroupBox("서비스") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("시작") { model.request(.startByori) }
                            Button("재시작") { model.request(.restartByori) }
                            Spacer()
                            Button("중지", role: .destructive) {
                                model.request(.stopByori, confirmation: true)
                            }
                        }
                        Text("에이전트 세션은 ByoriDB를 통해 프로젝트 메모리를 읽고 씁니다. 중지하면 세션은 계속 실행되지만 메모리 없이 동작합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("설치") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("번들 자산으로 설치·복구") {
                                model.request(.installByori, confirmation: true)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("온라인 업데이트") {
                                model.request(.updateByori, confirmation: true)
                            }
                            Spacer()
                        }
                        Text("두 작업 모두 변경 전 runtime을 백업하며, 검증에 실패하면 이전 상태로 되돌립니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("파일") {
                    HStack {
                        Button("서버 로그 열기") { model.openLogs() }
                        Button("설정 백업 열기") { model.openBackups() }
                        Spacer()
                        Text(model.snapshot?.byori.homePath ?? "~/.byoridb")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
            }
            .padding(24)
        }
        .disabled(model.isBusy)
    }
}

private struct ActivityView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "진단",
                subtitle: "설치와 설정 변경 작업의 기록입니다. 인증정보는 기록하지 않습니다."
            )
            if model.activities.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("아직 실행한 작업이 없습니다.")
                        .font(.headline)
                    Text("설치, 연결 또는 유지관리 작업을 실행하면 결과가 여기에 표시됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.activities) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(entry.level))
                            .foregroundStyle(color(entry.level))
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.title).font(.headline)
                                Spacer()
                                Text(entry.date, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(24)
    }

    private func icon(_ level: ActivityEntry.Level) -> String {
        switch level {
        case .info: return "clock"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func color(_ level: ActivityEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .failure: return .red
        }
    }
}
