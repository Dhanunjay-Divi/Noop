import Foundation
import GRDB

public enum ManagedSyncCell: Equatable, Sendable {
    case integer(Int64)
    case number(Double)
    case string(String)
    case boolean(Bool)
    case null
}

public struct ManagedSyncTabularStream: Equatable, Sendable {
    public let streamKey: String
    public let columns: [String]
    public let rows: [[ManagedSyncCell]]
    public let schemaRevision: Int

    public init(
        streamKey: String,
        columns: [String],
        rows: [[ManagedSyncCell]],
        schemaRevision: Int = 1
    ) {
        self.streamKey = streamKey
        self.columns = columns
        self.rows = rows
        self.schemaRevision = schemaRevision
    }
}

public enum ManagedSyncChunkStoreError: Error, Equatable {
    case unsupportedDataClass
    case invalidWindow
    case windowTooDense
    case invalidStoredValue
}

extension WhoopStore {
    private static let managedMaximumRowsPerStream = 100_000

    /// Find the first local row without materializing a window. Timestamps are returned in milliseconds
    /// even though the primary sensor tables store whole seconds.
    public func managedSyncNextEventTime(
        localSourceID: String,
        dataClass: String,
        atOrAfterMs: Int64,
        beforeMs: Int64
    ) async throws -> Int64? {
        guard atOrAfterMs >= 0, beforeMs > atOrAfterMs else {
            throw ManagedSyncChunkStoreError.invalidWindow
        }
        let expressions: [(table: String, timestamp: String)]
        switch dataClass {
        case "essential_timeseries":
            expressions = [
                ("hrSample", "ts * 1000"),
                ("rrInterval", "ts * 1000"),
                ("event", "ts * 1000"),
                ("battery", "ts * 1000"),
                ("stepSample", "ts * 1000"),
                ("ppgHrSample", "ts * 1000"),
                ("bodyMeasurement", "measuredAt * 1000"),
            ]
        case "raw_auxiliary":
            expressions = [
                ("skinTempSample", "ts * 1000"),
                ("respSample", "ts * 1000"),
                ("sleepStateSample", "ts * 1000"),
            ]
        case "raw_ppg":
            expressions = [
                ("spo2Sample", "ts * 1000"),
                ("ppgWaveformSample", "ts * 1000"),
            ]
        case "raw_motion":
            expressions = [
                ("gravitySample", "ts * 1000"),
                ("rawImuSample", "ts * 1000"),
            ]
        case "derived_summaries":
            expressions = [
                ("dailyMetric", "CAST(strftime('%s', day || 'T00:00:00Z') AS INTEGER) * 1000"),
                ("appleDaily", "CAST(strftime('%s', day || 'T00:00:00Z') AS INTEGER) * 1000"),
                ("metricSeries", "CAST(strftime('%s', day || 'T00:00:00Z') AS INTEGER) * 1000"),
                ("sleepSession", "startTs * 1000"),
                ("workout", "startTs * 1000"),
                ("liveSession", "startTs * 1000"),
            ]
        default:
            throw ManagedSyncChunkStoreError.unsupportedDataClass
        }

        return try syncRead { db in
            let parts = expressions.map { table, timestamp in
                """
                SELECT \(timestamp) AS eventAtMs FROM \(table)
                WHERE deviceId = ? AND \(timestamp) >= ? AND \(timestamp) < ?
                """
            }
            var arguments: [DatabaseValueConvertible] = []
            for _ in expressions {
                arguments.append(localSourceID)
                arguments.append(atOrAfterMs)
                arguments.append(beforeMs)
            }
            return try Int64.fetchOne(
                db,
                sql: "SELECT MIN(eventAtMs) FROM (\(parts.joined(separator: " UNION ALL ")))",
                arguments: StatementArguments(arguments)
            )
        }
    }

    public func managedSyncStreams(
        localSourceID: String,
        dataClass: String,
        startMs: Int64,
        endExclusiveMs: Int64
    ) async throws -> [ManagedSyncTabularStream] {
        guard startMs >= 0, endExclusiveMs > startMs else {
            throw ManagedSyncChunkStoreError.invalidWindow
        }
        return try syncRead { db in
            switch dataClass {
            case "essential_timeseries":
                return try Self.managedEssentialStreams(
                    db: db, source: localSourceID, startMs: startMs, endMs: endExclusiveMs
                )
            case "raw_auxiliary":
                return try Self.managedAuxiliaryStreams(
                    db: db, source: localSourceID, startMs: startMs, endMs: endExclusiveMs
                )
            case "raw_ppg":
                return try Self.managedPPGStreams(
                    db: db, source: localSourceID, startMs: startMs, endMs: endExclusiveMs
                )
            case "raw_motion":
                return try Self.managedMotionStreams(
                    db: db, source: localSourceID, startMs: startMs, endMs: endExclusiveMs
                )
            case "derived_summaries":
                return try Self.managedDerivedStreams(
                    db: db, source: localSourceID, startMs: startMs, endMs: endExclusiveMs
                )
            default:
                throw ManagedSyncChunkStoreError.unsupportedDataClass
            }
        }
    }

    private static func managedEssentialStreams(
        db: Database,
        source: String,
        startMs: Int64,
        endMs: Int64
    ) throws -> [ManagedSyncTabularStream] {
        let bounds = managedSecondBounds(startMs: startMs, endMs: endMs)
        let limit = managedMaximumRowsPerStream + 1
        let hr = try managedRows(
            db,
            sql: """
                SELECT ts, bpm FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [.integer(Int64(row["ts"] as Int) * 1_000),
             .integer(Int64(row["bpm"] as Int)), .null, .string("sensor")]
        }
        let rr = try managedRows(
            db,
            sql: """
                SELECT ts, rrMs, seq, ord, srcChannel, tsSuspect FROM rrInterval
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts, ord, rrMs, seq LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [
                .integer(Int64(row["ts"] as Int) * 1_000),
                .integer(Int64(row["rrMs"] as Int)),
                .integer(Int64(row["seq"] as Int)),
                managedInteger(row["ord"] as Int?),
                managedInteger(row["srcChannel"] as Int?),
                .boolean((row["tsSuspect"] as Int? ?? 0) == 1),
            ]
        }
        let battery = try managedRows(
            db,
            sql: """
                SELECT ts, soc, mv, charging FROM battery
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [
                .integer(Int64(row["ts"] as Int) * 1_000),
                managedNumber(row["soc"] as Double?),
                managedInteger(row["mv"] as Int?),
                managedBoolean(row["charging"] as Int?),
            ]
        }
        let derivedHR = try managedRows(
            db,
            sql: """
                SELECT ts, bpm, conf FROM ppgHrSample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [
                .integer(Int64(row["ts"] as Int) * 1_000),
                .number(row["bpm"] as Double),
                .number(row["conf"] as Double),
                .string("local_autocorrelation_v1"),
            ]
        }
        let events = try managedRows(
            db,
            sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts, kind LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [
                .integer(Int64(row["ts"] as Int) * 1_000),
                .string(row["kind"] as String),
                .string(row["payloadJSON"] as String),
            ]
        }
        let steps = try managedRows(
            db,
            sql: """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [
                .integer(Int64(row["ts"] as Int) * 1_000),
                .integer(Int64(row["counter"] as Int)),
                managedInteger(row["activityClass"] as Int?),
            ]
        }
        let body = try managedRows(
            db,
            sql: """
                SELECT measuredAt, weightKg, bmi, heightCm, userId, source
                FROM bodyMeasurement
                WHERE deviceId = ? AND measuredAt >= ? AND measuredAt < ?
                ORDER BY measuredAt, userId LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [
                .integer(Int64(row["measuredAt"] as Int) * 1_000),
                .number(row["weightKg"] as Double),
                managedNumber(row["bmi"] as Double?),
                managedNumber(row["heightCm"] as Double?),
                .integer(Int64(row["userId"] as Int)),
                .string(row["source"] as String),
            ]
        }
        return [
            ManagedSyncTabularStream(
                streamKey: "heart_rate",
                columns: ["event_at_ms", "bpm", "quality", "provenance"],
                rows: hr
            ),
            ManagedSyncTabularStream(
                streamKey: "rr_intervals",
                columns: [
                    "event_at_ms", "rr_ms", "seq", "ord", "source_channel",
                    "timestamp_suspect",
                ],
                rows: rr
            ),
            ManagedSyncTabularStream(
                streamKey: "battery",
                columns: ["event_at_ms", "percent", "millivolts", "charging"],
                rows: battery
            ),
            ManagedSyncTabularStream(
                streamKey: "derived_heart_rate",
                columns: ["event_at_ms", "bpm", "confidence", "algorithm_revision"],
                rows: derivedHR
            ),
            ManagedSyncTabularStream(
                streamKey: "device_events",
                columns: ["event_at_ms", "kind", "payload_json"],
                rows: events
            ),
            ManagedSyncTabularStream(
                streamKey: "step_counter",
                columns: ["event_at_ms", "counter", "activity_class"],
                rows: steps
            ),
            ManagedSyncTabularStream(
                streamKey: "body_measurement",
                columns: [
                    "event_at_ms", "weight_kg", "bmi", "height_cm", "user_id", "source",
                ],
                rows: body
            ),
        ]
    }

    private static func managedAuxiliaryStreams(
        db: Database,
        source: String,
        startMs: Int64,
        endMs: Int64
    ) throws -> [ManagedSyncTabularStream] {
        let bounds = managedSecondBounds(startMs: startMs, endMs: endMs)
        let limit = managedMaximumRowsPerStream + 1
        func scalar(_ table: String) throws -> [[ManagedSyncCell]] {
            try managedRows(
                db,
                sql: """
                    SELECT ts, raw FROM \(table)
                    WHERE deviceId = ? AND ts >= ? AND ts < ?
                    ORDER BY ts LIMIT ?
                    """,
                arguments: [source, bounds.start, bounds.end, limit]
            ) { row in
                [.integer(Int64(row["ts"] as Int) * 1_000),
                 .integer(Int64(row["raw"] as Int))]
            }
        }
        let state = try managedRows(
            db,
            sql: """
                SELECT ts, state FROM sleepStateSample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [.integer(Int64(row["ts"] as Int) * 1_000),
             .integer(Int64(row["state"] as Int))]
        }
        return [
            ManagedSyncTabularStream(
                streamKey: "skin_temperature_adc",
                columns: ["event_at_ms", "adc"],
                rows: try scalar("skinTempSample")
            ),
            ManagedSyncTabularStream(
                streamKey: "respiration_adc",
                columns: ["event_at_ms", "adc"],
                rows: try scalar("respSample")
            ),
            ManagedSyncTabularStream(
                streamKey: "sleep_state",
                columns: ["event_at_ms", "state_code"],
                rows: state
            ),
        ]
    }

    private static func managedPPGStreams(
        db: Database,
        source: String,
        startMs: Int64,
        endMs: Int64
    ) throws -> [ManagedSyncTabularStream] {
        let bounds = managedSecondBounds(startMs: startMs, endMs: endMs)
        let limit = managedMaximumRowsPerStream + 1
        let optical = try managedRows(
            db,
            sql: """
                SELECT ts, red, ir FROM spo2Sample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [
                .integer(Int64(row["ts"] as Int) * 1_000),
                .integer(Int64(row["red"] as Int)),
                .integer(Int64(row["ir"] as Int)),
            ]
        }
        let waveform = try managedRows(
            db,
            sql: """
                SELECT ts, samples FROM ppgWaveformSample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            let samples: Data = row["samples"]
            return [
                .integer(Int64(row["ts"] as Int) * 1_000),
                .number(24),
                .integer(Int64(samples.count / 2)),
                .string(samples.base64EncodedString()),
            ]
        }
        return [
            ManagedSyncTabularStream(
                streamKey: "spo2_optical_adc",
                columns: ["event_at_ms", "red_adc", "infrared_adc"],
                rows: optical
            ),
            ManagedSyncTabularStream(
                streamKey: "ppg_waveform",
                columns: ["event_at_ms", "sample_rate_hz", "sample_count", "samples_base64"],
                rows: waveform
            ),
        ]
    }

    private static func managedMotionStreams(
        db: Database,
        source: String,
        startMs: Int64,
        endMs: Int64
    ) throws -> [ManagedSyncTabularStream] {
        let bounds = managedSecondBounds(startMs: startMs, endMs: endMs)
        let limit = managedMaximumRowsPerStream + 1
        let gravity = try managedRows(
            db,
            sql: """
                SELECT ts, x, y, z FROM gravitySample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            [
                .integer(Int64(row["ts"] as Int) * 1_000),
                .number(row["x"] as Double),
                .number(row["y"] as Double),
                .number(row["z"] as Double),
            ]
        }
        let imu = try managedRows(
            db,
            sql: """
                SELECT ts, samples FROM rawImuSample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts LIMIT ?
                """,
            arguments: [source, bounds.start, bounds.end, limit]
        ) { row in
            let samples: Data = row["samples"]
            return [
                .integer(Int64(row["ts"] as Int) * 1_000),
                .number(100),
                .integer(Int64(samples.count / 12)),
                .string("ax_ay_az_gx_gy_gz"),
                .string(samples.base64EncodedString()),
            ]
        }
        return [
            ManagedSyncTabularStream(
                streamKey: "gravity",
                columns: ["event_at_ms", "x_g", "y_g", "z_g"],
                rows: gravity
            ),
            ManagedSyncTabularStream(
                streamKey: "raw_imu",
                columns: [
                    "event_at_ms", "sample_rate_hz", "sample_count", "axis_order",
                    "samples_base64",
                ],
                rows: imu
            ),
        ]
    }

    private static func managedDerivedStreams(
        db: Database,
        source: String,
        startMs: Int64,
        endMs: Int64
    ) throws -> [ManagedSyncTabularStream] {
        let days = managedDayBounds(startMs: startMs, endMs: endMs)
        let seconds = managedSecondBounds(startMs: startMs, endMs: endMs)
        let limit = managedMaximumRowsPerStream + 1
        let daily = try managedRows(
            db,
            sql: """
                SELECT * FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day < ?
                ORDER BY day LIMIT ?
                """,
            arguments: [source, days.start, days.end, limit]
        ) { row in
            let event = try managedDayMilliseconds(row["day"] as String)
            let payload = try managedPayload([
                "record_type": "daily_metric",
                "total_sleep_min": managedAny(row["totalSleepMin"] as Double?),
                "efficiency": managedAny(row["efficiency"] as Double?),
                "deep_min": managedAny(row["deepMin"] as Double?),
                "rem_min": managedAny(row["remMin"] as Double?),
                "light_min": managedAny(row["lightMin"] as Double?),
                "disturbances": managedAny(row["disturbances"] as Int?),
                "resting_hr": managedAny(row["restingHr"] as Int?),
                "avg_hrv": managedAny(row["avgHrv"] as Double?),
                "recovery": managedAny(row["recovery"] as Double?),
                "strain": managedAny(row["strain"] as Double?),
                "exercise_count": managedAny(row["exerciseCount"] as Int?),
                "spo2_pct": managedAny(row["spo2Pct"] as Double?),
                "skin_temp_dev_c": managedAny(row["skinTempDevC"] as Double?),
                "resp_rate_bpm": managedAny(row["respRateBpm"] as Double?),
                "steps": managedAny(row["steps"] as Int?),
                "active_kcal_est": managedAny(row["activeKcalEst"] as Double?),
                "spo2_red": managedAny(row["spo2Red"] as Int?),
                "spo2_ir": managedAny(row["spo2Ir"] as Int?),
                "hrv_method": managedAny(row["hrvMethod"] as String?),
            ])
            return [
                .integer(event), .string(row["day"] as String), .string(source),
                .string(payload), .integer(event), .boolean(false),
            ]
        }
        let platformDaily = try managedRows(
            db,
            sql: """
                SELECT * FROM appleDaily
                WHERE deviceId = ? AND day >= ? AND day < ?
                ORDER BY day LIMIT ?
                """,
            arguments: [source, days.start, days.end, limit]
        ) { row in
            let event = try managedDayMilliseconds(row["day"] as String)
            let payload = try managedPayload([
                "record_type": "platform_daily",
                "steps": managedAny(row["steps"] as Int?),
                "active_kcal": managedAny(row["activeKcal"] as Double?),
                "basal_kcal": managedAny(row["basalKcal"] as Double?),
                "vo2max": managedAny(row["vo2max"] as Double?),
                "avg_hr": managedAny(row["avgHr"] as Int?),
                "max_hr": managedAny(row["maxHr"] as Int?),
                "walking_hr": managedAny(row["walkingHr"] as Int?),
                "weight_kg": managedAny(row["weightKg"] as Double?),
            ])
            return [
                .integer(event), .string(row["day"] as String), .string(source),
                .string(payload), .integer(event), .boolean(false),
            ]
        }
        let metrics = try managedRows(
            db,
            sql: """
                SELECT day, key, value FROM metricSeries
                WHERE deviceId = ? AND day >= ? AND day < ?
                ORDER BY day, key LIMIT ?
                """,
            arguments: [source, days.start, days.end, limit]
        ) { row in
            let event = try managedDayMilliseconds(row["day"] as String)
            return [
                .integer(event), .string(row["day"] as String),
                .string(row["key"] as String), .number(row["value"] as Double),
                .string(source), .integer(event), .boolean(false),
            ]
        }
        let sleep = try managedRows(
            db,
            sql: """
                SELECT * FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs < ?
                ORDER BY startTs LIMIT ?
                """,
            arguments: [source, seconds.start, seconds.end, limit]
        ) { row in
            let start = Int64(row["startTs"] as Int) * 1_000
            let payload = try managedPayload([
                "efficiency": managedAny(row["efficiency"] as Double?),
                "resting_hr": managedAny(row["restingHr"] as Int?),
                "avg_hrv": managedAny(row["avgHrv"] as Double?),
                "stages_json": managedAny(row["stagesJSON"] as String?),
                "user_edited": (row["userEdited"] as Int? ?? 0) == 1,
                "start_ts_adjusted": managedAny(row["startTsAdjusted"] as Int?),
                "motion_json": managedAny(row["motionJSON"] as String?),
                "sleep_state_json": managedAny(row["sleepStateJSON"] as String?),
                "gravity_sparse": managedAnyBoolean(row["gravitySparse"] as Int?),
                "rr_eligible_window_count": managedAny(row["rrEligibleWindowCount"] as Int?),
                "rr_valid_window_count": managedAny(row["rrValidWindowCount"] as Int?),
            ])
            return [
                .integer(start), .string("\(source):\(row["startTs"] as Int)"),
                .integer(Int64(row["endTs"] as Int) * 1_000), .string(payload),
                .integer(start), .boolean(false),
            ]
        }
        let workout = try managedRows(
            db,
            sql: """
                SELECT * FROM workout
                WHERE deviceId = ? AND startTs >= ? AND startTs < ?
                ORDER BY startTs, sport LIMIT ?
                """,
            arguments: [source, seconds.start, seconds.end, limit]
        ) { row in
            let start = Int64(row["startTs"] as Int) * 1_000
            let sport: String = row["sport"]
            let payload = try managedPayload([
                "sport": sport,
                "source": row["source"] as String,
                "duration_s": managedAny(row["durationS"] as Double?),
                "energy_kcal": managedAny(row["energyKcal"] as Double?),
                "avg_hr": managedAny(row["avgHr"] as Int?),
                "max_hr": managedAny(row["maxHr"] as Int?),
                "strain": managedAny(row["strain"] as Double?),
                "distance_m": managedAny(row["distanceM"] as Double?),
                "zones_json": managedAny(row["zonesJSON"] as String?),
                "notes": managedAny(row["notes"] as String?),
                "steps": managedAny(row["steps"] as Int?),
            ])
            return [
                .integer(start), .string("\(source):\(row["startTs"] as Int):\(sport)"),
                .integer(Int64(row["endTs"] as Int) * 1_000), .string(payload),
                .integer(start), .boolean(false),
            ]
        }
        let live = try managedRows(
            db,
            sql: """
                SELECT * FROM liveSession
                WHERE deviceId = ? AND startTs >= ? AND startTs < ?
                ORDER BY startTs LIMIT ?
                """,
            arguments: [source, seconds.start, seconds.end, limit]
        ) { row in
            let start = Int64(row["startTs"] as Int) * 1_000
            let end: Int? = row["endTs"]
            let payload = try managedPayload([
                "charge_at_start": managedAny(row["chargeAtStart"] as Double?),
                "floor_bpm": row["floorBpm"] as Double,
                "ceiling_bpm": row["ceilingBpm"] as Double,
                "in_band_sec": row["inBandSec"] as Double,
                "below_sec": row["belowSec"] as Double,
                "above_sec": row["aboveSec"] as Double,
                "push_count": row["pushCount"] as Int,
                "ease_count": row["easeCount"] as Int,
                "hr_source": row["hrSource"] as String,
            ])
            return [
                .integer(start), .string("\(source):\(row["startTs"] as Int)"),
                managedInteger(end.map { Int64($0) * 1_000 }), .string(payload),
                .integer(start), .boolean(false),
            ]
        }
        let dailyRows = (daily + platformDaily).sorted {
            let leftTime = $0.first?.integerValue ?? 0
            let rightTime = $1.first?.integerValue ?? 0
            if leftTime != rightTime { return leftTime < rightTime }
            return ($0[safe: 3]?.stringValue ?? "") < ($1[safe: 3]?.stringValue ?? "")
        }
        return [
            ManagedSyncTabularStream(
                streamKey: "daily_metrics",
                columns: [
                    "event_at_ms", "day", "source_id", "payload_json", "updated_at_ms",
                    "deleted",
                ],
                rows: dailyRows
            ),
            ManagedSyncTabularStream(
                streamKey: "metric_series",
                columns: [
                    "event_at_ms", "day", "metric_key", "value", "source_id",
                    "updated_at_ms", "deleted",
                ],
                rows: metrics
            ),
            ManagedSyncTabularStream(
                streamKey: "sleep_summary",
                columns: [
                    "event_at_ms", "record_id", "end_at_ms", "payload_json",
                    "updated_at_ms", "deleted",
                ],
                rows: sleep
            ),
            ManagedSyncTabularStream(
                streamKey: "workout_summary",
                columns: [
                    "event_at_ms", "record_id", "end_at_ms", "payload_json",
                    "updated_at_ms", "deleted",
                ],
                rows: workout
            ),
            ManagedSyncTabularStream(
                streamKey: "live_session",
                columns: [
                    "event_at_ms", "record_id", "end_at_ms", "payload_json",
                    "updated_at_ms", "deleted",
                ],
                rows: live
            ),
        ]
    }

    private static func managedRows(
        _ db: Database,
        sql: String,
        arguments: StatementArguments,
        transform: (Row) throws -> [ManagedSyncCell]
    ) throws -> [[ManagedSyncCell]] {
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        guard rows.count <= managedMaximumRowsPerStream else {
            throw ManagedSyncChunkStoreError.windowTooDense
        }
        return try rows.map(transform)
    }

    private static func managedSecondBounds(
        startMs: Int64,
        endMs: Int64
    ) -> (start: Int64, end: Int64) {
        ((startMs + 999) / 1_000, (endMs + 999) / 1_000)
    }

    private static func managedDayBounds(
        startMs: Int64,
        endMs: Int64
    ) -> (start: String, end: String) {
        (managedDay(startMs), managedDay(endMs))
    }

    private static func managedDay(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    private static func managedDayMilliseconds(_ day: String) throws -> Int64 {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else {
            throw ManagedSyncChunkStoreError.invalidStoredValue
        }
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func managedPayload(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ManagedSyncChunkStoreError.invalidStoredValue
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw ManagedSyncChunkStoreError.invalidStoredValue
        }
        return value
    }

    private static func managedAny<T>(_ value: T?) -> Any {
        value ?? NSNull()
    }

    private static func managedAnyBoolean(_ value: Int?) -> Any {
        value.map { $0 != 0 } ?? NSNull()
    }

    private static func managedInteger(_ value: Int?) -> ManagedSyncCell {
        value.map { .integer(Int64($0)) } ?? .null
    }

    private static func managedInteger(_ value: Int64?) -> ManagedSyncCell {
        value.map(ManagedSyncCell.integer) ?? .null
    }

    private static func managedNumber(_ value: Double?) -> ManagedSyncCell {
        value.map(ManagedSyncCell.number) ?? .null
    }

    private static func managedBoolean(_ value: Int?) -> ManagedSyncCell {
        value.map { .boolean($0 != 0) } ?? .null
    }
}

private extension ManagedSyncCell {
    var integerValue: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
