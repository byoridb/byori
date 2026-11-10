import XCTest
@testable import ByoriManagerCore

/// Which `byori` the app asks to read a repository's history.
///
/// `~/.byoridb/bin/byori` is only rewritten when the engine is installed, so an app
/// that updated on its own kept whatever CLI was there before — and the button this
/// release added asked it for `init`, a subcommand it had never heard of. Measured on
/// a machine running app 0.8.18 against a CLI from the previous install:
///
///     byori: error: argument command: invalid choice: 'init'
///
/// The copy that ships inside the app always matches the app, so it goes first.
final class ManagerServiceProjectMemoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheBundledCLIIsPreferredOverTheInstalledOne() async throws {
        let runtime = try makeRuntimeWithBundledCLI()
        let installed = try makeInstalledCLI()
        let paths = ManagerPaths(home: root, runtimeRoot: runtime)

        let command = try await ManagerService(paths: paths).projectMemoryCommand(
            projectRoot: URL(fileURLWithPath: "/tmp/shop", isDirectory: true),
            space: "byori_shop_1a2b",
            commitLimit: 20_000
        )

        // Symlinks are resolved, so a Homebrew python3 arrives as `python3.14`.
        XCTAssertTrue(command.executable.contains("python3"), command.executable)
        XCTAssertEqual(command.arguments, [
            runtime.appendingPathComponent("cli/byori.py").path,
            "init", "/tmp/shop",
            "--space", "byori_shop_1a2b",
            "--limit", "20000",
        ])
        XCTAssertNotEqual(command.executable, installed.path)
        // The CLI reads its own env file, but it has to be told which home to read.
        XCTAssertEqual(command.environment["BYORIDB_HOME"], paths.byoriHome.path)
        XCTAssertEqual(command.environment["BYORI_INDEXER"], paths.bundledCodeIndexer.path)
        XCTAssertEqual(command.workingDirectory, "/tmp/shop")
        // Reading a large repository is minutes of Git; a short timeout would kill
        // the pass partway and report a failure that was only impatience.
        XCTAssertEqual(command.timeout, 1_800)
    }

    /// `swift run` has no bundled runtime. The installed CLI is the only one there,
    /// so it is used rather than failing on a resource that build never had.
    func testWithoutABundledCLITheInstalledOneIsUsed() async throws {
        let installed = try makeInstalledCLI()
        let paths = ManagerPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("absent", isDirectory: true)
        )

        let command = try await ManagerService(paths: paths).projectMemoryCommand(
            projectRoot: URL(fileURLWithPath: "/tmp/shop", isDirectory: true),
            space: "byori_shop_1a2b",
            commitLimit: 500
        )

        XCTAssertEqual(command.executable, installed.path)
        XCTAssertEqual(command.arguments, [
            "init", "/tmp/shop", "--space", "byori_shop_1a2b", "--limit", "500",
        ])
        XCTAssertEqual(command.environment["BYORI_INDEXER"], paths.installedCodeIndexer.path)
    }

    func testWithNoCLIAtAllTheMissingBundledOneIsNamed() async throws {
        let paths = ManagerPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("absent", isDirectory: true)
        )

        do {
            _ = try await ManagerService(paths: paths).projectMemoryCommand(
                projectRoot: URL(fileURLWithPath: "/tmp/shop", isDirectory: true),
                space: "byori_shop_1a2b",
                commitLimit: 10
            )
            XCTFail("a command was returned with no CLI to run")
        } catch let ManagerError.missingResource(path) {
            XCTAssertEqual(path, paths.bundledByoriCLI.path)
        }
    }

    func testAnIncompleteBundleDoesNotFallBackToAnOlderInstalledBridge() async throws {
        let runtime = try makeRuntimeWithBundledCLI()
        _ = try makeInstalledCLI()
        let paths = ManagerPaths(home: root, runtimeRoot: runtime)
        try FileManager.default.removeItem(at: paths.bundledCodeGraph)
        do {
            _ = try await ManagerService(paths: paths).projectMemoryCommand(
                projectRoot: root, space: "byori_test", commitLimit: 10
            )
            XCTFail("missing bundled code graph must be reported")
        } catch let ManagerError.missingResource(path) {
            XCTAssertEqual(path, paths.bundledCodeGraph.path)
        }
    }

    func testAnIncompleteBundleDoesNotUseTheInstalledIndexer() async throws {
        let runtime = try makeRuntimeWithBundledCLI()
        _ = try makeInstalledCLI()
        let paths = ManagerPaths(home: root, runtimeRoot: runtime)
        try FileManager.default.removeItem(at: paths.bundledCodeIndexer)
        do {
            _ = try await ManagerService(paths: paths).projectMemoryCommand(
                projectRoot: root, space: "byori_test", commitLimit: 10
            )
            XCTFail("missing bundled indexer must be reported")
        } catch let ManagerError.prerequisite(message) {
            XCTAssertTrue(message.contains("scripts/build-indexer.sh"))
        }
    }

    func testASourceRuntimeUsesItsOwnBuiltIndexer() async throws {
        let runtime = try makeRuntimeWithBundledCLI()
        _ = try makeInstalledCLI()
        let paths = ManagerPaths(home: root, runtimeRoot: runtime)
        let sourceBinary = runtime.appendingPathComponent("indexer/target/release/byori-indexer")
        try FileManager.default.createDirectory(
            at: sourceBinary.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: paths.bundledCodeIndexer, to: sourceBinary)
        let command = try await ManagerService(paths: paths).projectMemoryCommand(
            projectRoot: root, space: "byori_test", commitLimit: 10
        )
        XCTAssertEqual(command.environment["BYORI_INDEXER"], sourceBinary.path)
    }

    func testSuccessfulBundledAnalysisExplainsAnOlderInstalledMCP() async throws {
        let runtime = try makeRuntimeWithBundledCLI()
        _ = try makeInstalledCLI()
        let paths = ManagerPaths(home: root, runtimeRoot: runtime)
        let result = try await ManagerService(paths: paths, runner: MemoryAnalysisRunner()).buildProjectMemory(
            projectRoot: root, space: "byori_test"
        )
        XCTAssertEqual(result.summary, "프로젝트 분석 완료")
        XCTAssertTrue(result.detail.contains("indexed 12 symbols"))
        XCTAssertTrue(result.detail.contains("Settings > ByoriDB"))
        XCTAssertTrue(result.detail.contains("세션을 다시 시작"))
        // An analysis must not replace installed runtime files as a side effect.
        XCTAssertEqual(try String(contentsOf: paths.byoriHome.appendingPathComponent("code_graph.py")), "# installed old bridge\n")
    }

    func testMatchingInstalledMCPDoesNotRequestAnotherRuntimeUpdate() async throws {
        let runtime = try makeRuntimeWithBundledCLI()
        _ = try makeInstalledCLI()
        let paths = ManagerPaths(home: root, runtimeRoot: runtime)
        for name in ["byoridb_mcp.py", "code_graph.py"] {
            let source = runtime.appendingPathComponent("mcp/\(name)")
            try Data(contentsOf: source).write(to: paths.byoriHome.appendingPathComponent(name))
        }
        let result = try await ManagerService(paths: paths, runner: MemoryAnalysisRunner()).buildProjectMemory(
            projectRoot: root, space: "byori_test"
        )
        XCTAssertEqual(result.detail, "indexed 12 symbols")
    }

    func testFailedRuntimeUpdateRestoresTheMatchingCodeBridge() async throws {
        let runtime = try makeRuntimeWithBundledCLI()
        _ = try makeInstalledCLI()
        let paths = ManagerPaths(home: root, runtimeRoot: runtime)
        let bridge = paths.byoriHome.appendingPathComponent("code_graph.py")
        let notices = paths.byoriHome.appendingPathComponent("INDEXER_LICENSES.txt")
        try Data("old notices".utf8).write(to: notices)
        let service = ManagerService(paths: paths, runner: FailingRuntimeUpdateRunner(home: paths.byoriHome))
        do {
            _ = try await service.installOrUpdateByori()
            XCTFail("the fixture install fails")
        } catch {
            XCTAssertEqual(try String(contentsOf: bridge), "# installed old bridge\n")
            XCTAssertEqual(try String(contentsOf: notices), "old notices")
        }
    }

    private func makeRuntimeWithBundledCLI() throws -> URL {
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let cli = runtime.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8)
            .write(to: cli.appendingPathComponent("byori.py"))
        let mcp = runtime.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: mcp, withIntermediateDirectories: true)
        for name in ["byoridb_mcp.py", "code_graph.py"] {
            try Data("# matching bundled bridge\n".utf8).write(to: mcp.appendingPathComponent(name))
        }
        let bin = runtime.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let indexer = bin.appendingPathComponent("byori-indexer")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: indexer)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: indexer.path)
        return runtime
    }

    private func makeInstalledCLI() throws -> URL {
        let bin = root.appendingPathComponent(".byoridb/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("byori")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        let indexer = bin.appendingPathComponent("byori-indexer")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: indexer)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: indexer.path)
        for name in ["byoridb_mcp.py", "code_graph.py"] {
            try Data("# installed old bridge\n".utf8)
                .write(to: bin.deletingLastPathComponent().appendingPathComponent(name))
        }
        return executable
    }
}

private struct MemoryAnalysisRunner: CommandRunning {
    func run(_ command: CommandSpec) async -> CommandResult {
        CommandResult(exitCode: 0, output: "indexed 12 symbols")
    }
}

private struct FailingRuntimeUpdateRunner: CommandRunning {
    let home: URL

    func run(_ command: CommandSpec) async -> CommandResult {
        if command.executable == "/bin/bash" {
            try? Data("new bridge".utf8).write(to: home.appendingPathComponent("code_graph.py"))
            try? Data("new notices".utf8).write(to: home.appendingPathComponent("INDEXER_LICENSES.txt"))
        }
        return CommandResult(exitCode: 1, output: "fixture failure")
    }
}
