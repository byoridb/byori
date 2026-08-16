import XCTest
@testable import ByoriManagerCore

/// The installed engine cannot be asked what it is: `byoridb-server` has no
/// `--version` and, on the pinned release, treats the flag as a normal server
/// launch. This file is therefore the only answer to "which engine is installed",
/// which makes both what it reports and what it refuses to report worth pinning.
final class EngineBuildManifestTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-engine-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testReadsWhatTheInstallerWrites() throws {
        let digest = String(repeating: "a1b2c3d4", count: 8)
        let url = try write("""
        {
          "binary_path": "/Users/example/.byoridb/bin/byoridb-server",
          "installed_at": "2026-08-16T04:05:06Z",
          "sha256": "\(digest)",
          "source": "https://github.com/byoridb/byoridb/releases/download/v0.3.3/byoridb-v0.3.3-aarch64-apple-darwin.tar.gz",
          "tag": "v0.3.3",
          "target": "aarch64-apple-darwin"
        }
        """)

        let manifest = try XCTUnwrap(EngineBuildManifest.read(at: url))
        XCTAssertEqual(manifest.tag, "v0.3.3")
        XCTAssertEqual(manifest.target, "aarch64-apple-darwin")
        XCTAssertEqual(manifest.sha256, digest)
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        (components.year, components.month, components.day) = (2026, 8, 16)
        (components.hour, components.minute, components.second) = (4, 5, 6)
        XCTAssertEqual(
            manifest.installedAt,
            Calendar(identifier: .gregorian).date(from: components),
            "the recorded timestamp must be read as UTC, not in the local zone"
        )
        XCTAssertEqual(
            manifest.displayIdentity,
            "v0.3.3 · a1b2c3d4a1b2",
            "enough digest to tell two builds of one tag apart"
        )
    }

    /// `--binary` installs an engine with no release tag. That is a legitimate
    /// state and must not read as "unknown engine".
    func testLocalBinaryIsIdentifiedByItsDigest() throws {
        let digest = String(repeating: "f", count: 64)
        let url = try write("""
        { "tag": "", "sha256": "\(digest)", "target": "x86_64-unknown-linux-gnu" }
        """)

        let manifest = try XCTUnwrap(EngineBuildManifest.read(at: url))
        XCTAssertNil(manifest.tag)
        XCTAssertEqual(manifest.displayIdentity, "로컬 빌드 · ffffffffffff")
    }

    /// Absent, damaged, and empty must all report nothing rather than a healthy
    /// unknown: engines installed before the installer recorded this have no file.
    func testUnusableManifestsReportNothing() throws {
        XCTAssertNil(
            EngineBuildManifest.read(at: temporaryRoot.appendingPathComponent("missing.json")),
            "a missing manifest is the state of every pre-existing install"
        )
        XCTAssertNil(EngineBuildManifest.read(at: try write("{ not json")))
        XCTAssertNil(EngineBuildManifest.read(at: try write("[]")))
        XCTAssertNil(EngineBuildManifest.read(at: try write("{}")))
        XCTAssertNil(
            EngineBuildManifest.read(at: try write(#"{ "tag": "", "sha256": "" }"#)),
            "a file that carried nothing recognizable is the same as no file"
        )
    }

    /// The values are written locally but land in the UI, so each is checked
    /// against the shape it should have instead of being trusted for being local.
    func testMalformedFieldsAreDroppedRatherThanDisplayed() throws {
        let url = try write("""
        {
          "installed_at": "yesterday",
          "sha256": "not-a-digest",
          "tag": "v1.0.0 \\u001b[31mred",
          "target": "../../etc/passwd"
        }
        """)

        XCTAssertNil(
            EngineBuildManifest.read(at: url),
            "every field was invalid, so there is nothing to report"
        )
    }

    func testAPartiallyValidManifestKeepsOnlyTheValidFields() throws {
        let digest = String(repeating: "0", count: 64)
        let url = try write("""
        { "tag": "v0.3.3", "sha256": "\(digest)", "target": "has spaces", "installed_at": "nope" }
        """)

        let manifest = try XCTUnwrap(EngineBuildManifest.read(at: url))
        XCTAssertEqual(manifest.tag, "v0.3.3")
        XCTAssertEqual(manifest.sha256, digest)
        XCTAssertNil(manifest.target)
        XCTAssertNil(manifest.installedAt)
    }

    func testManifestPathSitsBesideTheEngineBinary() {
        let paths = ManagerPaths(home: temporaryRoot, runtimeRoot: temporaryRoot)

        XCTAssertEqual(
            paths.engineManifest.deletingLastPathComponent().standardizedFileURL,
            paths.byoriHome.standardizedFileURL
        )
        XCTAssertEqual(paths.engineManifest.lastPathComponent, "engine.json")
    }

    /// Running the wrong engine with `--version` starts a second database against
    /// the live data directory. The recorded tag is the only thing that says
    /// whether the probe is safe, so the gate is pinned in both directions.
    func testVersionProbeIsAllowedOnlyFromRecordedZeroFourOrLater() {
        func manifest(_ tag: String?) -> EngineBuildManifest {
            EngineBuildManifest(tag: tag, target: nil, sha256: nil, installedAt: nil)
        }

        XCTAssertTrue(manifest("v0.4.0").allowsVersionProbe)
        XCTAssertTrue(manifest("v0.4.1").allowsVersionProbe)
        XCTAssertTrue(manifest("v1.0.0").allowsVersionProbe)
        XCTAssertTrue(manifest("0.4.0").allowsVersionProbe, "a tag without the v prefix still counts")

        XCTAssertFalse(manifest("v0.3.3").allowsVersionProbe)
        XCTAssertFalse(manifest("v0.3.9").allowsVersionProbe)
        XCTAssertFalse(manifest(nil).allowsVersionProbe, "a local binary was never recorded as a release")
        XCTAssertFalse(manifest("nightly").allowsVersionProbe, "an unparsable tag must not authorize a probe")
    }

    /// The literal output of the shipped v0.4.0 binary, taken from running it
    /// rather than from the release notes — which showed the version without the
    /// binary name clap actually prints in front of it.
    func testVersionOutputIsParsedAndBounded() {
        XCTAssertEqual(
            EngineBuildManifest.version(
                fromVersionOutput: "byoridb-server 0.4.0 (commit fbeb4ac55417, release)\n"
            ),
            "0.4.0 (commit fbeb4ac55417, release)",
            "the name is dropped; the commit and profile distinguish two builds of one tag"
        )
        XCTAssertEqual(
            EngineBuildManifest.version(fromVersionOutput: "0.4.0 (commit 1a2b3c4, release)"),
            "0.4.0 (commit 1a2b3c4, release)",
            "a bare version stays acceptable if the framing ever changes"
        )
        XCTAssertEqual(EngineBuildManifest.version(fromVersionOutput: "  0.4.0  "), "0.4.0")

        for output in ["", "\n", "byoridb-server", "not a version", "byoridb-server unknown",
                       "0.4.0 \u{1b}[31mred", "byoridb-server 0.4.0 \u{1b}[31mred",
                       String(repeating: "9", count: 300)] {
            XCTAssertNil(
                EngineBuildManifest.version(fromVersionOutput: output),
                "refused: \(output.debugDescription)"
            )
        }
    }

    private func write(_ contents: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent("engine-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return url
    }
}
