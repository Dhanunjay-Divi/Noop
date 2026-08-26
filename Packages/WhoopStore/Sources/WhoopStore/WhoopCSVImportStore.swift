import Foundation
import GRDB

/// One authoritative metric-series range represented by an official CSV export.
public struct WhoopCSVMetricSeriesReplacement: Sendable {
    public let rows: [MetricPoint]
    public let deviceId: String
    public let from: String
    public let to: String
    public let managedKeys: Set<String>

    public init(
        rows: [MetricPoint],
        deviceId: String,
        from: String,
        to: String,
        managedKeys: Set<String>
    ) {
        self.rows = rows
        self.deviceId = deviceId
        self.from = from
        self.to = to
        self.managedKeys = managedKeys
    }
}

/// One authoritative journal range represented by an official CSV export.
public struct WhoopCSVJournalReplacement: Sendable {
    public let rows: [JournalEntry]
    public let deviceId: String
    public let from: String
    public let to: String

    public init(rows: [JournalEntry], deviceId: String, from: String, to: String) {
        self.rows = rows
        self.deviceId = deviceId
        self.from = from
        self.to = to
    }
}

/// Inclusive day span owned by one official CSV projection.
public struct WhoopCSVDayRange: Equatable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Inclusive timestamp span owned by one official CSV projection.
public struct WhoopCSVTimestampRange: Equatable, Sendable {
    public let from: Int
    public let to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// The complete relational projection of one parsed CSV bundle.
///
/// Official rows remain authoritative. Local/approximate daily rows fill null fields and absent rows;
/// other local projections are insert-only. Their target `-noop` namespace is also owned by on-device
/// analytics, whose newer values must never be replaced by a portable export round-trip.
public struct WhoopCSVImportBatch: Sendable {
    public let officialDailyMetrics: [DailyMetric]
    public let officialDailyMetricRange: WhoopCSVDayRange?
    public let fillOnlyDailyMetrics: [DailyMetric]
    public let officialSleepSessions: [CachedSleepSession]
    public let officialSleepSessionRange: WhoopCSVTimestampRange?
    public let fillOnlySleepSessions: [CachedSleepSession]
    public let officialMetricSeriesReplacements: [WhoopCSVMetricSeriesReplacement]
    public let fillOnlyMetricSeries: [MetricPoint]
    public let journalReplacement: WhoopCSVJournalReplacement?
    public let officialWorkouts: [WorkoutRow]
    public let officialWorkoutRange: WhoopCSVTimestampRange?
    public let fillOnlyWorkouts: [WorkoutRow]
    public let officialDeviceId: String
    public let fillOnlyDeviceId: String
    public let officialWorkoutSource: String

    public init(
        officialDailyMetrics: [DailyMetric],
        officialDailyMetricRange: WhoopCSVDayRange? = nil,
        fillOnlyDailyMetrics: [DailyMetric],
        officialSleepSessions: [CachedSleepSession],
        officialSleepSessionRange: WhoopCSVTimestampRange? = nil,
        fillOnlySleepSessions: [CachedSleepSession],
        officialMetricSeriesReplacements: [WhoopCSVMetricSeriesReplacement],
        fillOnlyMetricSeries: [MetricPoint],
        journalReplacement: WhoopCSVJournalReplacement?,
        officialWorkouts: [WorkoutRow],
        officialWorkoutRange: WhoopCSVTimestampRange? = nil,
        fillOnlyWorkouts: [WorkoutRow],
        officialDeviceId: String,
        fillOnlyDeviceId: String,
        officialWorkoutSource: String = "whoop"
    ) {
        self.officialDailyMetrics = officialDailyMetrics
        self.officialDailyMetricRange = officialDailyMetricRange
        self.fillOnlyDailyMetrics = fillOnlyDailyMetrics
        self.officialSleepSessions = officialSleepSessions
        self.officialSleepSessionRange = officialSleepSessionRange
        self.fillOnlySleepSessions = fillOnlySleepSessions
        self.officialMetricSeriesReplacements = officialMetricSeriesReplacements
        self.fillOnlyMetricSeries = fillOnlyMetricSeries
        self.journalReplacement = journalReplacement
        self.officialWorkouts = officialWorkouts
        self.officialWorkoutRange = officialWorkoutRange
        self.fillOnlyWorkouts = fillOnlyWorkouts
        self.officialDeviceId = officialDeviceId
        self.fillOnlyDeviceId = fillOnlyDeviceId
        let trimmedWorkoutSource = officialWorkoutSource.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.officialWorkoutSource = trimmedWorkoutSource.isEmpty ? "whoop" : trimmedWorkoutSource
    }
}

public struct WhoopCSVImportWriteCounts: Equatable, Sendable {
    public let dailyMetrics: Int
    public let sleepSessions: Int
    public let metricSeries: Int
    public let journal: Int
    public let workouts: Int
}

extension WhoopStore {
    /// Commit the complete CSV projection in one SQLite transaction.
    ///
    /// The optional portable-user-data sidecar has its own graph-validation transaction and is not
    /// included here. Combining those independent import surfaces would require a wider store refactor.
    public func importWhoopCSV(_ batch: WhoopCSVImportBatch) async throws -> WhoopCSVImportWriteCounts {
        try syncWrite { db in
            var dailyMetrics = 0
            var sleepSessions = 0
            var metricSeries = 0
            var journal = 0
            var workouts = 0

            if let range = batch.officialDailyMetricRange, range.from <= range.to {
                try db.execute(
                    sql: """
                        DELETE FROM dailyMetric
                        WHERE deviceId = ? AND day >= ? AND day <= ?
                    """,
                    arguments: [batch.officialDeviceId, range.from, range.to]
                )
            }
            dailyMetrics += try Self.writeCSVImportDailyMetrics(
                batch.officialDailyMetrics,
                deviceId: batch.officialDeviceId,
                fillOnly: false,
                db: db
            )
            dailyMetrics += try Self.writeCSVImportDailyMetrics(
                batch.fillOnlyDailyMetrics,
                deviceId: batch.fillOnlyDeviceId,
                fillOnly: true,
                db: db
            )
            if let range = batch.officialSleepSessionRange, range.from <= range.to {
                // Imported rows carry no raw motion/state evidence. Preserve locally measured rows and
                // user edits; only the provider-owned projection is authoritative in this range.
                try db.execute(
                    sql: """
                        DELETE FROM sleepSession
                        WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                          AND userEdited = 0
                          AND motionJSON IS NULL
                          AND sleepStateJSON IS NULL
                          AND gravitySparse IS NULL
                          AND rrEligibleWindowCount IS NULL
                          AND rrValidWindowCount IS NULL
                    """,
                    arguments: [batch.officialDeviceId, range.from, range.to]
                )
            }
            sleepSessions += try Self.writeCSVImportSleepSessions(
                batch.officialSleepSessions,
                deviceId: batch.officialDeviceId,
                fillOnly: false,
                db: db
            )
            sleepSessions += try Self.writeCSVImportSleepSessions(
                batch.fillOnlySleepSessions,
                deviceId: batch.fillOnlyDeviceId,
                fillOnly: true,
                db: db
            )

            for replacement in batch.officialMetricSeriesReplacements {
                metricSeries += try Self.replaceCSVImportMetricSeries(replacement, db: db)
            }
            metricSeries += try Self.writeCSVImportMetricSeries(
                batch.fillOnlyMetricSeries,
                deviceId: batch.fillOnlyDeviceId,
                fillOnly: true,
                db: db
            )

            if let replacement = batch.journalReplacement, replacement.from <= replacement.to {
                try db.execute(
                    sql: """
                        DELETE FROM journal
                        WHERE deviceId = ? AND day >= ? AND day <= ?
                    """,
                    arguments: [replacement.deviceId, replacement.from, replacement.to]
                )
                for row in replacement.rows {
                    try db.execute(sql: """
                        INSERT INTO journal
                            (deviceId, day, question, answeredYes, notes, numericValue)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceId, day, question) DO UPDATE SET
                            answeredYes = excluded.answeredYes,
                            notes = excluded.notes,
                            numericValue = excluded.numericValue
                        """, arguments: [
                            replacement.deviceId, row.day, row.question,
                            row.answeredYes ? 1 : 0, row.notes, row.numericValue,
                        ])
                    journal += db.changesCount
                }
            }

            // Workouts are intentionally last. A malformed row or persistence constraint still rolls
            // back every earlier daily/sleep/range write in this transaction.
            if let range = batch.officialWorkoutRange, range.from <= range.to {
                try db.execute(
                    sql: """
                        DELETE FROM workout
                        WHERE deviceId = ? AND source = ?
                          AND startTs >= ? AND startTs <= ?
                        """,
                    arguments: [
                        batch.officialDeviceId, batch.officialWorkoutSource,
                        range.from, range.to,
                    ]
                )
            }
            workouts += try Self.writeCSVImportWorkouts(
                batch.officialWorkouts,
                deviceId: batch.officialDeviceId,
                fillOnly: false,
                sourceOverride: batch.officialWorkoutSource,
                db: db
            )
            workouts += try Self.writeCSVImportWorkouts(
                batch.fillOnlyWorkouts,
                deviceId: batch.fillOnlyDeviceId,
                fillOnly: true,
                db: db
            )

            return WhoopCSVImportWriteCounts(
                dailyMetrics: dailyMetrics,
                sleepSessions: sleepSessions,
                metricSeries: metricSeries,
                journal: journal,
                workouts: workouts
            )
        }
    }

    private static func writeCSVImportDailyMetrics(
        _ rows: [DailyMetric],
        deviceId: String,
        fillOnly: Bool,
        db: Database
    ) throws -> Int {
        let conflict = fillOnly ? """
            DO UPDATE SET
                totalSleepMin = COALESCE(dailyMetric.totalSleepMin, excluded.totalSleepMin),
                efficiency = COALESCE(dailyMetric.efficiency, excluded.efficiency),
                deepMin = COALESCE(dailyMetric.deepMin, excluded.deepMin),
                remMin = COALESCE(dailyMetric.remMin, excluded.remMin),
                lightMin = COALESCE(dailyMetric.lightMin, excluded.lightMin),
                disturbances = COALESCE(dailyMetric.disturbances, excluded.disturbances),
                restingHr = COALESCE(dailyMetric.restingHr, excluded.restingHr),
                avgHrv = COALESCE(dailyMetric.avgHrv, excluded.avgHrv),
                recovery = COALESCE(dailyMetric.recovery, excluded.recovery),
                strain = COALESCE(dailyMetric.strain, excluded.strain),
                exerciseCount = COALESCE(dailyMetric.exerciseCount, excluded.exerciseCount),
                spo2Pct = COALESCE(dailyMetric.spo2Pct, excluded.spo2Pct),
                skinTempDevC = COALESCE(dailyMetric.skinTempDevC, excluded.skinTempDevC),
                respRateBpm = COALESCE(dailyMetric.respRateBpm, excluded.respRateBpm),
                steps = COALESCE(dailyMetric.steps, excluded.steps),
                activeKcalEst = COALESCE(dailyMetric.activeKcalEst, excluded.activeKcalEst),
                spo2Red = COALESCE(dailyMetric.spo2Red, excluded.spo2Red),
                spo2Ir = COALESCE(dailyMetric.spo2Ir, excluded.spo2Ir),
                hrvMethod = CASE
                    WHEN dailyMetric.avgHrv IS NULL THEN excluded.hrvMethod
                    ELSE dailyMetric.hrvMethod
                END
            """ : """
            DO UPDATE SET
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
            """
        var changed = 0
        for row in rows {
            try db.execute(sql: """
                INSERT INTO dailyMetric
                    (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                     disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                     spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst, spo2Red, spo2Ir,
                     hrvMethod)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, day) \(conflict)
                """, arguments: [
                    deviceId, row.day, finite(row.totalSleepMin), finite(row.efficiency),
                    finite(row.deepMin), finite(row.remMin), finite(row.lightMin),
                    row.disturbances, row.restingHr, finite(row.avgHrv), finite(row.recovery),
                    finite(row.strain), row.exerciseCount, finite(row.spo2Pct),
                    finite(row.skinTempDevC), finite(row.respRateBpm), row.steps,
                    finite(row.activeKcalEst), row.spo2Red, row.spo2Ir,
                    row.avgHrv == nil ? nil : row.hrvMethod?.rawValue,
                ])
            changed += db.changesCount
        }
        return changed
    }

    private static func writeCSVImportSleepSessions(
        _ rows: [CachedSleepSession],
        deviceId: String,
        fillOnly: Bool,
        db: Database
    ) throws -> Int {
        let conflict = fillOnly ? "DO NOTHING" : """
            DO UPDATE SET
                endTs = CASE WHEN sleepSession.userEdited THEN sleepSession.endTs ELSE excluded.endTs END,
                efficiency = CASE
                    WHEN sleepSession.userEdited THEN sleepSession.efficiency
                    ELSE excluded.efficiency
                END,
                restingHr = CASE
                    WHEN sleepSession.userEdited THEN sleepSession.restingHr
                    ELSE excluded.restingHr
                END,
                avgHrv = CASE
                    WHEN sleepSession.userEdited THEN sleepSession.avgHrv
                    ELSE excluded.avgHrv
                END,
                stagesJSON = CASE
                    WHEN sleepSession.userEdited THEN sleepSession.stagesJSON
                    ELSE excluded.stagesJSON
                END,
                startTsAdjusted = CASE
                    WHEN sleepSession.userEdited THEN sleepSession.startTsAdjusted
                    ELSE excluded.startTsAdjusted
                END,
                gravitySparse = COALESCE(sleepSession.gravitySparse, excluded.gravitySparse),
                rrEligibleWindowCount = excluded.rrEligibleWindowCount,
                rrValidWindowCount = excluded.rrValidWindowCount,
                userEdited = sleepSession.userEdited
            """
        var changed = 0
        for row in rows {
            try db.execute(sql: """
                INSERT INTO sleepSession
                    (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                     userEdited, startTsAdjusted, gravitySparse,
                     rrEligibleWindowCount, rrValidWindowCount)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, startTs) \(conflict)
                """, arguments: [
                    deviceId, row.startTs, row.endTs, finite(row.efficiency), row.restingHr,
                    finite(row.avgHrv), row.stagesJSON, row.userEdited, row.startTsAdjusted,
                    row.gravitySparse, row.rrEligibleWindowCount, row.rrValidWindowCount,
                ])
            changed += db.changesCount
        }
        return changed
    }

    private static func replaceCSVImportMetricSeries(
        _ replacement: WhoopCSVMetricSeriesReplacement,
        db: Database
    ) throws -> Int {
        let keys = replacement.managedKeys.filter { !$0.isEmpty }.sorted()
        guard replacement.from <= replacement.to, !keys.isEmpty else { return 0 }
        let allowedKeys = Set(keys)
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        try db.execute(
            sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND day >= ? AND day <= ?
                  AND key IN (\(placeholders))
                """,
            arguments: StatementArguments(
                [replacement.deviceId, replacement.from, replacement.to] + keys
            )
        )
        return try writeCSVImportMetricSeries(
            replacement.rows.filter {
                $0.day >= replacement.from
                    && $0.day <= replacement.to
                    && allowedKeys.contains($0.key)
            },
            deviceId: replacement.deviceId,
            fillOnly: false,
            db: db
        )
    }

    private static func writeCSVImportMetricSeries(
        _ rows: [MetricPoint],
        deviceId: String,
        fillOnly: Bool,
        db: Database
    ) throws -> Int {
        let conflict = fillOnly ? "DO NOTHING" : "DO UPDATE SET value = excluded.value"
        var changed = 0
        for row in rows {
            guard let value = normalizedMetricSeriesValue(row.value, forKey: row.key) else {
                continue
            }
            try db.execute(sql: """
                INSERT INTO metricSeries (deviceId, day, key, value)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceId, day, key) \(conflict)
                """, arguments: [deviceId, row.day, row.key, value])
            changed += db.changesCount
        }
        return changed
    }

    private static func writeCSVImportWorkouts(
        _ rows: [WorkoutRow],
        deviceId: String,
        fillOnly: Bool,
        sourceOverride: String? = nil,
        db: Database
    ) throws -> Int {
        let conflict = fillOnly ? "DO NOTHING" : """
            DO UPDATE SET
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
            WHERE workout.source = excluded.source
            """
        var changed = 0
        for row in rows {
            try db.execute(sql: """
                INSERT INTO workout
                    (deviceId, startTs, endTs, sport, source, durationS, energyKcal,
                     avgHr, maxHr, strain, distanceM, zonesJSON, notes, steps)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, startTs, sport) \(conflict)
                """, arguments: [
                    deviceId, row.startTs, row.endTs, row.sport, sourceOverride ?? row.source,
                    finite(row.durationS), finite(row.energyKcal), row.avgHr, row.maxHr,
                    finite(row.strain), finite(row.distanceM),
                    row.zonesJSON, row.notes, row.steps,
                ])
            changed += db.changesCount
        }
        return changed
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
