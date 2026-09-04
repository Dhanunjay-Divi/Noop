import CryptoKit
import CoreFoundation
import Foundation
import GRDB

public struct ManagedSyncRestoreChunk: Equatable, Sendable {
    public let chunkID: UUID
    public let sourceID: UUID
    public let dataClass: String
    public let schemaVersion: Int
    public let eventStartMs: Int64
    public let eventEndMs: Int64
    public let streams: [ManagedSyncTabularStream]

    public init(
        chunkID: UUID,
        sourceID: UUID,
        dataClass: String,
        schemaVersion: Int,
        eventStartMs: Int64,
        eventEndMs: Int64,
        streams: [ManagedSyncTabularStream]
    ) {
        self.chunkID = chunkID
        self.sourceID = sourceID
        self.dataClass = dataClass
        self.schemaVersion = schemaVersion
        self.eventStartMs = eventStartMs
        self.eventEndMs = eventEndMs
        self.streams = streams
    }
}

public struct ManagedSyncRestoreResult: Equatable, Sendable {
    public let localSourceID: String
    public let appliedRows: Int

    public init(localSourceID: String, appliedRows: Int) {
        self.localSourceID = localSourceID
        self.appliedRows = appliedRows
    }
}

public enum ManagedSyncRestoreError: Error, Equatable {
    case unsupportedSchema
    case invalidEnvelope
    case invalidStream
    case invalidRow
    case invalidValue
}

extension WhoopStore {
    private static let managedRestoreMaximumRowsPerChunk = 250_000

    /// Apply one server-validated immutable chunk to the local natural-key tables. The client repeats
    /// every structural and value check because cloud storage is an untrusted restore boundary.
    public func applyManagedSyncChunk(
        _ chunk: ManagedSyncRestoreChunk
    ) async throws -> ManagedSyncRestoreResult {
        guard chunk.schemaVersion == 1,
              chunk.eventStartMs >= 0,
              chunk.eventEndMs >= chunk.eventStartMs,
              !chunk.streams.isEmpty else {
            throw ManagedSyncRestoreError.invalidEnvelope
        }
        let allowed = try Self.managedRestoreStreamKeys(dataClass: chunk.dataClass)
        let keys = chunk.streams.map(\.streamKey)
        guard Set(keys).count == keys.count,
              Set(keys).isSubset(of: allowed),
              chunk.streams.allSatisfy({ $0.schemaRevision == 1 }),
              chunk.streams.reduce(0, { $0 + $1.rows.count })
                <= Self.managedRestoreMaximumRowsPerChunk else {
            throw ManagedSyncRestoreError.invalidStream
        }

        return try syncWrite { db in
            let source = try Self.managedRestoreSource(
                db: db,
                sourceID: chunk.sourceID,
                streams: chunk.streams
            )
            guard source.shouldApply else {
                return ManagedSyncRestoreResult(
                    localSourceID: source.localSourceID,
                    appliedRows: 0
                )
            }
            let validated = try chunk.streams
                .sorted(by: { $0.streamKey < $1.streamKey })
                .map { stream in
                    (stream, try Self.managedRestoreRows(stream, chunk: chunk))
                }
            var applied = 0
            if Set(keys) == allowed {
                applied += try Self.clearManagedRestoreSnapshot(
                    chunk: chunk,
                    localSourceID: source.localSourceID,
                    db: db
                )
            }
            for (stream, rows) in validated {
                applied += try Self.applyManagedRestoreRows(
                    rows,
                    streamKey: stream.streamKey,
                    localSourceID: source.localSourceID,
                    db: db
                )
            }
            return ManagedSyncRestoreResult(
                localSourceID: source.localSourceID,
                appliedRows: applied
            )
        }
    }

    /// Reconstruct a locally pruned sensor window before merging a late strap backfill. Existing local
    /// rows are copied inside the same write transaction and overlaid after the validated cloud base,
    /// so a row that arrived immediately before hydration wins on its natural key.
    public func hydrateManagedSyncChunk(
        _ chunk: ManagedSyncRestoreChunk,
        localSourceID: String
    ) async throws -> ManagedSyncRestoreResult {
        guard chunk.schemaVersion == 1,
              chunk.eventStartMs >= 0,
              chunk.eventEndMs >= chunk.eventStartMs,
              !localSourceID.isEmpty,
              chunk.dataClass != "derived_summaries" else {
            throw ManagedSyncRestoreError.invalidEnvelope
        }
        let allowed = try Self.managedRestoreStreamKeys(dataClass: chunk.dataClass)
        let keys = chunk.streams.map(\.streamKey)
        guard Set(keys) == allowed,
              Set(keys).count == keys.count,
              chunk.streams.allSatisfy({ $0.schemaRevision == 1 }),
              chunk.streams.reduce(0, { $0 + $1.rows.count })
                <= Self.managedRestoreMaximumRowsPerChunk else {
            throw ManagedSyncRestoreError.invalidStream
        }
        let validated = try chunk.streams
            .sorted(by: { $0.streamKey < $1.streamKey })
            .map { stream in
                (stream, try Self.managedRestoreRows(stream, chunk: chunk))
            }
        let prunableKeys = try Self.managedPrunableStreamKeys(
            dataClass: chunk.dataClass
        )

        return try syncWrite { db in
            let canonicalSourceID = chunk.sourceID.uuidString.lowercased()
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM managedSyncSource
                        WHERE sourceId = ? AND localSourceId = ?
                          AND sourceKind != 'managed_restore'
                    )
                    """,
                arguments: [canonicalSourceID, localSourceID]
            ) == true else {
                throw ManagedSyncRestoreError.invalidEnvelope
            }

            let tables = try Self.managedPrunableTables(dataClass: chunk.dataClass)
            let fromSeconds = (chunk.eventStartMs + 999) / 1_000
            let throughSeconds = chunk.eventEndMs / 1_000
            try db.execute(
                sql: "INSERT OR IGNORE INTO managedPruneGuard (guardId) VALUES (1)"
            )
            for table in tables {
                let backup = "managedHydrate_\(table)"
                try db.execute(sql: "DROP TABLE IF EXISTS temp.\(backup)")
                try db.execute(
                    sql: """
                        CREATE TEMP TABLE \(backup) AS
                        SELECT * FROM \(table)
                        WHERE deviceId = ? AND ts >= ? AND ts <= ?
                        """,
                    arguments: [localSourceID, fromSeconds, throughSeconds]
                )
                try db.execute(
                    sql: """
                        DELETE FROM \(table)
                        WHERE deviceId = ? AND ts >= ? AND ts <= ?
                        """,
                    arguments: [localSourceID, fromSeconds, throughSeconds]
                )
            }

            var applied = 0
            for (stream, rows) in validated where prunableKeys.contains(stream.streamKey) {
                applied += try Self.applyManagedRestoreRows(
                    rows,
                    streamKey: stream.streamKey,
                    localSourceID: localSourceID,
                    db: db,
                    enforceRawIMURetention: false
                )
            }
            for table in tables {
                let backup = "managedHydrate_\(table)"
                try db.execute(
                    sql: "INSERT OR REPLACE INTO \(table) SELECT * FROM temp.\(backup)"
                )
                applied += db.changesCount
                try db.execute(sql: "DROP TABLE temp.\(backup)")
            }
            try db.execute(sql: "DELETE FROM managedPruneGuard WHERE guardId = 1")
            return ManagedSyncRestoreResult(
                localSourceID: localSourceID,
                appliedRows: applied
            )
        }
    }

    private static func managedRestoreStreamKeys(dataClass: String) throws -> Set<String> {
        switch dataClass {
        case "essential_timeseries":
            return [
                "heart_rate", "rr_intervals", "battery", "derived_heart_rate",
                "device_events", "step_counter", "body_measurement",
            ]
        case "raw_auxiliary":
            return ["skin_temperature_adc", "respiration_adc", "sleep_state"]
        case "raw_ppg":
            return ["spo2_optical_adc", "ppg_waveform"]
        case "raw_motion":
            return ["gravity", "raw_imu"]
        case "derived_summaries":
            return [
                "daily_metrics", "metric_series", "sleep_summary", "workout_summary",
                "live_session",
            ]
        default:
            throw ManagedSyncRestoreError.unsupportedSchema
        }
    }

    private static func managedPrunableStreamKeys(
        dataClass: String
    ) throws -> Set<String> {
        let keys = try managedRestoreStreamKeys(dataClass: dataClass)
        return dataClass == "essential_timeseries"
            ? keys.subtracting(["body_measurement"])
            : keys
    }

    private static func managedPrunableTables(dataClass: String) throws -> [String] {
        switch dataClass {
        case "essential_timeseries":
            return [
                "hrSample", "rrInterval", "battery", "ppgHrSample", "event",
                "stepSample",
            ]
        case "raw_auxiliary":
            return ["skinTempSample", "respSample", "sleepStateSample"]
        case "raw_ppg":
            return ["spo2Sample", "ppgWaveformSample"]
        case "raw_motion":
            return ["gravitySample", "rawImuSample"]
        default:
            throw ManagedSyncRestoreError.unsupportedSchema
        }
    }

    private static func managedRestoreColumns(streamKey: String) throws -> [String] {
        switch streamKey {
        case "heart_rate":
            return ["event_at_ms", "bpm", "quality", "provenance"]
        case "rr_intervals":
            return [
                "event_at_ms", "rr_ms", "seq", "ord", "source_channel",
                "timestamp_suspect",
            ]
        case "battery":
            return ["event_at_ms", "percent", "millivolts", "charging"]
        case "derived_heart_rate":
            return ["event_at_ms", "bpm", "confidence", "algorithm_revision"]
        case "device_events":
            return ["event_at_ms", "kind", "payload_json"]
        case "step_counter":
            return ["event_at_ms", "counter", "activity_class"]
        case "body_measurement":
            return [
                "event_at_ms", "weight_kg", "bmi", "height_cm", "user_id", "source",
            ]
        case "skin_temperature_adc", "respiration_adc":
            return ["event_at_ms", "adc"]
        case "sleep_state":
            return ["event_at_ms", "state_code"]
        case "spo2_optical_adc":
            return ["event_at_ms", "red_adc", "infrared_adc"]
        case "ppg_waveform":
            return [
                "event_at_ms", "sample_rate_hz", "sample_count", "samples_base64",
            ]
        case "gravity":
            return ["event_at_ms", "x_g", "y_g", "z_g"]
        case "raw_imu":
            return [
                "event_at_ms", "sample_rate_hz", "sample_count", "axis_order",
                "samples_base64",
            ]
        case "daily_metrics":
            return [
                "event_at_ms", "day", "source_id", "payload_json", "updated_at_ms",
                "deleted",
            ]
        case "metric_series":
            return [
                "event_at_ms", "day", "metric_key", "value", "source_id",
                "updated_at_ms", "deleted",
            ]
        case "sleep_summary", "workout_summary", "live_session":
            return [
                "event_at_ms", "record_id", "end_at_ms", "payload_json",
                "updated_at_ms", "deleted",
            ]
        default:
            throw ManagedSyncRestoreError.unsupportedSchema
        }
    }

    private static func managedRestoreRows(
        _ stream: ManagedSyncTabularStream,
        chunk: ManagedSyncRestoreChunk
    ) throws -> [ManagedRestoreRow] {
        let expectedColumns = try managedRestoreColumns(streamKey: stream.streamKey)
        guard stream.columns == expectedColumns else {
            throw ManagedSyncRestoreError.invalidStream
        }
        return try stream.rows.map { values in
            guard values.count == expectedColumns.count else {
                throw ManagedSyncRestoreError.invalidRow
            }
            let row = ManagedRestoreRow(columns: expectedColumns, values: values)
            let timestamp = try row.requiredInteger("event_at_ms")
            guard timestamp >= chunk.eventStartMs,
                  timestamp <= chunk.eventEndMs,
                  timestamp % 1_000 == 0 else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return row
        }
    }

    private static func managedRestoreSource(
        db: Database,
        sourceID: UUID,
        streams: [ManagedSyncTabularStream]
    ) throws -> (localSourceID: String, shouldApply: Bool) {
        let canonicalSourceID = sourceID.uuidString.lowercased()
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT localSourceId, sourceKind
                FROM managedSyncSource WHERE sourceId = ?
                """,
            arguments: [canonicalSourceID]
        ) {
            let local: String = row["localSourceId"]
            let sourceKind: String = row["sourceKind"]
            guard sourceKind == "managed_restore" else {
                return (local, false)
            }
            try updateManagedRestoreCapabilities(
                db: db,
                localSourceID: local,
                streams: streams
            )
            return (local, true)
        }

        let localSourceID = "noop-plus-\(canonicalSourceID)"
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let logicalHash = SHA256.hash(data: Data(canonicalSourceID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try db.execute(
            sql: """
                INSERT INTO managedSyncSource (
                    sourceId, localSourceId, sourceKind, platform, logicalSourceHash,
                    createdAtMs, updatedAtMs
                ) VALUES (?, ?, 'managed_restore', 'cloud', ?, ?, ?)
                """,
            arguments: [canonicalSourceID, localSourceID, logicalHash, now, now]
        )
        let nowSeconds = now / 1_000
        try db.execute(
            sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, NULL, 'NOOP+ synced source', ?, ?)
                ON CONFLICT(id) DO UPDATE SET lastSeen = excluded.lastSeen
                """,
            arguments: [localSourceID, nowSeconds, nowSeconds]
        )
        let capabilities = managedRestoreCapabilities(streams: streams)
            .sorted()
            .joined(separator: ",")
        try db.execute(
            sql: """
                INSERT INTO pairedDevice (
                    id, brand, model, nickname, sourceKind, capabilities, status,
                    addedAt, lastSeenAt, peripheralId
                ) VALUES (?, 'NOOP', 'NOOP+ synced source', NULL, 'cloudImport', ?,
                          'paired', ?, ?, NULL)
                ON CONFLICT(id) DO NOTHING
                """,
            arguments: [localSourceID, capabilities, nowSeconds, nowSeconds]
        )
        return (localSourceID, true)
    }

    private static func managedRestoreCapabilities(
        streams: [ManagedSyncTabularStream]
    ) -> Set<String> {
        var capabilities: Set<String> = []
        for key in streams.map(\.streamKey) {
            switch key {
            case "heart_rate", "derived_heart_rate":
                capabilities.insert("hr")
            case "rr_intervals":
                capabilities.insert("hrv")
            case "step_counter":
                capabilities.insert("steps")
            case "sleep_state", "sleep_summary":
                capabilities.insert("sleep")
            case "daily_metrics", "workout_summary", "live_session":
                capabilities.insert("strainLoad")
            default:
                break
            }
        }
        return capabilities
    }

    private static func updateManagedRestoreCapabilities(
        db: Database,
        localSourceID: String,
        streams: [ManagedSyncTabularStream]
    ) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT sourceKind, capabilities FROM pairedDevice WHERE id = ?",
            arguments: [localSourceID]
        ) else {
            return
        }
        let kind: String = row["sourceKind"]
        guard kind == "cloudImport" else { return }
        let current = Set((row["capabilities"] as String).split(separator: ",").map(String.init))
        let merged = current.union(managedRestoreCapabilities(streams: streams))
        try db.execute(
            sql: """
                UPDATE pairedDevice SET capabilities = ?, lastSeenAt = ?
                WHERE id = ? AND sourceKind = 'cloudImport'
                """,
            arguments: [
                merged.sorted().joined(separator: ","),
                Int(Date().timeIntervalSince1970),
                localSourceID,
            ]
        )
    }

    /// Full stream sets are authoritative fixed-window snapshots. Partial legacy chunks remain merge-only.
    private static func clearManagedRestoreSnapshot(
        chunk: ManagedSyncRestoreChunk,
        localSourceID: String,
        db: Database
    ) throws -> Int {
        let fromSeconds = chunk.eventStartMs / 1_000
            + (chunk.eventStartMs % 1_000 == 0 ? 0 : 1)
        let throughSeconds = chunk.eventEndMs / 1_000
        var changed = 0

        func clearSeconds(_ table: String, column: String = "ts") throws {
            try db.execute(
                sql: """
                    DELETE FROM \(table)
                    WHERE deviceId = ? AND \(column) >= ? AND \(column) <= ?
                    """,
                arguments: [localSourceID, fromSeconds, throughSeconds]
            )
            changed += db.changesCount
        }

        switch chunk.dataClass {
        case "essential_timeseries":
            try clearSeconds("hrSample")
            try clearSeconds("rrInterval")
            try clearSeconds("battery")
            try clearSeconds("ppgHrSample")
            try clearSeconds("event")
            try clearSeconds("stepSample")
            try clearSeconds("bodyMeasurement", column: "measuredAt")
        case "raw_auxiliary":
            try clearSeconds("skinTempSample")
            try clearSeconds("respSample")
            try clearSeconds("sleepStateSample")
        case "raw_ppg":
            try clearSeconds("spo2Sample")
            try clearSeconds("ppgWaveformSample")
        case "raw_motion":
            try clearSeconds("gravitySample")
            try clearSeconds("rawImuSample")
        case "derived_summaries":
            let fromDay = managedRestoreDay(milliseconds: chunk.eventStartMs)
            let throughDay = managedRestoreDay(milliseconds: chunk.eventEndMs)
            for table in ["dailyMetric", "appleDaily", "metricSeries"] {
                try db.execute(
                    sql: """
                        DELETE FROM \(table)
                        WHERE deviceId = ? AND day >= ? AND day <= ?
                        """,
                    arguments: [localSourceID, fromDay, throughDay]
                )
                changed += db.changesCount
            }
            try clearSeconds("sleepSession", column: "startTs")
            try clearSeconds("workout", column: "startTs")
            try clearSeconds("liveSession", column: "startTs")
        default:
            throw ManagedSyncRestoreError.unsupportedSchema
        }
        return changed
    }

    private static func managedRestoreDay(milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(
            from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        )
    }

    private static func applyManagedRestoreRows(
        _ rows: [ManagedRestoreRow],
        streamKey: String,
        localSourceID: String,
        db: Database,
        enforceRawIMURetention: Bool = true
    ) throws -> Int {
        switch streamKey {
        case "heart_rate":
            return try restoreHeartRate(rows, source: localSourceID, db: db)
        case "rr_intervals":
            return try restoreRR(rows, source: localSourceID, db: db)
        case "battery":
            return try restoreBattery(rows, source: localSourceID, db: db)
        case "derived_heart_rate":
            return try restoreDerivedHeartRate(rows, source: localSourceID, db: db)
        case "device_events":
            return try restoreEvents(rows, source: localSourceID, db: db)
        case "step_counter":
            return try restoreSteps(rows, source: localSourceID, db: db)
        case "body_measurement":
            return try restoreBodyMeasurements(rows, source: localSourceID, db: db)
        case "skin_temperature_adc":
            return try restoreScalarADC(rows, source: localSourceID, table: "skinTempSample", db: db)
        case "respiration_adc":
            return try restoreScalarADC(rows, source: localSourceID, table: "respSample", db: db)
        case "sleep_state":
            return try restoreSleepState(rows, source: localSourceID, db: db)
        case "spo2_optical_adc":
            return try restoreOpticalADC(rows, source: localSourceID, db: db)
        case "ppg_waveform":
            return try restorePPGWaveform(rows, source: localSourceID, db: db)
        case "gravity":
            return try restoreGravity(rows, source: localSourceID, db: db)
        case "raw_imu":
            return try restoreRawIMU(
                rows,
                source: localSourceID,
                db: db,
                enforceRetention: enforceRawIMURetention
            )
        case "daily_metrics":
            return try restoreDailyMetrics(rows, source: localSourceID, db: db)
        case "metric_series":
            return try restoreMetricSeries(rows, source: localSourceID, db: db)
        case "sleep_summary":
            return try restoreSleepSummaries(rows, source: localSourceID, db: db)
        case "workout_summary":
            return try restoreWorkoutSummaries(rows, source: localSourceID, db: db)
        case "live_session":
            return try restoreLiveSessions(rows, source: localSourceID, db: db)
        default:
            throw ManagedSyncRestoreError.unsupportedSchema
        }
    }

    private static func restoreHeartRate(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, ?, ?, 0)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                bpm = excluded.bpm, synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let bpm = try row.requiredInteger("bpm")
            guard (20...260).contains(bpm) else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [source, try row.seconds(), bpm]
        }
    }

    private static func restoreRR(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO rrInterval (
                deviceId, ts, rrMs, seq, synced, tsSuspect, ord, srcChannel
            ) VALUES (?, ?, ?, ?, 0, ?, ?, ?)
            ON CONFLICT(deviceId, ts, rrMs, seq) DO UPDATE SET
                tsSuspect = excluded.tsSuspect,
                ord = excluded.ord,
                srcChannel = excluded.srcChannel,
                synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let rr = try row.requiredInteger("rr_ms")
            let seq = try row.requiredInteger("seq")
            guard (200...3_000).contains(rr), (0...100).contains(seq) else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [
                source, try row.seconds(), rr, seq,
                try row.requiredBoolean("timestamp_suspect") ? 1 : 0,
                try row.optionalInteger("ord"),
                try row.optionalInteger("source_channel"),
            ]
        }
    }

    private static func restoreBattery(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO battery (deviceId, ts, soc, mv, charging, synced)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                soc = excluded.soc,
                mv = excluded.mv,
                charging = excluded.charging,
                synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let percent = try row.optionalNumber("percent")
            let millivolts = try row.optionalInteger("millivolts")
            guard percent.map({ (0...100).contains($0) }) ?? true,
                  millivolts.map({ (0...10_000).contains($0) }) ?? true else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [
                source, try row.seconds(), percent, millivolts,
                try row.optionalBoolean("charging").map { $0 ? 1 : 0 },
            ]
        }
    }

    private static func restoreDerivedHeartRate(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO ppgHrSample (deviceId, ts, bpm, conf, synced)
            VALUES (?, ?, ?, ?, 0)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                bpm = excluded.bpm, conf = excluded.conf, synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let bpm = try row.requiredNumber("bpm")
            let confidence = try row.requiredNumber("confidence")
            guard (20...260).contains(bpm), (0...1).contains(confidence) else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [source, try row.seconds(), bpm, confidence]
        }
    }

    private static func restoreEvents(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO event (deviceId, ts, kind, payloadJSON, synced)
            VALUES (?, ?, ?, ?, 0)
            ON CONFLICT(deviceId, ts, kind) DO UPDATE SET
                payloadJSON = excluded.payloadJSON, synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let kind = try row.requiredString("kind", maximumLength: 128)
            let payload = try row.requiredJSONString("payload_json")
            return [source, try row.seconds(), kind, payload]
        }
    }

    private static func restoreSteps(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO stepSample (deviceId, ts, counter, activityClass, synced)
            VALUES (?, ?, ?, ?, 0)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                counter = excluded.counter,
                activityClass = excluded.activityClass,
                synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let counter = try row.requiredInteger("counter")
            let activity = try row.optionalInteger("activity_class")
            guard (0...65_535).contains(counter),
                  activity.map({ (0...2).contains($0) }) ?? true else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [source, try row.seconds(), counter, activity]
        }
    }

    private static func restoreBodyMeasurements(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO bodyMeasurement (
                deviceId, measuredAt, receivedAt, weightKg, bmi, heightCm,
                userId, unit, source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'kg', ?)
            ON CONFLICT(deviceId, measuredAt, userId) DO UPDATE SET
                weightKg = excluded.weightKg,
                bmi = excluded.bmi,
                heightCm = excluded.heightCm,
                source = excluded.source
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let seconds = try row.seconds()
            let weight = try row.requiredNumber("weight_kg")
            let bmi = try row.optionalNumber("bmi")
            let height = try row.optionalNumber("height_cm")
            let userID = try row.requiredInteger("user_id")
            guard (1...1_000).contains(weight),
                  bmi.map({ (1...200).contains($0) }) ?? true,
                  height.map({ (20...300).contains($0) }) ?? true,
                  (-1...255).contains(userID) else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [
                source, seconds, seconds, weight, bmi, height, userID,
                try row.requiredString("source", maximumLength: 64),
            ]
        }
    }

    private static func restoreScalarADC(
        _ rows: [ManagedRestoreRow],
        source: String,
        table: String,
        db: Database
    ) throws -> Int {
        guard table == "skinTempSample" || table == "respSample" else {
            throw ManagedSyncRestoreError.invalidStream
        }
        let statement = try db.cachedStatement(sql: """
            INSERT INTO \(table) (deviceId, ts, raw, synced) VALUES (?, ?, ?, 0)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                raw = excluded.raw, synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            [source, try row.seconds(), try row.requiredInteger("adc")]
        }
    }

    private static func restoreSleepState(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO sleepStateSample (deviceId, ts, state, synced)
            VALUES (?, ?, ?, 0)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                state = excluded.state, synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let state = try row.requiredInteger("state_code")
            guard (0...3).contains(state) else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [source, try row.seconds(), state]
        }
    }

    private static func restoreOpticalADC(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO spo2Sample (deviceId, ts, red, ir, synced)
            VALUES (?, ?, ?, ?, 0)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                red = excluded.red, ir = excluded.ir, synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            [
                source, try row.seconds(), try row.requiredInteger("red_adc"),
                try row.requiredInteger("infrared_adc"),
            ]
        }
    }

    private static func restorePPGWaveform(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO ppgWaveformSample (deviceId, ts, samples)
            VALUES (?, ?, ?)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                samples = excluded.samples, synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let sampleRate = try row.requiredNumber("sample_rate_hz")
            let sampleCount = try row.requiredInteger("sample_count")
            let samples = try row.requiredBase64("samples_base64", maximumBytes: 8_192)
            guard (1...1_000).contains(sampleRate),
                  (1...4_096).contains(sampleCount),
                  samples.count == sampleCount * 2 else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [source, try row.seconds(), samples]
        }
    }

    private static func restoreGravity(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO gravitySample (deviceId, ts, x, y, z, synced)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                x = excluded.x, y = excluded.y, z = excluded.z, synced = 0
            """)
        return try apply(rows, statement: statement, db: db) { row in
            let x = try row.requiredNumber("x_g")
            let y = try row.requiredNumber("y_g")
            let z = try row.requiredNumber("z_g")
            guard [-64...64 ~= x, -64...64 ~= y, -64...64 ~= z].allSatisfy({ $0 }) else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [source, try row.seconds(), x, y, z]
        }
    }

    private static func restoreRawIMU(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database,
        enforceRetention: Bool
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO rawImuSample (deviceId, ts, samples)
            VALUES (?, ?, ?)
            ON CONFLICT(deviceId, ts) DO UPDATE SET
                samples = excluded.samples
            """)
        let changed = try apply(rows, statement: statement, db: db) { row in
            let sampleRate = try row.requiredNumber("sample_rate_hz")
            let sampleCount = try row.requiredInteger("sample_count")
            let axisOrder = try row.requiredString("axis_order", maximumLength: 32)
            let samples = try row.requiredBase64(
                "samples_base64",
                maximumBytes: 120_000
            )
            guard (1...2_000).contains(sampleRate),
                  (1...10_000).contains(sampleCount),
                  axisOrder == "ax_ay_az_gx_gy_gz",
                  samples.count == sampleCount * 12 else {
                throw ManagedSyncRestoreError.invalidValue
            }
            return [source, try row.seconds(), samples]
        }
        if enforceRetention {
            try db.execute(
                sql: """
                    DELETE FROM rawImuSample
                    WHERE deviceId = ? AND ts < COALESCE((
                        SELECT MIN(ts) FROM (
                            SELECT ts FROM rawImuSample
                            WHERE deviceId = ?
                            ORDER BY ts DESC LIMIT ?
                        )
                    ), 0)
                    """,
                arguments: [source, source, rawImuRetentionRows]
            )
        }
        return changed
    }

    private static func restoreDailyMetrics(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        var changed = 0
        for row in rows {
            let day = try row.requiredDay("day")
            let payload = try row.requiredJSONObject("payload_json")
            let recordType = try payload.requiredString("record_type")
            let deleted = try row.requiredBoolean("deleted")
            switch recordType {
            case "daily_metric":
                if deleted {
                    try db.execute(
                        sql: "DELETE FROM dailyMetric WHERE deviceId = ? AND day = ?",
                        arguments: [source, day]
                    )
                } else {
                    try db.execute(sql: """
                        INSERT INTO dailyMetric (
                            deviceId, day, totalSleepMin, efficiency, deepMin, remMin,
                            lightMin, disturbances, restingHr, avgHrv, recovery, strain,
                            exerciseCount, spo2Pct, skinTempDevC, respRateBpm, steps,
                            activeKcalEst, spo2Red, spo2Ir, hrvMethod
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                        )
                        ON CONFLICT(deviceId, day) DO UPDATE SET
                            totalSleepMin = excluded.totalSleepMin,
                            efficiency = excluded.efficiency,
                            deepMin = excluded.deepMin,
                            remMin = excluded.remMin,
                            lightMin = excluded.lightMin,
                            disturbances = excluded.disturbances,
                            restingHr = excluded.restingHr,
                            avgHrv = excluded.avgHrv,
                            recovery = excluded.recovery,
                            strain = excluded.strain,
                            exerciseCount = excluded.exerciseCount,
                            spo2Pct = excluded.spo2Pct,
                            skinTempDevC = excluded.skinTempDevC,
                            respRateBpm = excluded.respRateBpm,
                            steps = excluded.steps,
                            activeKcalEst = excluded.activeKcalEst,
                            spo2Red = excluded.spo2Red,
                            spo2Ir = excluded.spo2Ir,
                            hrvMethod = excluded.hrvMethod
                        """, arguments: [
                            source, day,
                            try payload.optionalNumber("total_sleep_min"),
                            try payload.optionalNumber("efficiency"),
                            try payload.optionalNumber("deep_min"),
                            try payload.optionalNumber("rem_min"),
                            try payload.optionalNumber("light_min"),
                            try payload.optionalInteger("disturbances"),
                            try payload.optionalInteger("resting_hr"),
                            try payload.optionalNumber("avg_hrv"),
                            try payload.optionalNumber("recovery"),
                            try payload.optionalNumber("strain"),
                            try payload.optionalInteger("exercise_count"),
                            try payload.optionalNumber("spo2_pct"),
                            try payload.optionalNumber("skin_temp_dev_c"),
                            try payload.optionalNumber("resp_rate_bpm"),
                            try payload.optionalInteger("steps"),
                            try payload.optionalNumber("active_kcal_est"),
                            try payload.optionalInteger("spo2_red"),
                            try payload.optionalInteger("spo2_ir"),
                            try payload.optionalString("hrv_method"),
                        ])
                }
            case "platform_daily":
                if deleted {
                    try db.execute(
                        sql: "DELETE FROM appleDaily WHERE deviceId = ? AND day = ?",
                        arguments: [source, day]
                    )
                } else {
                    try db.execute(sql: """
                        INSERT INTO appleDaily (
                            deviceId, day, steps, activeKcal, basalKcal, vo2max,
                            avgHr, maxHr, walkingHr, weightKg
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceId, day) DO UPDATE SET
                            steps = excluded.steps,
                            activeKcal = excluded.activeKcal,
                            basalKcal = excluded.basalKcal,
                            vo2max = excluded.vo2max,
                            avgHr = excluded.avgHr,
                            maxHr = excluded.maxHr,
                            walkingHr = excluded.walkingHr,
                            weightKg = excluded.weightKg
                        """, arguments: [
                            source, day,
                            try payload.optionalInteger("steps"),
                            try payload.optionalNumber("active_kcal"),
                            try payload.optionalNumber("basal_kcal"),
                            try payload.optionalNumber("vo2max"),
                            try payload.optionalInteger("avg_hr"),
                            try payload.optionalInteger("max_hr"),
                            try payload.optionalInteger("walking_hr"),
                            try payload.optionalNumber("weight_kg"),
                        ])
                }
            default:
                throw ManagedSyncRestoreError.invalidValue
            }
            changed += db.changesCount
        }
        return changed
    }

    private static func restoreMetricSeries(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        var changed = 0
        for row in rows {
            let day = try row.requiredDay("day")
            let key = try row.requiredString("metric_key", maximumLength: 64)
            if try row.requiredBoolean("deleted") {
                try db.execute(
                    sql: """
                        DELETE FROM metricSeries
                        WHERE deviceId = ? AND day = ? AND key = ?
                        """,
                    arguments: [source, day, key]
                )
            } else {
                let value = try row.requiredNumber("value")
                guard let normalized = normalizedMetricSeriesValue(value, forKey: key) else {
                    throw ManagedSyncRestoreError.invalidValue
                }
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [source, day, key, normalized])
            }
            changed += db.changesCount
        }
        return changed
    }

    private static func restoreSleepSummaries(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        var changed = 0
        for row in rows {
            let start = try row.seconds()
            if try row.requiredBoolean("deleted") {
                try db.execute(
                    sql: "DELETE FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                    arguments: [source, start]
                )
            } else {
                let end = try row.requiredMilliseconds("end_at_ms") / 1_000
                let payload = try row.requiredJSONObject("payload_json")
                let userEdited = try payload.optionalBoolean("user_edited") ?? false
                try db.execute(sql: """
                    INSERT INTO sleepSession (
                        deviceId, startTs, endTs, efficiency, restingHr, avgHrv,
                        stagesJSON, userEdited, startTsAdjusted, motionJSON,
                        sleepStateJSON, gravitySparse, rrEligibleWindowCount,
                        rrValidWindowCount
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs) DO UPDATE SET
                        endTs = CASE
                            WHEN sleepSession.userEdited AND NOT excluded.userEdited
                            THEN sleepSession.endTs ELSE excluded.endTs END,
                        efficiency = excluded.efficiency,
                        restingHr = excluded.restingHr,
                        avgHrv = excluded.avgHrv,
                        stagesJSON = CASE
                            WHEN sleepSession.userEdited AND NOT excluded.userEdited
                            THEN sleepSession.stagesJSON ELSE excluded.stagesJSON END,
                        startTsAdjusted = CASE
                            WHEN sleepSession.userEdited AND NOT excluded.userEdited
                            THEN sleepSession.startTsAdjusted
                            ELSE excluded.startTsAdjusted END,
                        motionJSON = CASE
                            WHEN sleepSession.userEdited AND NOT excluded.userEdited
                            THEN sleepSession.motionJSON ELSE excluded.motionJSON END,
                        sleepStateJSON = CASE
                            WHEN sleepSession.userEdited AND NOT excluded.userEdited
                            THEN sleepSession.sleepStateJSON
                            ELSE excluded.sleepStateJSON END,
                        gravitySparse = CASE
                            WHEN sleepSession.userEdited AND NOT excluded.userEdited
                            THEN sleepSession.gravitySparse
                            ELSE excluded.gravitySparse END,
                        rrEligibleWindowCount = CASE
                            WHEN sleepSession.userEdited AND NOT excluded.userEdited
                            THEN sleepSession.rrEligibleWindowCount
                            ELSE excluded.rrEligibleWindowCount END,
                        rrValidWindowCount = CASE
                            WHEN sleepSession.userEdited AND NOT excluded.userEdited
                            THEN sleepSession.rrValidWindowCount
                            ELSE excluded.rrValidWindowCount END,
                        userEdited = MAX(sleepSession.userEdited, excluded.userEdited)
                    """, arguments: [
                        source, start, end,
                        try payload.optionalNumber("efficiency"),
                        try payload.optionalInteger("resting_hr"),
                        try payload.optionalNumber("avg_hrv"),
                        try payload.optionalString("stages_json"),
                        userEdited ? 1 : 0,
                        try payload.optionalInteger("start_ts_adjusted"),
                        try payload.optionalString("motion_json"),
                        try payload.optionalString("sleep_state_json"),
                        try payload.optionalBoolean("gravity_sparse").map { $0 ? 1 : 0 },
                        try payload.optionalInteger("rr_eligible_window_count"),
                        try payload.optionalInteger("rr_valid_window_count"),
                    ])
            }
            changed += db.changesCount
        }
        return changed
    }

    private static func restoreWorkoutSummaries(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        var changed = 0
        for row in rows {
            let start = try row.seconds()
            let payload = try row.requiredJSONObject("payload_json")
            let sport = try payload.requiredString("sport")
            if try row.requiredBoolean("deleted") {
                try db.execute(
                    sql: """
                        DELETE FROM workout
                        WHERE deviceId = ? AND startTs = ? AND sport = ?
                        """,
                    arguments: [source, start, sport]
                )
            } else {
                let end = try row.requiredMilliseconds("end_at_ms") / 1_000
                try db.execute(sql: """
                    INSERT INTO workout (
                        deviceId, startTs, endTs, sport, source, durationS,
                        energyKcal, avgHr, maxHr, strain, distanceM, zonesJSON,
                        notes, steps
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                        endTs = excluded.endTs,
                        source = excluded.source,
                        durationS = excluded.durationS,
                        energyKcal = excluded.energyKcal,
                        avgHr = excluded.avgHr,
                        maxHr = excluded.maxHr,
                        strain = excluded.strain,
                        distanceM = excluded.distanceM,
                        zonesJSON = excluded.zonesJSON,
                        notes = excluded.notes,
                        steps = excluded.steps
                    """, arguments: [
                        source, start, end, sport,
                        try payload.requiredString("source"),
                        try payload.optionalNumber("duration_s"),
                        try payload.optionalNumber("energy_kcal"),
                        try payload.optionalInteger("avg_hr"),
                        try payload.optionalInteger("max_hr"),
                        try payload.optionalNumber("strain"),
                        try payload.optionalNumber("distance_m"),
                        try payload.optionalString("zones_json"),
                        try payload.optionalString("notes"),
                        try payload.optionalInteger("steps"),
                    ])
            }
            changed += db.changesCount
        }
        return changed
    }

    private static func restoreLiveSessions(
        _ rows: [ManagedRestoreRow],
        source: String,
        db: Database
    ) throws -> Int {
        var changed = 0
        for row in rows {
            let start = try row.seconds()
            if try row.requiredBoolean("deleted") {
                try db.execute(
                    sql: "DELETE FROM liveSession WHERE deviceId = ? AND startTs = ?",
                    arguments: [source, start]
                )
            } else {
                let payload = try row.requiredJSONObject("payload_json")
                try db.execute(sql: """
                    INSERT INTO liveSession (
                        deviceId, startTs, endTs, chargeAtStart, floorBpm,
                        ceilingBpm, inBandSec, belowSec, aboveSec, pushCount,
                        easeCount, hrSource
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs) DO UPDATE SET
                        endTs = excluded.endTs,
                        chargeAtStart = excluded.chargeAtStart,
                        floorBpm = excluded.floorBpm,
                        ceilingBpm = excluded.ceilingBpm,
                        inBandSec = excluded.inBandSec,
                        belowSec = excluded.belowSec,
                        aboveSec = excluded.aboveSec,
                        pushCount = excluded.pushCount,
                        easeCount = excluded.easeCount,
                        hrSource = excluded.hrSource
                    """, arguments: [
                        source, start,
                        try row.optionalMilliseconds("end_at_ms").map { $0 / 1_000 },
                        try payload.optionalNumber("charge_at_start"),
                        try payload.requiredNumber("floor_bpm"),
                        try payload.requiredNumber("ceiling_bpm"),
                        try payload.requiredNumber("in_band_sec"),
                        try payload.requiredNumber("below_sec"),
                        try payload.requiredNumber("above_sec"),
                        try payload.requiredInteger("push_count"),
                        try payload.requiredInteger("ease_count"),
                        try payload.requiredString("hr_source"),
                    ])
            }
            changed += db.changesCount
        }
        return changed
    }

    private static func apply(
        _ rows: [ManagedRestoreRow],
        statement: Statement,
        db: Database,
        arguments: (ManagedRestoreRow) throws -> StatementArguments
    ) throws -> Int {
        var changed = 0
        for row in rows {
            try statement.execute(arguments: try arguments(row))
            changed += db.changesCount
        }
        return changed
    }
}

private struct ManagedRestoreRow {
    let columns: [String]
    let values: [ManagedSyncCell]

    private func value(_ name: String) throws -> ManagedSyncCell {
        guard let index = columns.firstIndex(of: name), values.indices.contains(index) else {
            throw ManagedSyncRestoreError.invalidRow
        }
        return values[index]
    }

    func requiredInteger(_ name: String) throws -> Int64 {
        switch try value(name) {
        case .integer(let value):
            return value
        case .number(let value)
            where value.isFinite && value.rounded(.towardZero) == value
                && value >= Double(Int64.min) && value <= Double(Int64.max):
            return Int64(value)
        default:
            throw ManagedSyncRestoreError.invalidValue
        }
    }

    func optionalInteger(_ name: String) throws -> Int64? {
        if case .null = try value(name) { return nil }
        return try requiredInteger(name)
    }

    func requiredNumber(_ name: String) throws -> Double {
        let number: Double
        switch try value(name) {
        case .integer(let value):
            number = Double(value)
        case .number(let value):
            number = value
        default:
            throw ManagedSyncRestoreError.invalidValue
        }
        guard number.isFinite else { throw ManagedSyncRestoreError.invalidValue }
        return number
    }

    func optionalNumber(_ name: String) throws -> Double? {
        if case .null = try value(name) { return nil }
        return try requiredNumber(name)
    }

    func requiredString(_ name: String, maximumLength: Int = 262_144) throws -> String {
        guard case .string(let string) = try value(name),
              !string.isEmpty,
              string.utf8.count <= maximumLength else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return string
    }

    func optionalString(_ name: String, maximumLength: Int = 262_144) throws -> String? {
        if case .null = try value(name) { return nil }
        return try requiredString(name, maximumLength: maximumLength)
    }

    func requiredBoolean(_ name: String) throws -> Bool {
        guard case .boolean(let boolean) = try value(name) else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return boolean
    }

    func optionalBoolean(_ name: String) throws -> Bool? {
        if case .null = try value(name) { return nil }
        return try requiredBoolean(name)
    }

    func requiredMilliseconds(_ name: String) throws -> Int64 {
        let milliseconds = try requiredInteger(name)
        guard milliseconds >= 0, milliseconds % 1_000 == 0 else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return milliseconds
    }

    func optionalMilliseconds(_ name: String) throws -> Int64? {
        if case .null = try value(name) { return nil }
        return try requiredMilliseconds(name)
    }

    func seconds() throws -> Int64 {
        try requiredMilliseconds("event_at_ms") / 1_000
    }

    func requiredDay(_ name: String) throws -> String {
        let day = try requiredString(name, maximumLength: 10)
        guard day.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) != nil else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return day
    }

    func requiredBase64(_ name: String, maximumBytes: Int) throws -> Data {
        let encoded = try requiredString(name, maximumLength: maximumBytes * 2)
        guard let data = Data(base64Encoded: encoded),
              data.count <= maximumBytes else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return data
    }

    func requiredJSONString(_ name: String) throws -> String {
        let encoded = try requiredString(name)
        guard let data = encoded.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return encoded
    }

    func requiredJSONObject(_ name: String) throws -> ManagedRestoreJSONObject {
        let encoded = try requiredString(name)
        guard let data = encoded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return ManagedRestoreJSONObject(values: dictionary)
    }
}

private struct ManagedRestoreJSONObject {
    let values: [String: Any]

    private func value(_ key: String) -> Any? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        guard let string = value(key) as? String, !string.isEmpty else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return string
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let string = value as? String else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return string
    }

    func requiredInteger(_ key: String) throws -> Int64 {
        guard let value = value(key) else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return try Self.integer(value)
    }

    func optionalInteger(_ key: String) throws -> Int64? {
        guard let value = value(key) else { return nil }
        return try Self.integer(value)
    }

    func requiredNumber(_ key: String) throws -> Double {
        guard let value = value(key) else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return try Self.number(value)
    }

    func optionalNumber(_ key: String) throws -> Double? {
        guard let value = value(key) else { return nil }
        return try Self.number(value)
    }

    func optionalBoolean(_ key: String) throws -> Bool? {
        guard let value = value(key) else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return number.boolValue
    }

    private static func integer(_ value: Any) throws -> Int64 {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ManagedSyncRestoreError.invalidValue
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int64.min),
              double <= Double(Int64.max) else {
            throw ManagedSyncRestoreError.invalidValue
        }
        return Int64(double)
    }

    private static func number(_ value: Any) throws -> Double {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ManagedSyncRestoreError.invalidValue
        }
        let double = number.doubleValue
        guard double.isFinite else { throw ManagedSyncRestoreError.invalidValue }
        return double
    }
}
