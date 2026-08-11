import AppKit
import ByoriManagerCore
import SwiftUI

@main
struct ByoriManagerApp: App {
    @NSApplicationDelegateAdaptor(ByoriApplicationDelegate.self) private var appDelegate
    @StateObject private var model: ManagerViewModel
    @StateObject private var workspaceModel: WorkspaceViewModel
    @StateObject private var terminalController: TerminalSessionController
    private let workspaceWindowCoordinator: WorkspaceWindowCoordinator
    private let settingsWindowCoordinator: SettingsWindowCoordinator

    init() {
        let service = ManagerService()
        let managerModel = ManagerViewModel(service: service)
        let terminalController = TerminalSessionController.shared
        let dataSource = LiveWorkspaceDataSource(
            managerService: service,
            terminalController: terminalController,
            workspaceHome: Self.workspaceHome
        )
        let workspaceModel = WorkspaceViewModel(dataSource: dataSource)
        dataSource.workspaceChanged = { [weak workspaceModel] in
            Task { @MainActor in
                await workspaceModel?.load(force: true)
            }
        }

        _model = StateObject(wrappedValue: managerModel)
        _workspaceModel = StateObject(wrappedValue: workspaceModel)
        _terminalController = StateObject(wrappedValue: terminalController)
        let settingsCoordinator = SettingsWindowCoordinator(model: managerModel)
        let windowCoordinator = WorkspaceWindowCoordinator(
            managerModel: managerModel,
            workspaceModel: workspaceModel,
            terminalController: terminalController,
            openSettingsWindow: settingsCoordinator.showWindow
        )
        workspaceWindowCoordinator = windowCoordinator
        settingsWindowCoordinator = settingsCoordinator
        appDelegate.openWorkspaceWindow = windowCoordinator.showWindow
        appDelegate.openSettingsWindow = settingsCoordinator.showWindow
        appDelegate.managerModel = managerModel
        DispatchQueue.main.async {
            windowCoordinator.showWindow()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                openWorkspaceWindow: workspaceWindowCoordinator.showWindow,
                openSettingsWindow: settingsWindowCoordinator.showWindow
            )
                .environmentObject(model)
                .environmentObject(workspaceModel)
                .environmentObject(terminalController)
        } label: {
            Label("Byori", systemImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    settingsWindowCoordinator.showWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Refresh Workspace") {
                    Task { await workspaceModel.load(force: true) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Byori") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    private var menuBarIcon: String {
        if model.isBusy { return "arrow.triangle.2.circlepath" }
        return model.snapshot?.byori.isHealthy == true
            ? "externaldrive.connected.to.line.below.fill"
            : "externaldrive.badge.exclamationmark"
    }

    private static var workspaceHome: URL {
        if let path = ProcessInfo.processInfo.environment["BYORI_WORKSPACE_HOME"],
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".byori", isDirectory: true)
    }
}

@MainActor
private final class ByoriApplicationDelegate: NSObject, NSApplicationDelegate {
    var openWorkspaceWindow: (@MainActor () -> Void)?
    var openSettingsWindow: (@MainActor () -> Void)?
    weak var managerModel: ManagerViewModel?
    private var terminationTask: Task<Void, Never>?
    private var hasDrainedForTermination = false

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        openWorkspaceWindow?()
        return true
    }

    /// Drains, then asks again — it never answers `.terminateLater`.
    ///
    /// `.terminateLater` parks the main thread in a nested AppKit event loop
    /// until `reply(toApplicationShouldTerminate:)` arrives. That reply came
    /// from a `@MainActor` task, which cannot be scheduled while the main actor
    /// is the thing being blocked, so quitting with anything left to drain hung
    /// the app against itself: no reply, no drain, and the two sessions it was
    /// meant to stop still running half an hour later.
    ///
    /// Cancelling instead keeps the main thread free to run the drain, and the
    /// second pass finds nothing left and terminates immediately.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if hasDrainedForTermination {
            return .terminateNow
        }
        let terminalController = TerminalSessionController.shared
        let needsManagerDrain = managerModel?.hasActiveOperation == true
        guard needsManagerDrain || terminalController.needsTerminationDrain else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateCancel
        }

        terminationTask = Task { @MainActor in
            let managerSafe = await managerModel?.cancelActiveOperationAndWait() ?? true
            guard managerSafe else {
                managerModel?.selectedSection = .activity
                openSettingsWindow?()
                terminationTask = nil
                return
            }
            await terminalController.stopAllAndWaitForApplicationTermination()
            terminationTask = nil
            // Latched so a process that survives even SIGKILL cannot keep
            // reporting work to drain and turn this into a loop.
            hasDrainedForTermination = true
            NSApplication.shared.terminate(nil)
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort fallback for lifecycle paths that do not first ask the
        // delegate. Normal menu, keyboard, Dock and Apple-event quits are
        // drained asynchronously by `applicationShouldTerminate` above.
        // Releases rather than stops: a tmux-backed session must survive the
        // quit so it can be reattached on the next launch.
        TerminalSessionController.shared.releaseAllForApplicationExit()
    }
}

@MainActor
private final class WorkspaceWindowCoordinator {
    private let managerModel: ManagerViewModel
    private let workspaceModel: WorkspaceViewModel
    private let terminalController: TerminalSessionController
    private let openSettingsWindow: @MainActor () -> Void
    private var retainedWindow: NSWindow?

    init(
        managerModel: ManagerViewModel,
        workspaceModel: WorkspaceViewModel,
        terminalController: TerminalSessionController,
        openSettingsWindow: @escaping @MainActor () -> Void
    ) {
        self.managerModel = managerModel
        self.workspaceModel = workspaceModel
        self.terminalController = terminalController
        self.openSettingsWindow = openSettingsWindow
    }

    func showWindow() {
        _ = NSApplication.shared.setActivationPolicy(.regular)
        if let window = retainedWindow ?? NSApplication.shared.windows.first(where: {
            $0.title == "Byori" && $0.canBecomeMain
        }) {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let root = ContentView(openSettings: openSettingsWindow)
            .environmentObject(managerModel)
            .environmentObject(workspaceModel)
            .environmentObject(terminalController)
            .frame(minWidth: 1_000, minHeight: 620)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Byori"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 1_000, height: 620)
        window.setContentSize(NSSize(width: 1_480, height: 880))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        retainedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// Owns a concrete AppKit settings window instead of depending on the
/// undocumented `showSettingsWindow:` responder selector. That selector is
/// not reliably delivered for a MenuBarExtra app with a manually-owned main
/// window, which previously made every visible Settings entry a no-op.
@MainActor
private final class SettingsWindowCoordinator {
    private let model: ManagerViewModel
    private var retainedWindow: NSWindow?

    init(model: ManagerViewModel) {
        self.model = model
    }

    func showWindow() {
        _ = NSApplication.shared.setActivationPolicy(.regular)
        if let window = retainedWindow {
            Task { await model.refresh() }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let root = ManagerSettingsView()
            .environmentObject(model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Byori Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 920, height: 640))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        retainedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
