/*
 THESIS: Project lineage stays visible while one real agent terminal owns attention; refuse settings dashboards and automatic fan-out.
 OWN-WORLD: Native macOS light chrome, edge-bound near-black terminal, 1px separators, system UI type, monospaced terminal type, and restrained teal state accents.
 STORY: Choose a project and source tree, enter a task's launch-selected agent/model session, work interactively, then inspect Files, Git, or shared ByoriDB knowledge.
 FIRST VIEWPORT: A 290pt project/source-tree outline at left, dominant terminal center, and 320pt tabbed inspector at right; New Session sits beside the selected task.
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
            WorkspaceView(model: workspaceModel, openSettings: openSettings) { session in
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
                            Circle()
                                .fill(workingTreeColor(sourceTree.workingState))
                                .frame(width: 6, height: 6)
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

    private func workingTreeColor(_ state: WorkspaceWorkingTreeStatus) -> Color {
        switch state {
        case .clean: return .green
        case .modified: return .orange
        case .unavailable: return .red
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
                return AnyView(MaintenanceView())
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
                ProgressView()
                    .controlSize(.small)
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

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Byori",
                    subtitle: "워크스페이스를 지원하는 ByoriDB와 코딩 에이전트 연결 상태"
                )

                if let snapshot = model.snapshot {
                    HStack(spacing: 14) {
                        StatusCard(
                            title: "ByoriDB",
                            value: byoriStatusLabel(snapshot.byori),
                            detail: snapshot.byori.serverVersion ?? snapshot.byori.homePath,
                            icon: "cylinder.split.1x2",
                            healthy: snapshot.byori.isHealthy
                        )
                        ForEach(snapshot.agents) { agent in
                            StatusCard(
                                title: agent.kind.displayName,
                                value: agent.isInstalled ? "설치됨" : "설치 필요",
                                detail: agent.version ?? agent.executablePath ?? "CLI를 찾지 못했습니다.",
                                icon: agent.kind == .claude ? "sparkles" : "terminal",
                                healthy: agent.isInstalled
                            )
                        }
                    }

                    GroupBox("빠른 설정") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("1. ByoriDB를 설치한 뒤 2. 사용할 에이전트의 MCP와 Skill을 연결하세요.")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("ByoriDB 설치/복구") {
                                    model.request(.installByori, confirmation: true)
                                }
                                .buttonStyle(.borderedProminent)
                                Button("에이전트 연결 열기") {
                                    model.selectedSection = .integrations
                                }
                                Button("로그 열기") { model.openLogs() }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("보안 경계") {
                        Text("Byori는 Claude/Codex 로그인이나 토큰을 읽지 않습니다. 에이전트 설치는 공식 설치 스크립트만 실행하고, MCP 설정은 각 벤더 CLI를 통해 변경합니다. MCP 설정·Skill·runtime 변경 전에는 백업을 남깁니다.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                } else {
                    ProgressView("로컬 상태 확인 중…")
                }
            }
            .padding(28)
        }
    }

    private func byoriStatusLabel(_ status: ByoriStatus) -> String {
        if status.isHealthy { return "실행 중" }
        if status.serviceLoaded { return "응답 없음" }
        return status.isInstalled ? "중지됨" : "설치 필요"
    }
}

private struct StatusCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let healthy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.title2)
                Spacer()
                Circle()
                    .fill(healthy ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
            }
            Text(title).font(.headline)
            Text(value).font(.title3.bold())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
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
            .padding(28)
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

    private var installAction: ManagerAction { kind == .claude ? .installClaude : .installCodex }
    private var connectAction: ManagerAction { kind == .claude ? .connectClaude : .connectCodex }
    private var disconnectAction: ManagerAction { kind == .claude ? .disconnectClaude : .disconnectCodex }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: kind == .claude ? "sparkles" : "terminal")
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(kind.displayName)
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
                Button(status?.isInstalled == true ? "공식 설치기로 업데이트" : "CLI 설치") {
                    model.request(installAction, confirmation: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.isRefreshingIntegrations)
            }
            .padding(.vertical, 12)

            Divider()

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
        switch (kind, skill) {
        case (.claude, .byoridbMemory): return .syncClaudeSkill
        case (.codex, .byoridbMemory): return .syncCodexSkill
        case (.claude, .byoriDesign): return .syncClaudeDesignSkill
        case (.codex, .byoriDesign): return .syncCodexDesignSkill
        }
    }

    private func removeAction(for skill: ManagedSkill) -> ManagerAction {
        switch (kind, skill) {
        case (.claude, .byoridbMemory): return .removeClaudeSkill
        case (.codex, .byoridbMemory): return .removeCodexSkill
        case (.claude, .byoriDesign): return .removeClaudeDesignSkill
        case (.codex, .byoriDesign): return .removeCodexDesignSkill
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

private struct MaintenanceView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "유지관리",
                    subtitle: "ByoriDB 서비스와 앱이 관리하는 파일을 점검합니다."
                )
                GroupBox("ByoriDB") {
                    VStack(alignment: .leading, spacing: 14) {
                        LabeledContent("설치") {
                            Text(model.snapshot?.byori.isInstalled == true ? "설치됨" : "설치 필요")
                        }
                        LabeledContent("Health") {
                            Text(model.snapshot?.byori.isHealthy == true ? "정상" : "응답 없음")
                        }
                        LabeledContent("launchd") {
                            Text(model.snapshot?.byori.serviceLoaded == true ? "로드됨" : "중지됨")
                        }
                        LabeledContent("Python 3") {
                            Text(model.snapshot?.byori.pythonAvailable == true ? "사용 가능" : "필요")
                        }
                        Divider()
                        HStack {
                            Button("번들 자산 + 엔진 다운로드") {
                                model.request(.installByori, confirmation: true)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("온라인 업데이트") {
                                model.request(.updateByori, confirmation: true)
                            }
                            Button("시작") { model.request(.startByori) }
                            Button("중지") { model.request(.stopByori, confirmation: true) }
                            Button("재시작") { model.request(.restartByori) }
                        }
                    }
                    .padding(10)
                }
                GroupBox("파일 및 진단") {
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
            .padding(28)
        }
        .disabled(model.isBusy)
    }
}

private struct ActivityView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "작업 기록",
                subtitle: "설치와 설정 변경 결과입니다. 인증정보는 기록하지 않습니다."
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
        .padding(28)
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
