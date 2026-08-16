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
        guard let codexSkill = paths.codexSkill,
              codexSkill.path.hasSuffix("/.agents/skills/byoridb-memory/SKILL.md") else {
            throw Failure("Codex skill path is not the current official location")
        }
        guard let codexDesignSkill = paths.skillDestination(.byoriDesign, for: .codex),
              codexDesignSkill.path.hasSuffix("/.agents/skills/byori-design/SKILL.md") else {
            throw Failure("Codex design skill path is not the current official location")
        }
        // A launch-only CLI has no skills directory at all. Asserting the nil
        // keeps a future catalog edit from silently pointing a skill write at a
        // path that was never verified.
        guard paths.skillDirectory(.byoridbMemory, for: .opencode) == nil else {
            throw Failure("a launch-only CLI must not report a skill directory")
        }

        let claudeInventory = MCPInventoryParser.claudeServers(fromText: """
        \u{001B}[32mlocal-tools:\u{001B}[0m /bin/error-handler --header Authorization:Bearer-super-secret - ✓ Connected
        failing-server: /bin/server --token another-secret - ✗ Failed
        claude.ai Google Calendar: https://example.invalid/private - Needs authentication
        """)
        guard claudeInventory.map(\.name) == ["failing-server", "Google Calendar", "local-tools"],
              claudeInventory.first(where: { $0.name == "local-tools" })?.status == .connected,
              claudeInventory.first(where: { $0.name == "failing-server" })?.status == .unavailable,
              claudeInventory.first(where: { $0.name == "Google Calendar" })?.status
                == .authenticationRequired,
              claudeInventory.first(where: { $0.name == "Google Calendar" })?.isClaudeCloud == true,
              !claudeInventory.map(\.name).joined().contains("secret") else {
            throw Failure("Claude MCP inventory retained sensitive details or lost a coarse state")
        }

        guard let codexInventory = MCPInventoryParser.codexServers(fromJSON: """
        [
          {
            "name": "github",
            "enabled": true,
            "transport": {
              "command": "/bin/server",
              "args": ["--token", "super-secret"],
              "env": {"API_TOKEN": "super-secret"}
            }
          },
          {"name": "disabled-one", "enabled": false, "headers": {"Authorization": "secret"}}
        ]
        """),
              codexInventory.map(\.name) == ["disabled-one", "github"],
              codexInventory.first(where: { $0.name == "github" })?.status == .configured,
              codexInventory.first(where: { $0.name == "disabled-one" })?.status == .disabled,
              !codexInventory.map(\.name).joined().contains("secret") else {
            throw Failure("Codex MCP inventory retained sensitive configuration details")
        }

        let safeTerminalText = SafeDisplayText.strippingTerminalControls(
            "\u{001B}[34mblue\u{001B}[0m\u{000D}\u{0000} ok\tline\n"
                + "\u{001B}]0;private-title\u{0007}done"
                + "\u{001B}Pprivate-payload\u{001B}\\tail"
                + "\u{009B}31m red"
        )
        guard safeTerminalText == "blue ok\tline\ndonetail red",
              !safeTerminalText.contains("private") else {
            throw Failure("terminal controls or control-string payload escaped display sanitization")
        }

        let inventoryHome = root.appendingPathComponent("inventory-home", isDirectory: true)
        let inventorySkills = inventoryHome.appendingPathComponent(".claude/skills", isDirectory: true)
        let directSkill = inventorySkills.appendingPathComponent("direct", isDirectory: true)
        try fileManager.createDirectory(at: directSkill, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: directSkill.appendingPathComponent("SKILL.md"))
        let nestedSkill = inventorySkills.appendingPathComponent("container/nested", isDirectory: true)
        try fileManager.createDirectory(at: nestedSkill, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nestedSkill.appendingPathComponent("SKILL.md"))
        let outsideSkill = root.appendingPathComponent("outside-skill", isDirectory: true)
        try fileManager.createDirectory(at: outsideSkill, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideSkill.appendingPathComponent("SKILL.md"))
        try fileManager.createSymbolicLink(
            at: inventorySkills.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: outsideSkill
        )
        let skillScanner = UserSkillScanner(home: inventoryHome)
        let scannedSkills = skillScanner.scan(.claude)
        guard scannedSkills.skills.map(\.name) == ["direct"],
              !scannedSkills.wasTruncated,
              try skillScanner.validatedDirectory(for: scannedSkills.skills[0]) == directSkill else {
            throw Failure("Skill inventory was not direct-child and symlink safe")
        }
        let forgedSkill = UserSkillSummary(
            agent: .claude,
            name: "outside-skill",
            directoryPath: outsideSkill.path,
            skillFilePath: outsideSkill.appendingPathComponent("SKILL.md").path,
            origin: .claudeUser,
            isByoriManaged: false
        )
        do {
            _ = try skillScanner.validatedDirectory(for: forgedSkill)
            throw Failure("Skill inventory accepted a path outside its user root")
        } catch is Failure {
            throw Failure("Skill inventory accepted a path outside its user root")
        } catch {
            // Expected: removal/open validation rejects forged ownership.
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

        let terminalWorktree = root.appendingPathComponent("terminal-worktree", isDirectory: true)
        try fileManager.createDirectory(at: terminalWorktree, withIntermediateDirectories: true)
        let launchFactory = TerminalLaunchDescriptorFactory(
            paths: paths,
            environment: [
                "BYORI_SELF_TEST": "1",
                "NO_COLOR": "1",
                "NODE_DISABLE_COLORS": "1",
                "FORCE_COLOR": "0",
                "CLICOLOR_FORCE": "0",
                "TERM": "dumb",
            ]
        )
        let fixedSessionID = UUID(uuidString: "AD8EFCF7-985E-45E1-9C3E-97AD899E9D01")!
        let explicitLaunch = try launchFactory.codingAgent(
            .claude,
            model: "sonnet",
            workingDirectory: terminalWorktree,
            sessionID: fixedSessionID
        )
        guard explicitLaunch.target == .codingAgent(.claude),
              explicitLaunch.modelSelection == .explicit("sonnet"),
              explicitLaunch.arguments == [
                  "--model", "sonnet",
                  "--session-id", fixedSessionID.uuidString.lowercased(),
              ],
              explicitLaunch.environment["TERM"] == "xterm-256color",
              explicitLaunch.environment["COLORTERM"] == "truecolor",
              explicitLaunch.environment["CLICOLOR"] == "1",
              explicitLaunch.environment["NO_COLOR"] == nil,
              explicitLaunch.environment["NODE_DISABLE_COLORS"] == nil,
              explicitLaunch.environment["FORCE_COLOR"] == nil,
              explicitLaunch.environment["CLICOLOR_FORCE"] == nil,
              explicitLaunch.environment["PATH"] == paths.processPath else {
            throw Failure("explicit interactive Claude launch descriptor is incorrect")
        }
        let defaultLaunch = try launchFactory.codingAgent(
            .claude,
            workingDirectory: terminalWorktree
        )
        guard defaultLaunch.modelSelection == .cliDefault,
              defaultLaunch.model == nil,
              !defaultLaunch.arguments.contains("--model"),
              !defaultLaunch.arguments.contains("default") else {
            throw Failure("CLI-default model selection emitted a synthetic model argument")
        }
        do {
            _ = try launchFactory.codingAgent(
                .codex,
                workingDirectory: terminalWorktree,
                executableOverride: root.appendingPathComponent("missing-codex")
            )
            throw Failure("invalid Codex executable unexpectedly fell back to a shell")
        } catch TerminalLaunchDescriptorError.invalidExecutable {
            // Expected: vendor sessions never fall back to a system shell.
        }

        try fileManager.createDirectory(
            at: paths.mcpRunner.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: paths.mcpRunner)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.mcpRunner.path)

        let runner = RecordingRunner(mcpPath: paths.mcpRunner.path)
        let service = ManagerService(paths: paths, runner: runner)
        let connection = try await service.connectMCP(.claude)
        guard !connection.detail.contains("RAW_MCP_OUTPUT_MUST_NOT_ESCAPE") else {
            throw Failure("raw MCP CLI output escaped into an activity result")
        }
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
            guard !error.localizedDescription.contains("RAW_MCP_SECRET_MUST_NOT_ESCAPE") else {
                throw Failure("raw MCP failure output escaped into a user-facing error")
            }
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

        try Data("failed-remove-original".utf8).write(to: paths.claudeConfig)
        let failedRemoveService = ManagerService(paths: paths, runner: FailedRemoveRunner())
        do {
            _ = try await failedRemoveService.disconnectMCP(.claude)
            throw Failure("failed MCP remove was reported as success after a failed probe")
        } catch is Failure {
            throw Failure("failed MCP remove was reported as success after a failed probe")
        } catch let error as ManagerError {
            guard case .commandFailed = error else {
                throw Failure("failed MCP remove surfaced the wrong error: \(error)")
            }
            let restored = try Data(contentsOf: paths.claudeConfig)
            guard restored == Data("failed-remove-original".utf8) else {
                throw Failure("MCP config backup was not restored after remove command failure")
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

        // A background descendant can outlive the process-group leader while
        // retaining the inherited stdout pipe. Reaping the leader must still
        // return promptly without signalling its now-reusable PGID.
        let heldPipePIDFile = root.appendingPathComponent("held-pipe-child.pid")
        let heldPipeStart = ProcessInfo.processInfo.systemUptime
        let heldPipe = await processRunner.run(CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/bin/sleep 30 & echo $! > \"$PID_FILE\"; printf held-output",
            ],
            environment: ["PID_FILE": heldPipePIDFile.path],
            timeout: 10
        ))
        let heldPipeElapsed = ProcessInfo.processInfo.systemUptime - heldPipeStart
        let heldPipePIDText = try String(contentsOf: heldPipePIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let heldPipePID = pid_t(heldPipePIDText) else {
            throw Failure("pipe-holding descendant did not publish a valid pid")
        }
        let heldPipeChildWasAlive = kill(heldPipePID, 0) == 0
        _ = kill(heldPipePID, SIGTERM)
        guard heldPipe.succeeded,
              heldPipe.output == "held-output",
              heldPipeChildWasAlive,
              heldPipeElapsed < 0.8 else {
            throw Failure("reaped leader remained blocked on a descendant output pipe")
        }

        let cancellationStart = Date()
        let cancellableCommand = Task {
            await processRunner.run(CommandSpec(
                executable: "/bin/sleep",
                arguments: ["30"],
                timeout: 60
            ))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancellableCommand.cancel()
        let cancelledResult = await cancellableCommand.value
        guard !cancelledResult.succeeded,
              Date().timeIntervalSince(cancellationStart) < 5 else {
            throw Failure("cancelled Manager command did not stop promptly")
        }

        // Cancellation must finish the whole process group before reaping its
        // leader. Otherwise a TERM-ignoring installer child could keep writing
        // files while ManagerService is already restoring its runtime snapshot.
        let stubbornChildPIDFile = root.appendingPathComponent("cancel-stubborn-child.pid")
        let stubbornStart = Date()
        let stubbornCommand = Task {
            await processRunner.run(CommandSpec(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap 'exit 0' TERM; /bin/sh -c 'trap \"\" TERM; " +
                        "echo $$ > \"$PID_FILE\"; while :; do /bin/sleep 1; done' & wait",
                ],
                environment: ["PID_FILE": stubbornChildPIDFile.path],
                timeout: 60
            ))
        }
        for _ in 0..<100 where !fileManager.fileExists(atPath: stubbornChildPIDFile.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard fileManager.fileExists(atPath: stubbornChildPIDFile.path) else {
            stubbornCommand.cancel()
            throw Failure("TERM-ignoring cancellation child did not start")
        }
        let stubbornPIDText = try String(contentsOf: stubbornChildPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stubbornPID = pid_t(stubbornPIDText) else {
            stubbornCommand.cancel()
            throw Failure("TERM-ignoring cancellation child did not publish a valid pid")
        }
        stubbornCommand.cancel()
        let stubbornResult = await stubbornCommand.value
        for _ in 0..<40 where kill(stubbornPID, 0) == 0 {
            usleep(25_000)
        }
        if kill(stubbornPID, 0) == 0 {
            _ = kill(stubbornPID, SIGKILL)
            throw Failure("cancellation left TERM-ignoring child \(stubbornPID) running")
        }
        guard !stubbornResult.succeeded,
              Date().timeIntervalSince(stubbornStart) < 5 else {
            throw Failure("TERM-ignoring command did not cancel promptly")
        }

        let cancelInstallHome = root.appendingPathComponent("cancel-install-home", isDirectory: true)
        let cancelInstallRuntime = root.appendingPathComponent("cancel-install-runtime", isDirectory: true)
        let cancelInstallPaths = ManagerPaths(
            home: cancelInstallHome,
            runtimeRoot: cancelInstallRuntime
        )
        let fakePython = cancelInstallHome.appendingPathComponent(".local/bin/python3")
        try fileManager.createDirectory(
            at: fakePython.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakePython)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePython.path)
        let runtimeState = cancelInstallPaths.byoriHome.appendingPathComponent("bin/state")
        try fileManager.createDirectory(
            at: runtimeState.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("before".utf8).write(to: runtimeState)
        let installStarted = cancelInstallPaths.byoriHome.appendingPathComponent("install-started")
        try fileManager.createDirectory(
            at: cancelInstallPaths.installer.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        #!/bin/sh
        printf mutated > "$BYORIDB_HOME/bin/state"
        printf started > "$BYORIDB_HOME/install-started"
        /bin/sleep 30
        """.utf8).write(to: cancelInstallPaths.installer)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: cancelInstallPaths.installer.path
        )
        let cancelInstallService = ManagerService(paths: cancelInstallPaths)
        let installTask = Task {
            try await cancelInstallService.installByoriBundled()
        }
        for _ in 0..<100 where !fileManager.fileExists(atPath: installStarted.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard fileManager.fileExists(atPath: installStarted.path) else {
            installTask.cancel()
            throw Failure("cancellable installer did not start")
        }
        installTask.cancel()
        do {
            _ = try await installTask.value
            throw Failure("cancelled ByoriDB install unexpectedly succeeded")
        } catch is Failure {
            throw Failure("cancelled ByoriDB install did not surface cancellation")
        } catch {
            // Expected: the installer command is cancelled, then rollback runs
            // from a fresh task that does not inherit that cancellation.
        }
        guard try String(contentsOf: runtimeState, encoding: .utf8) == "before" else {
            throw Failure("cancelled ByoriDB install did not restore its runtime snapshot")
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

        let workspacePrimary = root.appendingPathComponent("workspace/primary", isDirectory: true)
        let workspaceLinked = root.appendingPathComponent("workspace/linked feature", isDirectory: true)
        try fileManager.createDirectory(at: workspacePrimary, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspaceLinked, withIntermediateDirectories: true)
        let worktreeOutput = "worktree \(workspacePrimary.path)\0"
            + "HEAD \(String(repeating: "a", count: 40))\0"
            + "branch refs/heads/main\0\0"
            + "worktree \(workspaceLinked.path)\0"
            + "HEAD \(String(repeating: "b", count: 40))\0"
            + "branch refs/heads/feature/workspace\0\0"
        let worktreeGit = WorkspaceGitService(
            runner: WorktreeCommandRunner(root: workspacePrimary, output: worktreeOutput),
            gitExecutable: "/test/bin/git"
        )
        let listedWorktrees = try await worktreeGit.worktrees(at: workspacePrimary)
        guard listedWorktrees.count == 2,
              listedWorktrees[0].isPrimary,
              listedWorktrees[0].branch == "main",
              !listedWorktrees[1].isPrimary,
              listedWorktrees[1].branch == "feature/workspace" else {
            throw Failure("Git worktree porcelain discovery is incorrect")
        }

        let registryHome = root.appendingPathComponent("workspace-home/.byori", isDirectory: true)
        try fileManager.createDirectory(at: registryHome, withIntermediateDirectories: true)
        let registryURL = registryHome.appendingPathComponent("projects.json")
        let registryDocument: [String: Any] = [
            "schema_version": 1,
            "projects": [[
                "id": "selftest1234",
                "name": "workspace",
                "root": workspacePrimary.path,
                "space": "byori_workspace_selftest",
                "remote": "",
                "added_at": "2026-08-06T01:02:03Z",
                "future_project_field": ["keep": true],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: registryDocument, options: [.prettyPrinted])
            .write(to: registryURL)
        let registry = WorkspaceProjectRegistry(
            home: registryHome,
            git: RegistryGitStub(root: workspacePrimary, worktreeSnapshots: listedWorktrees)
        )
        let firstProjects = try await registry.projects()
        let secondProjects = try await registry.projects()
        guard let firstDiscovered = firstProjects.first?.sourceTrees.first?.worktrees.first,
              let secondDiscovered = secondProjects.first?.sourceTrees.first?.worktrees.first,
              firstDiscovered.path == workspaceLinked.path,
              firstDiscovered.branch == "feature/workspace",
              firstDiscovered.id == secondDiscovered.id else {
            throw Failure("workspace registry did not expose a stable linked-worktree identity")
        }
        let unchangedRegistry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: registryURL)
        ) as? [String: Any]
        let unchangedProjects = unchangedRegistry?["projects"] as? [[String: Any]]
        guard unchangedProjects?.first?["source_trees"] == nil else {
            throw Failure("worktree discovery unexpectedly mutated projects.json")
        }

        let linkedSentinel = workspaceLinked.appendingPathComponent("uncommitted-user-work.txt")
        try Data("keep".utf8).write(to: linkedSentinel)
        let visibilityStore = WorkspaceCheckoutVisibilityStore(home: registryHome)
        let visibilityRegistry = WorkspaceProjectRegistry(
            home: registryHome,
            git: RegistryGitStub(root: workspacePrimary, worktreeSnapshots: listedWorktrees),
            visibilityStore: visibilityStore
        )
        try await visibilityStore.hideCheckout(projectID: "selftest1234", at: workspaceLinked)
        let hiddenProjects = try await visibilityRegistry.projects()
        guard hiddenProjects.first?.sourceTrees.first?.worktrees.isEmpty == true,
              fileManager.fileExists(atPath: linkedSentinel.path) else {
            throw Failure("hiding a checkout changed files or failed to persist visibility")
        }
        try await visibilityStore.unhideCheckout(projectID: "selftest1234", at: workspaceLinked)
        let restoredCheckouts = try await visibilityRegistry.projects()
        guard restoredCheckouts.first?.sourceTrees.first?.worktrees.first?.id == firstDiscovered.id else {
            throw Failure("restoring a hidden checkout did not preserve its stable identity")
        }

        _ = try await visibilityRegistry.removeProject(id: "selftest1234")
        let projectsAfterRemoval = try await visibilityRegistry.projects()
        guard projectsAfterRemoval.isEmpty,
              fileManager.fileExists(atPath: workspacePrimary.path),
              fileManager.fileExists(atPath: linkedSentinel.path) else {
            throw Failure("project removal changed repository files or remained active")
        }
        let archivedDocument = try JSONSerialization.jsonObject(
            with: Data(contentsOf: registryURL)
        ) as? [String: Any]
        let archivedProjects = archivedDocument?["removed_projects"] as? [[String: Any]]
        let futureProjectField = archivedProjects?.first?["future_project_field"] as? [String: Any]
        guard futureProjectField?["keep"] as? Bool == true else {
            throw Failure("project removal did not archive the exact extensible record")
        }
        let restoredProject = try await visibilityRegistry.registerProject(
            at: workspacePrimary,
            memorySpace: nil
        )
        guard restoredProject.id == "selftest1234",
              restoredProject.memorySpace == "byori_workspace_selftest" else {
            throw Failure("re-registering an archived project did not restore its identity")
        }
        let unavailableRegistry = WorkspaceProjectRegistry(
            home: registryHome,
            git: RegistryGitStub(
                root: workspacePrimary,
                worktreeError: .notGitRepository(workspacePrimary.path)
            )
        )
        let unavailableProjects = try await unavailableRegistry.projects()
        guard unavailableProjects.first?.sourceTrees.first?.path == workspacePrimary.path else {
            throw Failure("non-Git project fallback was lost when worktree discovery failed")
        }

        let sanitizedHome = root.appendingPathComponent("sanitized-home/.byori", isDirectory: true)
        let sanitizerGit = RegistryGitStub(
            root: workspacePrimary,
            remote: "https://oauth:secret@example.test/org/repo.git?token=secret#private"
        )
        let sanitizerRegistry = WorkspaceProjectRegistry(
            home: sanitizedHome,
            git: sanitizerGit,
            idGenerator: { "sanitized123" }
        )
        let sanitizedPreview = try await sanitizerRegistry.previewUnregisteredProject(at: workspacePrimary)
        guard sanitizedPreview?.remote == "https://example.test/org/repo" else {
            throw Failure("workspace remote sanitizer retained URL credentials or metadata")
        }
        let scpRegistry = WorkspaceProjectRegistry(
            home: root.appendingPathComponent("scp-home/.byori", isDirectory: true),
            git: RegistryGitStub(
                root: workspacePrimary,
                remote: "oauth:secret@example.test:org/repo.git"
            )
        )
        let scpPreview = try await scpRegistry.previewUnregisteredProject(at: workspacePrimary)
        guard scpPreview?.remote == "example.test:org/repo" else {
            throw Failure("workspace remote sanitizer retained SCP-style user info")
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
            // The space is named explicitly: there is no shared default to read.
            guard let liveSpace = ProcessInfo.processInfo.environment["BYORIDB_MEMORY_SPACE"],
                  !liveSpace.isEmpty else {
                throw Failure(
                    "BYORI_MANAGER_LIVE_GRAPH_TEST=1 requires BYORIDB_MEMORY_SPACE "
                        + "(the project space to read)"
                )
            }
            let livePaths = ManagerPaths.applicationDefault()
            let client = ByoriGraphClient()
            let liveGraph = try await client.loadGraph(
                paths: livePaths,
                nodeLimit: 200,
                space: liveSpace
            )
            if let firstNode = liveGraph.nodes.first {
                _ = try await client.loadBody(
                    paths: livePaths,
                    nodeID: firstNode.id,
                    tag: firstNode.tag,
                    space: liveSpace
                )
            }
            print(
                "ByoriManager live graph PASS "
                    + "(nodes=\(liveGraph.nodes.count), edges=\(liveGraph.edges.count))"
            )
        }

        print("ByoriManager core self-test PASS")
    }
}

private struct WorktreeCommandRunner: CommandRunning {
    let root: URL
    let output: String

    func run(_ command: CommandSpec) async -> CommandResult {
        if command.arguments.contains("--show-toplevel") {
            return CommandResult(exitCode: 0, output: root.path)
        }
        if command.arguments == [
            "-C", root.path, "worktree", "list", "--porcelain", "-z",
        ] {
            return CommandResult(exitCode: 0, output: output)
        }
        return CommandResult(exitCode: 1, output: "unexpected Git command")
    }
}

private struct RegistryGitStub: WorkspaceGitInspecting {
    let root: URL
    var remote: String? = nil
    var worktreeSnapshots: [WorkspaceGitWorktreeSnapshot] = []
    var worktreeError: WorkspaceError? = nil

    func repositoryRoot(at path: URL) async throws -> URL {
        root
    }

    func originRemote(at repositoryRoot: URL) async throws -> String? {
        remote
    }

    func worktrees(at path: URL) async throws -> [WorkspaceGitWorktreeSnapshot] {
        if let worktreeError { throw worktreeError }
        return worktreeSnapshots
    }

    func status(at path: URL, maxChanges: Int) async throws -> WorkspaceGitStatusSnapshot {
        WorkspaceGitStatusSnapshot(
            repositoryRoot: root.path,
            branch: "main",
            headRevision: nil,
            changes: [],
            isTruncated: false
        )
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
            return CommandResult(exitCode: 1, output: "RAW_MCP_SECRET_MUST_NOT_ESCAPE")
        }
        if Array(command.arguments.prefix(2)) == ["mcp", "add"] {
            return CommandResult(exitCode: 0, output: "RAW_MCP_OUTPUT_MUST_NOT_ESCAPE")
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

private actor FailedRemoveRunner: CommandRunning {
    func run(_ command: CommandSpec) async -> CommandResult {
        if Array(command.arguments.prefix(2)) == ["mcp", "remove"] {
            return CommandResult(exitCode: 1, output: "simulated remove failure")
        }
        if command.arguments == ["mcp", "get", "byoridb"] {
            return CommandResult(exitCode: 1, output: "simulated probe failure")
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
