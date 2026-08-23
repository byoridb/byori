import Darwin
import Foundation

public actor ManagerService {
    private struct RuntimeSnapshot: Sendable {
        let root: URL
        let existingNames: Set<String>
        let serviceWasLoaded: Bool
        let serviceWasHealthy: Bool
    }

    public nonisolated let paths: ManagerPaths
    private let runner: any CommandRunning
    private let files: ManagedFileInstaller
    private let graphProvider: any KnowledgeGraphProviding
    private let fileManager: FileManager
    private let serviceVerifier: LocalServiceVerifier
    /// Settings' own tmux probe. Deliberately separate from the terminal
    /// controller's: this one answers status questions, and both caches are
    /// refreshed after an install so neither can keep reporting the old answer.
    private let tmux: TmuxSessionService

    public init(
        paths: ManagerPaths = .applicationDefault(),
        runner: any CommandRunning = ProcessCommandRunner(),
        files: ManagedFileInstaller = ManagedFileInstaller(),
        graphProvider: any KnowledgeGraphProviding = ByoriGraphClient(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.runner = runner
        self.files = files
        self.graphProvider = graphProvider
        self.fileManager = fileManager
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
    /// - **The engine** is resolved at install time by `--engine-tag latest`, which
    ///   falls back to the installer's pinned tag when GitHub cannot be reached.
    public func installOrUpdateByori() async throws -> OperationResult {
        try Task.checkCancellation()
        guard paths.executable(named: "python3") != nil else {
            throw ManagerError.prerequisite(
                "현재 MCP 런타임에는 python3가 필요합니다. Python 3를 설치한 뒤 다시 시도해 주세요."
            )
        }
        let snapshot = try await createRuntimeSnapshot()
        try Task.checkCancellation()
        let result = await runner.run(byoriInstallCommand())
        do {
            try require(result, label: "ByoriDB 설치")
            try await verifyByori()
            try await verifyByoriCLI()
        } catch {
            try await rollbackRuntimeUncancelled(snapshot, originalError: error)
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

    /// The bundled installer when the app carries one, otherwise the installer from
    /// the latest release. Both ask for the newest engine release.
    func byoriInstallCommand() -> CommandSpec {
        let engineArguments = ["--engine-tag", "latest", "--no-claude", "--no-codex"]
        guard fileManager.fileExists(atPath: paths.installer.path) else {
            let command = "/usr/bin/curl -fsSL "
                + "https://github.com/byoridb/byori/releases/latest/download/install.sh "
                + "| /bin/bash -s -- " + engineArguments.joined(separator: " ")
            return CommandSpec(
                executable: "/bin/bash",
                arguments: ["-o", "pipefail", "-c", command],
                environment: commonEnvironment,
                timeout: 900
            )
        }
        return CommandSpec(
            executable: "/bin/bash",
            arguments: [paths.installer.path, "--assets", paths.runtimeRoot.path] + engineArguments,
            environment: commonEnvironment,
            timeout: 900
        )
    }

    /// Reports whether a newer signed release exists, without downloading it.
    public func checkForAppUpdate() async throws -> AppUpdateStatus {
        try await makeAppUpdater().check()
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
        guard fileManager.fileExists(atPath: paths.launchAgent.path) else {
            throw ManagerError.prerequisite("ByoriDB를 먼저 설치해 주세요.")
        }
        let target = serviceTarget
        let bootstrap = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(getuid())", paths.launchAgent.path]
        ))
        let detail: String
        if !bootstrap.succeeded {
            let kickstart = await runner.run(CommandSpec(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "-k", target]
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
        let result = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["bootout", serviceTarget]
        ))
        if !result.succeeded, await isServiceLoaded() {
            try require(result, label: "ByoriDB 서비스 중지")
        }
        return OperationResult(summary: "ByoriDB 서비스 중지 완료", detail: result.output)
    }

    public func restartService() async throws -> OperationResult {
        let result = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", serviceTarget]
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
            (paths.launchAgent, "launch-agent.plist"),
        ]
        let serviceWasLoaded = await isServiceLoaded()
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
        for (source, name) in sources where fileManager.fileExists(atPath: source.path) {
            existingNames.insert(name)
            try fileManager.copyItem(at: source, to: snapshot.appendingPathComponent(name))
        }
        return RuntimeSnapshot(
            root: snapshot,
            existingNames: existingNames,
            serviceWasLoaded: serviceWasLoaded,
            serviceWasHealthy: serviceWasHealthy
        )
    }

    private func rollbackRuntimeIfPossible(
        _ snapshot: RuntimeSnapshot,
        originalError: Error
    ) async throws {
        let destinations: [(String, URL)] = [
            ("bin", paths.byoriHome.appendingPathComponent("bin", isDirectory: true)),
            ("byoridb_mcp.py", paths.byoriHome.appendingPathComponent("byoridb_mcp.py")),
            ("env", paths.byoriHome.appendingPathComponent("env")),
            ("launch-agent.plist", paths.launchAgent),
        ]

        _ = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["bootout", serviceTarget],
            timeout: 15
        ))

        do {
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
                    timeout: 30
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

    /// Rollback must not inherit cancellation from the operation that caused
    /// it. Otherwise a user Cancel can terminate the installer and then also
    /// cancel the commands needed to restore the previous runtime.
    private func rollbackRuntimeUncancelled(
        _ snapshot: RuntimeSnapshot,
        originalError: Error
    ) async throws {
        let rollback = Task.detached(priority: .userInitiated) { [self] in
            try await rollbackRuntimeIfPossible(snapshot, originalError: originalError)
        }
        try await rollback.value
    }
}
