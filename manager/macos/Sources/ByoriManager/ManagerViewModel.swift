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

enum ManagerAction: String, Identifiable {
    case installClaude
    case installCodex
    case installByori
    case updateByori
    case startByori
    case stopByori
    case restartByori
    case connectClaude
    case connectCodex
    case disconnectClaude
    case disconnectCodex
    case syncClaudeSkill
    case syncCodexSkill
    case removeClaudeSkill
    case removeCodexSkill

    var id: String { rawValue }

    var confirmationTitle: String {
        switch self {
        case .installClaude: return "Claude Code를 설치하거나 업데이트할까요?"
        case .installCodex: return "Codex를 설치하거나 업데이트할까요?"
        case .installByori: return "번들 자산으로 ByoriDB를 설치할까요?"
        case .updateByori: return "최신 ByoriDB 설치기를 내려받아 업데이트할까요?"
        case .stopByori: return "ByoriDB 서비스를 중지할까요?"
        case .disconnectClaude: return "Claude Code에서 Byori MCP 연결을 해제할까요?"
        case .disconnectCodex: return "Codex에서 Byori MCP 연결을 해제할까요?"
        case .removeClaudeSkill: return "Claude Code에서 Byori Skill을 제거할까요?"
        case .removeCodexSkill: return "Codex에서 Byori Skill을 제거할까요?"
        default: return "이 작업을 실행할까요?"
        }
    }

    var confirmationDetail: String {
        switch self {
        case .installClaude:
            return "Anthropic의 공식 설치 스크립트를 다운로드해 실행합니다. 로그인 정보는 Byori가 다루지 않습니다."
        case .installCodex:
            return "OpenAI의 공식 설치 스크립트를 다운로드해 실행합니다. 로그인 정보는 Byori가 다루지 않습니다."
        case .updateByori:
            return "GitHub의 최신 Byori 릴리스 설치기를 실행합니다. 기존 데이터와 root 비밀번호는 보존됩니다."
        case .installByori:
            return "앱에 포함된 MCP·Skill·서비스 자산을 사용하고, 호환되는 ByoriDB 엔진은 GitHub 릴리스에서 다운로드합니다. 기존 runtime은 먼저 백업합니다."
        case .removeClaudeSkill, .removeCodexSkill:
            return "기존 파일은 ~/.byori-manager/backups에 백업한 뒤 제거합니다."
        default:
            return "완료 후 상태를 다시 검사합니다."
        }
    }

    var isDestructive: Bool {
        switch self {
        case .stopByori, .disconnectClaude, .disconnectCodex,
             .removeClaudeSkill, .removeCodexSkill:
            return true
        default:
            return false
        }
    }
}

struct ActivityEntry: Identifiable {
    enum Level { case info, success, failure }

    let id = UUID()
    let date: Date
    let title: String
    let detail: String
    let level: Level
}

@MainActor
final class ManagerViewModel: ObservableObject {
    @Published var selectedSection: ManagerSection? = .overview
    @Published private(set) var snapshot: ManagerSnapshot?
    @Published private(set) var isBusy = false
    @Published private(set) var currentOperation = ""
    @Published var pendingAction: ManagerAction?
    @Published private(set) var activities: [ActivityEntry] = []

    let service: ManagerService

    init(service: ManagerService = ManagerService()) {
        self.service = service
        Task { [weak self] in
            await self?.refresh()
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
        Task {
            await perform(action)
        }
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

    private func perform(_ action: ManagerAction) async {
        isBusy = true
        currentOperation = action.confirmationTitle.replacingOccurrences(of: "할까요?", with: "중")
        activities.insert(ActivityEntry(
            date: Date(), title: currentOperation, detail: "", level: .info
        ), at: 0)

        do {
            let result: OperationResult
            switch action {
            case .installClaude:
                result = try await service.installOrUpdateCLI(.claude)
            case .installCodex:
                result = try await service.installOrUpdateCLI(.codex)
            case .installByori:
                result = try await service.installByoriBundled()
            case .updateByori:
                result = try await service.updateByoriOnline()
            case .startByori:
                result = try await service.startService()
            case .stopByori:
                result = try await service.stopService()
            case .restartByori:
                result = try await service.restartService()
            case .connectClaude:
                result = try await service.connectMCP(.claude)
            case .connectCodex:
                result = try await service.connectMCP(.codex)
            case .disconnectClaude:
                result = try await service.disconnectMCP(.claude)
            case .disconnectCodex:
                result = try await service.disconnectMCP(.codex)
            case .syncClaudeSkill:
                result = try await service.syncSkill(.claude)
            case .syncCodexSkill:
                result = try await service.syncSkill(.codex)
            case .removeClaudeSkill:
                result = try await service.removeSkill(.claude)
            case .removeCodexSkill:
                result = try await service.removeSkill(.codex)
            }
            activities.insert(ActivityEntry(
                date: Date(),
                title: result.summary,
                detail: String(result.detail.prefix(12_000)),
                level: .success
            ), at: 0)
        } catch {
            activities.insert(ActivityEntry(
                date: Date(),
                title: "작업 실패",
                detail: String(error.localizedDescription.suffix(12_000)),
                level: .failure
            ), at: 0)
            selectedSection = .activity
        }

        snapshot = await service.snapshot()
        isBusy = false
        currentOperation = ""
    }
}
