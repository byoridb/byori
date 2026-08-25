import AppKit
import SwiftUI

struct MenuBarView: View {
    let openWorkspaceWindow: () -> Void
    let openSettingsWindow: () -> Void

    @EnvironmentObject private var model: ManagerViewModel
    @EnvironmentObject private var workspaceModel: WorkspaceViewModel
    @EnvironmentObject private var terminalController: TerminalSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Byori").font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }

            Divider()

            Button {
                openWorkspace()
            } label: {
                Label("Open Workspace", systemImage: "macwindow")
            }
            Button {
                openWorkspace()
                Task { await workspaceModel.prepareNewSession() }
            } label: {
                Label("New Session…", systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(workspaceModel.projects.isEmpty)

            Button {
                openSettingsWindow()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }

            Divider()

            Button {
                Task {
                    async let managerRefresh: Void = model.refresh()
                    async let workspaceRefresh: Void = workspaceModel.load(force: true)
                    _ = await (managerRefresh, workspaceRefresh)
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy || workspaceModel.isRefreshing)

            Button {
                model.openLogs()
            } label: {
                Label("Open Logs", systemImage: "doc.text.magnifyingglass")
            }

            Divider()

            Button("Quit Byori") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 270)
        .task { await model.refresh() }
    }

    private var statusIcon: String {
        if model.isBusy { return "arrow.triangle.2.circlepath" }
        return model.snapshot?.byori.isHealthy == true
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
    }

    private var statusColor: Color {
        guard let condition = model.snapshot?.byori.condition else { return .orange }
        switch condition {
        case .running: return .green
        case .unresponsive: return .red
        case .stopped, .notInstalled: return .orange
        }
    }

    private var statusText: String {
        if model.isBusy { return model.currentOperation }
        let sessions = terminalController.activeSessionCount
        guard let status = model.snapshot?.byori else {
            return sessions == 0 ? "Checking ByoriDB" : "\(sessions) active session\(sessions == 1 ? "" : "s")"
        }
        // Derived from the same condition every other surface reports, so the
        // menu bar cannot call the engine stopped while Settings calls it broken.
        let database: String
        switch status.condition {
        case .running: database = "ByoriDB running"
        case .unresponsive: database = "ByoriDB unavailable"
        case .stopped: database = "ByoriDB stopped"
        case .notInstalled: database = "ByoriDB setup needed"
        }
        guard sessions > 0 else { return database }
        return "\(database) · \(sessions) active session\(sessions == 1 ? "" : "s")"
    }

    private func openWorkspace() {
        openWorkspaceWindow()
    }

}
