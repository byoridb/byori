import XCTest
@testable import ByoriManagerCore

final class ManagerServiceProjectHandbookTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori handbook \(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime.appendingPathComponent("cli", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("#!/usr/bin/env python3\n".utf8)
            .write(to: runtime.appendingPathComponent("cli/byori.py"))
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python3")
        try Data("#!/bin/sh\n".utf8).write(to: python)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: python.path
        )
        paths = ManagerPaths(home: root, runtimeRoot: runtime)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Loading an unpublished project runs `show` first, then only the read-only
    /// `preview` command. The root stays one argv element even when it has spaces.
    func testMissingHandbookLoadsBoundedReadOnlyPreviewWithDecodedCoverage() async throws {
        let project = root.appendingPathComponent("My Project", isDirectory: true)
        let runner = HandbookRunner(results: [
            jsonResult(["state": "missing", "reason": "No published handbook", "generation": NSNull()], exitCode: 1),
            previewResult(root: project.path),
        ])
        let service = ManagerService(paths: paths, runner: runner)

        let snapshot = try await service.projectHandbook(projectRoot: project)

        XCTAssertEqual(snapshot.freshness, .missing)
        XCTAssertTrue(snapshot.isPreview)
        XCTAssertEqual(snapshot.handbook, "# Project handbook\n\nSource: PRODUCT.md")
        XCTAssertEqual(snapshot.claimCount, 3)
        XCTAssertEqual(snapshot.excludedSourceCount, 2)
        XCTAssertEqual(snapshot.sensitiveSourceCount, 1)
        XCTAssertEqual(snapshot.omittedSectionCount, 4)
        XCTAssertEqual(snapshot.warnings, ["history was bounded"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".byori").path))

        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(Array(commands[0].arguments.suffix(4)), [
            "handbook", "show", project.path, "--json",
        ])
        XCTAssertEqual(Array(commands[1].arguments.suffix(4)), [
            "handbook", "preview", project.path, "--json",
        ])
        XCTAssertEqual(commands[1].timeout, 120)
    }

    func testInstalledCLIFallbackKeepsTheProjectPathAsOneArgument() async throws {
        try FileManager.default.removeItem(at: paths.bundledByoriCLI)
        let installedDirectory = root.appendingPathComponent(".byoridb/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        let installed = installedDirectory.appendingPathComponent("byori")
        try Data("#!/bin/sh\n".utf8).write(to: installed)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installed.path
        )
        let project = root.appendingPathComponent("Another Project", isDirectory: true)

        let command = try await ManagerService(paths: paths)
            .projectHandbookCommand(.status, projectRoot: project)

        XCTAssertEqual(command.executable, installed.path)
        XCTAssertEqual(command.arguments, ["handbook", "status", project.path, "--json"])
        XCTAssertEqual(command.timeout, 30)
    }

    func testConnectionPreviewApplyAndDisconnectUseExplicitTypedCommands() async throws {
        let project = root.appendingPathComponent("Project With Spaces", isDirectory: true)
        let runner = HandbookRunner(results: [
            connectionResult(root: project.path, host: .claude, status: .unconfigured, preview: true),
            connectionResult(root: project.path, host: .claude, status: .configured, changed: true),
            connectionResult(
                root: project.path,
                host: .claude,
                status: .disconnected,
                changed: true,
                removedInstructionFile: false
            ),
        ])
        let service = ManagerService(paths: paths, runner: runner)

        let preview = try await service.previewProjectHandbookConnection(
            projectRoot: project,
            host: .claude
        )
        XCTAssertEqual(preview.status, .unconfigured)
        XCTAssertEqual(preview.wouldChange, true)
        XCTAssertFalse(preview.changed)
        XCTAssertTrue(preview.managedBlock?.contains("byori handbook show .") == true)

        let applied = try await service.applyProjectHandbookConnection(
            projectRoot: project,
            host: .claude
        )
        XCTAssertEqual(applied.status, .configured)
        XCTAssertTrue(applied.changed)

        let disconnected = try await service.disconnectProjectHandbookConnection(
            projectRoot: project,
            host: .claude
        )
        XCTAssertEqual(disconnected.status, .disconnected)
        XCTAssertEqual(disconnected.removedInstructionFile, false)

        let commands = await runner.commands()
        XCTAssertEqual(Array(commands[0].arguments.suffix(5)), [
            "handbook", "connect", "claude", project.path, "--json",
        ])
        XCTAssertEqual(Array(commands[1].arguments.suffix(6)), [
            "handbook", "connect", "claude", project.path, "--apply", "--json",
        ])
        XCTAssertEqual(Array(commands[2].arguments.suffix(5)), [
            "handbook", "disconnect", "claude", project.path, "--json",
        ])
    }

    func testConnectionDecoderRefusesToCallConfiguredVerifiedConsumption() async throws {
        let project = root.appendingPathComponent("Project", isDirectory: true)
        var payload = connectionObject(
            root: project.path,
            host: .codex,
            status: .configured,
            preview: true
        )
        payload["startup_consumption"] = "verified"
        let service = ManagerService(
            paths: paths,
            runner: HandbookRunner(results: [jsonResult(payload)])
        )

        do {
            _ = try await service.previewProjectHandbookConnection(
                projectRoot: project,
                host: .codex
            )
            XCTFail("configured must not be accepted as verified consumption")
        } catch let error as ProjectHandbookServiceError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalid response, got \(error)")
            }
        }
    }

    func testStaleAndUnavailableAreExpectedJSONStatesNotCommandFailures() async throws {
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let staleRunner = HandbookRunner(results: [
            jsonResult([
                "state": "stale",
                "reason": "Selected sources or policy changed",
                "generation": "published-old",
                "path": project.appendingPathComponent(".byori/handbook.md").path,
                "handbook": NSNull(),
            ], exitCode: 1),
            previewResult(root: project.path, generation: "preview-new"),
        ])
        let stale = try await ManagerService(paths: paths, runner: staleRunner)
            .projectHandbook(projectRoot: project)

        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertEqual(stale.generation, "preview-new")
        XCTAssertEqual(stale.publishedGeneration, "published-old")
        XCTAssertTrue(stale.isPreview)

        let unavailableRunner = HandbookRunner(results: [
            jsonResult([
                "state": "unavailable",
                "reason": "Published artifact differs from deterministic source compilation",
                "generation": "published-bad",
            ], exitCode: 1),
        ])
        let state = try await ManagerService(paths: paths, runner: unavailableRunner)
            .projectHandbookStatus(projectRoot: project)
        XCTAssertEqual(state.freshness, .unavailable)
        XCTAssertEqual(state.generation, "published-bad")
        XCTAssertEqual(
            state.reason,
            "Published artifact differs from deterministic source compilation"
        )
    }

    /// Publication success is followed by an independent read. A stale read must
    /// never be relabeled current merely because the build command exited zero.
    func testBuildRefusesToReportCurrentWhenThePublishedReadIsStale() async throws {
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let runner = HandbookRunner(results: [
            buildResult(root: project.path),
            jsonResult([
                "state": "stale",
                "reason": "Selected sources changed",
                "generation": "generation-1",
                "handbook": NSNull(),
            ], exitCode: 1),
        ])
        let service = ManagerService(paths: paths, runner: runner)

        do {
            _ = try await service.buildProjectHandbook(projectRoot: project)
            XCTFail("a stale post-build read must not be reported as current")
        } catch let error as ProjectHandbookServiceError {
            guard case .verificationFailed = error else {
                return XCTFail("expected verification failure, got \(error)")
            }
        }

        let commands = await runner.commands()
        XCTAssertEqual(Array(commands[0].arguments.suffix(4)), [
            "handbook", "build", project.path, "--json",
        ])
        XCTAssertEqual(Array(commands[1].arguments.suffix(4)), [
            "handbook", "show", project.path, "--json",
        ])
    }

    func testVerifiedBuildCarriesBuildCoverageAndNoOpStatus() async throws {
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let runner = HandbookRunner(results: [
            buildResult(root: project.path, changed: false),
            currentResult(root: project.path),
        ])
        let snapshot = try await ManagerService(paths: paths, runner: runner)
            .buildProjectHandbook(projectRoot: project)

        XCTAssertEqual(snapshot.freshness, .current)
        XCTAssertFalse(snapshot.isPreview)
        XCTAssertEqual(snapshot.buildChanged, false)
        XCTAssertEqual(snapshot.claimCount, 3)
        XCTAssertEqual(snapshot.warnings, ["history was bounded"])
    }

    func testReviewedCustomCommitLimitStillUsesExplicitOverride() async throws {
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let command = try await ManagerService(paths: paths)
            .projectHandbookCommand(.preview, projectRoot: project, maxCommits: 75)

        XCTAssertEqual(Array(command.arguments.suffix(6)), [
            "handbook", "preview", project.path, "--max-commits", "75", "--json",
        ])
    }

    func testCurrentShowCarriesPublishedCoverageSummary() async throws {
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let snapshot = try await ManagerService(
            paths: paths,
            runner: HandbookRunner(results: [currentResult(root: project.path)])
        ).projectHandbook(projectRoot: project)

        XCTAssertEqual(snapshot.freshness, .current)
        XCTAssertEqual(snapshot.warnings, ["one source was bounded"])
        XCTAssertEqual(snapshot.excludedSourceCount, 2)
        XCTAssertEqual(snapshot.sensitiveSourceCount, 1)
        XCTAssertEqual(snapshot.omittedSectionCount, 4)
    }

    func testRefreshConfigurationReadAndExplicitChangesUseTypedContract() async throws {
        let project = root.appendingPathComponent("Project With Spaces", isDirectory: true)
        let canonicalProjectPath = project.resolvingSymlinksInPath().path
        let enabledRevision = String(repeating: "a", count: 64)
        let runner = HandbookRunner(results: [
            refreshConfigurationResult(root: canonicalProjectPath, enabled: false),
            refreshConfigurationResult(
                root: canonicalProjectPath,
                enabled: true,
                revision: enabledRevision,
                changeID: String(repeating: "b", count: 32)
            ),
            refreshConfigurationResult(
                root: canonicalProjectPath,
                enabled: false,
                revision: String(repeating: "c", count: 64),
                changeID: String(repeating: "d", count: 32)
            ),
        ])
        let service = ManagerService(paths: paths, runner: runner)

        let initial = try await service.projectHandbookRefreshConfiguration(projectRoot: project)
        XCTAssertFalse(initial.enabled)
        XCTAssertNil(initial.revision)
        XCTAssertNil(initial.changeID)
        XCTAssertEqual(initial.sourceLimits.maxCommits, 100)
        XCTAssertEqual(initial.sourceLimits.maxFiles, 60)
        XCTAssertEqual(initial.sourceLimits.excludePaths, ["private/"])
        XCTAssertEqual(initial.debounceMilliseconds, 300)
        XCTAssertEqual(initial.maxCharacters, 12_000)

        let enabled = try await service.setProjectHandbookAutomaticRefresh(
            projectRoot: project,
            enabled: true,
            expectedRevision: nil
        )
        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(enabled.revision, enabledRevision)
        XCTAssertEqual(enabled.changeID, String(repeating: "b", count: 32))

        let disabled = try await service.setProjectHandbookAutomaticRefresh(
            projectRoot: project,
            enabled: false,
            expectedRevision: enabledRevision
        )
        XCTAssertFalse(disabled.enabled)

        let commands = await runner.commands()
        XCTAssertEqual(Array(commands[0].arguments.suffix(4)), [
            "handbook", "refresh-config", project.path, "--json",
        ])
        XCTAssertEqual(Array(commands[1].arguments.suffix(6)), [
            "handbook", "refresh-config", project.path, "--enable",
            "--expect-unconfigured", "--json",
        ])
        XCTAssertEqual(Array(commands[2].arguments.suffix(7)), [
            "handbook", "refresh-config", project.path, "--disable",
            "--expected-revision", enabledRevision, "--json",
        ])
    }

    func testAutomaticSyncAndExplicitRefreshUseDifferentCoordinatorCommands() async throws {
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let runner = HandbookRunner(results: [
            refreshResult(root: project.path, disposition: .unchanged, changed: false),
            refreshResult(root: project.path, disposition: .rebuilt, changed: true),
        ])
        let service = ManagerService(paths: paths, runner: runner)

        let automatic = try await service.syncProjectHandbook(projectRoot: project)
        XCTAssertEqual(automatic.disposition, .unchanged)
        XCTAssertEqual(automatic.snapshot?.handbook, "# Project handbook\n\nSource: PRODUCT.md")
        XCTAssertEqual(automatic.changed, false)

        let explicit = try await service.refreshProjectHandbook(projectRoot: project)
        XCTAssertEqual(explicit.disposition, .rebuilt)
        XCTAssertEqual(explicit.snapshot?.buildChanged, true)

        let commands = await runner.commands()
        XCTAssertEqual(Array(commands[0].arguments.suffix(4)), [
            "handbook", "sync", project.path, "--json",
        ])
        XCTAssertEqual(Array(commands[1].arguments.suffix(4)), [
            "handbook", "refresh", project.path, "--json",
        ])
        XCTAssertEqual(commands[0].timeout, 120)
        XCTAssertEqual(commands[1].timeout, 120)
    }

    func testCurrentBundledCLIConfigContractDecodesInTemporaryRepository() async throws {
        let project = root.appendingPathComponent("CLI Fixture", isDirectory: true)
        let integrationHome = root.appendingPathComponent("CLI Fixture Home", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: integrationHome,
            withIntermediateDirectories: true
        )
        try runGit(["init", "-b", "main"], in: project)
        let repository = try repositoryRoot()
        let service = ManagerService(
            // The common test home contains an intentionally empty python3 stub
            // for command-construction tests. Keep this integration fixture on
            // a clean home so it executes the repository CLI with system Python.
            paths: ManagerPaths(home: integrationHome, runtimeRoot: repository),
            runner: ProcessCommandRunner()
        )

        let initial = try await service.projectHandbookRefreshConfiguration(projectRoot: project)
        XCTAssertFalse(initial.enabled)
        XCTAssertNil(initial.revision)
        XCTAssertNil(initial.changeID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent(".byori/refresh.json").path
        ))

        let enabled = try await service.setProjectHandbookAutomaticRefresh(
            projectRoot: project,
            enabled: true,
            expectedRevision: nil
        )
        XCTAssertTrue(enabled.enabled)
        XCTAssertNotNil(enabled.revision)
        XCTAssertNotNil(enabled.changeID)

        let disabled = try await service.setProjectHandbookAutomaticRefresh(
            projectRoot: project,
            enabled: false,
            expectedRevision: enabled.revision
        )
        XCTAssertFalse(disabled.enabled)
        XCTAssertNotEqual(disabled.revision, enabled.revision)
        XCTAssertNotEqual(disabled.changeID, enabled.changeID)
    }

    func testFailedRefreshCannotExposeAHandbookBody() async throws {
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let service = ManagerService(paths: paths, runner: HandbookRunner(results: [
            jsonResult([
                "state": "unavailable",
                "reason": "source verification failed",
                "generation": NSNull(),
                "handbook": "obsolete body",
                "refresh": "failed",
            ], exitCode: 1),
        ]))

        do {
            _ = try await service.syncProjectHandbook(projectRoot: project)
            XCTFail("failed refreshes must never expose a body")
        } catch let error as ProjectHandbookServiceError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalid response, got \(error)")
            }
        }
    }

    private func previewResult(
        root: String,
        generation: String = "preview-generation"
    ) -> CommandResult {
        jsonResult([
            "schema_version": 1,
            "generation": generation,
            "project_root": root,
            "handbook": "# Project handbook\n\nSource: PRODUCT.md",
            "published": false,
            "claim_count": 3,
            "warnings": ["history was bounded"],
            "excluded_sources": 2,
            "sensitive_sources_withheld": 1,
            "omitted_sections": 4,
        ])
    }

    private func buildResult(root: String, changed: Bool = true) -> CommandResult {
        jsonResult([
            "schema_version": 1,
            "generation": "generation-1",
            "project_root": root,
            "handbook": "# Project handbook\n\nSource: PRODUCT.md",
            "published": true,
            "changed": changed,
            "claim_count": 3,
            "warnings": ["history was bounded"],
            "excluded_sources": 2,
            "sensitive_sources_withheld": 1,
            "omitted_sections": 4,
        ])
    }

    private func currentResult(root: String) -> CommandResult {
        jsonResult([
            "state": "current",
            "reason": "Selected source snapshot matches",
            "generation": "generation-1",
            "current_generation": "generation-1",
            "path": URL(fileURLWithPath: root).appendingPathComponent(".byori/handbook.md").path,
            "claim_count": 3,
            "warnings": ["one source was bounded"],
            "excluded_sources": 2,
            "sensitive_sources_withheld": 1,
            "omitted_sections": 4,
            "handbook": "# Project handbook\n\nSource: PRODUCT.md",
        ])
    }

    private func refreshConfigurationResult(
        root: String,
        enabled: Bool,
        revision: String? = nil,
        changeID: String? = nil
    ) -> CommandResult {
        jsonResult([
            "schema_version": 1,
            "enabled": enabled,
            "revision": revision ?? NSNull(),
            "change_id": changeID ?? NSNull(),
            "project_root": root,
            "checkout_id": String(repeating: "e", count: 64),
            "debounce_ms": 300,
            "source_limits": [
                "max_commits": 100,
                "max_files": 60,
                "max_file_bytes": 65_536,
                "max_total_bytes": 1_048_576,
                "exclude_paths": ["private/"],
            ],
            "max_chars": 12_000,
        ])
    }

    private func refreshResult(
        root: String,
        disposition: ProjectHandbookRefreshDisposition,
        changed: Bool
    ) -> CommandResult {
        jsonResult([
            "state": "current",
            "reason": "Selected source snapshot matches",
            "generation": "generation-1",
            "current_generation": "generation-1",
            "path": URL(fileURLWithPath: root).appendingPathComponent(".byori/handbook.md").path,
            "claim_count": 3,
            "warnings": ["one source was bounded"],
            "excluded_sources": 2,
            "sensitive_sources_withheld": 1,
            "omitted_sections": 4,
            "handbook": "# Project handbook\n\nSource: PRODUCT.md",
            "refresh": disposition.rawValue,
            "changed": changed,
        ])
    }

    private func connectionResult(
        root: String,
        host: ProjectHandbookHost,
        status: ProjectHandbookConnectionStatus,
        changed: Bool = false,
        preview: Bool = false,
        removedInstructionFile: Bool? = nil
    ) -> CommandResult {
        jsonResult(connectionObject(
            root: root,
            host: host,
            status: status,
            changed: changed,
            preview: preview,
            removedInstructionFile: removedInstructionFile
        ))
    }

    private func connectionObject(
        root: String,
        host: ProjectHandbookHost,
        status: ProjectHandbookConnectionStatus,
        changed: Bool = false,
        preview: Bool = false,
        removedInstructionFile: Bool? = nil
    ) -> [String: Any] {
        let instructionName = host == .claude ? "CLAUDE.md" : "AGENTS.md"
        var result: [String: Any] = [
            "schema_version": 1,
            "host": host.rawValue,
            "status": status.rawValue,
            "verification": "unverified",
            "startup_consumption": "unverified",
            "changed": changed,
            "instruction_file": URL(fileURLWithPath: root).appendingPathComponent(instructionName).path,
            "handbook_file": URL(fileURLWithPath: root).appendingPathComponent(".byori/handbook.md").path,
            "handbook_present": true,
            "warnings": [],
        ]
        if preview {
            result["would_change"] = status != .configured
            result["managed_block"] = "<!-- byori:handbook:start v1 -->\nRun byori handbook show .\n"
        }
        if let removedInstructionFile {
            result["removed_instruction_file"] = removedInstructionFile
        }
        return result
    }

    private func jsonResult(_ object: [String: Any], exitCode: Int32 = 0) -> CommandResult {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return CommandResult(exitCode: exitCode, output: String(decoding: data, as: UTF8.self))
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("cli/byori.py").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ManagerServiceProjectHandbookTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate the repository CLI fixture."]
        )
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ManagerServiceProjectHandbookTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Could not initialize the temporary Git fixture."]
            )
        }
    }
}

private actor HandbookRunner: CommandRunning {
    private var results: [CommandResult]
    private var invocations: [CommandSpec] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func commands() -> [CommandSpec] { invocations }

    func run(_ command: CommandSpec) async -> CommandResult {
        invocations.append(command)
        guard !results.isEmpty else {
            return CommandResult(exitCode: 127, output: "unexpected command")
        }
        return results.removeFirst()
    }
}
