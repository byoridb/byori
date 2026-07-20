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
    }

    public func snapshot() async -> ManagerSnapshot {
        let byori = await byoriStatus()
        var agents: [AgentStatus] = []
        for kind in AgentKind.allCases {
            agents.append(await agentStatus(kind))
        }
        return ManagerSnapshot(byori: byori, agents: agents)
    }

    public func loadKnowledgeGraph(limit: Int = 200) async throws -> KnowledgeGraphSnapshot {
        try await graphProvider.loadGraph(paths: paths, nodeLimit: limit)
    }

    public func loadKnowledgeBody(nodeID: Int64) async throws -> String {
        try await graphProvider.loadBody(paths: paths, nodeID: nodeID)
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
        guard fileManager.fileExists(atPath: paths.installer.path) else {
            throw ManagerError.missingResource(paths.installer.path)
        }
        guard paths.executable(named: "python3") != nil else {
            throw ManagerError.prerequisite(
                "현재 MCP 런타임에는 python3가 필요합니다. Python 3를 설치한 뒤 다시 시도해 주세요."
            )
        }
        let snapshot = try await createRuntimeSnapshot()
        let result = await runner.run(CommandSpec(
            executable: "/bin/bash",
            arguments: [
                paths.installer.path,
                "--assets", paths.runtimeRoot.path,
                "--no-claude",
            ],
            environment: commonEnvironment,
            timeout: 900
        ))
        do {
            try require(result, label: "ByoriDB 설치")
            try await verifyByori()
        } catch {
            try await rollbackRuntimeIfPossible(snapshot, originalError: error)
            throw error
        }
        return OperationResult(summary: "ByoriDB 설치/복구 완료", detail: result.output)
    }

    public func updateByoriOnline() async throws -> OperationResult {
        guard paths.executable(named: "python3") != nil else {
            throw ManagerError.prerequisite(
                "현재 MCP 런타임에는 python3가 필요합니다. Python 3를 설치한 뒤 다시 시도해 주세요."
            )
        }
        let command = "/usr/bin/curl -fsSL "
            + "https://github.com/byoridb/byori/releases/latest/download/install.sh "
            + "| /bin/bash -s -- --no-claude"
        let snapshot = try await createRuntimeSnapshot()
        let result = await runner.run(CommandSpec(
            executable: "/bin/bash",
            arguments: ["-o", "pipefail", "-c", command],
            environment: commonEnvironment,
            timeout: 900
        ))
        do {
            try require(result, label: "ByoriDB 온라인 업데이트")
            try await verifyByori()
        } catch {
            try await rollbackRuntimeIfPossible(snapshot, originalError: error)
            throw error
        }
        return OperationResult(summary: "ByoriDB 업데이트 완료", detail: result.output)
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
        _ = await runner.run(CommandSpec(
            executable: cli.path,
            arguments: removeArguments,
            environment: commonEnvironment
        ))

        do {
            let result = await runner.run(CommandSpec(
                executable: cli.path,
                arguments: addArguments,
                environment: commonEnvironment
            ))
            try require(result, label: "\(kind.displayName) MCP 연결")

            guard await isMCPConnected(kind, cli: cli) else {
                throw ManagerError.verificationFailed(
                    "\(kind.displayName)의 user scope command가 \(paths.mcpRunner.path)와 일치하지 않습니다."
                )
            }
            return OperationResult(
                summary: "\(kind.displayName) MCP 연결 완료",
                detail: backup.map { "기존 설정 백업: \($0.path)\n\(result.output)" }
                    ?? result.output
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
            if await isMCPConnected(kind, cli: cli) {
                if !result.succeeded {
                    try require(result, label: "\(kind.displayName) MCP 연결 해제")
                }
                throw ManagerError.verificationFailed(
                    "\(kind.displayName)에 \(paths.mcpRunner.path)를 사용하는 byoridb MCP가 남아 있습니다."
                )
            }
            return OperationResult(
                summary: "\(kind.displayName) MCP 연결 해제 완료",
                detail: backup.map { "기존 설정 백업: \($0.path)\n\(result.output)" }
                    ?? result.output
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

    public func startService() async throws -> OperationResult {
        guard fileManager.fileExists(atPath: paths.launchAgent.path) else {
            throw ManagerError.prerequisite("ByoriDB를 먼저 설치해 주세요.")
        }
        let target = serviceTarget
        let bootstrap = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(getuid())", paths.launchAgent.path]
        ))
        if !bootstrap.succeeded {
            let kickstart = await runner.run(CommandSpec(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "-k", target]
            ))
            try require(kickstart, label: "ByoriDB 서비스 시작")
        }
        try await verifyByori()
        return OperationResult(summary: "ByoriDB 서비스 시작 완료", detail: bootstrap.output)
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
            throw ManagerError.verificationFailed(
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

    private func byoriStatus() async -> ByoriStatus {
        let installed = fileManager.isExecutableFile(atPath: paths.serverBinary.path)
        return ByoriStatus(
            isInstalled: installed,
            isHealthy: await healthCheck(),
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
        for _ in 0..<15 {
            if await healthCheck() { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ManagerError.verificationFailed(
            "http://127.0.0.1:\(paths.httpPort)/health 응답이 없습니다."
        )
    }

    private func healthCheck() async -> Bool {
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
            serviceWasHealthy = await healthCheck()
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
            throw ManagerError.verificationFailed(
                "\(originalError.localizedDescription)\n자동 롤백도 실패했습니다: \(error.localizedDescription)"
            )
        }
    }
}
