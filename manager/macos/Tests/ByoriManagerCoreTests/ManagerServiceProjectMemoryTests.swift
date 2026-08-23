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

    private func makeRuntimeWithBundledCLI() throws -> URL {
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let cli = runtime.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8)
            .write(to: cli.appendingPathComponent("byori.py"))
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
        return executable
    }
}
