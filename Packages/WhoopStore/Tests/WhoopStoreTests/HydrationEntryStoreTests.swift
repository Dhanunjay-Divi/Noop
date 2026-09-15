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

    func testSharedMaximumAllowsExactlyTenThousandMillilitres() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-04"
        let entries = [
            HydrationLogEntry(
                id: UUID().uuidString,
                day: day,
                amountML: 6_000,
                loggedAt: 4_039_632_000
            ),
            HydrationLogEntry(
                id: UUID().uuidString,
                day: day,
                amountML: 4_000,
                loggedAt: 4_039_632_060
            ),
        ]

        let total = try await store.replaceHydrationLogEntries(
            entries,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(total, 10_000)
        let persistedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertEqual(persistedEntries, entries)
    }

    func testEntryAboveSharedMaximumIsRejectedBeforePersist() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-05"
        let invalid = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: 10_001,
            loggedAt: 4_039_718_400
        )

        do {
            _ = try await store.replaceHydrationLogEntries(
                [invalid],
                deviceId: "hydration",
                day: day,
                metricKey: "hydration"
            )
            XCTFail("Expected an over-limit hydration entry to be rejected")
        } catch HydrationEntryStoreError.invalidEntry {
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
        XCTAssertTrue(persistedEntries.isEmpty)
        XCTAssertTrue(persistedMetric.isEmpty)
    }

    func testAccumulatedDayAboveSharedMaximumIsRejectedBeforePersist() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-06"
        let entries = [
            HydrationLogEntry(
                id: UUID().uuidString,
                day: day,
                amountML: 6_000,
                loggedAt: 4_039_804_800
            ),
            HydrationLogEntry(
                id: UUID().uuidString,
                day: day,
                amountML: 4_001,
                loggedAt: 4_039_804_860
            ),
        ]

        do {
            _ = try await store.replaceHydrationLogEntries(
                entries,
                deviceId: "hydration",
                day: day,
                metricKey: "hydration"
            )
            XCTFail("Expected an over-limit hydration day to be rejected")
        } catch HydrationEntryStoreError.invalidEntry {
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
        XCTAssertTrue(persistedEntries.isEmpty)
        XCTAssertTrue(persistedMetric.isEmpty)
    }

    func testLegacyMigrationPersistsOversizedDayWithoutRelaxingCurrentWrites() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-07"
        let legacy = [
            HydrationLogEntry(
                id: UUID().uuidString,
                day: day,
                amountML: 6_000,
                loggedAt: 4_039_891_200
            ),
            HydrationLogEntry(
                id: UUID().uuidString,
                day: day,
                amountML: 6_000,
                loggedAt: 4_039_891_260
            ),
        ]

        let migratedTotal = try await store.migrateLegacyHydrationLogEntries(
            legacy,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(migratedTotal, 12_000)
        let migratedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertEqual(migratedEntries, legacy)
        do {
            _ = try await store.replaceHydrationLogEntries(
                legacy,
                deviceId: "hydration",
                day: day,
                metricKey: "hydration"
            )
            XCTFail("The normal write path must still reject an oversized day")
        } catch HydrationEntryStoreError.invalidEntry {
            // Expected.
        }
        let entriesAfterRejectedWrite = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertEqual(entriesAfterRejectedWrite, legacy)
        let persistedMetric = try await store.metricSeries(
            deviceId: "hydration",
            key: "hydration",
            from: day,
            to: day
        )
        XCTAssertEqual(persistedMetric.first?.value, 12_000)
    }

    func testLegacyCompatibilityAcceptsItsExactCeiling() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-09"
        let entry = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: WhoopStore.hydrationLegacyMaximumML,
            loggedAt: 4_040_064_000
        )

        let total = try await store.migrateLegacyHydrationLogEntries(
            [entry],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(total, Double(WhoopStore.hydrationLegacyMaximumML))
    }

    func testLegacyCompatibilityRejectsCorruptEntryAndAccumulatedTotals() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-10"
        let timestamp = 4_040_150_400
        let aboveCeiling = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: WhoopStore.hydrationLegacyMaximumML + 1,
            loggedAt: timestamp
        )
        let splitAboveCeiling = [
            HydrationLogEntry(
                id: UUID().uuidString,
                day: day,
                amountML: WhoopStore.hydrationLegacyMaximumML,
                loggedAt: timestamp
            ),
            HydrationLogEntry(
                id: UUID().uuidString,
                day: day,
                amountML: 1,
                loggedAt: timestamp + 60
            ),
        ]

        for entries in [[aboveCeiling], splitAboveCeiling] {
            do {
                _ = try await store.migrateLegacyHydrationLogEntries(
                    entries,
                    deviceId: "hydration",
                    day: day,
                    metricKey: "hydration"
                )
                XCTFail("Expected corrupt legacy hydration to be rejected")
            } catch HydrationEntryStoreError.invalidEntry {
                // Expected.
            }
        }

        let persistedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertTrue(persistedEntries.isEmpty)
    }

    func testPersistedTimestampBeyondCompatibilityWindowIsRejectedBeforeWrite() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-11"
        let invalid = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: 237,
            loggedAt: Int.max
        )

        do {
            _ = try await store.migrateLegacyHydrationLogEntries(
                [invalid],
                deviceId: "hydration",
                day: day,
                metricKey: "hydration"
            )
            XCTFail("Expected an implausible hydration timestamp to be rejected")
        } catch HydrationEntryStoreError.invalidEntry {
            // Expected.
        }

        let persistedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertTrue(persistedEntries.isEmpty)
    }

    func testOversizedLegacyDayAllowsOnlyProgressiveReductionUntilItIsClear() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2098-01-08"
        let first = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: 7_000,
            loggedAt: 4_039_977_600
        )
        let second = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: 7_000,
            loggedAt: 4_039_977_660
        )
        let third = HydrationLogEntry(
            id: UUID().uuidString,
            day: day,
            amountML: 7_000,
            loggedAt: 4_039_977_720
        )
        try await store.migrateLegacyHydrationLogEntries(
            [first, second, third],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        let reducedFirst = HydrationLogEntry(
            id: first.id,
            day: day,
            amountML: 6_000,
            loggedAt: first.loggedAt
        )
        let stillOversized = [reducedFirst, second, third]
        let firstReduction = try await store.replaceHydrationLogEntriesAllowingLegacyReduction(
            stillOversized,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        XCTAssertEqual(
            firstReduction,
            20_000
        )

        let increasedFirst = HydrationLogEntry(
            id: first.id,
            day: day,
            amountML: 6_001,
            loggedAt: first.loggedAt
        )
        do {
            _ = try await store.replaceHydrationLogEntriesAllowingLegacyReduction(
                [increasedFirst, second, third],
                deviceId: "hydration",
                day: day,
                metricKey: "hydration"
            )
            XCTFail("An oversized legacy correction must not increase an entry")
        } catch HydrationEntryStoreError.invalidEntry {
            // Expected.
        }
        let entriesAfterRejectedIncrease = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertEqual(entriesAfterRejectedIncrease, stillOversized)

        let secondReduction = try await store.replaceHydrationLogEntriesAllowingLegacyReduction(
            [reducedFirst, third],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        XCTAssertEqual(
            secondReduction,
            13_000
        )
        let normalized = try await store.replaceHydrationLogEntriesAllowingLegacyReduction(
            [reducedFirst],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        XCTAssertEqual(
            normalized,
            6_000
        )
        let cleared = try await store.replaceHydrationLogEntriesAllowingLegacyReduction(
            [],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        XCTAssertNil(cleared)
        let clearedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertTrue(clearedEntries.isEmpty)
        let persistedMetric = try await store.metricSeries(
            deviceId: "hydration",
            key: "hydration",
            from: day,
            to: day
        )
        XCTAssertEqual(persistedMetric.first?.value, 0)
    }
}
