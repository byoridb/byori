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
    }

    public func snapshot() async -> ManagerSnapshot {
        let byori = await byoriStatus()
        var agents: [AgentStatus] = []
        for kind in AgentKind.allCases {
            agents.append(await agentStatus(kind))
        }
        return ManagerSnapshot(byori: byori, agents: agents)
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

    public func loadKnowledgeGraph(limit: Int = 200) async throws -> KnowledgeGraphSnapshot {
        try await loadKnowledgeGraph(space: nil, limit: limit)
    }

    public func loadKnowledgeGraph(
        space: String?,
        limit: Int = 200
    ) async throws -> KnowledgeGraphSnapshot {
        try await graphProvider.loadGraph(paths: paths, nodeLimit: limit, space: space)
    }

    public func loadKnowledgeBody(nodeID: Int64, tag: String) async throws -> String {
        try await loadKnowledgeBody(nodeID: nodeID, tag: tag, space: nil)
    }

    public func loadKnowledgeBody(
        nodeID: Int64,
        tag: String,
        space: String?
    ) async throws -> String {
        try await graphProvider.loadBody(
            paths: paths,
            nodeID: nodeID,
            tag: tag,
            space: space
        )
    }

    public func installOrUpdateCLI(_ kind: AgentKind) async throws -> OperationResult {
        let command: String
        switch kind {
        case .claude:
            command = "/usr/bin/curl -fsSL https://claude.ai/install.sh | /bin/bash"
        case .codex:
            command = "/usr/bin/curl -fsSL https://chatgpt.com/codex/install.sh | /bin/sh"
        }
        let result = await runner.run(CommandSpec(
            executable: "/bin/bash",
            arguments: ["-o", "pipefail", "-c", command],
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

    public func installByoriBundled() async throws -> OperationResult {
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: paths.installer.path) else {
            throw ManagerError.missingResource(paths.installer.path)
        }
        guard paths.executable(named: "python3") != nil else {
            throw ManagerError.prerequisite(
                "현재 MCP 런타임에는 python3가 필요합니다. Python 3를 설치한 뒤 다시 시도해 주세요."
            )
        }
        let snapshot = try await createRuntimeSnapshot()
        try Task.checkCancellation()
        let result = await runner.run(CommandSpec(
            executable: "/bin/bash",
            arguments: [
                paths.installer.path,
                "--assets", paths.runtimeRoot.path,
                "--no-claude",
                "--no-codex",
            ],
            environment: commonEnvironment,
            timeout: 900
        ))
        do {
            try require(result, label: "ByoriDB 설치")
            try await verifyByori()
            try await verifyByoriCLI()
        } catch {
            try await rollbackRuntimeUncancelled(snapshot, originalError: error)
            throw error
        }
        return OperationResult(summary: "ByoriDB 설치/복구 완료", detail: result.output)
    }

    public func updateByoriOnline() async throws -> OperationResult {
        try Task.checkCancellation()
        guard paths.executable(named: "python3") != nil else {
            throw ManagerError.prerequisite(
                "현재 MCP 런타임에는 python3가 필요합니다. Python 3를 설치한 뒤 다시 시도해 주세요."
            )
        }
        let command = "/usr/bin/curl -fsSL "
            + "https://github.com/byoridb/byori/releases/latest/download/install.sh "
            + "| /bin/bash -s -- --no-claude --no-codex"
        let snapshot = try await createRuntimeSnapshot()
        try Task.checkCancellation()
        let result = await runner.run(CommandSpec(
            executable: "/bin/bash",
            arguments: ["-o", "pipefail", "-c", command],
            environment: commonEnvironment,
            timeout: 900
        ))
        do {
            try require(result, label: "ByoriDB 온라인 업데이트")
            try await verifyByori()
            try await verifyByoriCLI()
        } catch {
            try await rollbackRuntimeUncancelled(snapshot, originalError: error)
            throw error
        }
        return OperationResult(summary: "ByoriDB 업데이트 완료", detail: result.output)
    }

    /// Reports whether a newer signed release exists, without downloading it.
    public func checkForAppUpdate() async throws -> AppUpdateStatus {
        try await makeAppUpdater().check()
    }

    /// Verifies a newer release and hands the swap to a detached helper. The
    /// caller must quit the app once this returns; the helper waits for the
    /// process to exit before replacing the bundle and reopening it.
    public func updateApp(progress: AppUpdateProgress? = nil) async throws -> OperationResult {
        let updater = try makeAppUpdater()
        progress?(.checking)
        guard case let .available(update) = try await updater.check() else {
            throw ManagerError.prerequisite("이미 최신 버전입니다.")
        }
        let staged = try await updater.stage(update, progress: progress)
        do {
            return try await updater.apply(staged, progress: progress)
        } catch {
            await updater.discard(staged)
            throw error
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

        let removeArguments: [String]
        let addArguments: [String]
        switch kind {
        case .claude:
            removeArguments = ["mcp", "remove", "--scope", "user", "byoridb"]
            addArguments = [
                "mcp", "add", "--transport", "stdio", "--scope", "user",
                "byoridb", "--", paths.mcpRunner.path,
            ]
        case .codex:
            removeArguments = ["mcp", "remove", "byoridb"]
            addArguments = ["mcp", "add", "byoridb", "--", paths.mcpRunner.path]
        }

        let config = configFile(kind)
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
        let arguments: [String]
        switch kind {
        case .claude:
            arguments = ["mcp", "remove", "--scope", "user", "byoridb"]
        case .codex:
            arguments = ["mcp", "remove", "byoridb"]
        }
        let config = configFile(kind)
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

        let config = configFile(server.agent)
        let backup = try files.backup(file: config, root: paths.backups)
        do {
            let removeArguments: [String]
            switch server.agent {
            case .claude:
                removeArguments = ["mcp", "remove", "--scope", "user", safeName]
            case .codex:
                removeArguments = ["mcp", "remove", safeName]
            }
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

    public func syncSkill(_ kind: AgentKind) throws -> OperationResult {
        guard fileManager.fileExists(atPath: paths.skillSource.path) else {
            throw ManagerError.missingResource(paths.skillSource.path)
        }
        let destination = skillDestination(kind)
        let changed = try files.install(
            source: paths.skillSource,
            destination: destination,
            backupRoot: paths.backups
        )
        if kind == .codex, fileManager.fileExists(atPath: paths.legacyCodexSkill.path) {
            _ = try files.remove(destination: paths.legacyCodexSkill, backupRoot: paths.backups)
        }
        return OperationResult(
            summary: changed
                ? "\(kind.displayName) Skill 설치 완료"
                : "\(kind.displayName) Skill이 이미 최신입니다.",
            detail: destination.path
        )
    }

    public func removeSkill(_ kind: AgentKind) throws -> OperationResult {
        let removed = try files.remove(
            destination: skillDestination(kind),
            backupRoot: paths.backups
        )
        var removedLegacy = false
        if kind == .codex {
            removedLegacy = try files.remove(
                destination: paths.legacyCodexSkill,
                backupRoot: paths.backups
            )
        }
        return OperationResult(
            summary: removed || removedLegacy
                ? "\(kind.displayName) Skill 제거 완료"
                : "제거할 \(kind.displayName) Skill이 없습니다.",
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

    private func skillDestination(_ kind: AgentKind) -> URL {
        switch kind {
        case .claude: return paths.claudeSkill
        case .codex: return paths.codexSkill
        }
    }

    private func configFile(_ kind: AgentKind) -> URL {
        switch kind {
        case .claude: return paths.claudeConfig
        case .codex: return paths.codexConfig
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
                skillState: skillState(kind)
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
            skillState: skillState(kind)
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
        let arguments: [String]
        let timeout: TimeInterval
        switch kind {
        case .claude:
            arguments = ["mcp", "list"]
            timeout = 20
        case .codex:
            arguments = ["mcp", "list", "--json"]
            timeout = 10
        }
        let result = await runner.run(CommandSpec(
            executable: cli.path,
            arguments: arguments,
            environment: commonEnvironment,
            workingDirectory: paths.home.path,
            timeout: timeout
        ))
        guard result.succeeded else { return (.unavailable, []) }

        let parsed: [MCPInventoryParser.ParsedServer]
        switch kind {
        case .claude:
            parsed = MCPInventoryParser.claudeServers(fromText: result.output)
        case .codex:
            guard let codex = MCPInventoryParser.codexServers(fromJSON: result.output) else {
                return (.unavailable, [])
            }
            parsed = codex
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

    private func skillState(_ kind: AgentKind) -> ManagedFileState {
        let destination = skillDestination(kind)
        let state = files.state(source: paths.skillSource, destination: destination)
        if kind == .codex,
           state == .missing,
           fileManager.fileExists(atPath: paths.legacyCodexSkill.path) {
            return .legacy
        }
        return state
    }

    private func isMCPConnected(_ kind: AgentKind, cli: URL) async -> Bool {
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
        if kind == .claude {
            guard let scope = mcpField("scope", in: result.output) else { return false }
            // `claude mcp get` prints the scope as "User config (available in all
            // your projects)". Drop a trailing parenthetical before matching so a
            // real user-scope registration verifies, while a different scope word
            // (e.g. "User config backup") still fails the exact comparison.
            let base = scope.split(separator: "(", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? scope
            return base.lowercased() == "user config"
        }
        return true
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
            // Engine v0.3.3 treats `--version` as a normal server launch. Do not
            // probe it here: a status refresh must never start a second database.
            serverVersion: nil,
            homePath: paths.byoriHome.path,
            pythonAvailable: paths.executable(named: "python3") != nil
        )
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
