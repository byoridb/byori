import ByoriManagerCore
import Foundation

/// The Settings inventory contains names and ownership, never command arguments
/// or credentials. Search stays on that same redacted surface.
enum AgentInventoryFilter: String, CaseIterable, Identifiable {
    case all
    case byoriManaged
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "전체"
        case .byoriManaged: return "Byori 관리"
        case .other: return "사용자·외부"
        }
    }

    func includes(isByoriManaged: Bool) -> Bool {
        switch self {
        case .all: return true
        case .byoriManaged: return isByoriManaged
        case .other: return !isByoriManaged
        }
    }
}

struct AgentInventoryQuery {
    var text = ""
    var filter: AgentInventoryFilter = .all

    func matches(name: String, isByoriManaged: Bool) -> Bool {
        guard filter.includes(isByoriManaged: isByoriManaged) else { return false }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.range(
            of: query, options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}

enum AgentInventoryPresentation {
    /// A failed or incomplete scan is not evidence of an empty inventory.
    static func countLabel(
        state: AgentInventoryState?,
        count: Int,
        truncated: Bool = false
    ) -> String {
        switch state {
        case nil: return "확인 중"
        case .cliMissing: return "CLI 필요"
        case .unavailable:
            return count > 0 ? "일부 확인 · \(count)개" : "확인 실패"
        case .ready:
            return truncated ? "\(count)개 표시 · 일부 목록" : "\(count)개"
        }
    }

    /// AgentStatus.mcpConnected verifies the registered command and scope. Only
    /// a successful inventory result may claim that the vendor reached a server.
    static func byoriMCPStatus(
        registrationConfirmed: Bool,
        inventoryState: AgentInventoryState?,
        serverStatus: MCPServerStatus?
    ) -> String {
        if registrationConfirmed {
            switch inventoryState == .ready ? serverStatus : nil {
            case .connected: return "연결 확인됨"
            case .authenticationRequired: return "등록됨 · 인증 필요"
            case .disabled: return "등록됨 · 비활성"
            case .pendingApproval: return "등록됨 · 승인 대기"
            case .unavailable: return "등록됨 · 연결 실패"
            default: return "등록됨 · 연결 미확인"
            }
        }
        return inventoryState == .ready ? "미등록" : "등록 미확인"
    }
}
