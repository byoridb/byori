import XCTest
@testable import ByoriManagerCore

final class AppVersionTests: XCTestCase {
    func testParsesReleaseTagsAndRejectsGarbage() {
        XCTAssertEqual(AppVersion("v0.3.0")?.description, "0.3.0")
        XCTAssertEqual(AppVersion("0.3")?.description, "0.3.0")
        XCTAssertEqual(AppVersion("1.2.3-beta.1")?.description, "1.2.3-beta.1")
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion("0.3.x"))
    }

    func testOrdersVersionsIncludingPrereleases() {
        XCTAssertTrue(AppVersion("0.3.0")! < AppVersion("0.10.0")!)
        XCTAssertTrue(AppVersion("0.3.0")! < AppVersion("1.0.0")!)
        XCTAssertTrue(AppVersion("0.2.9")! < AppVersion("0.3.0")!)
        XCTAssertEqual(AppVersion("v0.3.0"), AppVersion("0.3.0"))
        // A prerelease must never look newer than the release it leads to,
        // otherwise a beta tag would push itself onto stable installs.
        XCTAssertTrue(AppVersion("0.4.0-beta.1")! < AppVersion("0.4.0")!)
        XCTAssertFalse(AppVersion("0.4.0")! < AppVersion("0.4.0-beta.1")!)
    }
}

final class ReleaseCatalogTests: XCTestCase {
    private func payload(
        tag: String = "v0.4.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [(String, String)] = [
            ("install.sh", "https://example.invalid/install.sh"),
            ("Byori-0.4.0-universal.dmg", "https://example.invalid/Byori-0.4.0-universal.dmg"),
        ]
    ) -> Data {
        let entries = assets.map {
            "{\"name\":\"\($0.0)\",\"browser_download_url\":\"\($0.1)\"}"
        }.joined(separator: ",")
        return Data("""
        {"tag_name":"\(tag)","html_url":"https://example.invalid/release",
         "draft":\(draft),"prerelease":\(prerelease),"assets":[\(entries)]}
        """.utf8)
    }

    func testSelectsTheUniversalDiskImage() throws {
        let update = try ReleaseCatalog.latestUpdate(from: payload())
        XCTAssertEqual(update.version, AppVersion("0.4.0"))
        XCTAssertEqual(update.assetName, "Byori-0.4.0-universal.dmg")
        XCTAssertEqual(update.releaseURL?.absoluteString, "https://example.invalid/release")
    }

    func testFallsBackToAnyDiskImage() throws {
        let update = try ReleaseCatalog.latestUpdate(from: payload(assets: [
            ("Byori-0.4.0-arm64.dmg", "https://example.invalid/Byori-0.4.0-arm64.dmg"),
        ]))
        XCTAssertEqual(update.assetName, "Byori-0.4.0-arm64.dmg")
    }

    func testRejectsDraftsPrereleasesAndImagelessReleases() {
        XCTAssertThrowsError(try ReleaseCatalog.latestUpdate(from: payload(draft: true)))
        XCTAssertThrowsError(try ReleaseCatalog.latestUpdate(from: payload(prerelease: true)))
        XCTAssertThrowsError(try ReleaseCatalog.latestUpdate(from: payload(assets: [
            ("install.sh", "https://example.invalid/install.sh"),
        ])))
        XCTAssertThrowsError(try ReleaseCatalog.latestUpdate(from: payload(tag: "nightly")))
    }
}

/// The fixtures below are verbatim output from the v0.3.0 release build, so the
/// parsers stay pinned to what the tools actually print.
final class AppUpdaterVerificationTests: XCTestCase {
    private let codesignOutput = """
    Executable=/Volumes/Byori/Byori.app/Contents/MacOS/ByoriManager
    Identifier=io.byoridb.byori
    CodeDirectory v=20500 size=12860 flags=0x10000(runtime) hashes=395+3 location=embedded
    Signature size=8968
    Authority=Developer ID Application: Ju Ik Kim (4J8MZGZJ2B)
    Authority=Developer ID Certification Authority
    Authority=Apple Root CA
    Timestamp=Aug 8, 2026 at 8:45:56 AM
    TeamIdentifier=4J8MZGZJ2B
    """

    func testReadsTheTeamIdentifier() {
        XCTAssertEqual(AppUpdater.teamIdentifier(fromCodesignOutput: codesignOutput), "4J8MZGZJ2B")
    }

    func testTreatsAnAdHocSignatureAsHavingNoTeam() {
        XCTAssertNil(AppUpdater.teamIdentifier(fromCodesignOutput: """
        Identifier=io.byoridb.byori
        Signature=adhoc
        TeamIdentifier=not set
        """))
        XCTAssertNil(AppUpdater.teamIdentifier(fromCodesignOutput: "Identifier=io.byoridb.byori"))
    }

    func testAcceptsOnlyNotarizedAssessments() {
        XCTAssertTrue(AppUpdater.isNotarized(spctlOutput: """
        /Volumes/Byori/Byori.app: accepted
        source=Notarized Developer ID
        origin=Developer ID Application: Ju Ik Kim (4J8MZGZJ2B)
        """))
        // Observed before the DMG was notarized: signed by a real Developer ID
        // and still rejected. Accepting this would defeat the whole check.
        XCTAssertFalse(AppUpdater.isNotarized(spctlOutput: """
        dist/Byori-0.3.0-universal.dmg: rejected
        source=Unnotarized Developer ID
        """))
        XCTAssertFalse(AppUpdater.isNotarized(spctlOutput: "dist/x.dmg: rejected"))
        XCTAssertFalse(AppUpdater.isNotarized(spctlOutput: ""))
    }

    func testReadsTheMountPointFromAttachOutput() {
        XCTAssertEqual(
            AppUpdater.mountPoint(fromAttachOutput: """
            /dev/disk4          \tGUID_partition_scheme          \t
            /dev/disk4s1        \tApple_HFS                      \t/Volumes/Byori
            """),
            "/Volumes/Byori"
        )
        XCTAssertNil(AppUpdater.mountPoint(fromAttachOutput: "hdiutil: attach failed"))
    }
}

private struct StubFetcher: ReleaseFetching {
    let payload: Data

    func data(from url: URL) async throws -> Data { payload }

    func download(from url: URL, to destination: URL) async throws {
        throw ManagerError.prerequisite("스텁은 내려받지 않습니다.")
    }
}

private struct UnusedRunner: CommandRunning {
    func run(_ command: CommandSpec) async -> CommandResult {
        CommandResult(exitCode: 1, output: "")
    }
}

final class AppUpdaterCheckTests: XCTestCase {
    private func updater(current: String, latest: String) -> AppUpdater {
        let payload = Data("""
        {"tag_name":"\(latest)","html_url":"https://example.invalid/r","draft":false,
         "prerelease":false,"assets":[{"name":"Byori-\(latest)-universal.dmg",
         "browser_download_url":"https://example.invalid/Byori.dmg"}]}
        """.utf8)
        return AppUpdater(
            bundleURL: URL(fileURLWithPath: "/Applications/Byori.app"),
            currentVersion: AppVersion(current)!,
            runner: UnusedRunner(),
            fetcher: StubFetcher(payload: payload)
        )
    }

    func testReportsAnAvailableUpdate() async throws {
        let status = try await updater(current: "0.3.0", latest: "0.4.0").check()
        guard case let .available(update) = status else {
            return XCTFail("expected an available update, got \(status)")
        }
        XCTAssertEqual(update.version, AppVersion("0.4.0"))
    }

    func testReportsUpToDateForOlderAndEqualReleases() async throws {
        for latest in ["0.3.0", "0.2.9"] {
            let status = try await updater(current: "0.3.0", latest: latest).check()
            XCTAssertEqual(status, .upToDate(AppVersion("0.3.0")!), "latest=\(latest)")
        }
    }

    func testStagingRefusesADowngradeBeforeTouchingTheNetwork() async {
        let updater = updater(current: "0.3.0", latest: "0.2.0")
        let downgrade = AvailableUpdate(
            version: AppVersion("0.2.0")!,
            assetName: "Byori-0.2.0-universal.dmg",
            downloadURL: URL(string: "https://example.invalid/Byori.dmg")!
        )
        do {
            _ = try await updater.stage(downgrade)
            XCTFail("expected the downgrade to be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("업데이트하지 않습니다"), "\(error)")
        }
    }
}

/// The helper waits for the app to exit before swapping the bundle. A quit that
/// never happens must not strand it: the first version waited forever, and when
/// the app deadlocked instead of quitting, the helper sat there holding a
/// mounted image with no way to make progress.
final class AppUpdaterHelperScriptTests: XCTestCase {
    func testTheHelperGivesUpWhenTheAppNeverExits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("apply-update.sh")
        try Data(AppUpdater.applyScript.utf8).write(to: script)

        let source = directory.appendingPathComponent("New.app")
        let target = directory.appendingPathComponent("Installed.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: target.appendingPathComponent("marker"))

        // A process that outlives the helper's bound, standing in for an app
        // that was asked to quit and did not.
        let stubborn = Process()
        stubborn.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stubborn.arguments = ["30"]
        try stubborn.run()
        defer { stubborn.terminate() }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            script.path,
            String(stubborn.processIdentifier),
            source.path,
            target.path,
            directory.appendingPathComponent("not-a-mount").path,
            "5",
        ]
        try helper.run()
        helper.waitUntilExit()

        XCTAssertNotEqual(helper.terminationStatus, 0, "the helper should report giving up")
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("marker")),
            Data("installed".utf8),
            "the installed app must be left exactly as it was"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path + ".byori-new"),
            "nothing should have been staged next to the target"
        )
    }

    func testTheHelperSwapsAndKeepsNoLeftoversOnceTheAppExits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("apply-update.sh")
        try Data(AppUpdater.applyScript.utf8).write(to: script)

        let source = directory.appendingPathComponent("New.app")
        let target = directory.appendingPathComponent("Installed.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("marker"))
        try Data("installed".utf8).write(to: target.appendingPathComponent("marker"))

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/bin/sleep")
        finished.arguments = ["0"]
        try finished.run()
        finished.waitUntilExit()

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            script.path,
            String(finished.processIdentifier),
            source.path,
            target.path,
            directory.appendingPathComponent("not-a-mount").path,
            "50",
        ]
        // `open` at the end has no bundle to launch here; the swap itself is
        // what this covers.
        try helper.run()
        helper.waitUntilExit()

        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("marker")),
            Data("new".utf8),
            "the target should now hold the new app"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".byori-old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".byori-new"))
    }
}
