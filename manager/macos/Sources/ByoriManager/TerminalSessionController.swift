import AppKit
import ByoriManagerCore
import Darwin
import SwiftTerm

enum TerminalSessionStatus: Equatable {
    case starting
    case running
    case stopping
    case stopped
    case exited(Int32?)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running, .stopping:
            return true
        case .stopped, .exited, .failed:
            return false
        }
    }
}

struct TerminalSessionSnapshot: Identifiable, Equatable {
    let descriptor: TerminalLaunchDescriptor
    var status: TerminalSessionStatus
    var title: String?
    var reportedWorkingDirectory: String?

    var id: UUID { descriptor.id }
}

struct TerminalSessionCallbacks {
    var statusChanged: ((TerminalSessionSnapshot) -> Void)?
    var titleChanged: ((UUID, String?) -> Void)?

    init(
        statusChanged: ((TerminalSessionSnapshot) -> Void)? = nil,
        titleChanged: ((UUID, String?) -> Void)? = nil
    ) {
        self.statusChanged = statusChanged
        self.titleChanged = titleChanged
    }
}

enum TerminalSessionControllerError: LocalizedError, Equatable {
    case duplicateSession(UUID)
    case missingSession(UUID)
    case sessionNotRunning(UUID)
    case activeSession(UUID)
    case applicationIsTerminating
    case inputTooLarge

    var errorDescription: String? {
        switch self {
        case let .duplicateSession(id):
            return "이미 존재하는 터미널 세션입니다: \(id.uuidString)"
        case let .missingSession(id):
            return "터미널 세션을 찾을 수 없습니다: \(id.uuidString)"
        case let .sessionNotRunning(id):
            return "실행 중인 터미널 세션이 아닙니다: \(id.uuidString)"
        case let .activeSession(id):
            return "실행 중인 터미널 세션은 제거할 수 없습니다: \(id.uuidString)"
        case .applicationIsTerminating:
            return "앱이 종료 중이어서 새 터미널 세션을 시작할 수 없습니다."
        case .inputTooLarge:
            return "터미널에 한 번에 보낼 수 있는 입력은 최대 1 MiB입니다."
        }
    }
}

/// App-process-scoped owner of every interactive terminal and its PTY.
///
/// SwiftUI hosts only mount a retained `LocalProcessTerminalView`; removing a
/// host or closing its window never removes the session from this controller.
@MainActor
final class TerminalSessionController: ObservableObject {
    static let shared = TerminalSessionController()

    private static let gracefulStopNanoseconds: UInt64 = 2_000_000_000
    private static let forcedStopWaitNanoseconds: UInt64 = 500_000_000
    private static let shutdownPollNanoseconds: UInt64 = 25_000_000

    @Published private(set) var snapshots: [UUID: TerminalSessionSnapshot] = [:]

    var orderedSnapshots: [TerminalSessionSnapshot] {
        snapshots.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    var activeSessionCount: Int {
        snapshots.values.filter(\.status.isActive).count
    }

    /// Includes a process group whose leader has exited but whose children are
    /// still draining. AppKit must delay application termination while this is
    /// true, even when every visible session already says `stopped`.
    var needsTerminationDrain: Bool {
        activeSessionCount > 0 || !pendingStopTargets.isEmpty
    }

    private struct ProcessTarget: Equatable {
        let sessionID: UUID
        let processID: pid_t
    }

    private final class RetainedSession {
        let descriptor: TerminalLaunchDescriptor
        let terminalView: LocalProcessTerminalView
        let processDelegate: ProcessDelegate
        let callbacks: TerminalSessionCallbacks
        /// True when the retained process is a tmux client rather than the CLI
        /// itself. Killing it detaches; ending the session takes a tmux command.
        let isTmuxBacked: Bool
        var snapshot: TerminalSessionSnapshot

        init(
            descriptor: TerminalLaunchDescriptor,
            terminalView: LocalProcessTerminalView,
            processDelegate: ProcessDelegate,
            callbacks: TerminalSessionCallbacks,
            isTmuxBacked: Bool
        ) {
            self.descriptor = descriptor
            self.terminalView = terminalView
            self.processDelegate = processDelegate
            self.callbacks = callbacks
            self.isTmuxBacked = isTmuxBacked
            self.snapshot = TerminalSessionSnapshot(
                descriptor: descriptor,
                status: .starting,
                title: nil,
                reportedWorkingDirectory: nil
            )
        }
    }

    private final class ProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
        let sessionID: UUID
        var onTermination: ((UUID, Int32?) -> Void)?
        var onTitle: ((UUID, String?) -> Void)?
        var onDirectory: ((UUID, String?) -> Void)?

        init(sessionID: UUID) {
            self.sessionID = sessionID
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            onTitle?(sessionID, title.isEmpty ? nil : title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            onDirectory?(sessionID, directory)
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onTermination?(sessionID, exitCode)
        }
    }

    private var retainedSessions: [UUID: RetainedSession] = [:]
    private var pendingStopTargets: [UUID: ProcessTarget] = [:]
    private var escalationTasks: [UUID: Task<Void, Never>] = [:]
    private var applicationShutdownTask: Task<Void, Never>?
    private var isApplicationShuttingDown = false
    private let tmuxService: TmuxSessionService

    init(tmuxService: TmuxSessionService = TmuxSessionService(paths: .applicationDefault())) {
        self.tmuxService = tmuxService
    }

    /// Starts a session, or reattaches to the one tmux is already running for
    /// this id.
    ///
    /// Under tmux the retained process is the *client*: the CLI is a child of
    /// the tmux server, so it survives this app exiting. Without tmux the CLI is
    /// this app's own child and dies with it — the same behaviour Byori had
    /// before, kept as the fallback rather than refusing to start.
    @discardableResult
    func start(
        _ descriptor: TerminalLaunchDescriptor,
        callbacks: TerminalSessionCallbacks = .init()
    ) async throws -> UUID {
        guard !isApplicationShuttingDown else {
            throw TerminalSessionControllerError.applicationIsTerminating
        }
        guard retainedSessions[descriptor.id] == nil else {
            throw TerminalSessionControllerError.duplicateSession(descriptor.id)
        }

        let plan = await tmuxService.launchPlan(for: descriptor)
        let terminalView = makeTerminalView(descriptor: descriptor)
        let processDelegate = ProcessDelegate(sessionID: descriptor.id)
        let retained = RetainedSession(
            descriptor: descriptor,
            terminalView: terminalView,
            processDelegate: processDelegate,
            callbacks: callbacks,
            isTmuxBacked: plan != nil
        )

        processDelegate.onTermination = { [weak self] sessionID, status in
            Task { @MainActor [weak self] in
                self?.processTerminated(sessionID: sessionID, waitStatus: status)
            }
        }
        processDelegate.onTitle = { [weak self] sessionID, title in
            Task { @MainActor [weak self] in
                self?.terminalTitleChanged(sessionID: sessionID, title: title)
            }
        }
        processDelegate.onDirectory = { [weak self] sessionID, directory in
            Task { @MainActor [weak self] in
                self?.terminalDirectoryChanged(sessionID: sessionID, directory: directory)
            }
        }
        terminalView.processDelegate = processDelegate

        retainedSessions[descriptor.id] = retained
        publish(retained)

        // tmux passes the session's environment with `-e`, so the client itself
        // only needs a PATH to find the server.
        terminalView.startProcess(
            executable: (plan?.executable ?? descriptor.executable).path,
            args: plan?.arguments ?? descriptor.arguments,
            environment: descriptor.environmentArray,
            currentDirectory: descriptor.workingDirectory.path
        )

        if terminalView.process.running {
            updateStatus(.running, for: retained)
        } else {
            updateStatus(
                .failed("PTY에서 \(descriptor.executable.lastPathComponent)을 시작하지 못했습니다."),
                for: retained
            )
        }
        return descriptor.id
    }

    /// Session ids tmux still holds, whether or not this app has them retained.
    ///
    /// Used after a relaunch to tell a session that is still running from one
    /// that ended while Byori was closed.
    func liveDetachedSessionIDs() async -> Set<UUID> {
        await tmuxService.liveSessionIDs()
    }

    /// Whether sessions started from now on will outlive the app, and why not.
    func sessionPersistence() async -> TmuxAvailability {
        await tmuxService.availability()
    }

    func terminalView(for sessionID: UUID) -> LocalProcessTerminalView? {
        retainedSessions[sessionID]?.terminalView
    }

    func snapshot(for sessionID: UUID) -> TerminalSessionSnapshot? {
        snapshots[sessionID]
    }

    func send(_ text: String, to sessionID: UUID) throws {
        guard let retained = retainedSessions[sessionID] else {
            throw TerminalSessionControllerError.missingSession(sessionID)
        }
        guard retained.snapshot.status == .running else {
            throw TerminalSessionControllerError.sessionNotRunning(sessionID)
        }
        guard text.utf8.count <= 1_024 * 1_024 else {
            throw TerminalSessionControllerError.inputTooLarge
        }
        let bytes = Array(text.utf8)
        retained.terminalView.process.send(data: bytes[...])
    }

    func interrupt(_ sessionID: UUID) throws {
        guard let retained = retainedSessions[sessionID] else {
            throw TerminalSessionControllerError.missingSession(sessionID)
        }
        guard retained.snapshot.status == .running else {
            throw TerminalSessionControllerError.sessionNotRunning(sessionID)
        }
        let interruptByte: [UInt8] = [3]
        retained.terminalView.process.send(data: interruptByte[...])
    }

    /// Ends the session for good, as the user asked.
    ///
    /// Killing a tmux client would only detach it, leaving the CLI running
    /// while Byori reported the session as stopped. The tmux session is ended
    /// first so "stop" means the same thing on both backends.
    func stop(_ sessionID: UUID) throws {
        guard let retained = retainedSessions[sessionID] else {
            throw TerminalSessionControllerError.missingSession(sessionID)
        }
        guard retained.snapshot.status.isActive else { return }
        guard retained.snapshot.status != .stopping else { return }

        if retained.isTmuxBacked {
            Task { await tmuxService.killSession(id: sessionID) }
        }
        releaseTerminal(for: retained)
    }

    /// Drops this app's hold on the session without ending it.
    ///
    /// On tmux this is a detach: the CLI keeps running under the tmux server
    /// and is reattachable after a relaunch. Without tmux the process is this
    /// app's child, so releasing it does end it — nothing can be done about
    /// that beyond installing tmux.
    private func releaseTerminal(for retained: RetainedSession) {
        let sessionID = retained.descriptor.id
        if retained.snapshot.status != .stopping {
            updateStatus(.stopping, for: retained)
        }
        let processID = retained.terminalView.process.shellPid
        // Keep SwiftTerm's process monitor alive so `.stopping` is not changed
        // to `.stopped` until the real process-exit callback arrives.
        if processID > 0 {
            let target = ProcessTarget(sessionID: sessionID, processID: processID)
            pendingStopTargets[sessionID] = target
            signal(SIGTERM, to: target)
            scheduleEscalation(for: target)
        } else {
            retained.terminalView.terminate()
            updateStatus(.stopped, for: retained)
        }
    }

    /// Releases every session because the app is going away — not because the
    /// user ended them.
    ///
    /// This must not kill tmux sessions: quitting Byori is precisely when a
    /// tmux-backed session has to keep running so it can be reattached later.
    func releaseAllForApplicationExit() {
        let active = retainedSessions.values.filter { $0.snapshot.status.isActive }
        for retained in active {
            releaseTerminal(for: retained)
        }
    }

    /// Stops every retained PTY process group before AppKit is allowed to quit.
    ///
    /// The graceful window is bounded at two seconds. Any group that remains
    /// then receives SIGKILL, followed by a short asynchronous reap window.
    /// Sleeping always yields the main actor so SwiftTerm's process callbacks
    /// continue to run while AppKit is waiting for its termination reply.
    func stopAllAndWaitForApplicationTermination() async {
        if let applicationShutdownTask {
            await applicationShutdownTask.value
            return
        }

        isApplicationShuttingDown = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performApplicationShutdown()
        }
        applicationShutdownTask = task
        await task.value
    }

    /// Removes an inactive session and its terminal buffer. This is the only
    /// operation that releases the retained SwiftTerm view.
    func discard(_ sessionID: UUID) throws {
        guard let retained = retainedSessions[sessionID] else {
            throw TerminalSessionControllerError.missingSession(sessionID)
        }
        guard !retained.snapshot.status.isActive else {
            throw TerminalSessionControllerError.activeSession(sessionID)
        }
        retained.terminalView.removeFromSuperview()
        retained.processDelegate.onTermination = nil
        retained.processDelegate.onTitle = nil
        retained.processDelegate.onDirectory = nil
        retainedSessions.removeValue(forKey: sessionID)
        snapshots.removeValue(forKey: sessionID)
    }

    private func makeTerminalView(descriptor: TerminalLaunchDescriptor) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 640)
        )
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeForegroundColor = NSColor(
            calibratedRed: 0.88,
            green: 0.91,
            blue: 0.92,
            alpha: 1
        )
        terminal.nativeBackgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.067,
            blue: 0.075,
            alpha: 1
        )
        terminal.caretColor = .systemTeal
        terminal.optionAsMetaKey = true
        terminal.layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
        terminal.setAccessibilityLabel(accessibilityLabel(for: descriptor))
        return terminal
    }

    private func processTerminated(sessionID: UUID, waitStatus: Int32?) {
        guard let retained = retainedSessions[sessionID],
              retained.snapshot.status != .stopped else { return }
        if retained.snapshot.status == .stopping {
            updateStatus(.stopped, for: retained)
        } else {
            updateStatus(.exited(normalizedExitCode(waitStatus)), for: retained)
        }
        reconcileProcessGroupAfterLeaderExit(for: retained)
    }

    private func performApplicationShutdown() async {
        var targets = pendingStopTargets
        let activeSessions = retainedSessions.values.filter { $0.snapshot.status.isActive }

        for retained in activeSessions {
            let sessionID = retained.descriptor.id
            let processID = retained.terminalView.process.shellPid
            if processID > 0 {
                let target = ProcessTarget(sessionID: sessionID, processID: processID)
                targets[sessionID] = target
                pendingStopTargets[sessionID] = target
                if retained.snapshot.status != .stopping {
                    updateStatus(.stopping, for: retained)
                }
                signal(SIGTERM, to: target)
            } else {
                retained.terminalView.terminate()
                updateStatus(.stopped, for: retained)
            }
        }

        for sessionID in targets.keys {
            escalationTasks.removeValue(forKey: sessionID)?.cancel()
        }

        let gracefulDeadline = DispatchTime.now().uptimeNanoseconds
            + Self.gracefulStopNanoseconds
        await waitForExit(of: Array(targets.values), until: gracefulDeadline)

        let remaining = targets.values.filter(isProcessTargetAlive)
        for target in remaining {
            signal(SIGKILL, to: target)
        }

        let forcedDeadline = DispatchTime.now().uptimeNanoseconds
            + Self.forcedStopWaitNanoseconds
        await waitForExit(of: remaining, until: forcedDeadline)

        for target in targets.values where !isProcessTargetAlive(target) {
            pendingStopTargets.removeValue(forKey: target.sessionID)
        }
    }

    private func scheduleEscalation(for target: ProcessTarget) {
        escalationTasks.removeValue(forKey: target.sessionID)?.cancel()
        escalationTasks[target.sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = DispatchTime.now().uptimeNanoseconds
                + Self.gracefulStopNanoseconds
            await self.waitForExit(of: [target], until: deadline)
            guard !Task.isCancelled else { return }
            if self.isProcessTargetAlive(target) {
                self.signal(SIGKILL, to: target)
                let forcedDeadline = DispatchTime.now().uptimeNanoseconds
                    + Self.forcedStopWaitNanoseconds
                await self.waitForExit(of: [target], until: forcedDeadline)
            }
            if !self.isProcessTargetAlive(target) {
                self.pendingStopTargets.removeValue(forKey: target.sessionID)
            }
            self.escalationTasks.removeValue(forKey: target.sessionID)
        }
    }

    private func waitForExit(of targets: [ProcessTarget], until deadline: UInt64) async {
        while targets.contains(where: isProcessTargetAlive),
              DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                try await Task.sleep(nanoseconds: Self.shutdownPollNanoseconds)
            } catch {
                return
            }
        }
        for target in targets where !isProcessTargetAlive(target) {
            pendingStopTargets.removeValue(forKey: target.sessionID)
        }
    }

    private func reconcileProcessGroupAfterLeaderExit(for retained: RetainedSession) {
        let sessionID = retained.descriptor.id
        let processID = retained.terminalView.process.shellPid
        guard processID > 0 else { return }
        let target = pendingStopTargets[sessionID]
            ?? ProcessTarget(sessionID: sessionID, processID: processID)

        if isProcessTargetAlive(target) {
            // A descendant can remain in the PTY process group after its
            // leader exits. It is still app-owned and must not be orphaned.
            pendingStopTargets[sessionID] = target
            signal(SIGTERM, to: target)
            if !isApplicationShuttingDown, escalationTasks[sessionID] == nil {
                scheduleEscalation(for: target)
            }
        } else {
            pendingStopTargets.removeValue(forKey: sessionID)
            escalationTasks.removeValue(forKey: sessionID)?.cancel()
        }
    }

    private func isProcessTargetAlive(_ target: ProcessTarget) -> Bool {
        if Darwin.kill(-target.processID, 0) == 0 || errno == EPERM {
            return true
        }
        return Darwin.kill(target.processID, 0) == 0 || errno == EPERM
    }

    private func signal(_ signal: Int32, to target: ProcessTarget) {
        if Darwin.kill(-target.processID, signal) != 0 {
            _ = Darwin.kill(target.processID, signal)
        }
    }

    private func terminalTitleChanged(sessionID: UUID, title: String?) {
        guard let retained = retainedSessions[sessionID] else { return }
        retained.snapshot.title = title.map { String($0.prefix(512)) }
        publish(retained)
        retained.callbacks.titleChanged?(sessionID, retained.snapshot.title)
    }

    private func terminalDirectoryChanged(sessionID: UUID, directory: String?) {
        guard let retained = retainedSessions[sessionID] else { return }
        retained.snapshot.reportedWorkingDirectory = directory.map { String($0.prefix(2_048)) }
        publish(retained)
    }

    private func updateStatus(_ status: TerminalSessionStatus, for retained: RetainedSession) {
        retained.snapshot.status = status
        publish(retained)
    }

    private func publish(_ retained: RetainedSession) {
        snapshots[retained.descriptor.id] = retained.snapshot
        retained.callbacks.statusChanged?(retained.snapshot)
    }

    private func normalizedExitCode(_ waitStatus: Int32?) -> Int32? {
        guard let status = waitStatus else { return nil }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private func accessibilityLabel(for descriptor: TerminalLaunchDescriptor) -> String {
        switch descriptor.target {
        case let .codingAgent(provider):
            let model = descriptor.model ?? "CLI default model"
            return "\(provider.displayName) terminal, \(model)"
        case let .customAgent(id):
            // The id is what a session records; the display name lives in the
            // provider store, which this layer has no reason to read.
            return "Registered CLI terminal, \(id)"
        case .systemShellDemo:
            return "System shell demo terminal"
        }
    }
}
