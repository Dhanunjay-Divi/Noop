import Foundation
import GRDB

/// A HealthKit sample type's exact ownership inside NOOP's shared `apple-health` projection.
///
/// HealthKit deletions arrive as UUID tombstones without timestamps. Instead of guessing a recent window,
/// the iOS bridge re-queries the complete affected *type* and asks this store to atomically clear/rebuild only
/// these owned columns and metric keys. Static Apple-export fields belonging to other types are untouched.
public enum HealthKitProjectionKind: String, Sendable, CaseIterable {
    case restingHeartRate
    case heartRate
    case hrv
    case oxygenSaturation
    case respiratoryRate
    case bodyTemperature
    case wristTemperature
    case steps
    case activeEnergy
    case basalEnergy
    case vo2Max
    case bodyMass
    case bodyFat
    case leanBodyMass
    case bodyMassIndex
    case sleep
    case workout

    fileprivate var metricKeys: Set<String> {
        switch self {
        case .restingHeartRate: return ["resting_hr"]
        case .heartRate: return ["avg_hr", "max_hr"]
        case .hrv: return ["hrv"]
        case .oxygenSaturation: return ["spo2"]
        case .respiratoryRate: return ["resp_rate"]
        case .bodyTemperature: return ["body_temp"]
        case .wristTemperature: return ["wrist_temp"]
        case .steps: return ["steps"]
        case .activeEnergy: return ["active_kcal"]
        case .basalEnergy: return ["basal_kcal"]
        case .vo2Max: return ["vo2max"]
        case .bodyMass: return ["weight"]
        case .bodyFat: return ["body_fat"]
        case .leanBodyMass: return ["lean_mass"]
        case .bodyMassIndex: return ["bmi"]
        case .sleep: return ["asleep_min", "deep_min", "rem_min", "core_min", "awake_min", "in_bed_min"]
        case .workout: return []
        }
    }

    fileprivate var appleColumns: [String] {
        switch self {
        case .heartRate: return ["avgHr", "maxHr"]
        case .steps: return ["steps"]
        case .activeEnergy: return ["activeKcal"]
        case .basalEnergy: return ["basalKcal"]
        case .vo2Max: return ["vo2max"]
        case .bodyMass: return ["weightKg"]
        default: return []
        }
    }

    fileprivate var dailyColumns: [String] {
        switch self {
        case .restingHeartRate: return ["restingHr"]
        case .hrv: return ["avgHrv"]
        case .oxygenSaturation: return ["spo2Pct"]
        case .respiratoryRate: return ["respRateBpm"]
        case .steps: return ["steps"]
        case .sleep: return ["totalSleepMin", "deepMin", "remMin", "lightMin"]
        default: return []
        }
    }
}

extension WhoopStore {
    /// Durable per-type HealthKit observer cursor. Keeping it in SQLite lets a deletion rebuild and cursor
    /// advancement commit as one transaction.
    public func healthKitAnchor(sampleType: String) async throws -> Data? {
        try syncRead { db in
            try Data.fetchOne(
                db,
                sql: "SELECT anchor FROM healthKitSyncState WHERE sampleType = ?",
                arguments: [sampleType]
            )
        }
    }

    /// Commit an additions-only observer cursor after its idempotent aggregate sync completed. Repeating the
    /// aggregate after a crash before this write is safe; the cursor is never advanced before persistence.
    public func commitHealthKitAnchor(sampleType: String, anchor: Data) async throws {
        try syncWrite { db in
            try Self.upsertHealthKitAnchor(
                db, sampleType: sampleType, anchor: anchor, fullReconcile: false
            )
        }
    }

    /// Atomically replace one HealthKit type's complete projection and advance that type's query anchor.
    /// Only columns/metric keys owned by `kind` are cleared; other Health types, imports and other devices
    /// remain byte-for-byte untouched. A thrown write leaves both data and the previous anchor intact.
    public func reconcileHealthKitProjection(
        kind: HealthKitProjectionKind,
        sampleType: String,
        anchor: Data,
        deviceId: String,
        fromDay: String,
        toDay: String,
        fromTs: Int,
        toTs: Int,
        appleRows: [AppleDaily],
        dailyRows: [DailyMetric],
        metricPoints: [MetricPoint],
        workouts: [WorkoutRow]
    ) async throws {
        try syncWrite { db in
            if !kind.appleColumns.isEmpty {
                let assignments = kind.appleColumns.map { "\($0) = NULL" }.joined(separator: ", ")
                try db.execute(
                    sql: "UPDATE appleDaily SET \(assignments) WHERE deviceId = ? AND day >= ? AND day <= ?",
                    arguments: [deviceId, fromDay, toDay]
                )
                for row in appleRows { try Self.upsertHealthKitAppleRow(row, kind: kind, deviceId: deviceId, db: db) }
            }

            if !kind.dailyColumns.isEmpty {
                let assignments = kind.dailyColumns.map { "\($0) = NULL" }.joined(separator: ", ")
                try db.execute(
                    sql: "UPDATE dailyMetric SET \(assignments) WHERE deviceId = ? AND day >= ? AND day <= ?",
                    arguments: [deviceId, fromDay, toDay]
                )
                for row in dailyRows { try Self.upsertHealthKitDailyRow(row, kind: kind, deviceId: deviceId, db: db) }
            }

            for key in kind.metricKeys {
                try db.execute(
                    sql: "DELETE FROM metricSeries WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?",
                    arguments: [deviceId, key, fromDay, toDay]
                )
            }
            let allowedKeys = kind.metricKeys
            for point in metricPoints where allowedKeys.contains(point.key) {
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [deviceId, point.day, point.key, point.value])
            }

            if kind == .workout {
                try db.execute(sql: """
                    DELETE FROM workout
                    WHERE deviceId = ? AND source = 'apple-health' AND startTs >= ? AND startTs < ?
                    """, arguments: [deviceId, fromTs, toTs])
                for row in workouts {
                    try db.execute(sql: """
                        INSERT INTO workout
                            (deviceId, startTs, endTs, sport, source, durationS, energyKcal,
                             avgHr, maxHr, strain, distanceM, zonesJSON, notes, steps)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        """, arguments: [deviceId, row.startTs, row.endTs, row.sport, row.source,
                                         row.durationS, row.energyKcal, row.avgHr, row.maxHr, row.strain,
                                         row.distanceM, row.zonesJSON, row.notes, row.steps])
                }
            }

            // Do not leave empty shells after deleting the last sample of a day. Derived values stored in the
            // same row (for example Apple-Watch recovery) prevent cleanup and are deliberately preserved.
            try db.execute(sql: """
                DELETE FROM appleDaily
                WHERE deviceId = ? AND day >= ? AND day <= ?
                  AND steps IS NULL AND activeKcal IS NULL AND basalKcal IS NULL AND vo2max IS NULL
                  AND avgHr IS NULL AND maxHr IS NULL AND walkingHr IS NULL AND weightKg IS NULL
                """, arguments: [deviceId, fromDay, toDay])
            try db.execute(sql: """
                DELETE FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                  AND totalSleepMin IS NULL AND efficiency IS NULL AND deepMin IS NULL AND remMin IS NULL
                  AND lightMin IS NULL AND disturbances IS NULL AND restingHr IS NULL AND avgHrv IS NULL
                  AND recovery IS NULL AND strain IS NULL AND exerciseCount IS NULL AND spo2Pct IS NULL
                  AND skinTempDevC IS NULL AND respRateBpm IS NULL AND steps IS NULL
                  AND activeKcalEst IS NULL AND spo2Red IS NULL AND spo2Ir IS NULL
                """, arguments: [deviceId, fromDay, toDay])

            try Self.upsertHealthKitAnchor(
                db, sampleType: sampleType, anchor: anchor, fullReconcile: true
            )
        }
    }

    private static func upsertHealthKitAnchor(
        _ db: Database,
        sampleType: String,
        anchor: Data,
        fullReconcile: Bool
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        try db.execute(sql: """
            INSERT INTO healthKitSyncState (sampleType, anchor, updatedAt, lastFullReconcileAt)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(sampleType) DO UPDATE SET
                anchor = excluded.anchor,
                updatedAt = excluded.updatedAt,
                lastFullReconcileAt = COALESCE(excluded.lastFullReconcileAt,
                                               healthKitSyncState.lastFullReconcileAt)
            """, arguments: [sampleType, anchor, now, fullReconcile ? now : nil])
    }

    private static func upsertHealthKitAppleRow(
        _ row: AppleDaily,
        kind: HealthKitProjectionKind,
        deviceId: String,
        db: Database
    ) throws {
        switch kind {
        case .heartRate where row.avgHr != nil || row.maxHr != nil:
            try db.execute(sql: """
                INSERT INTO appleDaily (deviceId, day, avgHr, maxHr) VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET avgHr = excluded.avgHr, maxHr = excluded.maxHr
                """, arguments: [deviceId, row.day, row.avgHr, row.maxHr])
        case .steps where row.steps != nil:
            try db.execute(sql: """
                INSERT INTO appleDaily (deviceId, day, steps) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET steps = excluded.steps
                """, arguments: [deviceId, row.day, row.steps])
        case .activeEnergy where row.activeKcal != nil:
            try db.execute(sql: """
                INSERT INTO appleDaily (deviceId, day, activeKcal) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET activeKcal = excluded.activeKcal
                """, arguments: [deviceId, row.day, row.activeKcal])
        case .basalEnergy where row.basalKcal != nil:
            try db.execute(sql: """
                INSERT INTO appleDaily (deviceId, day, basalKcal) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET basalKcal = excluded.basalKcal
                """, arguments: [deviceId, row.day, row.basalKcal])
        case .vo2Max where row.vo2max != nil:
            try db.execute(sql: """
                INSERT INTO appleDaily (deviceId, day, vo2max) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET vo2max = excluded.vo2max
                """, arguments: [deviceId, row.day, row.vo2max])
        case .bodyMass where row.weightKg != nil:
            try db.execute(sql: """
                INSERT INTO appleDaily (deviceId, day, weightKg) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET weightKg = excluded.weightKg
                """, arguments: [deviceId, row.day, row.weightKg])
        default:
            break
        }
    }

    private static func upsertHealthKitDailyRow(
        _ row: DailyMetric,
        kind: HealthKitProjectionKind,
        deviceId: String,
        db: Database
    ) throws {
        switch kind {
        case .restingHeartRate where row.restingHr != nil:
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, restingHr) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET restingHr = excluded.restingHr
                """, arguments: [deviceId, row.day, row.restingHr])
        case .hrv where row.avgHrv != nil:
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, avgHrv) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET avgHrv = excluded.avgHrv
                """, arguments: [deviceId, row.day, row.avgHrv])
        case .oxygenSaturation where row.spo2Pct != nil:
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, spo2Pct) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET spo2Pct = excluded.spo2Pct
                """, arguments: [deviceId, row.day, row.spo2Pct])
        case .respiratoryRate where row.respRateBpm != nil:
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, respRateBpm) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET respRateBpm = excluded.respRateBpm
                """, arguments: [deviceId, row.day, row.respRateBpm])
        case .steps where row.steps != nil:
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, steps) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET steps = excluded.steps
                """, arguments: [deviceId, row.day, row.steps])
        case .sleep where row.totalSleepMin != nil || row.deepMin != nil || row.remMin != nil || row.lightMin != nil:
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, totalSleepMin, deepMin, remMin, lightMin)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET
                    totalSleepMin = excluded.totalSleepMin,
                    deepMin = excluded.deepMin,
                    remMin = excluded.remMin,
                    lightMin = excluded.lightMin
                """, arguments: [deviceId, row.day, row.totalSleepMin, row.deepMin, row.remMin, row.lightMin])
        default:
            break
        }
    }
}
