import Foundation

enum WorkspaceSessionLocationStrategy: String, CaseIterable, Identifiable, Hashable {
    case currentCheckout, newBranch, newWorktree
    var id: String { rawValue }
}

struct WorkspaceSessionLocationRecommendation: Equatable {
    let strategy: WorkspaceSessionLocationStrategy
    let reason: String
}
