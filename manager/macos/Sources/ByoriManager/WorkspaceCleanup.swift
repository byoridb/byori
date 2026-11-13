import Foundation

struct WorkspaceCleanupProject: Identifiable, Hashable {
    let id: String
    let name: String
}

enum WorkspaceCleanupThreshold: String, CaseIterable, Identifiable {
    case sevenDays, thirtyDays, ninetyDays, allEnded
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sevenDays: return "7일 이전 종료"
        case .thirtyDays: return "30일 이전 종료"
        case .ninetyDays: return "90일 이전 종료"
        case .allEnded: return "기간 제한 없음"
        }
    }
    func cutoff(relativeTo date: Date) -> Date? {
        let days: Int
        switch self {
        case .sevenDays: days = 7
        case .thirtyDays: days = 30
        case .ninetyDays: days = 90
        case .allEnded: return nil
        }
        return date.addingTimeInterval(-Double(days) * 86_400)
    }
}

struct WorkspaceCleanupTaskItem: Identifiable, Hashable {
    let id: String
    let projectID: String
    let projectName: String
    let sourceTreeID: String
    let title: String
    let sessionCount: Int
    /// Unknown when even one ended session has no end timestamp. A known older
    /// timestamp must never stand in for the unknown session's possible recency.
    let latestEndedAt: Date?
    let sessionIDs: Set<String>
}

struct WorkspaceArchivedTaskItem: Identifiable, Hashable {
    let id: String
    let projectID: String
    let projectName: String
    let sourceTreeID: String
    let title: String
    let sessionCount: Int
    let latestEndedAt: Date?
    let restoreUnavailableReason: String?
}

struct WorkspaceArchivedTaskList: Hashable {
    let items: [WorkspaceArchivedTaskItem]
    let isTruncated: Bool
}

enum WorkspaceCleanupEligibility {
    static func hasActiveSession(_ task: WorkspaceTaskItem) -> Bool {
        task.sessions.contains { $0.state.isActive || $0.isDetached }
    }

    static func candidate(
        task: WorkspaceTaskItem, project: WorkspaceProjectItem,
        threshold: WorkspaceCleanupThreshold, referenceDate: Date
    ) -> WorkspaceCleanupTaskItem? {
        guard !task.sessions.isEmpty, !hasActiveSession(task) else { return nil }
        let dates = task.sessions.compactMap(\.endedAt)
        let latest = dates.count == task.sessions.count ? dates.max() : nil
        if let cutoff = threshold.cutoff(relativeTo: referenceDate) {
            guard let latest, latest < cutoff else { return nil }
        }
        return WorkspaceCleanupTaskItem(
            id: task.id, projectID: project.id, projectName: project.name,
            sourceTreeID: task.sourceTreeID, title: task.title,
            sessionCount: task.sessions.count, latestEndedAt: latest,
            sessionIDs: Set(task.sessions.map(\.id))
        )
    }
}
