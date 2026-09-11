import XCTest
@testable import WhoopStore

final class HydrationEntryStoreTests: XCTestCase {
    func testEntryReplacementAndMetricProjectionCommitTogether() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-01"
        let first = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: 237,
            loggedAt: 4_039_372_800
        )

        let total = try await store.replaceHydrationLogEntries(
            [first],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(total, 237)
        let persistedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let persistedMetric = try await store.metricSeries(
            deviceId: "hydration",
            key: "hydration",
            from: day,
            to: day
        )
        XCTAssertEqual(persistedEntries, [first])
        XCTAssertEqual(persistedMetric.first?.value, 237)
    }

    func testFailureAfterProjectionWriteRollsBackProjectionAndEntries() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-02"
        let original = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: 237,
            loggedAt: 4_039_459_200
        )
        try await store.replaceHydrationLogEntries(
            [original],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let replacement = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: 500,
            loggedAt: 4_039_459_260
        )

        do {
            try await store.replaceHydrationLogEntries(
                [replacement],
                deviceId: "hydration",
                day: day,
                metricKey: "hydration",
                failAfterMetricWriteForTesting: true
            )
            XCTFail("Expected the injected transaction failure")
        } catch HydrationEntryStoreError.injectedFailure {
            // Expected.
        }

        let persistedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let persistedMetric = try await store.metricSeries(
            deviceId: "hydration",
            key: "hydration",
            from: day,
            to: day
        )
        XCTAssertEqual(persistedEntries, [original])
        XCTAssertEqual(persistedMetric.first?.value, 237)
    }

    func testClearedDayKeepsZeroProjectionAndNoEditableRows() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-03"

        let total = try await store.replaceHydrationLogEntries(
            [],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertNil(total)
        let persistedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let persistedMetric = try await store.metricSeries(
            deviceId: "hydration",
            key: "hydration",
            from: day,
            to: day
        )
        XCTAssertTrue(persistedEntries.isEmpty)
        XCTAssertEqual(persistedMetric.first?.value, 0)
    }
}
