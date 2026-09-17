import XCTest
@testable import NoopRemoteSync

@MainActor
final class ManagedSafetyIncidentGateTests: XCTestCase {
    func testSerializesWaitersInArrivalOrder() async throws {
        let gate = ManagedSafetyIncidentGate()
        try await gate.acquire()
        var arrivals: [Int] = []

        let first = Task { @MainActor in
            try await gate.acquire()
            arrivals.append(1)
            gate.release()
        }
        await waitForWaiterCount(1, in: gate)

        let second = Task { @MainActor in
            try await gate.acquire()
            arrivals.append(2)
            gate.release()
        }
        await waitForWaiterCount(2, in: gate)

        XCTAssertTrue(arrivals.isEmpty)
        gate.release()
        try await first.value
        try await second.value
        XCTAssertEqual(arrivals, [1, 2])
    }

    func testCanceledWaiterNeverAcquiresAndDoesNotBlockNextCaller() async throws {
        let gate = ManagedSafetyIncidentGate()
        try await gate.acquire()
        var canceledWaiterAcquired = false

        let canceled = Task { @MainActor in
            do {
                try await gate.acquire()
                canceledWaiterAcquired = true
                gate.release()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await waitForWaiterCount(1, in: gate)
        canceled.cancel()
        let canceledResult = await canceled.value
        XCTAssertTrue(canceledResult)
        XCTAssertFalse(canceledWaiterAcquired)
        XCTAssertEqual(gate.waitingCount, 0)

        let next = Task { @MainActor in
            try await gate.acquire()
            gate.release()
            return true
        }
        await waitForWaiterCount(1, in: gate)
        gate.release()
        let nextResult = try await next.value
        XCTAssertTrue(nextResult)
        XCTAssertFalse(canceledWaiterAcquired)
    }

    func testCancellationDuringOwnershipHandoffSkipsBodyAndReleasesNextWaiter() async throws {
        let gate = ManagedSafetyIncidentGate()
        try await gate.acquire()
        var canceledWaiterAcquired = false
        var nextWaiterAcquired = false

        let canceled = Task { @MainActor in
            do {
                try await gate.acquire()
                canceledWaiterAcquired = true
                gate.release()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await waitForWaiterCount(1, in: gate)

        let next = Task { @MainActor in
            try await gate.acquire()
            nextWaiterAcquired = true
            gate.release()
        }
        await waitForWaiterCount(2, in: gate)

        canceled.cancel()
        gate.release()

        let canceledResult = await canceled.value
        try await next.value
        XCTAssertTrue(canceledResult)
        XCTAssertFalse(canceledWaiterAcquired)
        XCTAssertTrue(nextWaiterAcquired)
        XCTAssertEqual(gate.waitingCount, 0)
    }

    private func waitForWaiterCount(
        _ expected: Int,
        in gate: ManagedSafetyIncidentGate
    ) async {
        for _ in 0..<1_000 {
            guard gate.waitingCount != expected else { return }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for \(expected) queued incident operation(s)."
        )
    }
}
