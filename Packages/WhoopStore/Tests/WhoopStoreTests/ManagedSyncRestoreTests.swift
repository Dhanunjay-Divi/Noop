import GRDB
import XCTest
@testable import WhoopStore

final class ManagedSyncRestoreTests: XCTestCase {
    private let origin = "restore-origin"
    private let timestamp = 1_788_393_600
    private let sourceID = UUID(uuidString: "63b6a8c4-cc34-4af8-b23c-c649e04dd6bd")!

    func testAllDataClassesRoundTripWithoutTouchingLiveSource() async throws {
        let source = try await populatedStore()
        let destination = try await WhoopStore.inMemory()
        let startMs = Int64(timestamp) * 1_000
        let endExclusiveMs = startMs + 86_400_000
        let timestamp = timestamp

        try await destination.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES ('live-local', ?, 199, 0)",
                arguments: [timestamp]
            )
        }

        var chunks: [ManagedSyncRestoreChunk] = []
        for dataClass in [
            "essential_timeseries",
            "raw_auxiliary",
            "raw_ppg",
            "raw_motion",
            "derived_summaries",
        ] {
            let streams = try await source.managedSyncStreams(
                localSourceID: origin,
                dataClass: dataClass,
                startMs: startMs,
                endExclusiveMs: endExclusiveMs
            )
            let chunk = ManagedSyncRestoreChunk(
                chunkID: UUID(),
                sourceID: sourceID,
                dataClass: dataClass,
                schemaVersion: 1,
                eventStartMs: startMs,
                eventEndMs: endExclusiveMs - 1,
                streams: streams.filter { !$0.rows.isEmpty }
            )
            chunks.append(chunk)
            let result: ManagedSyncRestoreResult
            do {
                result = try await destination.applyManagedSyncChunk(chunk)
            } catch {
                XCTFail("Restore failed for \(dataClass): \(error)")
                for stream in chunk.streams {
                    let probe = try await WhoopStore.inMemory()
                    do {
                        _ = try await probe.applyManagedSyncChunk(
                            ManagedSyncRestoreChunk(
                                chunkID: chunk.chunkID,
                                sourceID: chunk.sourceID,
                                dataClass: chunk.dataClass,
                                schemaVersion: chunk.schemaVersion,
                                eventStartMs: chunk.eventStartMs,
                                eventEndMs: chunk.eventEndMs,
                                streams: [stream]
                            )
                        )
                    } catch {
                        XCTFail("Restore failed for stream \(stream.streamKey): \(error)")
                        XCTFail("Failing stream rows: \(stream.rows)")
                        for (index, row) in stream.rows.enumerated() {
                            let rowProbe = try await WhoopStore.inMemory()
                            do {
                                _ = try await rowProbe.applyManagedSyncChunk(
                                    ManagedSyncRestoreChunk(
                                        chunkID: chunk.chunkID,
                                        sourceID: chunk.sourceID,
                                        dataClass: chunk.dataClass,
                                        schemaVersion: chunk.schemaVersion,
                                        eventStartMs: chunk.eventStartMs,
                                        eventEndMs: chunk.eventEndMs,
                                        streams: [
                                            ManagedSyncTabularStream(
                                                streamKey: stream.streamKey,
                                                columns: stream.columns,
                                                rows: [row],
                                                schemaRevision: stream.schemaRevision
                                            ),
                                        ]
                                    )
                                )
                            } catch {
                                XCTFail(
                                    "Restore failed for \(stream.streamKey) row \(index): "
                                        + "\(row), error: \(error)"
                                )
                            }
                        }
                    }
                }
                throw error
            }
            XCTAssertEqual(
                result.localSourceID,
                "noop-plus-\(sourceID.uuidString.lowercased())"
            )
            XCTAssertGreaterThan(result.appliedRows, 0)
        }

        let restoredSource = "noop-plus-\(sourceID.uuidString.lowercased())"
        let canonicalSourceID = sourceID.uuidString.lowercased()
        for dataClass in [
            "essential_timeseries",
            "raw_auxiliary",
            "raw_ppg",
            "raw_motion",
            "derived_summaries",
        ] {
            let original = try await source.managedSyncStreams(
                localSourceID: origin,
                dataClass: dataClass,
                startMs: startMs,
                endExclusiveMs: endExclusiveMs
            )
            let restored = try await destination.managedSyncStreams(
                localSourceID: restoredSource,
                dataClass: dataClass,
                startMs: startMs,
                endExclusiveMs: endExclusiveMs
            )
            XCTAssertEqual(normalized(original), normalized(restored))
        }

        for chunk in chunks {
            _ = try await destination.applyManagedSyncChunk(chunk)
        }
        let values = try await destination.registryWriter.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT bpm FROM hrSample WHERE deviceId = 'live-local' AND ts = ?",
                    arguments: [timestamp]
                ),
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM hrSample WHERE deviceId = ?",
                    arguments: [restoredSource]
                ),
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM managedSyncSource WHERE sourceId = ?",
                    arguments: [canonicalSourceID]
                )
            )
        }
        XCTAssertEqual(values.0, 199)
        XCTAssertEqual(values.1, 1)
        XCTAssertEqual(values.2, 1)
    }

    func testInvalidLaterStreamRollsBackRowsAndSourceRegistration() async throws {
        let store = try await WhoopStore.inMemory()
        let eventMs = Int64(timestamp) * 1_000
        let chunk = ManagedSyncRestoreChunk(
            chunkID: UUID(),
            sourceID: sourceID,
            dataClass: "essential_timeseries",
            schemaVersion: 1,
            eventStartMs: eventMs,
            eventEndMs: eventMs,
            streams: [
                ManagedSyncTabularStream(
                    streamKey: "battery",
                    columns: ["event_at_ms", "percent", "millivolts", "charging"],
                    rows: [[
                        .integer(eventMs), .number(82.5), .integer(4_100),
                        .boolean(true),
                    ]]
                ),
                ManagedSyncTabularStream(
                    streamKey: "heart_rate",
                    columns: ["event_at_ms", "bpm", "quality", "provenance"],
                    rows: [[
                        .integer(eventMs), .integer(999), .null, .string("sensor"),
                    ]]
                ),
            ]
        )

        do {
            _ = try await store.applyManagedSyncChunk(chunk)
            XCTFail("Expected invalid heart-rate value")
        } catch {
            XCTAssertEqual(error as? ManagedSyncRestoreError, .invalidValue)
        }

        let counts = try await store.registryWriter.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedSyncSource"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM device WHERE id LIKE 'noop-plus-%'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery")
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }

    func testRejectsMalformedPackedWaveform() async throws {
        let store = try await WhoopStore.inMemory()
        let eventMs = Int64(timestamp) * 1_000
        let chunk = ManagedSyncRestoreChunk(
            chunkID: UUID(),
            sourceID: sourceID,
            dataClass: "raw_ppg",
            schemaVersion: 1,
            eventStartMs: eventMs,
            eventEndMs: eventMs,
            streams: [
                ManagedSyncTabularStream(
                    streamKey: "ppg_waveform",
                    columns: [
                        "event_at_ms", "sample_rate_hz", "sample_count",
                        "samples_base64",
                    ],
                    rows: [[
                        .integer(eventMs), .number(100), .integer(2),
                        .string(Data([1, 2, 3]).base64EncodedString()),
                    ]]
                ),
            ]
        )

        do {
            _ = try await store.applyManagedSyncChunk(chunk)
            XCTFail("Expected packed waveform length rejection")
        } catch {
            XCTAssertEqual(error as? ManagedSyncRestoreError, .invalidValue)
        }
    }

    func testLaterCloudRevisionUpdatesNaturalKey() async throws {
        let store = try await WhoopStore.inMemory()
        let eventMs = Int64(timestamp) * 1_000

        func chunk(bpm: Int64) -> ManagedSyncRestoreChunk {
            ManagedSyncRestoreChunk(
                chunkID: UUID(),
                sourceID: sourceID,
                dataClass: "essential_timeseries",
                schemaVersion: 1,
                eventStartMs: eventMs,
                eventEndMs: eventMs,
                streams: [
                    ManagedSyncTabularStream(
                        streamKey: "heart_rate",
                        columns: ["event_at_ms", "bpm", "quality", "provenance"],
                        rows: [[
                            .integer(eventMs), .integer(bpm), .null, .string("sensor"),
                        ]]
                    ),
                ]
            )
        }

        _ = try await store.applyManagedSyncChunk(chunk(bpm: 68))
        _ = try await store.applyManagedSyncChunk(chunk(bpm: 72))

        let restoredSource = "noop-plus-\(sourceID.uuidString.lowercased())"
        let timestamp = timestamp
        let bpm = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT bpm FROM hrSample WHERE deviceId = ? AND ts = ?",
                arguments: [restoredSource, timestamp]
            )
        }
        XCTAssertEqual(bpm, 72)
    }

    func testFullEmptySnapshotDeletesLastRowInWindow() async throws {
        let store = try await WhoopStore.inMemory()
        let eventMs = Int64(timestamp) * 1_000

        func snapshot(bpm: Int64?) -> ManagedSyncRestoreChunk {
            ManagedSyncRestoreChunk(
                chunkID: UUID(),
                sourceID: sourceID,
                dataClass: "essential_timeseries",
                schemaVersion: 1,
                eventStartMs: eventMs,
                eventEndMs: eventMs + 3_599_999,
                streams: [
                    ManagedSyncTabularStream(
                        streamKey: "heart_rate",
                        columns: ["event_at_ms", "bpm", "quality", "provenance"],
                        rows: bpm.map {
                            [[.integer(eventMs), .integer($0), .null, .string("sensor")]]
                        } ?? []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "rr_intervals",
                        columns: [
                            "event_at_ms", "rr_ms", "seq", "ord", "source_channel",
                            "timestamp_suspect",
                        ],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "battery",
                        columns: ["event_at_ms", "percent", "millivolts", "charging"],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "derived_heart_rate",
                        columns: [
                            "event_at_ms", "bpm", "confidence", "algorithm_revision",
                        ],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "device_events",
                        columns: ["event_at_ms", "kind", "payload_json"],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "step_counter",
                        columns: ["event_at_ms", "counter", "activity_class"],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "body_measurement",
                        columns: [
                            "event_at_ms", "weight_kg", "bmi", "height_cm", "user_id",
                            "source",
                        ],
                        rows: []
                    ),
                ]
            )
        }

        _ = try await store.applyManagedSyncChunk(snapshot(bpm: 68))
        _ = try await store.applyManagedSyncChunk(snapshot(bpm: nil))

        let restoredSource = "noop-plus-\(sourceID.uuidString.lowercased())"
        let count = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM hrSample WHERE deviceId = ?",
                arguments: [restoredSource]
            )
        }
        XCTAssertEqual(count, 0)
    }

    func testEchoedChunkDoesNotOverwriteAuthoritativeLocalSource() async throws {
        let store = try await WhoopStore.inMemory()
        let nowMs = Int64(timestamp) * 1_000
        let canonicalSourceID = sourceID.uuidString.lowercased()
        let origin = origin
        let timestamp = timestamp
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, ?, 68, 0)",
                arguments: [origin, timestamp]
            )
        }
        try await store.upsertManagedSyncSource(
            ManagedSyncSourceState(
                sourceID: canonicalSourceID,
                localSourceID: origin,
                sourceKind: "live_ble",
                platform: "ios",
                logicalSourceHash: String(repeating: "a", count: 64),
                createdAtMs: nowMs,
                updatedAtMs: nowMs
            )
        )
        let result = try await store.applyManagedSyncChunk(
            ManagedSyncRestoreChunk(
                chunkID: UUID(),
                sourceID: sourceID,
                dataClass: "essential_timeseries",
                schemaVersion: 1,
                eventStartMs: nowMs,
                eventEndMs: nowMs,
                streams: [
                    ManagedSyncTabularStream(
                        streamKey: "heart_rate",
                        columns: ["event_at_ms", "bpm", "quality", "provenance"],
                        rows: [[
                            .integer(nowMs), .integer(99), .null, .string("sensor"),
                        ]]
                    ),
                ]
            )
        )

        let bpm = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT bpm FROM hrSample WHERE deviceId = ? AND ts = ?",
                arguments: [origin, timestamp]
            )
        }
        XCTAssertEqual(result.localSourceID, origin)
        XCTAssertEqual(result.appliedRows, 0)
        XCTAssertEqual(bpm, 68)
    }

    func testHydrationRestoresCloudBaseAndOverlaysLateLocalRows() async throws {
        let store = try await WhoopStore.inMemory()
        let localOrigin = origin
        let localTimestamp = timestamp
        let startMs = Int64(timestamp) * 1_000
        let endMs = startMs + 6 * 60 * 60 * 1_000 - 1
        let canonicalSourceID = sourceID.uuidString.lowercased()
        try await store.upsertManagedSyncSource(
            ManagedSyncSourceState(
                sourceID: canonicalSourceID,
                localSourceID: localOrigin,
                sourceKind: "live_ble",
                platform: "ios",
                logicalSourceHash: String(repeating: "a", count: 64),
                createdAtMs: startMs,
                updatedAtMs: startMs
            )
        )
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm, synced)
                    VALUES (?, ?, 72, 0)
                    """,
                arguments: [localOrigin, localTimestamp + 1]
            )
            try db.execute(
                sql: """
                    INSERT INTO bodyMeasurement (
                        deviceId, measuredAt, receivedAt, weightKg, bmi, heightCm,
                        userId, unit, source
                    ) VALUES (?, ?, ?, 80, 24, 181, -1, 'kg', 'manual')
                    """,
                arguments: [localOrigin, localTimestamp, localTimestamp]
            )
        }
        let dirtyBefore = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedDirtyWindow") ?? 0
        }
        let result = try await store.hydrateManagedSyncChunk(
            ManagedSyncRestoreChunk(
                chunkID: UUID(),
                sourceID: sourceID,
                dataClass: "essential_timeseries",
                schemaVersion: 1,
                eventStartMs: startMs,
                eventEndMs: endMs,
                streams: [
                    ManagedSyncTabularStream(
                        streamKey: "heart_rate",
                        columns: ["event_at_ms", "bpm", "quality", "provenance"],
                        rows: [[
                            .integer(startMs), .integer(68), .null, .string("sensor"),
                        ]]
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "rr_intervals",
                        columns: [
                            "event_at_ms", "rr_ms", "seq", "ord", "source_channel",
                            "timestamp_suspect",
                        ],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "battery",
                        columns: ["event_at_ms", "percent", "millivolts", "charging"],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "derived_heart_rate",
                        columns: [
                            "event_at_ms", "bpm", "confidence", "algorithm_revision",
                        ],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "device_events",
                        columns: ["event_at_ms", "kind", "payload_json"],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "step_counter",
                        columns: ["event_at_ms", "counter", "activity_class"],
                        rows: []
                    ),
                    ManagedSyncTabularStream(
                        streamKey: "body_measurement",
                        columns: [
                            "event_at_ms", "weight_kg", "bmi", "height_cm", "user_id",
                            "source",
                        ],
                        rows: [[
                            .integer(startMs), .number(70), .number(21),
                            .number(181), .integer(-1), .string("cloud"),
                        ]]
                    ),
                ]
            ),
            localSourceID: localOrigin
        )

        let values = try await store.registryWriter.read { db in
            (
                try Int.fetchAll(
                    db,
                    sql: """
                        SELECT bpm FROM hrSample
                        WHERE deviceId = ? ORDER BY ts
                        """,
                    arguments: [localOrigin]
                ),
                try Double.fetchOne(
                    db,
                    sql: """
                        SELECT weightKg FROM bodyMeasurement
                        WHERE deviceId = ? AND measuredAt = ?
                        """,
                    arguments: [localOrigin, localTimestamp]
                ),
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM managedDirtyWindow"
                ) ?? 0,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM managedPruneGuard"
                ) ?? 0
            )
        }
        XCTAssertEqual(result.localSourceID, localOrigin)
        XCTAssertEqual(values.0, [68, 72])
        XCTAssertEqual(values.1, 80)
        XCTAssertEqual(values.2, dirtyBefore)
        XCTAssertEqual(values.3, 0)
    }

    private func populatedStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let origin = origin
        let timestamp = timestamp
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, ?, 68, 0)",
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO rrInterval
                        (deviceId, ts, rrMs, synced, seq, tsSuspect, ord, srcChannel)
                    VALUES (?, ?, 812, 0, 0, 0, 1, 2)
                    """,
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON, synced)
                    VALUES (?, ?, 'wear', '{"state":"worn"}', 0)
                    """,
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, synced, charging)
                    VALUES (?, ?, 82.5, 4100, 0, 1)
                    """,
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO stepSample (deviceId, ts, counter, activityClass, synced)
                    VALUES (?, ?, 1234, 1, 0)
                    """,
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO ppgHrSample (deviceId, ts, bpm, conf, synced)
                    VALUES (?, ?, 67.5, 0.91, 0)
                    """,
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO bodyMeasurement (
                        deviceId, measuredAt, receivedAt, weightKg, bmi, heightCm,
                        userId, unit, source
                    ) VALUES (?, ?, ?, 72.5, 22.1, 181, -1, 'kg', 'bluetooth_wss')
                    """,
                arguments: [origin, timestamp, timestamp]
            )
            try db.execute(
                sql: "INSERT INTO skinTempSample VALUES (?, ?, 440, 0)",
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: "INSERT INTO respSample VALUES (?, ?, 230, 0)",
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: "INSERT INTO sleepStateSample VALUES (?, ?, 2, 0)",
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: "INSERT INTO spo2Sample VALUES (?, ?, 1001, 1002, 0)",
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: "INSERT INTO ppgWaveformSample VALUES (?, ?, ?, 0)",
                arguments: [origin, timestamp, Data([1, 0, 2, 0])]
            )
            try db.execute(
                sql: "INSERT INTO gravitySample VALUES (?, ?, 0.1, 0.2, 0.9, 0)",
                arguments: [origin, timestamp]
            )
            try db.execute(
                sql: "INSERT INTO rawImuSample VALUES (?, ?, ?)",
                arguments: [origin, timestamp, Data(repeating: 1, count: 24)]
            )
            try db.execute(
                sql: """
                    INSERT INTO dailyMetric (
                        deviceId, day, totalSleepMin, efficiency, deepMin, remMin,
                        lightMin, disturbances, restingHr, avgHrv, recovery, strain,
                        exerciseCount, spo2Pct, skinTempDevC, respRateBpm, steps,
                        activeKcalEst, spo2Red, spo2Ir, hrvMethod
                    ) VALUES (
                        ?, '2026-09-03', 460, 0.92, 80, 95, 285, 2, 52, 64.5,
                        78, 9.2, 1, 97.5, 0.2, 14.8, 8000, 420, 1001, 1002,
                        'rmssd'
                    )
                    """,
                arguments: [origin]
            )
            try db.execute(
                sql: """
                    INSERT INTO appleDaily (
                        deviceId, day, steps, activeKcal, basalKcal, vo2max,
                        avgHr, maxHr, walkingHr, weightKg
                    ) VALUES (?, '2026-09-03', 8000, 420, 1750, 47.2, 72, 171, 88, 72.5)
                    """,
                arguments: [origin]
            )
            try db.execute(
                sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, '2026-09-03', 'hydration_ml', 1800)
                    """,
                arguments: [origin]
            )
            try db.execute(
                sql: """
                    INSERT INTO sleepSession (
                        deviceId, startTs, endTs, efficiency, restingHr, avgHrv,
                        stagesJSON, userEdited, startTsAdjusted, motionJSON,
                        sleepStateJSON, gravitySparse, rrEligibleWindowCount,
                        rrValidWindowCount
                    ) VALUES (
                        ?, ?, ?, 0.92, 52, 64.5, '{"deep":80}', 1, ?,
                        '{"motion":[]}', '{"states":[]}', 0, 20, 18
                    )
                    """,
                arguments: [origin, timestamp, timestamp + 28_800, timestamp + 60]
            )
            try db.execute(
                sql: """
                    INSERT INTO workout (
                        deviceId, startTs, endTs, sport, source, durationS,
                        energyKcal, avgHr, maxHr, strain, distanceM, zonesJSON,
                        notes, steps
                    ) VALUES (
                        ?, ?, ?, 'run', 'detected', 1800, 320, 145, 171, 10.2,
                        5000, '{"z3":900}', 'steady', 4200
                    )
                    """,
                arguments: [origin, timestamp, timestamp + 1_800]
            )
            try db.execute(
                sql: """
                    INSERT INTO liveSession (
                        deviceId, startTs, endTs, chargeAtStart, floorBpm, ceilingBpm,
                        inBandSec, belowSec, aboveSec, pushCount, easeCount, hrSource
                    ) VALUES (?, ?, ?, 75, 90, 150, 600, 30, 10, 2, 1, 'strap')
                    """,
                arguments: [origin, timestamp, timestamp + 900]
            )
        }
        return store
    }

    private func normalized(
        _ streams: [ManagedSyncTabularStream]
    ) -> [ManagedSyncTabularStream] {
        streams.map { stream in
            let sourceIndex = stream.columns.firstIndex(of: "source_id")
            let recordIndex = stream.columns.firstIndex(of: "record_id")
            return ManagedSyncTabularStream(
                streamKey: stream.streamKey,
                columns: stream.columns,
                rows: stream.rows.map { row in
                    var row = row
                    if let sourceIndex {
                        row[sourceIndex] = .string("<source>")
                    }
                    if let recordIndex {
                        row[recordIndex] = .string("<record>")
                    }
                    return row
                },
                schemaRevision: stream.schemaRevision
            )
        }
    }
}
