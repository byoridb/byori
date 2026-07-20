import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: ManagerViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Byori Manager").font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }

            Divider()

            Button {
                open(.overview)
            } label: {
                Label("Manager 열기", systemImage: "macwindow")
            }
            Button {
                open(.knowledgeGraph)
            } label: {
                Label("지식 그래프 열기", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Button {
                open(.integrations)
            } label: {
                Label("에이전트 연결", systemImage: "link")
            }

            Divider()

            Button {
                Task { await model.refresh() }
            } label: {
                Label("상태 새로고침", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)

            Button {
                model.openLogs()
            } label: {
                Label("로그 열기", systemImage: "doc.text.magnifyingglass")
            }

            Divider()

            Button("Byori Manager 종료") {
                NSApplication.shared.terminate(nil)
            }
            .disabled(model.isBusy)
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
        model.snapshot?.byori.isHealthy == true ? .green : .orange
    }

    private var statusText: String {
        if model.isBusy { return model.currentOperation }
        guard let status = model.snapshot?.byori else { return "상태 확인 중" }
        if status.isHealthy { return "ByoriDB 실행 중" }
        return status.isInstalled ? "ByoriDB 중지됨" : "ByoriDB 설치 필요"
    }

    private func open(_ section: ManagerSection) {
        model.selectedSection = section
        openWindow(id: "manager")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
