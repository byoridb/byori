import Foundation

/// Why a session is not backed by tmux. Shown to the user, because a session
/// that dies with the app looks identical to one that survives until the moment
/// the app quits and the work is already gone.
public enum TmuxUnavailability: Equatable, Sendable {
    case notInstalled
    case versionTooOld(found: String, required: String)
    case unreadableVersion

    public var message: String {
        switch self {
        case .notInstalled:
            return "tmux가 설치되어 있지 않아 세션이 Byori와 함께 종료됩니다. tmux를 설치하면 앱을 닫아도 세션이 유지됩니다."
        case let .versionTooOld(found, required):
            return "tmux \(found)은 Byori 세션 백엔드가 지원하지 않습니다. \(required) 이상에서 세션 유지가 가능합니다."
        case .unreadableVersion:
            return "tmux 버전을 확인하지 못해 세션 유지를 사용하지 않습니다."
        }
    }
}

/// The exact argv Byori runs for one tmux-backed session, plus the session name
/// it can later be found by.
public struct TmuxLaunchPlan: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let sessionName: String

    public init(executable: URL, arguments: [String], sessionName: String) {
        self.executable = executable
        self.arguments = arguments
        self.sessionName = sessionName
    }
}

/// The tmux configuration Byori runs its sessions under.
///
/// Byori uses tmux as plumbing, not as a terminal multiplexer the user drives:
/// the session is meant to look exactly like the CLI running in Byori's own
/// terminal, with the single difference that it survives the app quitting.
public enum TmuxConfiguration {
    /// Written to a Byori-owned path and passed with `-f`, never merged into the
    /// user's own `~/.tmux.conf`. A user's key bindings and status line stay
    /// theirs, and Byori's settings cannot be broken by an unrelated edit.
    public static let fileContents = """
    # Byori writes this file. Edits are overwritten on the next session launch.
    # It applies only to sessions Byori starts (passed with -f).

    # tmux must not intercept keys: every keystroke belongs to the coding CLI.
    # A prefix would silently swallow one chord from an interactive TUI.
    set -g prefix None
    unbind C-b

    # No status bar, so the session looks like a plain terminal.
    set -g status off

    # Escape must reach the CLI immediately; the default delay makes a TUI's
    # Escape key feel broken.
    set -sg escape-time 0

    # The point of the backend: a session with no attached client keeps running.
    set -g destroy-unattached off

    set -g history-limit 50000
    set -g default-terminal "xterm-256color"
    set -ga terminal-overrides ",xterm-256color:Tc"

    # Let tmux own wheel events while its alternate screen is active. Otherwise
    # SwiftTerm translates wheel movement into Up/Down keys and the coding CLI
    # recalls earlier input instead of showing terminal history.
    set -g mouse on
    """
}

/// Builds tmux command lines. Pure argv construction with no process spawning,
/// so the shapes below are pinned by tests on a machine that has no tmux.
public enum TmuxSupport {
    /// Keep the same conservative floor previously required by the retained
    /// session backend. Newer tmux releases are tested with direct argv and
    /// per-session client environment updates.
    public static let minimumVersion = "3.2"

    /// Namespaced so Byori never attaches to, reports, or kills a tmux session
    /// the user created themselves.
    public static let sessionPrefix = "byori-"

    public static func sessionName(for sessionID: UUID) -> String {
        sessionPrefix + sessionID.uuidString.lowercased()
    }

    public static func sessionID(fromSessionName name: String) -> UUID? {
        guard name.hasPrefix(sessionPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(sessionPrefix.count)))
    }

    /// Start-or-reattach in one command.
    ///
    /// `-A` makes create and attach the same call, so a relaunch takes the same
    /// path as a first launch and there is no separate "does it already exist"
    /// branch that could disagree with tmux.
    ///
    /// The CLI goes after `--` as separate argv entries: tmux would otherwise
    /// join the remaining words and hand them to a shell, which is exactly the
    /// shell parsing `TerminalLaunchDescriptor` exists to avoid.
    public static func attachOrCreate(
        _ descriptor: TerminalLaunchDescriptor,
        tmux: URL,
        configFile: URL,
        socketFile: URL
    ) -> TmuxLaunchPlan {
        let name = sessionName(for: descriptor.id)
        var arguments = [
            "-S", socketFile.path,
            "-f", configFile.path,
            // Values arrive only through the tmux client's environment. The
            // argv contains names, never API keys or other secret values.
            "set-option", "-g", "update-environment",
            descriptor.environment.keys.sorted().joined(separator: " "),
            ";",
            "new-session",
            "-A",
            "-s", name,
            "-c", descriptor.workingDirectory.path,
        ]
        arguments.append("--")
        arguments.append(descriptor.executable.path)
        arguments.append(contentsOf: descriptor.arguments)

        return TmuxLaunchPlan(executable: tmux, arguments: arguments, sessionName: name)
    }

    /// Reattaches a session created by older Byori builds on the user's
    /// default tmux server. No launch environment is needed: its CLI is
    /// already running. New sessions always use Byori's private socket.
    public static func attachLegacy(
        sessionID: UUID,
        tmux: URL,
        configFile: URL
    ) -> TmuxLaunchPlan {
        let name = sessionName(for: sessionID)
        return TmuxLaunchPlan(
            executable: tmux,
            arguments: ["-f", configFile.path, "attach-session", "-t", name],
            sessionName: name
        )
    }

    /// Ends the session for good. Detaching is what happens on app quit; this
    /// runs only when the user explicitly stops the session.
    public static func killSessionArguments(
        configFile: URL,
        sessionName: String,
        socketFile: URL? = nil
    ) -> [String] {
        serverArguments(socketFile: socketFile)
            + ["-f", configFile.path, "kill-session", "-t", sessionName]
    }

    /// Lists only session names, one per line.
    public static func listSessionsArguments(
        configFile: URL,
        socketFile: URL? = nil
    ) -> [String] {
        serverArguments(socketFile: socketFile)
            + ["-f", configFile.path, "list-sessions", "-F", "#{session_name}"]
    }

    /// Applies scrolling to one Byori session without changing the user's
    /// unrelated tmux sessions that may share the same server.
    public static func enableMouseArguments(
        configFile: URL,
        sessionName: String,
        socketFile: URL? = nil
    ) -> [String] {
        serverArguments(socketFile: socketFile)
            + ["-f", configFile.path, "set-option", "-t", sessionName, "mouse", "on"]
    }

    /// Session ids for the live Byori sessions in `tmux list-sessions` output.
    ///
    /// Tolerates the "no server running" message and any session the user made,
    /// so an unparsable line can never be mistaken for a session to reattach.
    public static func liveSessionIDs(fromListOutput output: String) -> Set<UUID> {
        var ids: Set<UUID> = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let name = line.trimmingCharacters(in: .whitespaces)
            if let id = sessionID(fromSessionName: name) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Parses `tmux -V` ("tmux 3.5a", "tmux next-3.6").
    public static func version(fromVersionOutput output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("tmux ") else { return nil }
        let value = String(trimmed.dropFirst("tmux ".count))
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// True when `version` is at least `minimum`.
    ///
    /// Compares the leading numeric components only: tmux appends a letter to
    /// patch releases ("3.2a") and prefixes prereleases ("next-3.6"), neither of
    /// which is a number. A version that parses to nothing is refused rather
    /// than assumed new enough.
    public static func isAtLeast(_ version: String, _ minimum: String = minimumVersion) -> Bool {
        guard let found = numericComponents(version), !found.isEmpty else { return false }
        guard let required = numericComponents(minimum), !required.isEmpty else { return false }

        for index in 0..<max(found.count, required.count) {
            let lhs = index < found.count ? found[index] : 0
            let rhs = index < required.count ? required[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    private static func numericComponents(_ version: String) -> [Int]? {
        // Drop a "next-" style prefix, then read each dot-separated component up
        // to its first non-digit so "3.2a" compares as 3.2.
        let stripped = version.drop { !$0.isNumber }
        guard !stripped.isEmpty else { return nil }
        return stripped.split(separator: ".").map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }

    private static func serverArguments(socketFile: URL?) -> [String] {
        socketFile.map { ["-S", $0.path] } ?? []
    }
}
