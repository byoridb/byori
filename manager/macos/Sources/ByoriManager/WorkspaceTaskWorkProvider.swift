import ByoriManagerCore
import Foundation

struct WorkspaceTaskWorkScope: Identifiable, Equatable, Sendable {
    let id = UUID()
    let projectID: String
    let sourceTreeID: String
    let taskID: String
    let taskTitle: String
    let title: String
    let root: URL
}

/// Binds all reads and writes to the sheet's opening selection, even if the
/// outline selection changes while an asynchronous operation is pending.
@MainActor
struct WorkspaceTaskWorkProvider: WorkspaceTaskWorkProviding {
    let dataSource: any WorkspaceDataSource
    let scope: WorkspaceTaskWorkScope
    func loadWorkflow() async throws -> TaskWorkflowPlan? {
        try await dataSource.loadTaskWorkflow(scope: scope)
    }
    func saveWorkflow(_ plan: TaskWorkflowPlan) async throws {
        try await dataSource.saveTaskWorkflow(scope: scope, plan: plan)
    }
    func loadVerification() async throws -> VerificationSnapshot {
        try await dataSource.loadTaskVerification(scope: scope)
    }
    func saveVerificationCommands(_ commands: [VerificationCommand]) async throws {
        try await dataSource.saveTaskVerificationCommands(scope: scope, commands: commands)
    }
    func runVerification(commandID: String) async throws -> VerificationReceipt {
        try await dataSource.runTaskVerification(scope: scope, commandID: commandID)
    }
}
