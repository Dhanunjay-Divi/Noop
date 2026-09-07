import Foundation
import WhoopProtocol
import WhoopStore

public struct HistoryDatasetPlan: Codable, Equatable, Sendable {
    public let requestedDays: Int
    public let rawHistoryDays: Int
    public let essentialHistoryDays: Int
    public let aggregateHistoryDays: Int

    public init(requestedDays: Int) {
        self.requestedDays = requestedDays
        rawHistoryDays = min(requestedDays, 7)
        essentialHistoryDays = min(requestedDays, 30)
        aggregateHistoryDays = requestedDays
    }
}

public struct HistoryTiming: Codable, Equatable, Sendable {
    public let operation: String
    public let milliseconds: Double
    public let resultCount: Int?

    public init(operation: String, milliseconds: Double, resultCount: Int? = nil) {
        self.operation = operation
        self.milliseconds = milliseconds
        self.resultCount = resultCount
    }
}

public struct HistoryStorageObject: Codable, Equatable, Sendable {
    public let table: String
    public let bytes: Int64
}

public struct HistoryScenarioReport: Codable, Equatable, Sendable {
    public let plan: HistoryDatasetPlan
    public let insertedRows: Int
    public let decodedRows: Int
    public let rawOutboxBatches: Int
    public let rawOutboxLogicalBytes: Int
    public let databaseBytesBeforeCheckpoint: Int64
    public let walBytesBeforeCheckpoint: Int64
    public let databaseBytesAfterCheckpoint: Int64
    public let walBytesAfterCheckpoint: Int64
    public let backupBytes: Int64
    public let exportBytes: Int64
    public let temporaryPeakBytes: Int64
    public let availableVolumeBytes: Int64?
    public let topStorageObjects: [HistoryStorageObject]
    public let timings: [HistoryTiming]
    public let backupIntegrityPassed: Bool
    public let restoreVerificationPassed: Bool
    public let restoreContentChecks: [String]
    public let temporaryDatabaseRemoved: Bool
}

public struct HistoryHarnessReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let fixtureEndExclusiveUTC: String
    public let profile: String
    public let limitations: [String]
    public let scenarios: [HistoryScenarioReport]
}

public enum HistoryHarness {
    public static let supportedDays = [10, 30, 90, 365]
    public static let profileName =
        "managed-validation-candidate: 7-day raw, 30-day essential, full compact history"

    private static let secondsPerDay = 86_400
    private static let fixedEndExclusive = 1_788_739_200 // 2026-09-07T00:00:00Z
    private static let deviceID = "history-harness-wearable"
    private static let metricKeys = [
        "recovery", "effort", "rest", "sleep_total_min", "sleep_efficiency",
        "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "resting_hr",
        "hrv_rmssd", "resp_rate", "skin_temp_deviation", "steps", "active_kcal",
        "workout_minutes", "zone_1_minutes", "zone_2_minutes", "zone_3_minutes",
        "zone_4_minutes", "zone_5_minutes", "fitness_age", "vitality",
        "stress_load", "hydration_logs",
    ]

    public static func plan(days: Int) throws -> HistoryDatasetPlan {
        guard supportedDays.contains(days) else {
            throw HistoryHarnessError.unsupportedDays(days)
        }
        return HistoryDatasetPlan(requestedDays: days)
    }

    public static func run(
        days: [Int],
        keepTemporaryDatabases: Bool = false,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> HistoryHarnessReport {
        let normalized = Array(Set(days)).sorted()
        guard !normalized.isEmpty else { throw HistoryHarnessError.noScenarios }
        for dayCount in normalized {
            _ = try plan(days: dayCount)
        }

        var reports: [HistoryScenarioReport] = []
        for dayCount in normalized {
            progress("history-harness: starting \(dayCount)-day scenario")
            reports.append(
                try await runScenario(
                    plan: try plan(days: dayCount),
                    keepTemporaryDatabase: keepTemporaryDatabases,
                    progress: progress
                )
            )
        }
        return HistoryHarnessReport(
            schemaVersion: 2,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            fixtureEndExclusiveUTC: "2026-09-07T00:00:00Z",
            profile: profileName,
            limitations: [
                "All values and identities are deterministic synthetic fixtures.",
                "Host timings do not prove iPhone or Android physical-device performance, memory, thermal, battery, background survival, or BLE reliability.",
                "The retention profile measures existing managed-sync policy; it does not authorize pruning unless the exact server window is validated and unchanged.",
                "Population accuracy and sensor calibration require approved physical references and held-out participants.",
            ],
            scenarios: reports
        )
    }

    private static func runScenario(
        plan: HistoryDatasetPlan,
        keepTemporaryDatabase: Bool,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> HistoryScenarioReport {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(
            "noop-history-harness-\(plan.requestedDays)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let backupURL = directory.appendingPathComponent("history-backup.sqlite")
        let restoredURL = directory.appendingPathComponent("history-restored.sqlite")
        let safetyURL = directory.appendingPathComponent(
            "whoop-replaced-history-\(plan.requestedDays).sqlite"
        )

        var timings: [HistoryTiming] = []
        var insertedRows = 0
        var exportBytes: Int64 = 0
        var backupBytes: Int64 = 0
        var temporaryPeakBytes: Int64 = 0
        var backupIntegrityPassed = false
        var restoreVerificationPassed = false
        var restoreContentChecks: [String] = []
        var decodedRows = 0
        var rawBatches = 0
        var rawBytes = 0
        var databaseBytesBeforeCheckpoint: Int64 = 0
        var walBytesBeforeCheckpoint: Int64 = 0
        var databaseBytesAfterCheckpoint: Int64 = 0
        var walBytesAfterCheckpoint: Int64 = 0
        var topObjects: [HistoryStorageObject] = []

        let store = try await WhoopStore(path: databaseURL.path)
        try await store.upsertDevice(id: deviceID, mac: nil, name: "Synthetic wearable")

        let aggregate = try await measured("aggregate-write") {
            try await insertAggregateHistory(store: store, plan: plan)
        }
        insertedRows += aggregate.value
        timings.append(HistoryTiming(
            operation: "aggregate-write",
            milliseconds: aggregate.milliseconds,
            resultCount: aggregate.value
        ))
        progress("history-harness: \(plan.requestedDays)d aggregate history written")

        let streams = try await measured("stream-write") {
            try await insertStreams(store: store, plan: plan, progress: progress)
        }
        insertedRows += streams.value
        timings.append(HistoryTiming(
            operation: "stream-write",
            milliseconds: streams.milliseconds,
            resultCount: streams.value
        ))

        let raw = try await measured("raw-outbox-write-and-prune") {
            try await insertBoundedRawOutbox(store: store, plan: plan)
        }
        timings.append(HistoryTiming(
            operation: "raw-outbox-write-and-prune",
            milliseconds: raw.milliseconds,
            resultCount: raw.value
        ))

        let stats = try await store.storageStats()
        decodedRows = stats.decodedRows
        rawBatches = stats.rawBatches
        rawBytes = stats.rawBytes
        databaseBytesBeforeCheckpoint = await store.databaseFileSizeBytes() ?? 0
        walBytesBeforeCheckpoint = fileSize(databaseURL.path + "-wal")
        temporaryPeakBytes = max(temporaryPeakBytes, directorySize(directory))

        let queryStart = fixedEndExclusive - secondsPerDay
        let queryEnd = fixedEndExclusive - 1
        let oldestDay = dayKey(fixedEndExclusive - plan.aggregateHistoryDays * secondsPerDay)
        let newestDay = dayKey(fixedEndExclusive - 1)

        let daily = try await measured("calendar-daily-history-read") {
            try await store.dailyMetrics(deviceId: deviceID, from: oldestDay, to: newestDay)
        }
        timings.append(HistoryTiming(
            operation: "calendar-daily-history-read",
            milliseconds: daily.milliseconds,
            resultCount: daily.value.count
        ))

        let dayMetrics = try await measured("calendar-selected-day-read") {
            try await store.metricSeries(day: newestDay)
        }
        timings.append(HistoryTiming(
            operation: "calendar-selected-day-read",
            milliseconds: dayMetrics.milliseconds,
            resultCount: dayMetrics.value.count
        ))

        let metric = try await measured("metric-trend-read") {
            try await store.metricSeries(
                deviceId: deviceID,
                key: "recovery",
                from: oldestDay,
                to: newestDay
            )
        }
        timings.append(HistoryTiming(
            operation: "metric-trend-read",
            milliseconds: metric.milliseconds,
            resultCount: metric.value.count
        ))

        let buckets = try await measured("day-heart-rate-bucket-read") {
            try await store.hrBuckets(
                deviceId: deviceID,
                from: queryStart,
                to: queryEnd,
                bucketSeconds: 300
            )
        }
        timings.append(HistoryTiming(
            operation: "day-heart-rate-bucket-read",
            milliseconds: buckets.milliseconds,
            resultCount: buckets.value.count
        ))

        let fingerprint = try await measured("analysis-fingerprint-read") {
            try await store.analysisFingerprint(
                deviceId: deviceID,
                from: queryStart,
                to: queryEnd
            )
        }
        timings.append(HistoryTiming(
            operation: "analysis-fingerprint-read",
            milliseconds: fingerprint.milliseconds,
            resultCount: fingerprint.value.count
        ))

        let storageBreakdown = await measuredValue("storage-breakdown-read") {
            await store.databaseStorageBreakdown()
        }
        timings.append(HistoryTiming(
            operation: "storage-breakdown-read",
            milliseconds: storageBreakdown.milliseconds,
            resultCount: storageBreakdown.value?.objects.count
        ))
        topObjects = storageBreakdown.value?.objects.prefix(12).map {
            HistoryStorageObject(table: $0.tableName, bytes: $0.bytes)
        } ?? []

        let exported = try await measured("raw-csv-export-24h") {
            try await store.exportRawCSV(
                deviceId: deviceID,
                since: TimeInterval(queryStart)
            )
        }
        let sourceExportData = try Data(contentsOf: exported.value)
        exportBytes = fileSize(exported.value.path)
        temporaryPeakBytes = max(
            temporaryPeakBytes,
            directorySize(directory) + exportBytes
        )
        timings.append(HistoryTiming(
            operation: "raw-csv-export-24h",
            milliseconds: exported.milliseconds,
            resultCount: Int(exportBytes)
        ))
        try? fm.removeItem(at: exported.value)

        let checkpoint = try await measured("wal-checkpoint") {
            try await store.checkpointWAL()
        }
        timings.append(HistoryTiming(
            operation: "wal-checkpoint",
            milliseconds: checkpoint.milliseconds
        ))
        databaseBytesAfterCheckpoint = await store.databaseFileSizeBytes() ?? 0
        walBytesAfterCheckpoint = fileSize(databaseURL.path + "-wal")

        let backup = try await measured("verified-backup-copy") {
            try fm.copyItem(at: databaseURL, to: backupURL)
            if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: backupURL.path) {
                throw HistoryHarnessError.integrityFailure(complaint)
            }
        }
        backupBytes = fileSize(backupURL.path)
        backupIntegrityPassed = true
        temporaryPeakBytes = max(temporaryPeakBytes, directorySize(directory))
        timings.append(HistoryTiming(
            operation: "verified-backup-copy",
            milliseconds: backup.milliseconds,
            resultCount: Int(backupBytes)
        ))

        let stage = try await measured("restore-stage") {
            try PendingDatabaseRestore.stage(
                databaseAt: backupURL.path,
                settingsJSON: nil,
                forDatabaseAt: restoredURL.path,
                safetySnapshot: safetyURL
            )
        }
        timings.append(HistoryTiming(
            operation: "restore-stage",
            milliseconds: stage.milliseconds
        ))
        temporaryPeakBytes = max(temporaryPeakBytes, directorySize(directory))

        let restoreContext = RestoreVerificationContext(
            sourceStore: store,
            restoredURL: restoredURL,
            plan: plan,
            expectedDecodedRows: stats.decodedRows,
            expectedRawBatches: stats.rawBatches,
            expectedRawBytes: stats.rawBytes,
            expectedDaily: daily.value,
            expectedDayMetrics: dayMetrics.value,
            expectedRawExportData: sourceExportData,
            oldestDay: oldestDay,
            newestDay: newestDay,
            queryStart: queryStart
        )
        let restore = try await measured("restore-open-and-verify") {
            try await verifyRestore(context: restoreContext)
        }
        restoreVerificationPassed = true
        restoreContentChecks = restore.value.checks
        temporaryPeakBytes = max(temporaryPeakBytes, directorySize(directory))
        timings.append(HistoryTiming(
            operation: "restore-open-and-verify",
            milliseconds: restore.milliseconds,
            resultCount: restore.value.resultCount
        ))

        let available = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage.map { Int64($0) }

        if !keepTemporaryDatabase {
            try? fm.removeItem(at: directory)
        }
        let removed = !fm.fileExists(atPath: directory.path)
        progress("history-harness: completed \(plan.requestedDays)-day scenario")

        return HistoryScenarioReport(
            plan: plan,
            insertedRows: insertedRows,
            decodedRows: decodedRows,
            rawOutboxBatches: rawBatches,
            rawOutboxLogicalBytes: rawBytes,
            databaseBytesBeforeCheckpoint: databaseBytesBeforeCheckpoint,
            walBytesBeforeCheckpoint: walBytesBeforeCheckpoint,
            databaseBytesAfterCheckpoint: databaseBytesAfterCheckpoint,
            walBytesAfterCheckpoint: walBytesAfterCheckpoint,
            backupBytes: backupBytes,
            exportBytes: exportBytes,
            temporaryPeakBytes: temporaryPeakBytes,
            availableVolumeBytes: available ?? nil,
            topStorageObjects: topObjects,
            timings: timings,
            backupIntegrityPassed: backupIntegrityPassed,
            restoreVerificationPassed: restoreVerificationPassed,
            restoreContentChecks: restoreContentChecks,
            temporaryDatabaseRemoved: keepTemporaryDatabase ? false : removed
        )
    }

    private struct RestoreVerification {
        let resultCount: Int
        let checks: [String]
    }

    private struct RestoreVerificationContext {
        let sourceStore: WhoopStore
        let restoredURL: URL
        let plan: HistoryDatasetPlan
        let expectedDecodedRows: Int
        let expectedRawBatches: Int
        let expectedRawBytes: Int
        let expectedDaily: [DailyMetric]
        let expectedDayMetrics: [SourcedMetricPoint]
        let expectedRawExportData: Data
        let oldestDay: String
        let newestDay: String
        let queryStart: Int
    }

    private static func verifyRestore(
        context: RestoreVerificationContext
    ) async throws -> RestoreVerification {
        let restored = try await WhoopStore(path: context.restoredURL.path)
        let restoredStats = try await restored.storageStats()
        let restoredDaily = try await restored.dailyMetrics(
            deviceId: deviceID,
            from: context.oldestDay,
            to: context.newestDay
        )

        var checks: [String] = []
        guard restoredStats.decodedRows == context.expectedDecodedRows,
              restoredStats.rawBatches == context.expectedRawBatches,
              restoredStats.rawBytes == context.expectedRawBytes else {
            throw HistoryHarnessError.restoreContentMismatch("storage-stats")
        }
        checks.append("storage-stats")
        try requireRestoreEquality(
            restoredDaily,
            context.expectedDaily,
            check: "daily-metrics",
            completed: &checks
        )

        let restoredDayMetrics = try await restored.metricSeries(day: context.newestDay)
        try requireRestoreEquality(
            restoredDayMetrics,
            context.expectedDayMetrics,
            check: "selected-day-metric-series",
            completed: &checks
        )

        let sourceStore = context.sourceStore
        let sourceMetricKeys = try await sourceStore.metricKeys(deviceId: deviceID)
        let restoredMetricKeys = try await restored.metricKeys(deviceId: deviceID)
        try requireRestoreEquality(
            restoredMetricKeys,
            sourceMetricKeys,
            check: "metric-series-keys",
            completed: &checks
        )
        for key in sourceMetricKeys {
            let sourcePoints = try await sourceStore.metricSeries(
                deviceId: deviceID,
                key: key,
                from: context.oldestDay,
                to: context.newestDay
            )
            let restoredPoints = try await restored.metricSeries(
                deviceId: deviceID,
                key: key,
                from: context.oldestDay,
                to: context.newestDay
            )
            guard restoredPoints == sourcePoints else {
                throw HistoryHarnessError.restoreContentMismatch(
                    "metric-series:\(key)"
                )
            }
        }
        checks.append("metric-series-all-values")

        let aggregateStart =
            fixedEndExclusive - context.plan.aggregateHistoryDays * secondsPerDay
        let sourceSleeps = try await sourceStore.sleepSessions(
            deviceId: deviceID,
            from: aggregateStart - secondsPerDay,
            to: fixedEndExclusive - 1,
            limit: 10_000
        )
        let restoredSleeps = try await restored.sleepSessions(
            deviceId: deviceID,
            from: aggregateStart - secondsPerDay,
            to: fixedEndExclusive - 1,
            limit: 10_000
        )
        try requireRestoreEquality(
            restoredSleeps,
            sourceSleeps,
            check: "sleep-sessions",
            completed: &checks
        )

        let sourceJournal = try await sourceStore.journalEntries(
            deviceId: deviceID,
            from: context.oldestDay,
            to: context.newestDay
        )
        let restoredJournal = try await restored.journalEntries(
            deviceId: deviceID,
            from: context.oldestDay,
            to: context.newestDay
        )
        try requireRestoreEquality(
            restoredJournal,
            sourceJournal,
            check: "journal-entries",
            completed: &checks
        )

        let sourceWorkouts = try await sourceStore.workouts(
            deviceId: deviceID,
            from: aggregateStart,
            to: fixedEndExclusive - 1,
            limit: 10_000
        )
        let restoredWorkouts = try await restored.workouts(
            deviceId: deviceID,
            from: aggregateStart,
            to: fixedEndExclusive - 1,
            limit: 10_000
        )
        try requireRestoreEquality(
            restoredWorkouts,
            sourceWorkouts,
            check: "workouts",
            completed: &checks
        )

        let sourceApple = try await sourceStore.appleDaily(
            deviceId: deviceID,
            from: context.oldestDay,
            to: context.newestDay
        )
        let restoredApple = try await restored.appleDaily(
            deviceId: deviceID,
            from: context.oldestDay,
            to: context.newestDay
        )
        try requireRestoreEquality(
            restoredApple,
            sourceApple,
            check: "apple-daily",
            completed: &checks
        )

        let essentialStart =
            fixedEndExclusive - context.plan.essentialHistoryDays * secondsPerDay
        let sourceBattery = try await sourceStore.batterySamples(
            deviceId: deviceID,
            from: essentialStart,
            to: fixedEndExclusive - 1,
            limit: 1_000_000
        )
        let restoredBattery = try await restored.batterySamples(
            deviceId: deviceID,
            from: essentialStart,
            to: fixedEndExclusive - 1,
            limit: 1_000_000
        )
        try requireRestoreEquality(
            restoredBattery,
            sourceBattery,
            check: "battery-samples",
            completed: &checks
        )

        let rawStart = fixedEndExclusive - context.plan.rawHistoryDays * secondsPerDay
        let sourceWaveforms = try await sourceStore.ppgWaveformSamples(
            deviceId: deviceID,
            from: rawStart,
            to: fixedEndExclusive - 1,
            limit: 1_000_000
        )
        let restoredWaveforms = try await restored.ppgWaveformSamples(
            deviceId: deviceID,
            from: rawStart,
            to: fixedEndExclusive - 1,
            limit: 1_000_000
        )
        try requireRestoreEquality(
            restoredWaveforms,
            sourceWaveforms,
            check: "ppg-waveform-samples",
            completed: &checks
        )

        let sourcePending = try await sourceStore.pendingRawBatches(limit: 1_000)
        let restoredPending = try await restored.pendingRawBatches(limit: 1_000)
        try requireRestoreEquality(
            restoredPending,
            sourcePending,
            check: "raw-outbox-metadata",
            completed: &checks
        )
        for batch in sourcePending {
            let sourceFrames = try await sourceStore.rawFrames(batchId: batch.batchId)
            let restoredFrames = try await restored.rawFrames(batchId: batch.batchId)
            guard restoredFrames == sourceFrames else {
                throw HistoryHarnessError.restoreContentMismatch(
                    "raw-outbox-frames:\(batch.batchId)"
                )
            }
        }
        checks.append("raw-outbox-all-frame-bytes")

        let restoredExportURL = try await restored.exportRawCSV(
            deviceId: deviceID,
            since: TimeInterval(context.queryStart)
        )
        defer { try? FileManager.default.removeItem(at: restoredExportURL) }
        let restoredExportData = try Data(contentsOf: restoredExportURL)
        try requireRestoreEquality(
            restoredExportData,
            context.expectedRawExportData,
            check: "raw-csv-24h-bytes",
            completed: &checks
        )

        return RestoreVerification(
            resultCount: restoredStats.decodedRows
                + restoredDaily.count
                + sourceMetricKeys.count
                + sourceSleeps.count
                + sourceJournal.count
                + sourceWorkouts.count
                + sourceApple.count
                + sourceBattery.count
                + sourceWaveforms.count
                + sourcePending.count,
            checks: checks
        )
    }

    private static func requireRestoreEquality<T: Equatable>(
        _ restored: T,
        _ source: T,
        check: String,
        completed: inout [String]
    ) throws {
        guard restored == source else {
            throw HistoryHarnessError.restoreContentMismatch(check)
        }
        completed.append(check)
    }

    private static func insertAggregateHistory(
        store: WhoopStore,
        plan: HistoryDatasetPlan
    ) async throws -> Int {
        let start = fixedEndExclusive - plan.aggregateHistoryDays * secondsPerDay
        var daily: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        var metrics: [MetricPoint] = []
        var journal: [JournalEntry] = []
        var workouts: [WorkoutRow] = []
        var apple: [AppleDaily] = []

        for offset in 0..<plan.aggregateHistoryDays {
            let dayStart = start + offset * secondsPerDay
            let day = dayKey(dayStart)
            let variation = offset % 17
            daily.append(DailyMetric(
                day: day,
                totalSleepMin: Double(420 + variation),
                efficiency: 0.82 + Double(variation % 8) / 100,
                deepMin: Double(75 + variation % 20),
                remMin: Double(90 + variation % 25),
                lightMin: Double(245 + variation % 30),
                disturbances: 4 + variation % 5,
                restingHr: 52 + variation % 9,
                avgHrv: Double(48 + variation),
                recovery: Double(55 + variation * 2),
                strain: Double(7 + variation % 8),
                exerciseCount: offset % 3 == 0 ? 1 : 0,
                spo2Pct: nil,
                skinTempDevC: Double(variation - 8) / 20,
                respRateBpm: 13.5 + Double(variation % 5) / 10,
                steps: 6_000 + variation * 410,
                activeKcalEst: Double(350 + variation * 20),
                spo2Red: 1_200 + variation,
                spo2Ir: 1_600 + variation,
                hrvMethod: .rmssd
            ))
            let sleepStart = dayStart - 2 * 3_600
            sleeps.append(CachedSleepSession(
                startTs: sleepStart,
                endTs: dayStart + 6 * 3_600,
                efficiency: 0.86,
                restingHr: 54 + variation % 5,
                avgHrv: Double(50 + variation),
                stagesJSON:
                    #"[{"start":0,"end":90,"stage":"deep"},{"start":90,"end":210,"stage":"light"},{"start":210,"end":300,"stage":"rem"},{"start":300,"end":480,"stage":"light"}]"#,
                gravitySparse: false,
                rrEligibleWindowCount: 80,
                rrValidWindowCount: 74
            ))
            for (index, key) in metricKeys.enumerated() {
                metrics.append(MetricPoint(
                    day: day,
                    key: key,
                    value: Double((offset * 7 + index * 11) % 100) + 0.25
                ))
            }
            for question in 0..<8 {
                journal.append(JournalEntry(
                    day: day,
                    question: "synthetic-journal-\(question)",
                    answeredYes: (offset + question).isMultiple(of: 2),
                    notes: nil,
                    numericValue: question == 0 ? Double(500 + variation * 20) : nil
                ))
            }
            for workoutIndex in 0..<2 {
                let workoutStart = dayStart + (9 + workoutIndex * 8) * 3_600
                workouts.append(WorkoutRow(
                    startTs: workoutStart,
                    endTs: workoutStart + 3_600,
                    sport: workoutIndex == 0 ? "Synthetic strength" : "Synthetic walk",
                    source: "history_harness",
                    durationS: 3_600,
                    energyKcal: Double(240 + variation * 5),
                    avgHr: 112 + variation,
                    maxHr: 154 + variation,
                    strain: Double(7 + variation % 6),
                    distanceM: workoutIndex == 0 ? nil : 4_500,
                    zonesJSON: #"[10,20,35,25,10]"#,
                    notes: nil,
                    steps: workoutIndex == 0 ? nil : 5_500 + variation * 50
                ))
            }
            apple.append(AppleDaily(
                day: day,
                steps: 6_000 + variation * 410,
                activeKcal: Double(350 + variation * 20),
                basalKcal: 1_650,
                vo2max: 41.0 + Double(variation) / 10,
                avgHr: 74 + variation % 5,
                maxHr: 154 + variation,
                walkingHr: 96 + variation % 4,
                weightKg: 72.5
            ))
        }

        var count = 0
        count += try await store.upsertDailyMetrics(daily, deviceId: deviceID)
        count += try await store.upsertSleepSessions(sleeps, deviceId: deviceID)
        count += try await store.upsertMetricSeries(metrics, deviceId: deviceID)
        count += try await store.upsertJournal(journal, deviceId: deviceID)
        count += try await store.upsertWorkouts(workouts, deviceId: deviceID)
        count += try await store.upsertAppleDaily(apple, deviceId: deviceID)
        return count
    }

    private static func insertStreams(
        store: WhoopStore,
        plan: HistoryDatasetPlan,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> Int {
        let essentialStart = fixedEndExclusive - plan.essentialHistoryDays * secondsPerDay
        let rawStart = fixedEndExclusive - plan.rawHistoryDays * secondsPerDay
        var inserted = 0
        var completedHours = 0
        let totalHours = plan.essentialHistoryDays * 24

        for hourStart in stride(from: essentialStart, to: fixedEndExclusive, by: 3_600) {
            let hourEnd = min(hourStart + 3_600, fixedEndExclusive)
            var hr: [HRSample] = []
            var rr: [RRInterval] = []
            var ppgHR: [PpgHrSample] = []
            var gravity: [GravitySample] = []
            var waveforms: [PpgWaveformSample] = []
            var steps: [StepSample] = []
            var sleepStates: [SleepStateSample] = []
            var spo2: [SpO2Sample] = []
            var skin: [SkinTempSample] = []
            var resp: [RespSample] = []
            var events: [WhoopEvent] = []
            var battery: [BatterySample] = []

            for timestamp in hourStart..<hourEnd {
                let secondOfDay = positiveModulo(timestamp, secondsPerDay)
                let sleeping = secondOfDay >= 22 * 3_600 || secondOfDay < 6 * 3_600
                let opticalFallback = sleeping && (timestamp / 900).isMultiple(of: 4)
                let bpm = sleeping
                    ? 52 + positiveModulo(timestamp / 60, 8)
                    : 72 + positiveModulo(timestamp / 300, 44)

                if opticalFallback {
                    ppgHR.append(PpgHrSample(ts: timestamp, bpm: bpm, conf: 0.86))
                } else {
                    hr.append(HRSample(ts: timestamp, bpm: bpm))
                }
                if sleeping {
                    rr.append(RRInterval(
                        ts: timestamp,
                        rrMs: 1_000 - positiveModulo(timestamp, 120),
                        srcChannel: .greenQuality
                    ))
                }
                if timestamp.isMultiple(of: 60) {
                    steps.append(StepSample(
                        ts: timestamp,
                        counter: positiveModulo((timestamp - essentialStart) / 60 * 7, 65_536),
                        activityClass: sleeping ? 0 : 1
                    ))
                }
                if timestamp.isMultiple(of: 300) {
                    battery.append(BatterySample(
                        ts: timestamp,
                        soc: Double(95 - positiveModulo(timestamp / 300, 70)),
                        mv: 4_100 - positiveModulo(timestamp / 300, 500),
                        charging: false
                    ))
                }
                if timestamp.isMultiple(of: 900) {
                    events.append(WhoopEvent(
                        ts: timestamp,
                        kind: "SYNTHETIC_ACTIVITY_STATE",
                        payload: [:]
                    ))
                }

                guard timestamp >= rawStart else { continue }
                gravity.append(GravitySample(
                    ts: timestamp,
                    x: Double(positiveModulo(timestamp, 21) - 10) / 100,
                    y: Double(positiveModulo(timestamp / 2, 17) - 8) / 100,
                    z: 0.98 + Double(positiveModulo(timestamp / 3, 7)) / 100
                ))
                if opticalFallback {
                    waveforms.append(PpgWaveformSample(
                        ts: timestamp,
                        samples: waveform(timestamp: timestamp)
                    ))
                }
                if timestamp.isMultiple(of: 60) {
                    sleepStates.append(SleepStateSample(
                        ts: timestamp,
                        state: sleeping ? 2 : 0
                    ))
                    spo2.append(SpO2Sample(
                        ts: timestamp,
                        red: 1_200 + positiveModulo(timestamp / 60, 40),
                        ir: 1_600 + positiveModulo(timestamp / 60, 50)
                    ))
                    skin.append(SkinTempSample(
                        ts: timestamp,
                        raw: 3_250 + positiveModulo(timestamp / 60, 35)
                    ))
                    resp.append(RespSample(
                        ts: timestamp,
                        raw: 1_350 + positiveModulo(timestamp / 60, 25)
                    ))
                }
            }

            let counts = try await store.insert(
                Streams(
                    hr: hr,
                    rr: rr,
                    spo2: spo2,
                    skinTemp: skin,
                    resp: resp,
                    gravity: gravity,
                    steps: steps,
                    sleepState: sleepStates,
                    ppgHr: ppgHR,
                    ppgWaveform: waveforms,
                    events: events,
                    battery: battery
                ),
                deviceId: deviceID
            )
            inserted += counts.hr + counts.rr + counts.events + counts.battery
                + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity
                + counts.steps + counts.sleepState + counts.ppgHr + counts.ppgWaveform

            completedHours += 1
            if completedHours.isMultiple(of: 120) || completedHours == totalHours {
                progress(
                    "history-harness: \(plan.requestedDays)d streams \(completedHours)/\(totalHours) hours"
                )
            }
        }
        return inserted
    }

    private static func insertBoundedRawOutbox(
        store: WhoopStore,
        plan: HistoryDatasetPlan
    ) async throws -> Int {
        let frameBytes = 16_384
        let frameCount = 256
        let payload = deterministicBytes(count: frameBytes * frameCount)
        let frames = stride(from: 0, to: payload.count, by: frameBytes).map { offset in
            Array(payload[offset..<(offset + frameBytes)])
        }
        let logicalBytes = payload.count
        let batchCount = 14
        for index in 0..<batchCount {
            let capturedAt = fixedEndExclusive - (batchCount - index) * 3_600
            try await store.enqueueRawBatch(
                RawBatchMeta(
                    batchId: "history-\(plan.requestedDays)-\(index)",
                    deviceId: deviceID,
                    clockRef: ClockRef(device: capturedAt - 30, wall: capturedAt),
                    capturedAt: capturedAt,
                    startTs: capturedAt,
                    endTs: capturedAt + 3_599,
                    frameCount: frames.count,
                    byteSize: logicalBytes
                ),
                frames: frames
            )
        }
        return try await store.pruneRaw(
            now: fixedEndExclusive,
            keepWindowSeconds: secondsPerDay,
            maxUnsyncedBytes: 50 * 1_024 * 1_024
        )
    }

    private static func waveform(timestamp: Int) -> [Int] {
        let base = 800 + positiveModulo(timestamp, 37)
        return (0..<24).map { index in
            base + [0, 18, 33, 42, 37, 21, 0, -21, -37, -42, -33, -18][index % 12]
        }
    }

    private static func deterministicBytes(count: Int) -> [UInt8] {
        var state: UInt64 = 0x4e4f4f505f484953
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: state >> 32))
        }
        return bytes
    }

    private static func dayKey(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func measured<T>(
        _ operation: String,
        _ body: () async throws -> T
    ) async throws -> (value: T, milliseconds: Double) {
        _ = operation
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try await body()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return (value, Double(elapsed) / 1_000_000)
    }

    private static func measuredValue<T>(
        _ operation: String,
        _ body: () async -> T
    ) async -> (value: T, milliseconds: Double) {
        _ = operation
        let started = DispatchTime.now().uptimeNanoseconds
        let value = await body()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return (value, Double(elapsed) / 1_000_000)
    }
}

public enum HistoryHarnessError: Error, LocalizedError, Equatable {
    case noScenarios
    case unsupportedDays(Int)
    case integrityFailure(String)
    case restoreMismatch
    case restoreContentMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .noScenarios:
            return "At least one history scenario is required."
        case .unsupportedDays(let days):
            return "Unsupported history scenario: \(days) days."
        case .integrityFailure(let complaint):
            return "The generated backup failed SQLite integrity verification: \(complaint)"
        case .restoreMismatch:
            return "The restored history did not match the generated source."
        case .restoreContentMismatch(let check):
            return "The restored history failed exact content verification for \(check)."
        }
    }
}
