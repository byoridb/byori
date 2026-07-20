import ByoriManagerCore
import Darwin
import Foundation

@main
enum ByoriManagerSelfTest {
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("byori-manager-self-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let source = root.appendingPathComponent("runtime/SKILL.md")
        let destination = root.appendingPathComponent("home/.agents/skills/byoridb-memory/SKILL.md")
        let backups = root.appendingPathComponent("backups")
        try fileManager.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("version-one".utf8).write(to: source)

        let installer = ManagedFileInstaller()
        guard try installer.install(source: source, destination: destination, backupRoot: backups) else {
            throw Failure("first install did not report a change")
        }
        guard installer.state(source: source, destination: destination) == .current else {
            throw Failure("installed skill is not current")
        }
        guard try !installer.install(source: source, destination: destination, backupRoot: backups) else {
            throw Failure("idempotent install reported a change")
        }

        try Data("version-two".utf8).write(to: source)
        guard installer.state(source: source, destination: destination) == .outdated else {
            throw Failure("changed source was not detected")
        }
        guard try installer.install(source: source, destination: destination, backupRoot: backups) else {
            throw Failure("update did not report a change")
        }
        let backupCount = try fileManager.contentsOfDirectory(atPath: backups.path).count
        guard backupCount == 1 else {
            throw Failure("expected one backup, found \(backupCount)")
        }

        let paths = ManagerPaths(home: root.appendingPathComponent("home"), runtimeRoot: root)
        guard paths.codexSkill.path.hasSuffix("/.agents/skills/byoridb-memory/SKILL.md") else {
            throw Failure("Codex skill path is not the current official location")
        }

        guard try installer.remove(destination: destination, backupRoot: backups) else {
            throw Failure("remove did not report a change")
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw Failure("skill still exists after remove")
        }

        let claude = paths.home.appendingPathComponent(".local/bin/claude")
        try fileManager.createDirectory(
            at: claude.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claude)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        try fileManager.createDirectory(
            at: paths.mcpRunner.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: paths.mcpRunner)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.mcpRunner.path)

        let runner = RecordingRunner(mcpPath: paths.mcpRunner.path)
        let service = ManagerService(paths: paths, runner: runner)
        _ = try await service.connectMCP(.claude)
        let commands = await runner.recordedCommands
        guard commands.count == 3 else {
            throw Failure("expected remove, add and verify commands; found \(commands.count)")
        }
        guard commands[1].arguments == [
            "mcp", "add", "--transport", "stdio", "--scope", "user",
            "byoridb", "--", paths.mcpRunner.path,
        ] else {
            throw Failure("Claude MCP add arguments are incorrect: \(commands[1].arguments)")
        }

        _ = try await service.installOrUpdateCLI(.claude)
        guard let installerCommand = await runner.recordedCommands.last,
              installerCommand.executable == "/bin/bash",
              installerCommand.arguments == [
                  "-o", "pipefail", "-c",
                  "/usr/bin/curl -fsSL https://claude.ai/install.sh | /bin/bash",
              ] else {
            throw Failure("Claude installer command is not deterministic or official")
        }

        try Data("original-config".utf8).write(to: paths.claudeConfig)
        let failingRunner = RecordingRunner(mcpPath: paths.mcpRunner.path, failOnAdd: true)
        let failingService = ManagerService(paths: paths, runner: failingRunner)
        do {
            _ = try await failingService.connectMCP(.claude)
            throw Failure("expected MCP add failure")
        } catch is Failure {
            throw Failure("MCP add failure was not surfaced by ManagerService")
        } catch {
            let restored = try Data(contentsOf: paths.claudeConfig)
            guard restored == Data("original-config".utf8) else {
                throw Failure("MCP config backup was not restored after add failure")
            }
        }

        try Data("disconnect-original".utf8).write(to: paths.claudeConfig)
        do {
            _ = try await service.disconnectMCP(.claude)
            throw Failure("expected MCP disconnect verification failure")
        } catch is Failure {
            throw Failure("MCP disconnect verification failure was not surfaced")
        } catch {
            let restored = try Data(contentsOf: paths.claudeConfig)
            guard restored == Data("disconnect-original".utf8) else {
                throw Failure("MCP config backup was not restored after disconnect failure")
            }
        }

        let falsePathRunner = RecordingRunner(mcpPath: paths.mcpRunner.path + ".old")
        do {
            _ = try await ManagerService(paths: paths, runner: falsePathRunner).connectMCP(.claude)
            throw Failure("MCP verification accepted a command path substring")
        } catch is Failure {
            throw Failure("MCP command path must be matched exactly")
        } catch {}

        let falseScopeRunner = RecordingRunner(
            mcpPath: paths.mcpRunner.path,
            scope: "User config backup"
        )
        do {
            _ = try await ManagerService(paths: paths, runner: falseScopeRunner).connectMCP(.claude)
            throw Failure("MCP verification accepted a user scope substring")
        } catch is Failure {
            throw Failure("MCP user scope must be matched exactly")
        } catch {}

        // Real `claude mcp get` appends a parenthetical to the scope; verification
        // must accept it (regression: exact "user config" match rejected a healthy
        // registration and surfaced a spurious connect failure).
        let realScopeRunner = RecordingRunner(
            mcpPath: paths.mcpRunner.path,
            scope: "User config (available in all your projects)"
        )
        _ = try await ManagerService(paths: paths, runner: realScopeRunner).connectMCP(.claude)

        let discoveryHome = root.appendingPathComponent("discovery-home", isDirectory: true)
        let discoveredByoriHome = discoveryHome.appendingPathComponent("custom-runtime", isDirectory: true)
        let launchAgents = discoveryHome.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(
            at: discoveredByoriHome.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        export BYORIDB__SERVER__HTTP_ADDR="127.0.0.1:20669"
        export BYORIDB__SERVER__GRAPH_ADDR="127.0.0.1:10669"
        """.utf8).write(to: discoveredByoriHome.appendingPathComponent("bin/run-server.sh"))
        let plist: [String: Any] = [
            "Label": "io.byoridb.custom",
            "ProgramArguments": ["/bin/sh", discoveredByoriHome.appendingPathComponent("bin/run-server.sh").path],
            "WorkingDirectory": discoveredByoriHome.path,
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: launchAgents.appendingPathComponent("io.byoridb.custom.plist"))
        let discovered = ManagerPaths.applicationDefault(
            bundle: .main,
            home: discoveryHome,
            environment: [:]
        )
        guard discovered.byoriHome == discoveredByoriHome.standardizedFileURL,
              discovered.httpPort == 20_669,
              discovered.graphPort == 10_669,
              discovered.serviceLabel == "io.byoridb.custom" else {
            throw Failure("Finder-style launch did not discover custom ByoriDB settings")
        }

        let processRunner = ProcessCommandRunner()
        let workingDirectory = await processRunner.run(CommandSpec(
            executable: "/bin/pwd",
            workingDirectory: root.path
        ))
        let expectedWorkingDirectory = root.path.withCString { path -> String in
            guard let resolved = Darwin.realpath(path, nil) else { return root.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard workingDirectory.succeeded,
              workingDirectory.output == expectedWorkingDirectory else {
            throw Failure(
                "command working directory was not applied at spawn: \(workingDirectory.output)"
            )
        }
        let noisy = await processRunner.run(CommandSpec(
            executable: "/usr/bin/awk",
            arguments: ["BEGIN { for (i=0; i<300000; i++) printf \"x\"; print \"END\" }"]
        ))
        guard noisy.succeeded, noisy.output.utf8.count <= 256 * 1_024,
              noisy.output.hasSuffix("END") else {
            throw Failure("command output was not retained as a bounded tail")
        }

        let childPIDFile = root.appendingPathComponent("timeout-child.pid")
        let timeoutStart = Date()
        let timed = await processRunner.run(CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do :; done' & " +
                    "echo $! > \"$PID_FILE\"; wait",
            ],
            environment: ["PID_FILE": childPIDFile.path],
            timeout: 0.2
        ))
        guard timed.timedOut, Date().timeIntervalSince(timeoutStart) < 4 else {
            throw Failure("command timeout did not terminate the process promptly")
        }
        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let childPID = pid_t(childPIDText) else {
            throw Failure("timeout child did not publish a valid pid")
        }
        for _ in 0..<20 where kill(childPID, 0) == 0 {
            usleep(25_000)
        }
        if kill(childPID, 0) == 0 {
            _ = kill(childPID, SIGKILL)
            throw Failure("timeout left child process \(childPID) running")
        }

        let graph = KnowledgeGraphSnapshot(
            nodes: [
                KnowledgeNode(id: 1, name: "Root", kind: "concept", timestamp: 100),
                KnowledgeNode(id: 2, name: "Child", kind: "concept", timestamp: 200),
                KnowledgeNode(id: 3, name: "Sibling", kind: "concept", timestamp: 300),
                KnowledgeNode(id: 4, name: "Isolated", kind: "concept", timestamp: 400),
            ],
            edges: [
                KnowledgeEdge(source: 1, target: 2, kind: "contains"),
                KnowledgeEdge(source: 1, target: 3, kind: "contains"),
            ]
        )
        guard KnowledgeGraphLayout.suggestedRoot(for: graph) == 1,
              KnowledgeGraphLayout.suggestedRoot(for: graph, preferred: 4) == 4 else {
            throw Failure("knowledge graph root selection is incorrect")
        }
        for mode in KnowledgeGraphLayoutMode.allCases {
            let positions = KnowledgeGraphLayout.positions(for: graph, mode: mode, rootID: 1)
            let repeated = KnowledgeGraphLayout.positions(for: graph, mode: mode, rootID: 1)
            guard positions == repeated else {
                throw Failure("\(mode.rawValue) graph layout is not deterministic")
            }
            guard Set(positions.keys) == Set(graph.nodes.map(\.id)),
                  positions.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw Failure("\(mode.rawValue) graph layout omitted a node or produced invalid coordinates")
            }
        }
        let mindMap = KnowledgeGraphLayout.positions(for: graph, mode: .mindMap, rootID: 1)
        guard let rootPoint = mindMap[1], let childPoint = mindMap[2],
              childPoint.x > rootPoint.x else {
            throw Failure("mind-map children must be positioned to the right of the root")
        }

        if ProcessInfo.processInfo.environment["BYORI_MANAGER_LIVE_GRAPH_TEST"] == "1" {
            let livePaths = ManagerPaths.applicationDefault()
            let client = ByoriGraphClient()
            let liveGraph = try await client.loadGraph(paths: livePaths, nodeLimit: 200)
            if let firstNode = liveGraph.nodes.first {
                _ = try await client.loadBody(paths: livePaths, nodeID: firstNode.id)
            }
            print(
                "ByoriManager live graph PASS "
                    + "(nodes=\(liveGraph.nodes.count), edges=\(liveGraph.edges.count))"
            )
        }

        print("ByoriManager core self-test PASS")
    }
}

private actor RecordingRunner: CommandRunning {
    private let mcpPath: String
    private let failOnAdd: Bool
    private let scope: String
    private var commands: [CommandSpec] = []

    init(mcpPath: String, failOnAdd: Bool = false, scope: String = "User config") {
        self.mcpPath = mcpPath
        self.failOnAdd = failOnAdd
        self.scope = scope
    }

    var recordedCommands: [CommandSpec] {
        commands
    }

    func run(_ command: CommandSpec) async -> CommandResult {
        commands.append(command)
        if failOnAdd, Array(command.arguments.prefix(2)) == ["mcp", "add"] {
            return CommandResult(exitCode: 1, output: "simulated add failure")
        }
        if command.arguments == ["mcp", "get", "byoridb"] {
            return CommandResult(
                exitCode: 0,
                output: "Scope: \(scope)\nCommand: \(mcpPath)"
            )
        }
        return CommandResult(exitCode: 0, output: "ok")
    }
}

private struct Failure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
