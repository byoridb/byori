import CryptoKit
import Darwin
import Foundation

public actor ManagerService {
    private struct RuntimeSnapshot: Sendable {
        let root: URL
        let existingNames: Set<String>
        let inventory: [String: String]
        let serviceWasLoaded: Bool
        let serviceWasHealthy: Bool
    }

    public nonisolated let paths: ManagerPaths
    private let runner: any CommandRunning
    private let files: ManagedFileInstaller
    private let graphProvider: any KnowledgeGraphProviding
    private let fileManager: FileManager
    private let serviceVerifier: LocalServiceVerifier
    private let healthProbe: (@Sendable () async -> Bool)?
    /// Reads release metadata for the engine. The app's own updater keeps its
    /// fetcher, because that one also downloads and verifies a disk image; this
    /// one never downloads anything.
    private let releaseFetcher: any ReleaseFetching
    /// Settings' own tmux probe. Deliberately separate from the terminal
    /// controller's: this one answers status questions, and both caches are
    /// refreshed after an install so neither can keep reporting the old answer.
    private let tmux: TmuxSessionService

    /// The engine ships from its own repository, so its releases move without an
    /// app release. Kept next to the installer's `ENGINE_REPO`.
    static let engineRepository = "byoridb/byoridb"

    public init(
        paths: ManagerPaths = .applicationDefault(),
        runner: any CommandRunning = ProcessCommandRunner(),
        files: ManagedFileInstaller = ManagedFileInstaller(),
        graphProvider: any KnowledgeGraphProviding = ByoriGraphClient(),
        fileManager: FileManager = .default,
        releaseFetcher: any ReleaseFetching = URLSessionReleaseFetcher(),
        healthProbe: (@Sendable () async -> Bool)? = nil
    ) {
        self.paths = paths
        self.runner = runner
        self.files = files
        self.graphProvider = graphProvider
        self.fileManager = fileManager
        self.releaseFetcher = releaseFetcher
        self.healthProbe = healthProbe
        serviceVerifier = LocalServiceVerifier(runner: runner)
        // Takes the default FileManager rather than this service's: the status
        // and install paths only run `tmux -V`, and handing a non-Sendable
        // instance across the actor boundary is a data race the compiler is
        // right to refuse.
        tmux = TmuxSessionService(paths: paths, runner: runner)
    }

    public func snapshot() async -> ManagerSnapshot {
        let byori = await byoriStatus()
        let tmuxStatus = await tmuxStatus()
        var agents: [AgentStatus] = []
        for kind in AgentKind.allCases {
            agents.append(await agentStatus(kind))
        }
        return ManagerSnapshot(byori: byori, tmux: tmuxStatus, agents: agents)
    }

    public func tmuxStatus() async -> TmuxStatus {
        TmuxStatus(
            availability: await tmux.availability(),
            install: paths.executable(named: "brew").map {
                .homebrew(executablePath: $0.path)
            }
        )
    }

    /// Installs or upgrades tmux with Homebrew, then re-reads it.
    ///
    /// The two commands are not interchangeable: `brew install` refuses a
    /// formula that is already installed, and `brew upgrade` refuses one that is
    /// not, so the current state picks the command. Verification is the same in
    /// both directions — a command that exits zero without producing a tmux
    /// Byori will actually use has not finished the job.
    public func installTmux() async throws -> OperationResult {
        let status = await tmuxStatus()
        guard let install = status.install else {
            throw ManagerError.prerequisite(
                "tmux 설치에는 Homebrew가 필요합니다. https://brew.sh 에서 Homebrew를 설치한 뒤 다시 시도해 주세요."
            )
        }
        guard !status.isAvailable else {
            return OperationResult(
                summary: "tmux는 이미 사용 가능합니다",
                detail: status.stateLabel
            )
        }

        let subcommand = status.installSubcommand
        var environment = commonEnvironment
        // A status refresh must not turn into a full formula index update the
        // user did not ask for, and tmux is a core formula either way.
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let result = await runner.run(CommandSpec(
            executable: install.executablePath,
            arguments: [subcommand, "tmux"],
            environment: environment,
            timeout: 900
        ))
        try require(result, label: "tmux \(subcommand == "upgrade" ? "업그레이드" : "설치")")

        let refreshed = TmuxStatus(
            availability: await tmux.refreshAvailability(),
            install: install
        )
        guard case let .available(_, version) = refreshed.availability else {
            throw ManagerError.verificationFailed(
                "명령은 완료되었지만 Byori가 사용할 수 있는 tmux를 찾지 못했습니다. \(refreshed.stateLabel)"
            )
        }
        return OperationResult(
            summary: "tmux \(version) 준비 완료",
            detail: result.output
        )
    }

    /// Settings-only inventory. Keep this out of `snapshot()` because Claude's
    /// list command performs health checks and would otherwise delay workspace
    /// session creation and the compact status bar.
    public func integrationInventories() async -> [AgentIntegrationInventory] {
        async let claude = integrationInventory(.claude)
        async let codex = integrationInventory(.codex)
        let pair = await (claude, codex)
        return [pair.0, pair.1]
    }

    /// Read-only terminal command hints from installed Skills and plugins.
    /// Kept separate from integration inventory because it neither launches a
    /// provider CLI nor performs MCP health checks.
    public func agentCommandCatalog() -> [AgentCommandGroup] {
        AgentCommandCatalogScanner(home: paths.home, fileManager: fileManager).scan()
    }

    /// The space is required: reading "the" knowledge graph without naming a
    /// project is what put every project's memory in one shared space.
    public func loadKnowledgeGraph(
        space: String,
        limit: Int = 200
    ) async throws -> KnowledgeGraphSnapshot {
        try await graphProvider.loadGraph(paths: paths, nodeLimit: limit, space: space)
    }

    /// Reads many bodies in one batch. Prefer this over calling
    /// `loadKnowledgeBody` per node: each single read opens its own engine
    /// session, and that fan-out is what made the engine refuse valid logins.
    public func loadKnowledgeBodies(
        requests: [KnowledgeBodyRequest],
        space: String
    ) async throws -> [Int64: String] {
        try await graphProvider.loadBodies(paths: paths, requests: requests, space: space)
    }

    public func loadKnowledgeBody(
        nodeID: Int64,
        tag: String,
        space: String
    ) async throws -> String {
        try await graphProvider.loadBody(
            paths: paths,
            nodeID: nodeID,
            tag: tag,
            space: space
        )
    }

    public func installOrUpdateCLI(_ kind: AgentKind) async throws -> OperationResult {
        let descriptor = kind.descriptor
        guard let install = descriptor.install else {
            throw ManagerError.prerequisite(
                "Byori는 \(descriptor.displayName)를 설치하지 않습니다. 직접 설치한 뒤 다시 확인해 주세요."
            )
        }
        let result = await runner.run(CommandSpec(
            executable: "/bin/bash",
            arguments: ["-o", "pipefail", "-c", install.command],
            environment: commonEnvironment,
            timeout: 900
        ))
        try require(result, label: "\(kind.displayName) 설치/업데이트")
        guard paths.executable(named: kind.executableName) != nil else {
            throw ManagerError.verificationFailed("설치 후 \(kind.executableName) 실행 파일을 찾지 못했습니다.")
        }
        return OperationResult(
            summary: "\(kind.displayName) 설치/업데이트 완료",
            detail: result.output
        )
    }

    /// Installs or repairs the ByoriDB runtime, always taking the newest engine
    /// release rather than a version frozen when this app was built.
    ///
    /// This replaced a pair of buttons — "install from bundled assets" and "update
    /// online" — that asked the user to choose between two things neither name
    /// explained, and whose real difference was which *engine* each happened to
    /// land. Both could install an engine older than the one already running,
    /// because both took the tag pinned in whichever `install.sh` they used.
    ///
    /// So the two axes are separated instead of being offered as one choice:
    ///
    /// - **Byori-owned assets** (MCP runtime, CLI, Skills, service templates) come
    ///   from the app bundle. They are the ones this build was tested against, and
    ///   replacing them is what the app updater is for. A build with no bundled
    ///   assets — `swift run` during development — has none to use, so it falls
    ///   back to the installer from the latest release.
    /// - **The engine** is the release the caller already reported on screen when
    ///   there is one, and otherwise `--engine-tag latest`, which the installer
    ///   resolves itself and falls back to its pinned tag when GitHub cannot be
    ///   reached.
    ///
    /// Passing the tag matters: the installer's own resolution is a bare
    /// `curl | awk` that gives up quietly on a rate limit, and a fallback to the
    /// pinned tag while the page says a newer release exists installs an engine
    /// the user was just told was outdated. Byori resolved it once for that page,
    /// so the install uses that answer instead of asking again.
    public func installOrUpdateByori(engineTag: String? = nil) async throws -> OperationResult {
        try Task.checkCancellation()
        guard paths.executable(named: "python3") != nil else {
            throw ManagerError.prerequisite(
                "현재 MCP 런타임에는 python3가 필요합니다. Python 3를 설치한 뒤 다시 시도해 주세요."
            )
        }
        let lease = try RuntimeMutationLease.acquire(home: paths.byoriHome)
        defer { lease.release() }
        let snapshot = try await createRuntimeSnapshot()
        try Task.checkCancellation()
        let result = await runner.run(byoriInstallCommand(
            engineTag: engineTag, runtimeLeaseFileDescriptor: lease.fileDescriptor
        ))
        do {
            try require(result, label: "ByoriDB 설치")
            try await verifyByori()
            try await verifyByoriCLI()
        } catch {
            try await rollbackRuntimeUncancelled(
                snapshot, originalError: error, runtimeLeaseFileDescriptor: lease.fileDescriptor
            )
            throw error
        }
        return OperationResult(summary: "ByoriDB 설치/업데이트 완료", detail: result.output)
    }

    /// Builds a project's starting memory out of its own Git history.
    ///
    /// The graph used to start empty, which meant the first weeks of using Byori
    /// were spent earning the thing it advertises. The history that explains a
    /// codebase is already in the clone, so this reads it — `byori init`, whose pass
    /// is deterministic and records the commit, pull request or document behind every
    /// memory it writes. Re-running updates rather than duplicating.
    public func buildProjectMemory(
        projectRoot: URL,
        space: String,
        commitLimit: Int = 20_000
    ) async throws -> OperationResult {
        try Task.checkCancellation()
        let result = await runner.run(try projectMemoryCommand(
            projectRoot: projectRoot,
            space: space,
            commitLimit: commitLimit
        ))
        // An installed CLI older than this app answers argparse's usage text, which
        // says nothing about what to do. Name the cause and the one-step recovery.
        if result.output.contains("invalid choice: 'init'") {
            throw ManagerError.verificationFailed(
                "설치된 Byori CLI가 이 앱보다 오래되어 init을 모릅니다. "
                + "Settings의 ByoriDB에서 설치/업데이트를 한 번 실행해 주세요."
            )
        }
        try require(result, label: "프로젝트 기억 생성")
        return OperationResult(summary: "프로젝트 기억 생성 완료", detail: result.output)
    }

    /// Prefers the CLI that shipped with this app over the installed one, because
    /// only the bundled copy is guaranteed to know the subcommands this app calls.
    func projectMemoryCommand(
        projectRoot: URL,
        space: String,
        commitLimit: Int
    ) throws -> CommandSpec {
        let arguments = [
            "init", projectRoot.path,
            "--space", space,
            "--limit", String(commitLimit),
        ]
        // A large repository is minutes of Git, not seconds; the summary at the end
        // is what the caller shows.
        let timeout: TimeInterval = 1_800
        if fileManager.fileExists(atPath: paths.bundledByoriCLI.path),
           let python = paths.executable(named: "python3") {
            return CommandSpec(
                executable: python.path,
                arguments: [paths.bundledByoriCLI.path] + arguments,
                environment: commonEnvironment,
                timeout: timeout
            )
        }
        guard fileManager.isExecutableFile(atPath: paths.byoriCLI.path) else {
            throw ManagerError.missingResource(paths.bundledByoriCLI.path)
        }
        return CommandSpec(
            executable: paths.byoriCLI.path,
            arguments: arguments,
            environment: commonEnvironment,
            timeout: timeout
        )
    }

    /// Reads the active handbook when it is current. For missing, stale, or
    /// unavailable publication state, returns a fresh read-only preview while
    /// preserving that state and its reason. This path requires neither the
    /// graph database nor a model account.
    public func projectHandbook(
        projectRoot: URL,
        maxCommits: Int? = nil
    ) async throws -> ProjectHandbookSnapshot {
        let shown = try await runProjectHandbook(.show, projectRoot: projectRoot)
        if shown.state == .current {
            return try snapshot(fromCurrent: shown)
        }

        let preview = try await runProjectHandbook(
            .preview,
            projectRoot: projectRoot,
            maxCommits: maxCommits
        )
        guard let freshness = shown.state, let reason = shown.reason else {
            throw ProjectHandbookServiceError.invalidResponse(
                "Byori returned a handbook without a freshness state."
            )
        }
        return try snapshot(
            fromPreview: preview,
            freshness: freshness,
            reason: reason,
            publishedGeneration: shown.generation,
            path: shown.path
        )
    }

    /// Publishes one bounded deterministic build, then verifies it through the
    /// read path before reporting it as current. A zero exit from `build` alone
    /// is not treated as proof that the activated artifact is safe to show.
    public func buildProjectHandbook(
        projectRoot: URL,
        maxCommits: Int? = nil
    ) async throws -> ProjectHandbookSnapshot {
        let built = try await runProjectHandbook(
            .build,
            projectRoot: projectRoot,
            maxCommits: maxCommits
        )
        guard built.published == true, built.changed != nil else {
            throw ProjectHandbookServiceError.invalidResponse(
                "Byori did not confirm handbook publication."
            )
        }

        let shown = try await runProjectHandbook(.show, projectRoot: projectRoot)
        guard shown.state == .current,
              shown.generation == built.generation,
              shown.handbook == built.handbook else {
            throw ProjectHandbookServiceError.verificationFailed(
                "The handbook was built, but the published generation could not be verified as current."
            )
        }
        let verified = try snapshot(fromCurrent: shown)
        return ProjectHandbookSnapshot(
            freshness: verified.freshness,
            reason: verified.reason,
            generation: verified.generation,
            publishedGeneration: verified.publishedGeneration,
            path: verified.path,
            handbook: verified.handbook,
            isPreview: false,
            claimCount: built.claimCount ?? verified.claimCount,
            warnings: sanitized(built.warnings ?? []),
            excludedSourceCount: built.excludedSources ?? 0,
            sensitiveSourceCount: built.sensitiveSourcesWithheld ?? 0,
            omittedSectionCount: built.omittedSections ?? 0,
            buildChanged: built.changed
        )
    }

    public func projectHandbookStatus(
        projectRoot: URL
    ) async throws -> ProjectHandbookStatus {
        let payload = try await runProjectHandbook(.status, projectRoot: projectRoot)
        guard let state = payload.state, let reason = payload.reason else {
            throw ProjectHandbookServiceError.invalidResponse(
                "Byori returned a handbook status without a state or reason."
            )
        }
        return ProjectHandbookStatus(
            freshness: state,
            reason: sanitized(reason),
            generation: payload.generation,
            path: payload.path
        )
    }

    /// Reads checkout-scoped consent without creating a configuration file.
    public func projectHandbookRefreshConfiguration(
        projectRoot: URL
    ) async throws -> ProjectHandbookRefreshConfiguration {
        try await runProjectHandbookRefreshConfiguration(
            projectRoot: projectRoot,
            enabled: nil,
            expectedRevision: nil
        )
    }

    /// Changes automatic refresh only after an explicit user action. Supplying
    /// the last reviewed revision protects an existing setting from stale UI.
    public func setProjectHandbookAutomaticRefresh(
        projectRoot: URL,
        enabled: Bool,
        expectedRevision: String?
    ) async throws -> ProjectHandbookRefreshConfiguration {
        try await runProjectHandbookRefreshConfiguration(
            projectRoot: projectRoot,
            enabled: enabled,
            expectedRevision: expectedRevision
        )
    }

    /// Consent-aware automatic reconciliation. The CLI itself rechecks policy;
    /// the app-side gate is only a responsiveness and coalescing optimization.
    public func syncProjectHandbook(
        projectRoot: URL
    ) async throws -> ProjectHandbookRefreshResult {
        try await runProjectHandbookRefresh(.sync, projectRoot: projectRoot)
    }

    /// One explicit user refresh. This never enables future automatic work.
    public func refreshProjectHandbook(
        projectRoot: URL
    ) async throws -> ProjectHandbookRefreshResult {
        try await runProjectHandbookRefresh(.refresh, projectRoot: projectRoot)
    }

    /// Reads the project-local host adapter plan. The CLI's connect command is
    /// intentionally non-mutating unless `--apply` is present.
    public func previewProjectHandbookConnection(
        projectRoot: URL,
        host: ProjectHandbookHost
    ) async throws -> ProjectHandbookConnection {
        try await runProjectHandbookConnection(
            .connect,
            projectRoot: projectRoot,
            host: host,
            apply: false,
            requiresPreview: true
        )
    }

    /// Applies only the project-local connection that the user reviewed.
    public func applyProjectHandbookConnection(
        projectRoot: URL,
        host: ProjectHandbookHost
    ) async throws -> ProjectHandbookConnection {
        try await runProjectHandbookConnection(
            .connect,
            projectRoot: projectRoot,
            host: host,
            apply: true,
            requiresPreview: false
        )
    }

    public func disconnectProjectHandbookConnection(
        projectRoot: URL,
        host: ProjectHandbookHost
    ) async throws -> ProjectHandbookConnection {
        try await runProjectHandbookConnection(
            .disconnect,
            projectRoot: projectRoot,
            host: host,
            apply: false,
            requiresPreview: false
        )
    }

    func projectHandbookConnectionCommand(
        _ action: ProjectHandbookConnectionAction,
        projectRoot: URL,
        host: ProjectHandbookHost,
        apply: Bool = false
    ) throws -> CommandSpec {
        guard action == .connect || !apply else {
            throw ProjectHandbookServiceError.invalidResponse(
                "Only a handbook connection can be applied."
            )
        }
        var arguments = ["handbook", action.rawValue, host.rawValue, projectRoot.path]
        if apply { arguments.append("--apply") }
        arguments.append("--json")

        if fileManager.fileExists(atPath: paths.bundledByoriCLI.path),
           let python = paths.executable(named: "python3") {
            return CommandSpec(
                executable: python.path,
                arguments: [paths.bundledByoriCLI.path] + arguments,
                environment: commonEnvironment,
                timeout: 30
            )
        }
        guard fileManager.isExecutableFile(atPath: paths.byoriCLI.path) else {
            throw ManagerError.missingResource(paths.bundledByoriCLI.path)
        }
        return CommandSpec(
            executable: paths.byoriCLI.path,
            arguments: arguments,
            environment: commonEnvironment,
            timeout: 30
        )
    }

    func projectHandbookCommand(
        _ action: ProjectHandbookAction,
        projectRoot: URL,
        maxCommits: Int? = nil
    ) throws -> CommandSpec {
        if let maxCommits, !(0...10_000).contains(maxCommits) {
            throw ProjectHandbookServiceError.invalidResponse(
                "The handbook commit limit must be between 0 and 10000."
            )
        }
        var arguments = ["handbook", action.rawValue, projectRoot.path]
        if action.readsSources, let maxCommits {
            arguments += ["--max-commits", String(maxCommits)]
        }
        arguments.append("--json")
        let timeout: TimeInterval = action.readsSources ? 120 : 30

        if fileManager.fileExists(atPath: paths.bundledByoriCLI.path),
           let python = paths.executable(named: "python3") {
            return CommandSpec(
                executable: python.path,
                arguments: [paths.bundledByoriCLI.path] + arguments,
                environment: commonEnvironment,
                timeout: timeout
            )
        }
        guard fileManager.isExecutableFile(atPath: paths.byoriCLI.path) else {
            throw ManagerError.missingResource(paths.bundledByoriCLI.path)
        }
        return CommandSpec(
            executable: paths.byoriCLI.path,
            arguments: arguments,
            environment: commonEnvironment,
            timeout: timeout
        )
    }

    func projectHandbookRefreshConfigurationCommand(
        projectRoot: URL,
        enabled: Bool? = nil,
        expectedRevision: String? = nil
    ) throws -> CommandSpec {
        if let expectedRevision, !isSHA256(expectedRevision) {
            throw ProjectHandbookServiceError.invalidResponse(
                "The reviewed refresh revision is not a SHA-256 hash."
            )
        }
        var arguments = ["handbook", "refresh-config", projectRoot.path]
        if let enabled {
            arguments.append(enabled ? "--enable" : "--disable")
        } else if expectedRevision != nil {
            throw ProjectHandbookServiceError.invalidResponse(
                "A refresh revision can only accompany an explicit setting change."
            )
        }
        if let expectedRevision {
            arguments += ["--expected-revision", expectedRevision]
        } else if enabled != nil {
            // Distinguish a reviewed missing default from "no CAS requested."
            arguments.append("--expect-unconfigured")
        }
        arguments.append("--json")
        return try projectHandbookCLICommand(arguments: arguments, timeout: 30)
    }

    func projectHandbookRefreshCommand(
        _ action: ProjectHandbookRefreshAction,
        projectRoot: URL
    ) throws -> CommandSpec {
        try projectHandbookCLICommand(
            arguments: ["handbook", action.rawValue, projectRoot.path, "--json"],
            timeout: 120
        )
    }

    private func projectHandbookCLICommand(
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CommandSpec {
        if fileManager.fileExists(atPath: paths.bundledByoriCLI.path),
           let python = paths.executable(named: "python3") {
            return CommandSpec(
                executable: python.path,
                arguments: [paths.bundledByoriCLI.path] + arguments,
                environment: commonEnvironment,
                timeout: timeout
            )
        }
        guard fileManager.isExecutableFile(atPath: paths.byoriCLI.path) else {
            throw ManagerError.missingResource(paths.bundledByoriCLI.path)
        }
        return CommandSpec(
            executable: paths.byoriCLI.path,
            arguments: arguments,
            environment: commonEnvironment,
            timeout: timeout
        )
    }

    private func runProjectHandbook(
        _ action: ProjectHandbookAction,
        projectRoot: URL,
        maxCommits: Int? = nil
    ) async throws -> ProjectHandbookPayload {
        try Task.checkCancellation()
        let result = await runner.run(try projectHandbookCommand(
            action,
            projectRoot: projectRoot,
            maxCommits: maxCommits
        ))
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = result.output.data(using: .utf8),
              let payload = try? decoder.decode(ProjectHandbookPayload.self, from: data) else {
            let detail = SafeDisplayText.strippingTerminalControls(result.output)
            throw ProjectHandbookServiceError.commandFailed(
                detail.isEmpty ? "Byori did not return a readable handbook response." : detail
            )
        }

        if result.timedOut {
            throw ProjectHandbookServiceError.commandFailed("The handbook command timed out.")
        }
        if result.exitCode == 1,
           (action == .show || action == .status),
           let state = payload.state,
           state != .current {
            return payload
        }
        guard result.succeeded else {
            throw ProjectHandbookServiceError.commandFailed(
                "The handbook command failed with exit code \(result.exitCode)."
            )
        }
        return payload
    }

    private func runProjectHandbookRefreshConfiguration(
        projectRoot: URL,
        enabled: Bool?,
        expectedRevision: String?
    ) async throws -> ProjectHandbookRefreshConfiguration {
        try Task.checkCancellation()
        let result = await runner.run(try projectHandbookRefreshConfigurationCommand(
            projectRoot: projectRoot,
            enabled: enabled,
            expectedRevision: expectedRevision
        ))
        try Task.checkCancellation()
        if result.timedOut {
            throw ProjectHandbookServiceError.commandFailed(
                "The handbook refresh setting command timed out."
            )
        }
        let decoder = JSONDecoder()
        guard result.succeeded,
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == [
                "schema_version", "enabled", "revision", "change_id",
                "project_root", "checkout_id", "debounce_ms", "source_limits", "max_chars",
              ],
              let sourceLimits = object["source_limits"] as? [String: Any],
              Set(sourceLimits.keys) == [
                "max_commits", "max_files", "max_file_bytes",
                "max_total_bytes", "exclude_paths",
              ],
              let payload = try? decoder.decode(
                ProjectHandbookRefreshConfigurationPayload.self,
                from: data
              ) else {
            let detail = SafeDisplayText.strippingTerminalControls(result.output)
            throw ProjectHandbookServiceError.commandFailed(
                detail.isEmpty
                    ? "Byori did not return a readable handbook refresh setting."
                    : detail
            )
        }
        return try refreshConfiguration(from: payload, requestedRoot: projectRoot)
    }

    private func runProjectHandbookRefresh(
        _ action: ProjectHandbookRefreshAction,
        projectRoot: URL
    ) async throws -> ProjectHandbookRefreshResult {
        try Task.checkCancellation()
        let result = await runner.run(try projectHandbookRefreshCommand(
            action,
            projectRoot: projectRoot
        ))
        try Task.checkCancellation()
        if result.timedOut {
            throw ProjectHandbookServiceError.commandFailed(
                "The handbook \(action.rawValue) command timed out."
            )
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = result.output.data(using: .utf8),
              let payload = try? decoder.decode(ProjectHandbookPayload.self, from: data),
              let disposition = payload.refresh,
              let freshness = payload.state,
              let reason = payload.reason else {
            let detail = SafeDisplayText.strippingTerminalControls(result.output)
            throw ProjectHandbookServiceError.commandFailed(
                detail.isEmpty
                    ? "Byori did not return a readable handbook \(action.rawValue) response."
                    : detail
            )
        }
        guard result.succeeded || result.exitCode == 1 else {
            throw ProjectHandbookServiceError.commandFailed(
                "The handbook \(action.rawValue) command failed with exit code \(result.exitCode)."
            )
        }

        let currentSnapshot: ProjectHandbookSnapshot?
        if freshness == .current {
            currentSnapshot = try snapshot(fromCurrent: payload, buildChanged: payload.changed)
        } else {
            guard payload.handbook == nil else {
                throw ProjectHandbookServiceError.invalidResponse(
                    "Byori returned an unverified handbook body from \(action.rawValue)."
                )
            }
            currentSnapshot = nil
        }
        if disposition == .rebuilt || disposition == .unchanged {
            guard currentSnapshot != nil else {
                throw ProjectHandbookServiceError.invalidResponse(
                    "Byori reported \(disposition.rawValue) without a verified current handbook."
                )
            }
        }
        if disposition == .busy || disposition == .cancelled || disposition == .failed {
            guard currentSnapshot == nil else {
                throw ProjectHandbookServiceError.invalidResponse(
                    "Byori exposed a handbook body for a \(disposition.rawValue) refresh."
                )
            }
        }
        return ProjectHandbookRefreshResult(
            disposition: disposition,
            freshness: freshness,
            reason: sanitized(reason),
            generation: payload.generation,
            snapshot: currentSnapshot,
            changed: payload.changed
        )
    }

    private func runProjectHandbookConnection(
        _ action: ProjectHandbookConnectionAction,
        projectRoot: URL,
        host: ProjectHandbookHost,
        apply: Bool,
        requiresPreview: Bool
    ) async throws -> ProjectHandbookConnection {
        try Task.checkCancellation()
        let result = await runner.run(try projectHandbookConnectionCommand(
            action,
            projectRoot: projectRoot,
            host: host,
            apply: apply
        ))
        try Task.checkCancellation()
        if result.timedOut {
            throw ProjectHandbookServiceError.commandFailed(
                "The \(host.displayName) connection command timed out."
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard result.succeeded,
              let data = result.output.data(using: .utf8),
              let payload = try? decoder.decode(ProjectHandbookConnectionPayload.self, from: data)
        else {
            let detail = SafeDisplayText.strippingTerminalControls(result.output)
            throw ProjectHandbookServiceError.commandFailed(
                detail.isEmpty
                    ? "The \(host.displayName) connection command failed with exit code \(result.exitCode)."
                    : detail
            )
        }
        guard payload.schemaVersion == 1,
              payload.host == host,
              let status = payload.status,
              payload.verification == "unverified",
              payload.startupConsumption == "unverified",
              let changed = payload.changed,
              let instructionFile = payload.instructionFile,
              let handbookFile = payload.handbookFile,
              let handbookPresent = payload.handbookPresent else {
            throw ProjectHandbookServiceError.invalidResponse(
                "Byori returned an incomplete or unsupported \(host.displayName) connection state."
            )
        }
        if requiresPreview,
           (payload.wouldChange == nil || payload.managedBlock == nil || changed) {
            throw ProjectHandbookServiceError.invalidResponse(
                "Byori did not return a safe read-only \(host.displayName) connection preview."
            )
        }
        return ProjectHandbookConnection(
            host: host,
            status: status,
            changed: changed,
            instructionFile: sanitized(instructionFile),
            handbookFile: sanitized(handbookFile),
            handbookPresent: handbookPresent,
            warnings: sanitized(payload.warnings ?? []),
            wouldChange: payload.wouldChange,
            managedBlock: payload.managedBlock.map(sanitized),
            backupFile: payload.backupFile.map(sanitized),
            removedInstructionFile: payload.removedInstructionFile
        )
    }

    private func snapshot(
        fromCurrent payload: ProjectHandbookPayload,
        buildChanged: Bool? = nil
    ) throws -> ProjectHandbookSnapshot {
        guard payload.state == .current,
              let reason = payload.reason,
              let generation = payload.generation,
              let handbook = payload.handbook,
              let claimCount = payload.claimCount else {
            throw ProjectHandbookServiceError.invalidResponse(
                "Byori marked a handbook current without returning its verified body."
            )
        }
        return ProjectHandbookSnapshot(
            freshness: .current,
            reason: sanitized(reason),
            generation: generation,
            publishedGeneration: generation,
            path: payload.path,
            handbook: sanitized(handbook),
            isPreview: false,
            claimCount: claimCount,
            warnings: sanitized(payload.warnings ?? []),
            excludedSourceCount: payload.excludedSources ?? 0,
            sensitiveSourceCount: payload.sensitiveSourcesWithheld ?? 0,
            omittedSectionCount: payload.omittedSections ?? 0,
            buildChanged: buildChanged
        )
    }

    private func refreshConfiguration(
        from payload: ProjectHandbookRefreshConfigurationPayload,
        requestedRoot: URL
    ) throws -> ProjectHandbookRefreshConfiguration {
        guard payload.schemaVersion == 1,
              let enabled = payload.enabled,
              let projectRoot = payload.projectRoot,
              let checkoutID = payload.checkoutID,
              let debounceMs = payload.debounceMs,
              let limits = payload.sourceLimits,
              let maxCommits = limits.maxCommits,
              let maxFiles = limits.maxFiles,
              let maxFileBytes = limits.maxFileBytes,
              let maxTotalBytes = limits.maxTotalBytes,
              let excludePaths = limits.excludePaths,
              let maxChars = payload.maxChars,
              isSHA256(checkoutID),
              payload.revision == nil || isSHA256(payload.revision!),
              payload.changeID == nil || isLowercaseHex(payload.changeID!, count: 32),
              debounceMs >= 0, debounceMs <= 2_000,
              maxCommits >= 0, maxCommits <= 1_000,
              maxFiles >= 0, maxFiles <= 200,
              maxFileBytes >= 0, maxFileBytes <= 524_288,
              maxTotalBytes >= 0, maxTotalBytes <= 2_097_152,
              maxChars >= 2_048, maxChars <= 64_000,
              excludePaths.count <= 64,
              excludePaths.allSatisfy(isSafeExcludedPath),
              URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL.path
                == requestedRoot.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ProjectHandbookServiceError.invalidResponse(
                "Byori returned an incomplete, unsafe, or differently scoped handbook refresh setting."
            )
        }
        return ProjectHandbookRefreshConfiguration(
            enabled: enabled,
            revision: payload.revision,
            changeID: payload.changeID,
            projectRoot: sanitized(projectRoot),
            checkoutID: checkoutID,
            debounceMilliseconds: debounceMs,
            sourceLimits: ProjectHandbookSourceLimits(
                maxCommits: maxCommits,
                maxFiles: maxFiles,
                maxFileBytes: maxFileBytes,
                maxTotalBytes: maxTotalBytes,
                excludePaths: excludePaths.map(sanitized)
            ),
            maxCharacters: maxChars
        )
    }

    private func isSHA256(_ value: String) -> Bool {
        isLowercaseHex(value, count: 64)
    }

    private func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }
    }

    private func isSafeExcludedPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains(where: { "*?[]".contains($0) }),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return false
        }
        let plain = value.hasSuffix("/") ? String(value.dropLast()) : value
        return !plain.isEmpty && plain.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func snapshot(
        fromPreview payload: ProjectHandbookPayload,
        freshness: ProjectHandbookFreshness,
        reason: String,
        publishedGeneration: String?,
        path: String?
    ) throws -> ProjectHandbookSnapshot {
        guard payload.schemaVersion == 1,
              payload.published == false,
              let generation = payload.generation,
              let handbook = payload.handbook,
              let claimCount = payload.claimCount,
              let excludedSources = payload.excludedSources,
              let sensitiveSources = payload.sensitiveSourcesWithheld,
              let omittedSections = payload.omittedSections else {
            throw ProjectHandbookServiceError.invalidResponse(
                "Byori returned an incomplete handbook preview."
            )
        }
        return ProjectHandbookSnapshot(
            freshness: freshness,
            reason: sanitized(reason),
            generation: generation,
            publishedGeneration: publishedGeneration,
            path: path,
            handbook: sanitized(handbook),
            isPreview: true,
            claimCount: claimCount,
            warnings: sanitized(payload.warnings ?? []),
            excludedSourceCount: excludedSources,
            sensitiveSourceCount: sensitiveSources,
            omittedSectionCount: omittedSections
        )
    }

    private func sanitized(_ value: String) -> String {
        SafeDisplayText.strippingTerminalControls(value)
    }

    private func sanitized(_ values: [String]) -> [String] {
        values.map(sanitized)
    }

    /// The bundled installer when the app carries one, otherwise the installer from
    /// the latest release. Both install the engine release the caller resolved, or
    /// ask the installer to resolve the newest one when it could not be checked.
    ///
    /// A tag outside the installer's own charset is dropped rather than passed on:
    /// it is interpolated into a download URL and recorded in the engine manifest,
    /// and `latest` is a correct install where a rejected tag is no install at all.
    func byoriInstallCommand(
        engineTag: String? = nil, runtimeLeaseFileDescriptor: Int32? = nil
    ) -> CommandSpec {
        let tag = engineTag.flatMap { EngineRelease.isSafeTag($0) ? $0 : nil } ?? "latest"
        let engineArguments = ["--engine-tag", tag, "--no-claude", "--no-codex", "--no-hooks"]
        var environment = commonEnvironment
        if runtimeLeaseFileDescriptor != nil { environment["BYORI_RUNTIME_LEASE_FD"] = "9" }
        guard fileManager.fileExists(atPath: paths.installer.path) else {
            let command = "/usr/bin/curl -fsSL "
                + "https://github.com/byoridb/byori/releases/latest/download/install.sh "
                + "| /bin/bash -s -- " + engineArguments.joined(separator: " ")
            return CommandSpec(
                executable: "/bin/bash",
                arguments: ["-o", "pipefail", "-c", command],
                environment: environment,
                timeout: 900,
                runtimeLeaseFileDescriptor: runtimeLeaseFileDescriptor
            )
        }
        return CommandSpec(
            executable: "/bin/bash",
            arguments: [paths.installer.path, "--assets", paths.runtimeRoot.path] + engineArguments,
            environment: environment,
            timeout: 900,
            runtimeLeaseFileDescriptor: runtimeLeaseFileDescriptor
        )
    }

    /// Reports whether a newer signed release exists, without downloading it.
    public func checkForAppUpdate() async throws -> AppUpdateStatus {
        try await makeAppUpdater().check()
    }

    /// The newest published engine release, so the page can say which engine is
    /// installed *and* which one exists. Nothing is downloaded or installed by
    /// checking, and no comparison happens here: the caller pairs this with the
    /// installed identity through `EngineUpdateAvailability`.
    public func checkForEngineRelease() async throws -> EngineRelease {
        let endpoint = URL(
            string: "https://api.github.com/repos/\(Self.engineRepository)/releases/latest"
        )
        guard let endpoint else {
            throw ManagerError.prerequisite("엔진 릴리스 주소를 만들 수 없습니다.")
        }
        return try ReleaseCatalog.latestEngineRelease(
            from: try await releaseFetcher.data(from: endpoint)
        )
    }

    /// A bounded, display-safe tail of one engine log file.
    ///
    /// `nonisolated`, and deliberately so: this only reads a file whose location is
    /// already known. Putting it on the actor would queue "show me the log" behind
    /// a running install, which is exactly when someone opens the log.
    public nonisolated func serverLogTail(
        _ file: ServerLogFile,
        limit: Int = ServerLogReader.defaultTailBytes
    ) async -> ServerLogTail {
        let directory = paths.logs
        return await Task.detached(priority: .userInitiated) {
            ServerLogReader().tail(of: file, in: directory, limit: limit)
        }.value
    }

    /// Verifies a newer release and hands the swap to a detached helper. Only
    /// `.installed` obliges the caller to quit: the helper waits for the process
    /// to exit before replacing the bundle and reopening it. Running this while
    /// already current is a no-op, not a failure, so it reports `.alreadyCurrent`
    /// rather than throwing — the caller renders thrown errors as failures.
    public func updateApp(progress: AppUpdateProgress? = nil) async throws -> AppUpdateOutcome {
        let updater = try makeAppUpdater()
        progress?(.checking)
        switch try await updater.check() {
        case let .upToDate(version):
            return .alreadyCurrent(version)
        case let .available(update):
            let staged = try await updater.stage(update, progress: progress)
            do {
                return .installed(try await updater.apply(staged, progress: progress))
            } catch {
                await updater.discard(staged)
                throw error
            }
        }
    }

    private func makeAppUpdater() throws -> AppUpdater {
        // Running from `swift run` there is no bundle to replace, and an ad hoc
        // signature would fail verification anyway. Say so instead of failing
        // later inside codesign.
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app" else {
            throw ManagerError.prerequisite(
                "앱 번들로 실행 중일 때만 자동 업데이트를 사용할 수 있습니다."
            )
        }
        guard
            let text = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            let version = AppVersion(text)
        else {
            throw ManagerError.prerequisite("현재 앱 버전을 읽을 수 없습니다.")
        }
        return AppUpdater(bundleURL: bundle.bundleURL, currentVersion: version, runner: runner)
    }

    public func connectMCP(_ kind: AgentKind) async throws -> OperationResult {
        let cli = try requireCLI(kind)
        guard fileManager.isExecutableFile(atPath: paths.mcpRunner.path) else {
            throw ManagerError.prerequisite("ByoriDB를 먼저 설치해 주세요.")
        }

        guard let style = kind.descriptor.mcp else {
            throw ManagerError.prerequisite(
                "Byori는 \(kind.displayName)의 MCP 설정을 관리하지 않습니다. 직접 연결해 주세요."
            )
        }
        let removeArguments = style.removeArguments(name: "byoridb")
        let addArguments = style.addArguments(name: "byoridb", command: paths.mcpRunner.path)

        // Every CLI with a registration style has a known config file; the
        // rollback below has nothing to restore without one.
        guard let config = configFile(kind) else {
            throw ManagerError.prerequisite("\(kind.displayName)의 설정 파일 위치를 알 수 없습니다.")
        }
        let backup = try files.backup(file: config, root: paths.backups)
        do {
            _ = await runner.run(CommandSpec(
                executable: cli.path,
                arguments: removeArguments,
                environment: commonEnvironment
            ))
            try Task.checkCancellation()
            let result = await runner.run(CommandSpec(
                executable: cli.path,
                arguments: addArguments,
                environment: commonEnvironment
            ))
            try requireWithoutSensitiveOutput(result, label: "\(kind.displayName) MCP 연결")
            try Task.checkCancellation()

            guard await isMCPConnected(kind, cli: cli) else {
                throw ManagerError.verificationFailed(
                    "\(kind.displayName)의 user scope command가 \(paths.mcpRunner.path)와 일치하지 않습니다."
                )
            }
            try Task.checkCancellation()
            return OperationResult(
                summary: "\(kind.displayName) MCP 연결 완료",
                detail: mcpChangeDetail(
                    "공식 CLI로 byoridb MCP를 등록하고 실행 경로를 확인했습니다.",
                    backup: backup
                )
            )
        } catch let operationError {
            try restoreMCPConfig(
                config,
                backup: backup,
                originalError: operationError
            )
            throw operationError
        }
    }

    public func disconnectMCP(_ kind: AgentKind) async throws -> OperationResult {
        let cli = try requireCLI(kind)
        guard let style = kind.descriptor.mcp, let config = configFile(kind) else {
            throw ManagerError.prerequisite(
                "Byori는 \(kind.displayName)의 MCP 설정을 관리하지 않습니다."
            )
        }
        let arguments = style.removeArguments(name: "byoridb")
        let backup = try files.backup(file: config, root: paths.backups)
        do {
            let result = await runner.run(CommandSpec(
                executable: cli.path,
                arguments: arguments,
                environment: commonEnvironment
            ))
            try Task.checkCancellation()
            // A failed official removal is never success merely because a
            // follow-up probe also fails or cannot find the registration.
            try requireWithoutSensitiveOutput(
                result,
                label: "\(kind.displayName) MCP 연결 해제"
            )
            if await isMCPConnected(kind, cli: cli) {
                throw ManagerError.verificationFailed(
                    "\(kind.displayName)에 \(paths.mcpRunner.path)를 사용하는 byoridb MCP가 남아 있습니다."
                )
            }
            try Task.checkCancellation()
            return OperationResult(
                summary: "\(kind.displayName) MCP 연결 해제 완료",
                detail: mcpChangeDetail(
                    "공식 CLI로 byoridb MCP 등록을 제거하고 잔여 연결이 없음을 확인했습니다.",
                    backup: backup
                )
            )
        } catch let operationError {
            try restoreMCPConfig(
                config,
                backup: backup,
                originalError: operationError
            )
            throw operationError
        }
    }

    public func removeMCPRegistration(_ server: MCPServerSummary) async throws -> OperationResult {
        let cli = try requireCLI(server.agent)
        let current = await discoverMCPServers(server.agent, cli: cli)
        guard current.state == .ready else {
            throw ManagerError.verificationFailed(
                "\(server.agent.displayName) MCP 목록을 다시 확인하지 못했습니다. 잠시 후 새로고침해 주세요."
            )
        }
        guard let verified = current.servers.first(where: { $0.name == server.name }) else {
            return OperationResult(summary: "\(server.name) MCP는 이미 제거되어 있습니다.")
        }
        guard verified.management != .claudeCloudReadOnly else {
            throw ManagerError.prerequisite(
                "claude.ai 클라우드 커넥터는 여기서 변경할 수 없습니다. claude.ai에서 관리해 주세요."
            )
        }
        if verified.management == .byoriManaged {
            return try await disconnectMCP(server.agent)
        }
        guard let safeName = MCPInventoryParser.safeServerName(verified.name),
              safeName == verified.name else {
            throw ManagerError.prerequisite("이 MCP 서버 이름은 CLI로 안전하게 관리할 수 없습니다.")
        }
        if server.agent == .claude {
            guard await claudeMCPScope(name: safeName, cli: cli) == .user else {
                throw ManagerError.prerequisite(
                    "Claude Code의 user scope MCP만 이 화면에서 안전하게 제거할 수 있습니다. 다른 scope는 설정 파일에서 편집해 주세요."
                )
            }
        }

        guard let style = server.agent.descriptor.mcp, let config = configFile(server.agent) else {
            throw ManagerError.prerequisite(
                "Byori는 \(server.agent.displayName)의 MCP 설정을 관리하지 않습니다."
            )
        }
        let backup = try files.backup(file: config, root: paths.backups)
        do {
            let removeArguments = style.removeArguments(name: safeName)
            let result = await runner.run(CommandSpec(
                executable: cli.path,
                arguments: removeArguments,
                environment: commonEnvironment,
                workingDirectory: paths.home.path,
                timeout: 30
            ))
            try Task.checkCancellation()
            try requireWithoutSensitiveOutput(
                result,
                label: "\(server.agent.displayName) \(safeName) MCP 제거"
            )

            if server.agent == .claude {
                guard await claudeMCPScope(name: safeName, cli: cli) != .user else {
                    throw ManagerError.verificationFailed(
                        "Claude Code user scope에 \(safeName) MCP가 남아 있습니다."
                    )
                }
            } else {
                let verification = await discoverMCPServers(server.agent, cli: cli)
                guard verification.state == .ready,
                      !verification.servers.contains(where: { $0.name == safeName }) else {
                    throw ManagerError.verificationFailed(
                        "\(server.agent.displayName)에 \(safeName) MCP가 남아 있습니다."
                    )
                }
            }
            return OperationResult(
                summary: "\(safeName) MCP 제거 완료",
                detail: backup.map { "기존 설정 백업: \($0.path)" } ?? "변경 전 설정 파일이 없었습니다."
            )
        } catch let operationError {
            try restoreMCPConfig(config, backup: backup, originalError: operationError)
            throw operationError
        }
    }

    public func syncSkill(
        _ kind: AgentKind,
        skill: ManagedSkill = .byoridbMemory
    ) throws -> OperationResult {
        let directory = try requireSkillDirectory(skill, for: kind)
        let assets = skill.assetPaths.map { assetPath in
            (
                source: paths.skillSource(skill, assetPath: assetPath),
                destination: directory.appendingPathComponent(assetPath),
                legacy: paths.legacyCodexSkill(skill, assetPath: assetPath)
            )
        }
        for asset in assets where !fileManager.fileExists(atPath: asset.source.path) {
            throw ManagerError.missingResource(asset.source.path)
        }

        var changed = false
        for asset in assets {
            if try files.install(
                source: asset.source,
                destination: asset.destination,
                backupRoot: paths.backups
            ) {
                changed = true
            }
            if kind == .codex, fileManager.fileExists(atPath: asset.legacy.path) {
                _ = try files.remove(destination: asset.legacy, backupRoot: paths.backups)
            }
        }
        return OperationResult(
            summary: changed
                ? "\(kind.displayName) \(skill.rawValue) Skill 설치 완료"
                : "\(kind.displayName) \(skill.rawValue) Skill이 이미 최신입니다.",
            detail: directory.path
        )
    }

    public func removeSkill(
        _ kind: AgentKind,
        skill: ManagedSkill = .byoridbMemory
    ) throws -> OperationResult {
        let directory = try requireSkillDirectory(skill, for: kind)
        var removed = false
        var removedLegacy = false
        for assetPath in skill.assetPaths.reversed() {
            if try files.remove(
                destination: directory.appendingPathComponent(assetPath),
                backupRoot: paths.backups
            ) {
                removed = true
            }
            if kind == .codex {
                if try files.remove(
                    destination: paths.legacyCodexSkill(skill, assetPath: assetPath),
                    backupRoot: paths.backups
                ) {
                    removedLegacy = true
                }
            }
        }
        return OperationResult(
            summary: removed || removedLegacy
                ? "\(kind.displayName) \(skill.rawValue) Skill 제거 완료"
                : "제거할 \(kind.displayName) \(skill.rawValue) Skill이 없습니다.",
            detail: "기존 파일은 변경 전에 \(paths.backups.path)에 백업됩니다."
        )
    }

    public func removeUserSkill(_ skill: UserSkillSummary) throws -> OperationResult {
        let scanner = UserSkillScanner(home: paths.home, fileManager: fileManager)
        let directory = try scanner.validatedDirectory(for: skill)
        guard let backup = try files.backup(file: directory, root: paths.backups) else {
            throw ManagerError.verificationFailed("제거 전 Skill 백업을 만들지 못했습니다.")
        }

        do {
            // Revalidate after the backup so a path swapped for a symlink while
            // the operation was in progress cannot expand the removal scope.
            let verifiedDirectory = try scanner.validatedDirectory(for: skill)
            guard verifiedDirectory == directory else {
                throw ManagerError.verificationFailed("Skill 경로가 작업 중 변경되었습니다.")
            }
            try fileManager.removeItem(at: verifiedDirectory)
            guard !fileManager.fileExists(atPath: verifiedDirectory.path) else {
                throw ManagerError.verificationFailed("Skill 폴더가 제거 후에도 남아 있습니다.")
            }
            return OperationResult(
                summary: "\(skill.name) Skill 제거 완료",
                detail: "백업: \(backup.path)"
            )
        } catch let operationError {
            do {
                try files.restore(backup: backup, destination: directory)
            } catch {
                throw ManagerError.rollbackFailed(
                    "\(operationError.localizedDescription)\nSkill 자동 복원도 실패했습니다: \(error.localizedDescription)"
                )
            }
            throw operationError
        }
    }

    public func validatedUserSkillFile(_ skill: UserSkillSummary) throws -> URL {
        let scanner = UserSkillScanner(home: paths.home, fileManager: fileManager)
        return try scanner.validatedDirectory(for: skill).appendingPathComponent("SKILL.md")
    }

    public func startService() async throws -> OperationResult {
        try Task.checkCancellation()
        let lease = try RuntimeMutationLease.acquire(home: paths.byoriHome)
        defer { lease.release() }
        guard fileManager.fileExists(atPath: paths.launchAgent.path) else {
            throw ManagerError.prerequisite("ByoriDB를 먼저 설치해 주세요.")
        }
        let target = serviceTarget
        let bootstrap = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(getuid())", paths.launchAgent.path],
            runtimeLeaseFileDescriptor: lease.fileDescriptor
        ))
        let detail: String
        if !bootstrap.succeeded {
            let kickstart = await runner.run(CommandSpec(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "-k", target],
                runtimeLeaseFileDescriptor: lease.fileDescriptor
            ))
            try require(kickstart, label: "ByoriDB 서비스 시작")
            detail = "이미 등록된 launchd 서비스를 다시 시작하고 상태 확인을 완료했습니다."
        } else {
            detail = "launchd에 서비스를 등록하고 상태 확인을 완료했습니다."
        }
        try await verifyByori()
        return OperationResult(summary: "ByoriDB 서비스 시작 완료", detail: detail)
    }

    public func stopService() async throws -> OperationResult {
        try Task.checkCancellation()
        let lease = try RuntimeMutationLease.acquire(home: paths.byoriHome)
        defer { lease.release() }
        let result = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["bootout", serviceTarget],
            runtimeLeaseFileDescriptor: lease.fileDescriptor
        ))
        if !result.succeeded, await isServiceLoaded() {
            try require(result, label: "ByoriDB 서비스 중지")
        }
        return OperationResult(summary: "ByoriDB 서비스 중지 완료", detail: result.output)
    }

    public func restartService() async throws -> OperationResult {
        try Task.checkCancellation()
        let lease = try RuntimeMutationLease.acquire(home: paths.byoriHome)
        defer { lease.release() }
        let result = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", serviceTarget],
            runtimeLeaseFileDescriptor: lease.fileDescriptor
        ))
        try require(result, label: "ByoriDB 서비스 재시작")
        try await verifyByori()
        return OperationResult(summary: "ByoriDB 서비스 재시작 완료", detail: result.output)
    }

    private var commonEnvironment: [String: String] {
        [
            "HOME": paths.home.path,
            "PATH": paths.processPath,
            "BYORIDB_HOME": paths.byoriHome.path,
            "BYORIDB_HTTP_PORT": String(paths.httpPort),
            "BYORIDB_GRAPH_PORT": String(paths.graphPort),
            "BYORIDB_LABEL": paths.serviceLabel,
        ]
    }

    private var serviceTarget: String {
        "gui/\(getuid())/\(paths.serviceLabel)"
    }

    /// Refuses a CLI Byori installs no skill into, rather than aiming a write at
    /// a guessed directory for a skill layout that was never verified.
    private func requireSkillDirectory(
        _ skill: ManagedSkill,
        for kind: AgentKind
    ) throws -> URL {
        guard let directory = paths.skillDirectory(skill, for: kind) else {
            throw ManagerError.prerequisite(
                "\(kind.displayName)는 Byori가 관리하는 Skill 디렉터리를 사용하지 않습니다."
            )
        }
        return directory
    }

    /// The file backed up before an MCP registration is rewritten. Only the CLIs
    /// whose config location Byori knows have one; for the rest the registration
    /// path is refused earlier, so the backup is skipped rather than aimed at a
    /// guessed path.
    private func configFile(_ kind: AgentKind) -> URL? {
        switch kind {
        case .claude: return paths.claudeConfig
        case .codex: return paths.codexConfig
        case .gemini: return paths.geminiConfig
        case .cursorAgent, .opencode: return nil
        }
    }

    private func requireCLI(_ kind: AgentKind) throws -> URL {
        guard let cli = paths.executable(named: kind.executableName) else {
            throw ManagerError.missingExecutable(kind.displayName)
        }
        return cli
    }

    private func require(_ result: CommandResult, label: String) throws {
        guard result.succeeded else {
            let output = result.timedOut ? "시간 제한을 초과했습니다.\n\(result.output)" : result.output
            throw ManagerError.commandFailed(label, result.exitCode, output)
        }
    }

    private func requireWithoutSensitiveOutput(_ result: CommandResult, label: String) throws {
        guard result.succeeded else {
            let detail = result.timedOut
                ? "시간 제한을 초과했습니다. 원시 CLI 출력은 보안상 표시하지 않습니다."
                : "원시 CLI 출력은 보안상 표시하지 않습니다."
            throw ManagerError.commandFailed(label, result.exitCode, detail)
        }
    }

    private func mcpChangeDetail(_ verification: String, backup: URL?) -> String {
        guard let backup else { return verification }
        return "\(verification)\n기존 설정 백업: \(backup.path)"
    }

    private func restoreMCPConfig(
        _ config: URL,
        backup: URL?,
        originalError: Error
    ) throws {
        do {
            if let backup {
                try files.restore(backup: backup, destination: config)
            } else if fileManager.fileExists(atPath: config.path) {
                try fileManager.removeItem(at: config)
            }
        } catch {
            throw ManagerError.rollbackFailed(
                "\(originalError.localizedDescription)\n설정 자동 복원도 실패했습니다: \(error.localizedDescription)"
            )
        }
    }

    private func agentStatus(_ kind: AgentKind) async -> AgentStatus {
        guard let cli = paths.executable(named: kind.executableName) else {
            return AgentStatus(
                kind: kind,
                executablePath: nil,
                version: nil,
                mcpConnected: false,
                skillStates: skillStates(kind)
            )
        }
        let versionResult = await runner.run(CommandSpec(
            executable: cli.path,
            arguments: ["--version"],
            environment: commonEnvironment,
            timeout: 10
        ))
        return AgentStatus(
            kind: kind,
            executablePath: cli.path,
            version: versionResult.succeeded ? versionResult.output.components(separatedBy: .newlines).first : nil,
            mcpConnected: await isMCPConnected(kind, cli: cli),
            skillStates: skillStates(kind)
        )
    }

    private func integrationInventory(_ kind: AgentKind) async -> AgentIntegrationInventory {
        let skillScan = UserSkillScanner(home: paths.home, fileManager: fileManager).scan(kind)
        guard let cli = paths.executable(named: kind.executableName) else {
            return AgentIntegrationInventory(
                kind: kind,
                mcpState: .cliMissing,
                mcpServers: [],
                skillsState: skillScan.state,
                skills: skillScan.skills,
                skillsWereTruncated: skillScan.wasTruncated
            )
        }
        let mcp = await discoverMCPServers(kind, cli: cli)
        return AgentIntegrationInventory(
            kind: kind,
            mcpState: mcp.state,
            mcpServers: mcp.servers,
            skillsState: skillScan.state,
            skills: skillScan.skills,
            skillsWereTruncated: skillScan.wasTruncated
        )
    }

    private func discoverMCPServers(
        _ kind: AgentKind,
        cli: URL
    ) async -> (state: AgentInventoryState, servers: [MCPServerSummary]) {
        let parsed: [MCPInventoryParser.ParsedServer]
        switch kind {
        case .claude, .codex:
            let arguments = kind == .claude ? ["mcp", "list"] : ["mcp", "list", "--json"]
            let result = await runner.run(CommandSpec(
                executable: cli.path,
                arguments: arguments,
                environment: commonEnvironment,
                workingDirectory: paths.home.path,
                timeout: kind == .claude ? 20 : 10
            ))
            guard result.succeeded else { return (.unavailable, []) }
            if kind == .claude {
                parsed = MCPInventoryParser.claudeServers(fromText: result.output)
            } else {
                guard let codex = MCPInventoryParser.codexServers(fromJSON: result.output) else {
                    return (.unavailable, [])
                }
                parsed = codex
            }
        case .gemini:
            // `gemini mcp list` prints nothing even with servers configured
            // (0.37), so the settings file is read instead of shelling out to a
            // command whose silence is indistinguishable from "none".
            guard let config = configFile(kind) else { return (.unavailable, []) }
            parsed = MCPInventoryParser.settingsServers(
                in: config,
                serversKey: "mcpServers"
            )
        case .cursorAgent, .opencode:
            // Byori does not manage MCP for these, so it reports nothing rather
            // than guessing at a config location.
            return (.unavailable, [])
        }

        let hasByoriName = parsed.contains { $0.name == "byoridb" }
        let byoriIsManaged: Bool
        if hasByoriName {
            byoriIsManaged = await isMCPConnected(kind, cli: cli)
        } else {
            byoriIsManaged = false
        }
        let summaries = parsed.map { server in
            let management: MCPServerManagement
            if server.isClaudeCloud {
                management = .claudeCloudReadOnly
            } else if server.name == "byoridb", byoriIsManaged {
                management = .byoriManaged
            } else {
                management = .unmanaged
            }
            return MCPServerSummary(
                agent: kind,
                name: server.name,
                status: server.status,
                management: management
            )
        }
        return (.ready, summaries)
    }

    private func skillStates(_ kind: AgentKind) -> [ManagedSkill: ManagedFileState] {
        Dictionary(uniqueKeysWithValues: ManagedSkill.allCases.map { skill in
            (skill, skillState(kind, skill: skill))
        })
    }

    private func skillState(_ kind: AgentKind, skill: ManagedSkill) -> ManagedFileState {
        // A CLI Byori installs no Skill into is permanently "missing" rather
        // than pretending to track one.
        guard let directory = paths.skillDirectory(skill, for: kind) else { return .missing }
        let states = skill.assetPaths.map { assetPath in
            files.state(
                source: paths.skillSource(skill, assetPath: assetPath),
                destination: directory.appendingPathComponent(assetPath)
            )
        }
        let state: ManagedFileState
        if states.contains(.missing) {
            state = .missing
        } else if states.contains(.outdated) {
            state = .outdated
        } else {
            state = .current
        }
        if kind == .codex,
           state == .missing,
           fileManager.fileExists(atPath: paths.legacyCodexSkill(skill).path) {
            return .legacy
        }
        return state
    }

    private func isMCPConnected(_ kind: AgentKind, cli: URL) async -> Bool {
        guard let verification = kind.descriptor.mcp?.verification else { return false }
        switch verification {
        case let .cliGet(requiresUserScope):
            let result = await runner.run(CommandSpec(
                executable: cli.path,
                arguments: ["mcp", "get", "byoridb"],
                environment: commonEnvironment,
                timeout: 15
            ))
            guard result.succeeded,
                  mcpField("command", in: result.output) == paths.mcpRunner.path else {
                return false
            }
            guard requiresUserScope else { return true }
            guard let scope = mcpField("scope", in: result.output) else { return false }
            // `claude mcp get` prints the scope as "User config (available in all
            // your projects)". Drop a trailing parenthetical before matching so a
            // real user-scope registration verifies, while a different scope word
            // (e.g. "User config backup") still fails the exact comparison.
            let base = scope.split(separator: "(", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? scope
            return base.lowercased() == "user config"
        case let .settingsJSON(serversKey, commandKey):
            guard let config = configFile(kind) else { return false }
            return Self.settingsMCPCommand(
                name: "byoridb",
                in: config,
                serversKey: serversKey,
                commandKey: commandKey
            ) == paths.mcpRunner.path
        }
    }

    /// Reads one server's command out of a CLI settings file shaped like
    /// `{"<serversKey>": {"<name>": {"<commandKey>": "…"}}}`.
    static func settingsMCPCommand(
        name: String,
        in file: URL,
        serversKey: String,
        commandKey: String
    ) -> String? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root[serversKey] as? [String: Any],
              let entry = servers[name] as? [String: Any] else {
            return nil
        }
        return entry[commandKey] as? String
    }

    private func mcpField(_ name: String, in output: String) -> String? {
        let expected = name.lowercased()
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard key == expected else { continue }
            return trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private enum ClaudeMCPScope {
        case user
        case local
        case project
        case unknown
    }

    private func claudeMCPScope(name: String, cli: URL) async -> ClaudeMCPScope {
        guard MCPInventoryParser.safeServerName(name) == name else { return .unknown }
        let result = await runner.run(CommandSpec(
            executable: cli.path,
            arguments: ["mcp", "get", name],
            environment: commonEnvironment,
            workingDirectory: paths.home.path,
            timeout: 15
        ))
        guard result.succeeded, let rawScope = mcpField("scope", in: result.output) else {
            return .unknown
        }
        let scope = rawScope.split(separator: "(", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? rawScope.lowercased()
        if scope == "user config" { return .user }
        if scope == "local config" { return .local }
        if scope == "project config" { return .project }
        return .unknown
    }

    private func byoriStatus() async -> ByoriStatus {
        let installed = fileManager.isExecutableFile(atPath: paths.serverBinary.path)
        let endpointHealthy = await healthCheck()
        let credentialVerified: Bool
        if endpointHealthy {
            do {
                try await graphProvider.verifyConnection(paths: paths)
                credentialVerified = true
            } catch {
                credentialVerified = false
            }
        } else {
            credentialVerified = false
        }
        return ByoriStatus(
            isInstalled: installed,
            // "Ready" means the configured client can authenticate, not merely
            // that some process answered the unauthenticated health endpoint.
            isHealthy: endpointHealthy && credentialVerified,
            serviceLoaded: await isServiceLoaded(),
            serverVersion: await engineIdentity(),
            homePath: paths.byoriHome.path,
            pythonAvailable: paths.executable(named: "python3") != nil
        )
    }

    /// Which engine is installed, preferring the binary's own answer.
    ///
    /// The recorded manifest gates the probe rather than replacing it. Engines
    /// before 0.4.0 ignore every argument, so `--version` would start a full
    /// server against the live data directory — a status refresh must never do
    /// that. With a tag at or above 0.4.0, `--version` parses first and touches
    /// nothing, so the binary is asked and the file becomes the fallback for when
    /// the probe fails or was never recorded.
    private func engineIdentity() async -> String? {
        let manifest = EngineBuildManifest.read(at: paths.engineManifest)
        guard manifest?.allowsVersionProbe == true,
              fileManager.isExecutableFile(atPath: paths.serverBinary.path) else {
            return manifest?.displayIdentity
        }
        let result = await runner.run(CommandSpec(
            executable: paths.serverBinary.path,
            arguments: ["--version"],
            environment: commonEnvironment,
            timeout: 10
        ))
        guard result.succeeded,
              let version = EngineBuildManifest.version(fromVersionOutput: result.output) else {
            return manifest?.displayIdentity
        }
        return version
    }

    private func isServiceLoaded() async -> Bool {
        let result = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["print", serviceTarget],
            timeout: 5
        ))
        return result.succeeded
    }

    private func verifyByori() async throws {
        var sawHealthyEndpoint = false
        var authenticationFailures = 0
        var lastConnectionError: String?
        for _ in 0..<15 {
            try Task.checkCancellation()
            if await healthCheck() {
                sawHealthyEndpoint = true
                do {
                    try await graphProvider.verifyConnection(paths: paths)
                    return
                } catch KnowledgeGraphClientError.authenticationFailed {
                    authenticationFailures += 1
                    lastConnectionError = KnowledgeGraphClientError.authenticationFailed.localizedDescription
                    // Retrying catches a service that is still coming up, while
                    // failing promptly when a stale listener owns the port.
                    if authenticationFailures >= 3 { break }
                } catch let error as KnowledgeGraphClientError {
                    lastConnectionError = error.localizedDescription
                    switch error {
                    case .missingConfiguration, .invalidConfiguration:
                        throw ManagerError.verificationFailed(error.localizedDescription)
                    case .unavailable, .queryFailed, .invalidResponse, .authenticationFailed,
                         .untrustedService:
                        // 서비스가 기동 중이면 launchd/listener 신원이 아직 안 잡힐 수 있어
                        // 재시도로 흡수하고, 끝내 확인되지 않으면 루프 종료 후 실패한다.
                        break
                    }
                } catch {
                    lastConnectionError = error.localizedDescription
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if sawHealthyEndpoint {
            let detail = lastConnectionError.map { " (\($0))" } ?? ""
            throw ManagerError.verificationFailed(
                "health 응답은 있지만 현재 연결 정보로 인증할 수 없습니다. "
                    + "같은 포트를 사용하는 다른 ByoriDB 프로세스나 저장 데이터의 비밀번호를 확인해 주세요."
                    + detail
            )
        }
        throw ManagerError.verificationFailed(
            "http://127.0.0.1:\(paths.httpPort)/health 응답이 없습니다."
        )
    }

    private func verifyByoriCLI() async throws {
        let executable = paths.byoriHome.appendingPathComponent("bin/byori")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw ManagerError.verificationFailed(
                "설치 후 Byori CLI 실행 파일을 찾지 못했습니다: \(executable.path)"
            )
        }
        let result = await runner.run(CommandSpec(
            executable: executable.path,
            arguments: ["--help"],
            environment: commonEnvironment,
            timeout: 10
        ))
        try require(result, label: "Byori CLI 검증")
    }

    private func healthCheck() async -> Bool {
        if let healthProbe { return await healthProbe() }
        guard await serviceVerifier.verify(paths: paths) else { return false }
        guard let url = URL(string: "http://127.0.0.1:\(paths.httpPort)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func createRuntimeSnapshot() async throws -> RuntimeSnapshot {
        let sources: [(URL, String)] = [
            (paths.byoriHome.appendingPathComponent("bin", isDirectory: true), "bin"),
            (paths.byoriHome.appendingPathComponent("byoridb_mcp.py"), "byoridb_mcp.py"),
            (paths.byoriHome.appendingPathComponent("env"), "env"),
            (paths.byoriHome.appendingPathComponent("engine.json"), "engine.json"),
            (paths.launchAgent, "launch-agent.plist"),
        ]
        let serviceState = await runner.run(CommandSpec(
            executable: "/bin/launchctl", arguments: ["print", serviceTarget], timeout: 5
        ))
        guard !serviceState.timedOut, serviceState.succeeded || serviceState.exitCode == 113 else {
            throw ManagerError.verificationFailed("서비스의 설치 전 상태를 확인할 수 없어 설치를 중단했습니다.")
        }
        let serviceWasLoaded = serviceState.succeeded
        var serviceWasHealthy = false
        if serviceWasLoaded {
            let endpointHealthy = await healthCheck()
            if endpointHealthy {
                do {
                    try await graphProvider.verifyConnection(paths: paths)
                    serviceWasHealthy = true
                } catch {
                    // Preserve the pre-operation state honestly. A process that
                    // only answers /health is not a working Manager connection.
                    serviceWasHealthy = false
                }
            }
        }

        let snapshot = paths.backups.appendingPathComponent(
            "runtime-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshot.path)
        var existingNames = Set<String>()
        var inventory: [String: String] = [:]
        for (source, name) in sources {
            var sourceInfo = stat()
            if lstat(source.path, &sourceInfo) != 0 {
                guard errno == ENOENT else {
                    throw ManagerError.verificationFailed("런타임 스냅샷 경로를 확인할 수 없습니다.")
                }
                continue
            }
            let entries = try runtimeInventory(at: source, name: name)
            existingNames.insert(name)
            try fileManager.copyItem(at: source, to: snapshot.appendingPathComponent(name))
            guard try runtimeInventory(at: snapshot.appendingPathComponent(name), name: name) == entries else {
                throw ManagerError.verificationFailed("런타임 스냅샷 검증에 실패했습니다. 설치하지 않았습니다.")
            }
            inventory.merge(entries) { _, new in new }
        }
        return RuntimeSnapshot(
            root: snapshot,
            existingNames: existingNames,
            inventory: inventory,
            serviceWasLoaded: serviceWasLoaded,
            serviceWasHealthy: serviceWasHealthy
        )
    }

    private func rollbackRuntimeIfPossible(
        _ snapshot: RuntimeSnapshot,
        originalError: Error,
        runtimeLeaseFileDescriptor: Int32
    ) async throws {
        let destinations: [(String, URL)] = [
            ("bin", paths.byoriHome.appendingPathComponent("bin", isDirectory: true)),
            ("byoridb_mcp.py", paths.byoriHome.appendingPathComponent("byoridb_mcp.py")),
            ("env", paths.byoriHome.appendingPathComponent("env")),
            ("engine.json", paths.byoriHome.appendingPathComponent("engine.json")),
            ("launch-agent.plist", paths.launchAgent),
        ]

        do {
            // Verify every saved byte before changing any live destination. The
            // snapshot is private but a missing/corrupt backup must fail closed.
            var inventory: [String: String] = [:]
            for name in snapshot.existingNames {
                inventory.merge(try runtimeInventory(at: snapshot.root.appendingPathComponent(name), name: name)) {
                    _, new in new
                }
            }
            guard inventory == snapshot.inventory else {
                throw ManagerError.verificationFailed("런타임 스냅샷이 불완전하거나 변경되었습니다.")
            }
            // Runtime rollback is not a database backup. A replaced engine may
            // already have migrated data even if installation later failed.
            try validateRollbackData(snapshot)
            _ = await runner.run(CommandSpec(
                executable: "/bin/launchctl",
                arguments: ["bootout", serviceTarget],
                timeout: 15,
                runtimeLeaseFileDescriptor: runtimeLeaseFileDescriptor
            ))
            // A successful request is not proof the old process stopped. Refuse
            // restoration if service state is unknown or either port is occupied.
            let loaded = await runner.run(CommandSpec(
                executable: "/bin/launchctl", arguments: ["print", serviceTarget], timeout: 5
            ))
            guard loaded.exitCode == 113, !loaded.timedOut else {
                throw ManagerError.verificationFailed("서비스 중지 상태를 확인할 수 없어 파일 복원을 중단했습니다.")
            }
            for port in Set([paths.httpPort, paths.graphPort]) {
                let listener = await runner.run(CommandSpec(
                    executable: "/usr/sbin/lsof",
                    arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"], timeout: 5
                ))
                guard listener.exitCode == 1, !listener.timedOut,
                      listener.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ManagerError.verificationFailed("엔진 포트의 중지 상태를 확인할 수 없어 파일 복원을 중단했습니다.")
                }
            }
            // The engine could have created data while bootout was awaiting.
            // Recheck after stopping, immediately before any replacement.
            try validateRollbackData(snapshot)
            var stoppedInventory: [String: String] = [:]
            for name in snapshot.existingNames {
                stoppedInventory.merge(try runtimeInventory(at: snapshot.root.appendingPathComponent(name), name: name)) {
                    _, new in new
                }
            }
            guard stoppedInventory == snapshot.inventory else {
                throw ManagerError.verificationFailed("서비스 중지 중 런타임 스냅샷이 변경되었습니다.")
            }
            for (name, destination) in destinations {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                guard snapshot.existingNames.contains(name) else { continue }
                let source = snapshot.root.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw ManagerError.missingResource(source.path)
                }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
            }

            if snapshot.serviceWasLoaded {
                let restart = await runner.run(CommandSpec(
                    executable: "/bin/launchctl",
                    arguments: ["bootstrap", "gui/\(getuid())", paths.launchAgent.path],
                    timeout: 30,
                    runtimeLeaseFileDescriptor: runtimeLeaseFileDescriptor
                ))
                try require(restart, label: "ByoriDB 자동 롤백 후 서비스 시작")
                guard await isServiceLoaded() else {
                    throw ManagerError.verificationFailed("롤백한 launchd 서비스가 로드되지 않았습니다.")
                }
                if snapshot.serviceWasHealthy {
                    try await verifyByori()
                }
            } else if await isServiceLoaded() {
                throw ManagerError.verificationFailed("롤백 후 중지 상태를 복원하지 못했습니다.")
            }
        } catch {
            throw ManagerError.rollbackFailed(
                "\(originalError.localizedDescription)\n자동 롤백도 실패했습니다: \(error.localizedDescription)"
            )
        }
    }

    private func validateRollbackData(_ snapshot: RuntimeSnapshot) throws {
        let data = paths.byoriHome.appendingPathComponent("data", isDirectory: true)
        var dataInfo = stat()
        let dataExists = lstat(data.path, &dataInfo) == 0
        if !dataExists, errno != ENOENT {
            throw ManagerError.verificationFailed("데이터 상태를 확인할 수 없어 엔진 롤백을 중단했습니다.")
        }
        if dataExists {
            guard (dataInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw ManagerError.verificationFailed("안전한 데이터 디렉터리가 아니어서 엔진 롤백을 중단했습니다.")
            }
            if !(try fileManager.contentsOfDirectory(atPath: data.path)).isEmpty {
                let engineName = "bin/byoridb-server"
                let engine = paths.byoriHome.appendingPathComponent(engineName)
                var engineInfo = stat()
                let engineExists = lstat(engine.path, &engineInfo) == 0
                if !engineExists, errno != ENOENT {
                    throw ManagerError.verificationFailed("엔진 파일 상태를 확인할 수 없어 롤백을 중단했습니다.")
                }
                let live = engineExists ? try runtimeInventory(at: engine, name: engineName)[engineName] : nil
                guard live == snapshot.inventory[engineName] else {
                    throw ManagerError.verificationFailed(
                        "엔진이 변경되었고 데이터가 존재합니다. 데이터 호환성/백업 확인 전 자동 롤백하지 않습니다. 런타임 스냅샷은 보존했습니다."
                    )
                }
            }
        }
    }

    /// Rollback must not inherit cancellation from the operation that caused
    /// it. Otherwise a user Cancel can terminate the installer and then also
    /// cancel the commands needed to restore the previous runtime.
    private func rollbackRuntimeUncancelled(
        _ snapshot: RuntimeSnapshot,
        originalError: Error,
        runtimeLeaseFileDescriptor: Int32
    ) async throws {
        let rollback = Task.detached(priority: .userInitiated) { [self] in
            try await rollbackRuntimeIfPossible(
                snapshot, originalError: originalError,
                runtimeLeaseFileDescriptor: runtimeLeaseFileDescriptor
            )
        }
        try await rollback.value
    }

    /// A bounded byte-and-mode inventory; never follow symlinks or read special
    /// files while snapshotting. Original graph data is outside this inventory.
    private func runtimeInventory(at root: URL, name: String) throws -> [String: String] {
        var entries: [String: String] = [:]
        var remainingBytes = 1_073_741_824
        func visit(_ url: URL, _ key: String, depth: Int = 0) throws {
            var info = stat()
            guard depth <= 64, entries.count < 10_000, lstat(url.path, &info) == 0,
                  info.st_uid == getuid() else {
                throw ManagerError.verificationFailed("런타임 스냅샷 파일을 안전하게 확인할 수 없습니다.")
            }
            let mode = info.st_mode & 0o7777
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                entries[key] = "directory:\(mode)"
                for child in try fileManager.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(url.appendingPathComponent(child), key + "/" + child, depth: depth + 1)
                }
            case S_IFREG:
                guard info.st_nlink == 1, info.st_size >= 0, info.st_size <= remainingBytes else {
                    throw ManagerError.verificationFailed("런타임 스냅샷의 파일 크기 또는 링크가 안전하지 않습니다.")
                }
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else {
                    throw ManagerError.verificationFailed("런타임 스냅샷 파일을 열 수 없습니다.")
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev,
                      opened.st_ino == info.st_ino, (opened.st_mode & S_IFMT) == S_IFREG else {
                    throw ManagerError.verificationFailed("런타임 스냅샷 파일이 변경되었습니다.")
                }
                var digest = SHA256()
                var size = 0
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    remainingBytes -= chunk.count
                    guard remainingBytes >= 0 else {
                        throw ManagerError.verificationFailed("런타임 스냅샷 크기 제한을 초과했습니다.")
                    }
                    size += chunk.count
                    digest.update(data: chunk)
                }
                guard size == info.st_size else {
                    throw ManagerError.verificationFailed("런타임 스냅샷 파일이 변경되었습니다.")
                }
                entries[key] = "file:\(mode):" + digest.finalize().map { String(format: "%02x", $0) }.joined()
            default:
                throw ManagerError.verificationFailed("런타임 스냅샷에 심볼릭 링크 또는 특수 파일이 있습니다.")
            }
        }
        try visit(root, name)
        return entries
    }
}
