import Foundation
import XCTest
@testable import ByoriManagerCore

/// Every effect here is an injected closure or a private temporary JSON file.
/// A temporary HOME never makes launchctl safe to call in a test.
final class RuntimeRecoveryTests: XCTestCase {
    func testBudgetAndCooldownSurviveControllerRecreation() async throws {
        let clock = RecoveryTestClock()
        let store = RecoveryTestStore()
        for attempt in 0..<3 {
            let controller = RuntimeRecoveryController(store: store, now: { clock.date })
            do {
                _ = try await controller.recover(automatic: true, observe: { .stopped }, repair: { _ in })
                XCTFail("an unchanged stopped service must fail verification")
            } catch RuntimeRecoveryError.verificationFailed(.stopped) {}
            let report = await controller.status(diagnosis: .stopped)
            XCTAssertEqual(report.attemptsUsed, attempt + 1)
            XCTAssertFalse(report.canRecover)
            clock.advance(60)
        }
        let restarted = RuntimeRecoveryController(store: store, now: { clock.date })
        let blocked = await restarted.status(diagnosis: .stopped)
        XCTAssertEqual(blocked.attemptsUsed, 3)
        XCTAssertEqual(blocked.nextAttemptAt, Date(timeIntervalSince1970: 1_600))
        do {
            _ = try await restarted.recover(automatic: false, observe: { .stopped }, repair: { _ in
                XCTFail("budget exhaustion must refuse even an explicit recovery")
            })
            XCTFail("must wait for the budget window")
        } catch RuntimeRecoveryError.retryDeferred {}
        clock.advance(420)
        let released = await restarted.status(diagnosis: .stopped)
        XCTAssertTrue(released.canRecover)
        XCTAssertEqual(released.lastAttempt?.outcome, .failed, "history survives cooldown")
    }

    func testVerifiedSuccessIsPersistedAndStillCountsAgainstFlappingBudget() async throws {
        let store = RecoveryTestStore()
        let probe = RecoveryTestProbe()
        let controller = RuntimeRecoveryController(store: store)
        let report = try await controller.recover(
            automatic: false,
            observe: { await probe.diagnosis },
            repair: { action in
                XCTAssertEqual(action, .start)
                await probe.setHealthy()
            }
        )
        XCTAssertEqual(report.diagnosis, .healthy)
        XCTAssertEqual(report.lastAttempt?.outcome, .verified)
        XCTAssertEqual(try store.load().attempts.count, 1)
        XCTAssertFalse(report.isRunning)
    }

    func testUnsafeDiagnosesNeverInvokeRepairOrSpendBudget() async throws {
        for diagnosis in [RuntimeDiagnosis.authenticationFailed, .foreignListener, .diskLow,
                          .missingConfiguration, .notInstalled, .inspectionFailed, .queryFailed] {
            let store = RecoveryTestStore()
            let controller = RuntimeRecoveryController(store: store)
            do {
                _ = try await controller.recover(automatic: false, observe: { diagnosis }, repair: { _ in
                    XCTFail("no repair permitted for \(diagnosis)")
                })
                XCTFail("unsafe diagnosis should refuse repair")
            } catch RuntimeRecoveryError.refused(diagnosis) {}
            XCTAssertTrue(try store.load().attempts.isEmpty)
        }
    }

    func testPersistedStopBlocksAutomaticRecoveryButExplicitRecoveryCanResume() async throws {
        let store = RecoveryTestStore()
        let original = RuntimeRecoveryController(store: store)
        try await original.setUserStopped(true)
        let restarted = RuntimeRecoveryController(store: store)
        let stopped = await restarted.status(diagnosis: .stopped)
        XCTAssertTrue(stopped.canRecover)
        XCTAssertFalse(stopped.canRecoverAutomatically)
        do {
            _ = try await restarted.recover(automatic: true, observe: { .stopped }, repair: { _ in
                XCTFail("explicit stop must survive relaunch")
            })
            XCTFail("automatic recovery should be suppressed")
        } catch RuntimeRecoveryError.userStopped {}
        let probe = RecoveryTestProbe()
        _ = try await restarted.recover(automatic: false, observe: { await probe.diagnosis }, repair: { _ in
            await probe.setHealthy()
        })
        XCTAssertFalse(try store.load().userStopped)
    }

    func testCancellationRetainsReservedAttemptAndDoesNotClaimRollback() async throws {
        let store = RecoveryTestStore()
        let controller = RuntimeRecoveryController(store: store)
        do {
            _ = try await controller.recover(automatic: false, observe: { .stopped }, repair: { _ in
                XCTAssertEqual(try store.load().attempts.last?.outcome, .pending)
                throw CancellationError()
            })
            XCTFail("cancelled repair should propagate cancellation")
        } catch is CancellationError {}
        let state = try store.load()
        XCTAssertEqual(state.attempts.count, 1)
        XCTAssertEqual(state.attempts.last?.outcome, .cancelled)
        let recreated = RuntimeRecoveryController(store: store)
        let report = await recreated.status(diagnosis: .stopped)
        XCTAssertFalse(report.canRecover)
    }

    func testReservationMustPersistBeforeAnyRepair() async throws {
        let store = RecoveryTestStore(failWrites: true)
        let controller = RuntimeRecoveryController(store: store)
        do {
            _ = try await controller.recover(automatic: false, observe: { .stopped }, repair: { _ in
                XCTFail("must not mutate if reservation cannot be persisted")
            })
            XCTFail("must report unavailable persistence")
        } catch RuntimeRecoveryError.persistenceUnavailable {}
    }

    func testOverlappingRecoveryCannotRunASecondMutation() async throws {
        let store = RecoveryTestStore()
        let controller = RuntimeRecoveryController(store: store)
        let latch = RecoveryTestLatch()
        let first = Task {
            try await controller.recover(automatic: false, observe: { .stopped }, repair: { _ in
                await latch.wait()
                throw CancellationError()
            })
        }
        await latch.waitUntilEntered()
        do {
            _ = try await controller.recover(automatic: false, observe: { .stopped }, repair: { _ in
                XCTFail("overlap must be rejected")
            })
            XCTFail("second call must refuse")
        } catch RuntimeRecoveryError.alreadyRunning {}
        await latch.release()
        do { _ = try await first.value; XCTFail("first call should cancel") }
        catch is CancellationError {}
        XCTAssertEqual(try store.load().attempts.count, 1)
    }

    func testPrivateFileRoundTripAndCorruptionFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byori-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private/recovery.json")
        let file = RuntimeRecoveryFileStore(url: url)
        var state = RuntimeRecoveryState()
        state.userStopped = true
        try file.save(state)
        XCTAssertEqual(try RuntimeRecoveryFileStore(url: url).load(), state)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try Data("broken".utf8).write(to: url)
        let controller = RuntimeRecoveryController(store: file)
        let report = await controller.status(diagnosis: .stopped)
        XCTAssertFalse(report.persistenceAvailable)
        XCTAssertFalse(report.canRecover)
        do {
            _ = try await controller.recover(automatic: true, observe: { .stopped }, repair: { _ in
                XCTFail("corrupted records must not reset the budget")
            })
            XCTFail("corruption should refuse recovery")
        } catch RuntimeRecoveryError.persistenceUnavailable {}
    }

    func testFileStoreRejectsSymlinkInsteadOfReplacingUnrelatedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byori-recovery-link-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("state")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = RuntimeRecoveryFileStore(url: link)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(RuntimeRecoveryState()))
        XCTAssertEqual(try String(contentsOf: target), "preserve")
    }
}

private final class RecoveryTestStore: RuntimeRecoveryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state = RuntimeRecoveryState()
    private let failWrites: Bool
    init(failWrites: Bool = false) { self.failWrites = failWrites }
    func load() throws -> RuntimeRecoveryState { lock.lock(); defer { lock.unlock() }; return state }
    func save(_ state: RuntimeRecoveryState) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw RuntimeRecoveryError.persistenceUnavailable }
        self.state = state
    }
}

private final class RecoveryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

private actor RecoveryTestProbe {
    var diagnosis: RuntimeDiagnosis = .stopped
    func setHealthy() { diagnosis = .healthy }
}

private actor RecoveryTestLatch {
    private var waiter: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
        }
    }
    func waitUntilEntered() async {
        if waiter != nil { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { waiter?.resume(); waiter = nil }
}
