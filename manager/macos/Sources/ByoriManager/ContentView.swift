import ByoriManagerCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        NavigationSplitView {
            List(ManagerSection.allCases, selection: $model.selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Byori")
            .safeAreaInset(edge: .bottom) {
                if model.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.currentOperation)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(10)
                }
            }
        } detail: {
            Group {
                switch model.selectedSection ?? .overview {
                case .overview: OverviewView()
                case .knowledgeGraph: KnowledgeGraphView()
                case .integrations: IntegrationsView()
                case .maintenance: MaintenanceView()
                case .activity: ActivityView()
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }
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
                    title: "Byori Manager",
                    subtitle: "ByoriDB와 코딩 에이전트의 로컬 메모리 연결 상태"
                )

                if let snapshot = model.snapshot {
                    HStack(spacing: 14) {
                        StatusCard(
                            title: "ByoriDB",
                            value: snapshot.byori.isHealthy ? "실행 중" : snapshot.byori.isInstalled ? "중지됨" : "설치 필요",
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "에이전트 연결",
                    subtitle: "CLI 설치, MCP 연결, Byori Memory Skill을 각각 관리합니다."
                )
                ForEach(AgentKind.allCases) { kind in
                    AgentCard(kind: kind, status: model.snapshot?.agent(kind))
                }
            }
            .padding(28)
        }
    }
}

private struct AgentCard: View {
    @EnvironmentObject private var model: ManagerViewModel
    let kind: AgentKind
    let status: AgentStatus?

    private var installAction: ManagerAction { kind == .claude ? .installClaude : .installCodex }
    private var connectAction: ManagerAction { kind == .claude ? .connectClaude : .connectCodex }
    private var disconnectAction: ManagerAction { kind == .claude ? .disconnectClaude : .disconnectCodex }
    private var syncAction: ManagerAction { kind == .claude ? .syncClaudeSkill : .syncCodexSkill }
    private var removeAction: ManagerAction { kind == .claude ? .removeClaudeSkill : .removeCodexSkill }

    var body: some View {
        GroupBox {
            VStack(spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.displayName).font(.title2.bold())
                        Text(status?.version ?? status?.executablePath ?? "CLI가 설치되어 있지 않습니다.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(status?.isInstalled == true ? "공식 설치기로 업데이트" : "CLI 설치") {
                        model.request(installAction, confirmation: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Divider()
                IntegrationRow(
                    title: "MCP",
                    detail: status?.mcpConnected == true ? "byoridb가 연결되어 있습니다." : "연결되지 않았습니다.",
                    state: status?.mcpConnected == true ? "연결됨" : "미연결",
                    healthy: status?.mcpConnected == true,
                    primaryTitle: status?.mcpConnected == true ? "다시 연결" : "연결",
                    primary: { model.request(connectAction) },
                    secondaryTitle: status?.mcpConnected == true ? "연결 해제" : nil,
                    secondary: { model.request(disconnectAction, confirmation: true) }
                )
                IntegrationRow(
                    title: "Memory Skill",
                    detail: skillDetail(status?.skillState),
                    state: skillLabel(status?.skillState),
                    healthy: status?.skillState == .current,
                    primaryTitle: status?.skillState == .current ? "다시 동기화" : "설치/업데이트",
                    primary: { model.request(syncAction) },
                    secondaryTitle: status?.skillState == .missing ? nil : "제거",
                    secondary: { model.request(removeAction, confirmation: true) }
                )
            }
            .padding(10)
        }
        .disabled(model.isBusy)
    }

    private func skillLabel(_ state: ManagedFileState?) -> String {
        switch state {
        case .current: return "최신"
        case .outdated: return "업데이트 필요"
        case .legacy: return "이전 경로"
        default: return "미설치"
        }
    }

    private func skillDetail(_ state: ManagedFileState?) -> String {
        switch state {
        case .current: return "번들에 포함된 byoridb-memory와 일치합니다."
        case .outdated: return "기존 파일을 백업하고 최신 버전으로 교체할 수 있습니다."
        case .legacy: return "Codex의 이전 ~/.codex/skills 경로에서 발견했습니다. 최신 ~/.agents/skills 경로로 이전합니다."
        default: return "장기 기억을 언제 조회하고 기록할지 안내하는 Skill입니다."
        }
    }
}

private struct IntegrationRow: View {
    let title: String
    let detail: String
    let state: String
    let healthy: Bool
    let primaryTitle: String
    let primary: () -> Void
    let secondaryTitle: String?
    let secondary: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: healthy ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(healthy ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.headline)
                    Text(state)
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background((healthy ? Color.green : Color.orange).opacity(0.16), in: Capsule())
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let secondaryTitle {
                Button(secondaryTitle, action: secondary)
            }
            Button(primaryTitle, action: primary)
                .buttonStyle(.bordered)
        }
    }
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
