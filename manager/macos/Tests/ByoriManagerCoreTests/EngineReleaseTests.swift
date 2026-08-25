import XCTest
@testable import ByoriManagerCore

/// The engine ships from its own repository, so the page has to report two facts —
/// what is installed and what exists — and never guess one from the other.
final class EngineReleaseCatalogTests: XCTestCase {
    private func payload(
        tag: String = "v0.4.12",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"https://example.invalid/engine",
         "draft":\(draft),"prerelease":\(prerelease),
         "assets":[{"name":"byoridb-\(tag)-aarch64-apple-darwin.tar.gz",
                    "browser_download_url":"https://example.invalid/engine.tar.gz"}]}
        """.utf8)
    }

    func testReadsTheTagAndKeepsItVerbatim() throws {
        let release = try ReleaseCatalog.latestEngineRelease(from: payload())

        // The tag is what the installer interpolates into a download URL, so the
        // `v` must survive the round trip through the parsed version.
        XCTAssertEqual(release.tag, "v0.4.12")
        XCTAssertEqual(release.version, AppVersion("0.4.12"))
        XCTAssertEqual(release.releaseURL?.absoluteString, "https://example.invalid/engine")
    }

    /// An engine release carries archives, never a `.dmg`. Requiring an installable
    /// image here — as the app updater must — would refuse every one of them.
    func testAcceptsAReleaseWithoutADiskImage() throws {
        let payload = Data("""
        {"tag_name":"v0.5.0","html_url":null,"draft":false,"prerelease":false,"assets":[]}
        """.utf8)

        XCTAssertEqual(try ReleaseCatalog.latestEngineRelease(from: payload).tag, "v0.5.0")
    }

    /// Verbatim `GET /repos/byoridb/byoridb/releases/latest`, with the asset list
    /// and release notes shortened. Pinned to what GitHub actually returns —
    /// including the keys Byori ignores — so a parser that only handles a
    /// hand-written payload cannot pass.
    func testDecodesARealEngineReleasePayload() throws {
        let payload = Data("""
        {
          "url": "https://api.github.com/repos/byoridb/byoridb/releases/375462278",
          "html_url": "https://github.com/byoridb/byoridb/releases/tag/v0.4.12",
          "id": 375462278,
          "node_id": "RE_kwDOSbhyvs4WYRmG",
          "tag_name": "v0.4.12",
          "target_commitish": "e64bc5d487bcbd53b8442f1738b59ecce837a5b6",
          "name": "v0.4.12",
          "draft": false,
          "immutable": false,
          "prerelease": false,
          "created_at": "2026-08-24T05:01:24Z",
          "published_at": "2026-08-24T05:15:17Z",
          "tarball_url": "https://api.github.com/repos/byoridb/byoridb/tarball/v0.4.12",
          "author": { "login": "github-actions[bot]", "id": 41898282 },
          "assets": [
            {
              "url": "https://api.github.com/repos/byoridb/byoridb/releases/assets/527124400",
              "id": 527124400,
              "name": "byoridb-v0.4.12-aarch64-apple-darwin.tar.gz",
              "label": "",
              "content_type": "application/gzip",
              "state": "uploaded",
              "size": 7883273,
              "browser_download_url": "https://github.com/byoridb/byoridb/releases/download/v0.4.12/byoridb-v0.4.12-aarch64-apple-darwin.tar.gz"
            }
          ],
          "body": "## What's Changed"
        }
        """.utf8)

        let release = try ReleaseCatalog.latestEngineRelease(from: payload)

        XCTAssertEqual(release.tag, "v0.4.12")
        XCTAssertEqual(release.version, AppVersion("0.4.12"))
        XCTAssertEqual(
            release.releaseURL?.absoluteString,
            "https://github.com/byoridb/byoridb/releases/tag/v0.4.12"
        )
        // The pair this app shipped with: 0.4.2 installed while 0.4.12 was the
        // newest release, reported as current because nothing compared them.
        XCTAssertEqual(
            EngineUpdateAvailability.resolve(
                installedIdentity: "0.4.2 (commit f7ff47a55f50, release)",
                latest: release
            ),
            .available(release)
        )
    }

    func testRejectsDraftsPrereleasesAndUnparsableTags() {
        XCTAssertThrowsError(try ReleaseCatalog.latestEngineRelease(from: payload(draft: true)))
        XCTAssertThrowsError(try ReleaseCatalog.latestEngineRelease(from: payload(prerelease: true)))
        XCTAssertThrowsError(try ReleaseCatalog.latestEngineRelease(from: payload(tag: "nightly")))
    }

    /// The tag reaches a download URL and the engine manifest, so a value that
    /// could alter either is refused where it is read rather than where it is used.
    func testRejectsTagsOutsideTheInstallerCharset() {
        XCTAssertFalse(EngineRelease.isSafeTag("v0.4.2; rm -rf /"))
        XCTAssertFalse(EngineRelease.isSafeTag("v0.4.2/../../etc"))
        XCTAssertFalse(EngineRelease.isSafeTag(""))
        XCTAssertTrue(EngineRelease.isSafeTag("v0.4.12"))
        XCTAssertTrue(EngineRelease.isSafeTag("0.4.12+build.1"))
    }
}

final class EngineUpdateAvailabilityTests: XCTestCase {
    private let latest = EngineRelease(tag: "v0.4.12", version: AppVersion("0.4.12")!)

    /// Failing to reach GitHub must not read as "you are up to date": that is the
    /// state in which the installer silently lands its own pinned tag.
    func testWithoutACheckTheStateIsUnknown() {
        XCTAssertEqual(
            EngineUpdateAvailability.resolve(installedIdentity: "0.4.2", latest: nil),
            .unknown
        )
    }

    func testComparesTheProbedAndRecordedIdentityForms() {
        // `byoridb-server --version`
        XCTAssertEqual(
            EngineUpdateAvailability.resolve(
                installedIdentity: "0.4.2 (commit f7ff47a55f50, release)",
                latest: latest
            ),
            .available(latest)
        )
        // The installer's manifest
        XCTAssertEqual(
            EngineUpdateAvailability.resolve(installedIdentity: "v0.4.12 · b8c973d4fed1", latest: latest),
            .upToDate(latest)
        )
    }

    /// 0.4.2 must not look newer than 0.4.12 — the ordering is numeric, not
    /// lexical, which is exactly the pair this app shipped with.
    func testOrdersPatchNumbersNumerically() {
        XCTAssertEqual(
            EngineUpdateAvailability.resolve(installedIdentity: "0.4.2", latest: latest),
            .available(latest)
        )
    }

    /// An engine newer than the newest release is not an update opportunity; it is
    /// someone testing a build, and offering to overwrite it would be wrong.
    func testANewerInstalledEngineCountsAsUpToDate() {
        XCTAssertEqual(
            EngineUpdateAvailability.resolve(installedIdentity: "0.5.0", latest: latest),
            .upToDate(latest)
        )
    }

    func testAnUnrecordedOrLocalBuildIsReportedAsSuch() {
        XCTAssertEqual(
            EngineUpdateAvailability.resolve(installedIdentity: nil, latest: latest),
            .installedUnknown(latest)
        )
        XCTAssertEqual(
            EngineUpdateAvailability.resolve(installedIdentity: "로컬 빌드 · b8c973d4fed1", latest: latest),
            .installedUnknown(latest)
        )
    }
}
