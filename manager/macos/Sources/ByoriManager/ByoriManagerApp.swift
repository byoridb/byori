import AppKit
import ByoriManagerCore
import SwiftUI

@main
struct ByoriManagerApp: App {
    @StateObject private var model: ManagerViewModel
    @StateObject private var graphModel: KnowledgeGraphViewModel

    init() {
        let service = ManagerService()
        _model = StateObject(wrappedValue: ManagerViewModel(service: service))
        _graphModel = StateObject(wrappedValue: KnowledgeGraphViewModel(service: service))
    }

    var body: some Scene {
        Window("Byori Manager", id: "manager") {
            ContentView()
                .environmentObject(model)
                .environmentObject(graphModel)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1_120, height: 740)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("상태 새로고침") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Byori Manager 종료") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
                .disabled(model.isBusy)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Label("Byori Manager", systemImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        if model.isBusy { return "arrow.triangle.2.circlepath" }
        return model.snapshot?.byori.isHealthy == true
            ? "externaldrive.connected.to.line.below.fill"
            : "externaldrive.badge.exclamationmark"
    }
}
