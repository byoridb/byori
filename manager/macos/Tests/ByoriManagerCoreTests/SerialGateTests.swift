import XCTest
@testable import ByoriManagerCore

final class SerialGateTests: XCTestCase {
    /// The property the graph client depends on: work inside `perform` never
    /// overlaps, even when many callers await it at once. Actor isolation alone
    /// does not give this — an actor lets another call in at every suspension —
    /// and overlapping logins are what made the engine refuse valid credentials.
    func testConcurrentCallersNeverOverlap() async {
        let gate = SerialGate()
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await gate.perform {
                        await tracker.enter()
                        // Suspend inside the critical section: without the gate
                        // this is exactly where the next caller would slip in.
                        try? await Task.sleep(nanoseconds: 200_000)
                        await tracker.leave()
                    }
                }
            }
        }

        let maximumConcurrent = await tracker.maximumConcurrent
        let completed = await tracker.completed
        XCTAssertEqual(maximumConcurrent, 1)
        XCTAssertEqual(completed, 32)
    }

    func testGateReleasesAfterAThrowingCaller() async {
        let gate = SerialGate()
        struct Failure: Error {}

        do {
            try await gate.perform { throw Failure() }
            XCTFail("The gate must propagate the caller's error")
        } catch is Failure {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // A gate that stayed locked after a throw would hang here instead.
        let value = await gate.perform { 42 }
        XCTAssertEqual(value, 42)
    }

    func testReturnValueAndOrderingAreCallerObservable() async {
        let gate = SerialGate()
        let recorder = OrderRecorder()

        await withTaskGroup(of: Int.self) { group in
            for index in 0..<8 {
                group.addTask {
                    await gate.perform {
                        await recorder.record(index)
                        return index
                    }
                }
            }
            var returned: Set<Int> = []
            for await value in group { returned.insert(value) }
            XCTAssertEqual(returned, Set(0..<8))
        }
        let recorded = await recorder.count
        XCTAssertEqual(recorded, 8)
    }
}

private actor ConcurrencyTracker {
    private(set) var maximumConcurrent = 0
    private(set) var completed = 0
    private var current = 0

    func enter() {
        current += 1
        maximumConcurrent = max(maximumConcurrent, current)
    }

    func leave() {
        current -= 1
        completed += 1
    }
}

private actor OrderRecorder {
    private(set) var count = 0

    func record(_ value: Int) {
        count += 1
    }
}
