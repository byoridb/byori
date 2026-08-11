import XCTest
@testable import ByoriManagerCore

/// Autostart is wrong quietly in both directions: restarting a service the user
/// deliberately stopped, or leaving every agent session running against no
/// memory because nothing said the service was down.
final class ByoriAutostartTests: XCTestCase {
    func testStartsWhenInstalledButNotLoaded() {
        XCTAssertTrue(
            ByoriAutostart.shouldStart(
                makeStatus(isInstalled: true, isHealthy: false, serviceLoaded: false),
                userStoppedThisLaunch: false
            )
        )
    }

    /// The launch agent carries RunAtLoad and KeepAlive, so a registered but
    /// unresponsive service is exactly the case launchd could not fix itself.
    func testStartsWhenLoadedButUnhealthy() {
        XCTAssertTrue(
            ByoriAutostart.shouldStart(
                makeStatus(isInstalled: true, isHealthy: false, serviceLoaded: true),
                userStoppedThisLaunch: false
            )
        )
    }

    func testLeavesAHealthyServiceAlone() {
        XCTAssertFalse(
            ByoriAutostart.shouldStart(
                makeStatus(isInstalled: true, isHealthy: true, serviceLoaded: true),
                userStoppedThisLaunch: false
            )
        )
    }

    /// A stop the app immediately undoes reads as the button being broken.
    func testRespectsAnExplicitStop() {
        XCTAssertFalse(
            ByoriAutostart.shouldStart(
                makeStatus(isInstalled: true, isHealthy: false, serviceLoaded: false),
                userStoppedThisLaunch: true
            )
        )
    }

    /// Installing is a far larger operation with its own confirmation. Autostart
    /// must never escalate into one.
    func testNeverStartsWhatIsNotInstalled() {
        for stopped in [true, false] {
            XCTAssertFalse(
                ByoriAutostart.shouldStart(
                    makeStatus(isInstalled: false, isHealthy: false, serviceLoaded: false),
                    userStoppedThisLaunch: stopped
                )
            )
        }
    }

    private func makeStatus(
        isInstalled: Bool,
        isHealthy: Bool,
        serviceLoaded: Bool
    ) -> ByoriStatus {
        ByoriStatus(
            isInstalled: isInstalled,
            isHealthy: isHealthy,
            serviceLoaded: serviceLoaded,
            serverVersion: nil,
            homePath: "/tmp/byoridb",
            pythonAvailable: true
        )
    }
}
