import GRDB
import XCTest
@testable import WhoopStore

final class ManagedSyncChunksTests: XCTestCase {
    private let source = "managed-fixture"
    private let other = "other-source"
    private let ts = 1_788_393_600

    private func populatedStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let source = source
        let other = other
        let ts = ts
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, ?, 68, 0)",
                arguments: [source, ts]
            )
            try db.execute(
                sql: """
                    INSERT INTO rrInterval
                        (deviceId, ts, rrMs, synced, seq, tsSuspect, ord, srcChannel)
                    VALUES (?, ?, 812, 0, 0, NULL, 1, 2)
                    """,
                arguments: [source, ts]
            )
            try db.execute(
                sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON, synced)
                    VALUES (?, ?, 'wear', '{"state":"worn"}', 0)
                    """,
                arguments: [source, ts]
            )
            try db.execute(
                sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, synced, charging)
                    VALUES (?, ?, 82.5, 4100, 0, 1)
                    """,
                arguments: [source, ts]
            )
            try db.execute(
                sql: """
                    INSERT INTO stepSample (deviceId, ts, counter, activityClass, synced)
                    VALUES (?, ?, 1234, 1, 0)
                    """,
                arguments: [source, ts]
            )
            try db.execute(
                sql: """
                    INSERT INTO ppgHrSample (deviceId, ts, bpm, conf, synced)
                    VALUES (?, ?, 67.5, 0.91, 0)
                    """,
                arguments: [source, ts]
            )
            try db.execute(
                sql: """
                    INSERT INTO bodyMeasurement
                        (deviceId, measuredAt, receivedAt, weightKg, bmi, heightCm, userId, unit, source)
                    VALUES (?, ?, ?, 72.5, 22.1, 181.0, -1, 'kg', 'bluetooth_wss')
                    """,
                arguments: [source, ts, ts]
            )
            try db.execute(
                sql: "INSERT INTO skinTempSample VALUES (?, ?, 440, 0)",
                arguments: [source, ts]
            )
            try db.execute(
                sql: "INSERT INTO respSample VALUES (?, ?, 230, 0)",
                arguments: [source, ts]
            )
            try db.execute(
                sql: "INSERT INTO sleepStateSample VALUES (?, ?, 2, 0)",
                arguments: [source, ts]
            )
            try db.execute(
                sql: "INSERT INTO spo2Sample VALUES (?, ?, 1001, 1002, 0)",
                arguments: [source, ts]
            )
            try db.execute(
                sql: "INSERT INTO ppgWaveformSample VALUES (?, ?, ?, 0)",
                arguments: [source, ts, Data([1, 0, 2, 0])]
            )
            try db.execute(
                sql: "INSERT INTO gravitySample VALUES (?, ?, 0.1, 0.2, 0.9, 0)",
                arguments: [source, ts]
            )
            try db.execute(
                sql: "INSERT INTO rawImuSample VALUES (?, ?, ?)",
                arguments: [source, ts, Data(repeating: 1, count: 24)]
            )
            try db.execute(
                sql: """
                    INSERT INTO dailyMetric
                        (deviceId, day, totalSleepMin, restingHr, avgHrv, recovery, strain)
                    VALUES (?, '2026-09-03', 460, 52, 64.5, 78, 9.2)
                    """,
                arguments: [source]
            )
            try db.execute(
                sql: """
                    INSERT INTO appleDaily (deviceId, day, steps, activeKcal)
                    VALUES (?, '2026-09-03', 8000, 420)
                    """,
                arguments: [source]
            )
            try db.execute(
                sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, '2026-09-03', 'hydration_ml', 1800)
                    """,
                arguments: [source]
            )
            try db.execute(
                sql: """
                    INSERT INTO sleepSession
                        (deviceId, startTs, endTs, userEdited)
                    VALUES (?, ?, ?, 0)
                    """,
                arguments: [source, ts, ts + 28_800]
            )
            try db.execute(
                sql: """
                    INSERT INTO workout (deviceId, startTs, endTs, sport, source)
                    VALUES (?, ?, ?, 'run', 'detected')
                    """,
                arguments: [source, ts, ts + 1_800]
            )
            try db.execute(
                sql: """
                    INSERT INTO liveSession (
                        deviceId, startTs, endTs, chargeAtStart, floorBpm, ceilingBpm,
                        inBandSec, belowSec, aboveSec, pushCount, easeCount, hrSource
                    ) VALUES (?, ?, ?, 75, 90, 150, 600, 30, 10, 2, 1, 'strap')
                    """,
                arguments: [source, ts, ts + 900]
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, ?, 190, 0)",
                arguments: [other, ts]
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, ?, 99, 0)",
                arguments: [source, ts + 21_600]
            )
        }
        return store
    }

    func testEveryDataClassExtractsOnlyTruthfulRegisteredStreams() async throws {
        let store = try await populatedStore()
        let start = Int64(ts) * 1_000
        let end = start + 21_600_000

        let essential = try await store.managedSyncStreams(
            localSourceID: source,
            dataClass: "essential_timeseries",
            startMs: start,
            endExclusiveMs: end
        )
        XCTAssertEqual(
            Set(essential.filter { !$0.rows.isEmpty }.map(\.streamKey)),
            Set([
                "heart_rate", "rr_intervals", "battery", "derived_heart_rate",
                "device_events", "step_counter", "body_measurement",
            ])
        )
        XCTAssertFalse(essential.map(\.streamKey).contains("spo2"))
        XCTAssertEqual(essential.first { $0.streamKey == "heart_rate" }?.rows.count, 1)

        let auxiliary = try await store.managedSyncStreams(
            localSourceID: source,
            dataClass: "raw_auxiliary",
            startMs: start,
            endExclusiveMs: end
        )
        XCTAssertEqual(
            Set(auxiliary.filter { !$0.rows.isEmpty }.map(\.streamKey)),
            Set(["skin_temperature_adc", "respiration_adc", "sleep_state"])
        )

        let ppg = try await store.managedSyncStreams(
            localSourceID: source,
            dataClass: "raw_ppg",
            startMs: start,
            endExclusiveMs: end
        )
        XCTAssertEqual(
            Set(ppg.filter { !$0.rows.isEmpty }.map(\.streamKey)),
            Set(["spo2_optical_adc", "ppg_waveform"])
        )

        let motion = try await store.managedSyncStreams(
            localSourceID: source,
            dataClass: "raw_motion",
            startMs: start,
            endExclusiveMs: end
        )
        XCTAssertEqual(
            Set(motion.filter { !$0.rows.isEmpty }.map(\.streamKey)),
            Set(["gravity", "raw_imu"])
        )
    }

    func testDerivedRowsAreDeterministicAndWindowBounded() async throws {
        let store = try await populatedStore()
        let start = Int64(ts) * 1_000
        let end = start + 7 * 86_400_000
        let first = try await store.managedSyncStreams(
            localSourceID: source,
            dataClass: "derived_summaries",
            startMs: start,
            endExclusiveMs: end
        )
        let second = try await store.managedSyncStreams(
            localSourceID: source,
            dataClass: "derived_summaries",
            startMs: start,
            endExclusiveMs: end
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            Set(first.filter { !$0.rows.isEmpty }.map(\.streamKey)),
            Set([
                "daily_metrics", "metric_series", "sleep_summary", "workout_summary",
                "live_session",
            ])
        )
        XCTAssertEqual(first.first { $0.streamKey == "daily_metrics" }?.rows.count, 2)
    }

    func testNextEventJumpsEmptyHistoryAndRejectsUnknownClass() async throws {
        let store = try await populatedStore()
        let event = try await store.managedSyncNextEventTime(
            localSourceID: source,
            dataClass: "raw_ppg",
            atOrAfterMs: 0,
            beforeMs: Int64(ts + 10) * 1_000
        )
        XCTAssertEqual(event, Int64(ts) * 1_000)
        do {
            _ = try await store.managedSyncNextEventTime(
                localSourceID: source,
                dataClass: "unknown",
                atOrAfterMs: 0,
                beforeMs: 1
            )
            XCTFail("unknown class should fail closed")
        } catch {
            XCTAssertEqual(error as? ManagedSyncChunkStoreError, .unsupportedDataClass)
        }
    }
}
