import XCTest
@testable import ByoriManagerCore

/// `engine.json` decides whether `byoridb-server --version` is safe to run, so a
/// record that no longer describes the binary on disk is worse than no record:
/// it can send a pre-0.4.0 engine's argument-ignoring binary a probe that starts
/// a second server against the live data (#57).
final class EngineManifestIntegrityTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-manifest-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("byoridb", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        paths = ManagerPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("runtime", isDirectory: true),
            byoriHome: home,
            httpPort: 1
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeBinary(_ contents: String) throws -> String {
        let data = Data("#!/bin/sh\n# \(contents)\n".utf8)
        try data.write(to: paths.serverBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.serverBinary.path)
        return try XCTUnwrap(EngineBuildManifest.sha256(ofFileAt: paths.serverBinary))
    }

    private func writeManifest(tag: String, sha256: String) throws {
        let json = #"{"tag": "\#(tag)", "target": "aarch64-apple-darwin", "sha256": "\#(sha256)"}"#
        try Data(json.utf8).write(to: paths.engineManifest)
    }

    func testTheDigestIsTheFilesSHA256() throws {
        let file = root.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)

        XCTAssertEqual(
            EngineBuildManifest.sha256(ofFileAt: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertNil(EngineBuildManifest.sha256(ofFileAt: root.appendingPathComponent("missing")))
    }

    func testARecordDescribesOnlyTheBinaryItNames() {
        let digest = String(repeating: "a", count: 64)
        let recorded = EngineBuildManifest(tag: "v0.4.2", target: nil, sha256: digest, installedAt: nil)
        let undigested = EngineBuildManifest(tag: "v0.4.2", target: nil, sha256: nil, installedAt: nil)

        XCTAssertTrue(recorded.describes(binaryDigest: digest))
        XCTAssertFalse(recorded.describes(binaryDigest: String(repeating: "b", count: 64)))
        XCTAssertFalse(recorded.describes(binaryDigest: nil))
        XCTAssertTrue(undigested.describes(binaryDigest: nil), "records from before digests are taken as is")
        XCTAssertNil(
            EngineBuildManifest.installedVersion(
                fromIdentity: EngineBuildManifest.unrecordedIdentity(binaryDigest: digest)
            ),
            "an unrecorded engine must not be ordered against releases"
        )
    }

    func testAMatchingRecordStillAllowsTheVersionProbe() async throws {
        let digest = try writeBinary("0.4.2")
        try writeManifest(tag: "v0.4.2", sha256: digest)
        let runner = VersionRecordingRunner(serverBinary: paths.serverBinary, versionOutput: "byoridb-server 0.4.2 (commit f7ff47a55f50, release)")

        let version = await ManagerService(paths: paths, runner: runner).snapshot().byori.serverVersion

        XCTAssertEqual(version, "0.4.2 (commit f7ff47a55f50, release)")
        XCTAssertEqual(runner.versionProbes(), 1)
    }

    /// The incident: rollback restored a 0.4.0 binary while the record still said
    /// v0.4.2. A record that no longer matches must not unlock the probe.
    func testARecordForADifferentBinaryNeitherProbesNorIsBelieved() async throws {
        let digest = try writeBinary("restored 0.3.x")
        try writeManifest(tag: "v0.4.2", sha256: String(repeating: "b", count: 64))
        let runner = VersionRecordingRunner(serverBinary: paths.serverBinary, versionOutput: "byoridb-server 0.4.2 (commit f7ff47a55f50, release)")

        let version = await ManagerService(paths: paths, runner: runner).snapshot().byori.serverVersion

        XCTAssertEqual(version, EngineBuildManifest.unrecordedIdentity(binaryDigest: digest))
        XCTAssertEqual(runner.versionProbes(), 0, "a mismatched record must not gate a probe")
    }

    func testReplacingTheBinaryIsNoticedOnTheNextRefresh() async throws {
        let original = try writeBinary("0.4.2")
        try writeManifest(tag: "v0.4.2", sha256: original)
        let service = ManagerService(paths: paths, runner: VersionRecordingRunner(serverBinary: paths.serverBinary, versionOutput: "0.4.2"))
        _ = await service.snapshot()

        let replaced = try writeBinary("replaced out of band, a different length")
        let version = await service.snapshot().byori.serverVersion

        XCTAssertEqual(version, EngineBuildManifest.unrecordedIdentity(binaryDigest: replaced))
    }

    /// A failed install that had already written a new binary and record must
    /// put both back, not the binary alone.
    func testAFailedInstallRestoresTheRecordWithTheBinary() async throws {
        let oldDigest = try writeBinary("0.4.0")
        try writeManifest(tag: "v0.4.0", sha256: oldDigest)
        let oldRecord = try Data(contentsOf: paths.engineManifest)
        let runner = FailingInstallRunner(paths: paths)

        do {
            _ = try await ManagerService(paths: paths, runner: runner).installOrUpdateByori(engineTag: "v0.4.2")
            XCTFail("the install was set up to fail")
        } catch {}

        XCTAssertTrue(runner.installRan(), "the install must have replaced both before failing")
        XCTAssertEqual(try Data(contentsOf: paths.engineManifest), oldRecord)
        XCTAssertEqual(EngineBuildManifest.sha256(ofFileAt: paths.serverBinary), oldDigest)
    }

    func testAFailedFirstInstallLeavesNoRecordBehind() async throws {
        try FileManager.default.removeItem(at: paths.byoriHome.appendingPathComponent("bin"))
        let runner = FailingInstallRunner(paths: paths)

        do {
            _ = try await ManagerService(paths: paths, runner: runner).installOrUpdateByori(engineTag: "v0.4.2")
            XCTFail("the install was set up to fail")
        } catch {}

        XCTAssertTrue(runner.installRan())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.engineManifest.path))
    }
}

/// Answers the engine binary's `--version` and counts how often it was asked;
/// everything else fails, which reads as "not installed / not loaded".
private final class VersionRecordingRunner: CommandRunning, @unchecked Sendable {
    private let serverBinary: String
    private let versionOutput: String
    private let lock = NSLock()
    private var probes = 0

    init(serverBinary: URL, versionOutput: String) {
        self.serverBinary = serverBinary.path
        self.versionOutput = versionOutput
    }

    func versionProbes() -> Int { lock.withLock { probes } }

    func run(_ command: CommandSpec) async -> CommandResult {
        if command.executable == serverBinary, command.arguments == ["--version"] {
            lock.withLock { probes += 1 }
            return CommandResult(exitCode: 0, output: versionOutput)
        }
        return CommandResult(exitCode: 1, output: "")
    }
}

/// Plays an install that replaces the engine and its record, then dies in the
/// health wait. The launchd job reads as not loaded throughout.
private final class FailingInstallRunner: CommandRunning, @unchecked Sendable {
    private let paths: ManagerPaths
    private let lock = NSLock()
    private var ran = false

    init(paths: ManagerPaths) { self.paths = paths }

    func installRan() -> Bool { lock.withLock { ran } }

    func run(_ command: CommandSpec) async -> CommandResult {
        guard command.executable == "/bin/bash" else {
            return CommandResult(exitCode: 1, output: "")
        }
        let bin = paths.byoriHome.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n# 0.4.2\n".utf8).write(to: paths.serverBinary)
        let digest = EngineBuildManifest.sha256(ofFileAt: paths.serverBinary) ?? ""
        try? Data(#"{"tag": "v0.4.2", "sha256": "\#(digest)"}"#.utf8).write(to: paths.engineManifest)
        lock.withLock { ran = true }
        return CommandResult(exitCode: 1, output: "error: server did not become healthy")
    }
}
