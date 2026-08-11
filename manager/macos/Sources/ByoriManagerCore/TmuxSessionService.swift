import Foundation

/// Whether Byori-started sessions outlive the app, and why not when they do not.
public enum TmuxAvailability: Equatable, Sendable {
    case available(executable: URL, version: String)
    case unavailable(TmuxUnavailability)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var executable: URL? {
        guard case let .available(executable, _) = self else { return nil }
        return executable
    }
}

/// Resolves tmux, keeps Byori's tmux config on disk, and answers which sessions
/// are still alive in the tmux server.
///
/// Every method degrades to "no tmux" rather than throwing: a session must
/// still start when tmux is missing, broken, or too old — it just will not
/// survive the app quitting, which the caller surfaces.
public actor TmuxSessionService {
    private let paths: ManagerPaths
    private let runner: CommandRunning
    private let fileManager: FileManager
    private var cachedAvailability: TmuxAvailability?

    public init(
        paths: ManagerPaths,
        runner: CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    /// Cached after the first probe: it spawns a process, and the answer cannot
    /// change without the user installing tmux, which a relaunch picks up.
    public func availability() async -> TmuxAvailability {
        if let cachedAvailability { return cachedAvailability }
        let resolved = await probeAvailability()
        cachedAvailability = resolved
        return resolved
    }

    private func probeAvailability() async -> TmuxAvailability {
        guard let executable = paths.executable(named: "tmux") else {
            return .unavailable(.notInstalled)
        }
        let result = await runner.run(
            CommandSpec(
                executable: executable.path,
                arguments: ["-V"],
                environment: ["PATH": paths.processPath],
                timeout: 10
            )
        )
        guard result.succeeded,
              let version = TmuxSupport.version(fromVersionOutput: result.output) else {
            return .unavailable(.unreadableVersion)
        }
        guard TmuxSupport.isAtLeast(version) else {
            return .unavailable(
                .versionTooOld(found: version, required: TmuxSupport.minimumVersion)
            )
        }
        return .available(executable: executable, version: version)
    }

    /// Rewrites Byori's tmux config and returns its path.
    ///
    /// Written before every launch rather than once at install: a session
    /// started against a stale or hand-edited config would behave differently
    /// from every other session for reasons invisible to the user.
    public func prepareConfiguration() throws -> URL {
        let file = paths.tmuxConfig
        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = Data(TmuxConfiguration.fileContents.utf8)
        if let existing = try? Data(contentsOf: file), existing == contents {
            return file
        }
        try contents.write(to: file, options: [.atomic])
        return file
    }

    /// Session ids the tmux server still holds.
    ///
    /// An empty set means "reattach nothing", which is also what a missing tmux
    /// server produces — the safe direction, since the alternative is offering
    /// to reattach to a session that is gone.
    public func liveSessionIDs() async -> Set<UUID> {
        guard case let .available(executable, _) = await availability(),
              let configFile = try? prepareConfiguration() else {
            return []
        }
        let result = await runner.run(
            CommandSpec(
                executable: executable.path,
                arguments: TmuxSupport.listSessionsArguments(configFile: configFile),
                environment: ["PATH": paths.processPath],
                timeout: 10
            )
        )
        // A server with no sessions exits non-zero with "no server running on
        // …", which is not an error worth surfacing.
        guard result.succeeded else { return [] }
        return TmuxSupport.liveSessionIDs(fromListOutput: result.output)
    }

    /// Ends a session for good. Detaching happens by the client exiting; this is
    /// only for an explicit stop.
    @discardableResult
    public func killSession(id: UUID) async -> Bool {
        guard case let .available(executable, _) = await availability(),
              let configFile = try? prepareConfiguration() else {
            return false
        }
        let result = await runner.run(
            CommandSpec(
                executable: executable.path,
                arguments: TmuxSupport.killSessionArguments(
                    configFile: configFile,
                    sessionName: TmuxSupport.sessionName(for: id)
                ),
                environment: ["PATH": paths.processPath],
                timeout: 10
            )
        )
        return result.succeeded
    }

    /// The argv for starting or reattaching `descriptor` under tmux, or nil when
    /// the caller should launch the CLI directly.
    public func launchPlan(for descriptor: TerminalLaunchDescriptor) async -> TmuxLaunchPlan? {
        guard case let .available(executable, _) = await availability(),
              let configFile = try? prepareConfiguration() else {
            return nil
        }
        return TmuxSupport.attachOrCreate(
            descriptor,
            tmux: executable,
            configFile: configFile
        )
    }
}
