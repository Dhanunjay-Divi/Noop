import XCTest
import GRDB
@testable import WhoopStore

final class WhoopCSVImportStoreTests: XCTestCase {
    func testOfficialRowsReplaceWhileLocalDailyFieldsFillAndOtherRowsRemainInsertOnly() async throws {
        let store = try await WhoopStore.inMemory()
        let official = "wearable-import"
        let local = "wearable-import-noop"
        let firstStart = 1_767_300_000
        let secondStart = firstStart + 86_400

        try await store.upsertDailyMetrics(
            [daily(day: "2026-01-02", recovery: 10)],
            deviceId: official
        )
        try await store.upsertDailyMetrics(
            [daily(day: "2026-01-02", recovery: 20)],
            deviceId: local
        )
        try await store.upsertSleepSessions(
            [sleep(start: firstStart, end: firstStart + 20_000, efficiency: 0.5)],
            deviceId: local
        )
        try await store.upsertMetricSeries(
            [
                MetricPoint(day: "2026-01-02", key: "recovery", value: 30),
                MetricPoint(day: "2026-01-02", key: "sleep_performance", value: 40),
            ],
            deviceId: local
        )
        try await store.upsertMetricSeries(
            [MetricPoint(day: "2026-01-02", key: "recovery", value: 50)],
            deviceId: official
        )
        try await store.upsertWorkouts(
            [workout(start: firstStart, end: firstStart + 1_800, energy: 100)],
            deviceId: local
        )

        let counts = try await store.importWhoopCSV(
            WhoopCSVImportBatch(
                officialDailyMetrics: [daily(day: "2026-01-02", recovery: 91)],
                fillOnlyDailyMetrics: [
                    daily(day: "2026-01-02", recovery: 92, totalSleepMin: 480),
                    daily(day: "2026-01-03", recovery: 93),
                ],
                officialSleepSessions: [],
                fillOnlySleepSessions: [
                    sleep(start: firstStart, end: firstStart + 30_000, efficiency: 0.9),
                    sleep(start: secondStart, end: secondStart + 30_000, efficiency: 0.8),
                ],
                officialMetricSeriesReplacements: [
                    WhoopCSVMetricSeriesReplacement(
                        rows: [MetricPoint(day: "2026-01-02", key: "recovery", value: 94)],
                        deviceId: official,
                        from: "2026-01-02",
                        to: "2026-01-02",
                        managedKeys: ["recovery", "hrv"]
                    ),
                ],
                fillOnlyMetricSeries: [
                    MetricPoint(day: "2026-01-02", key: "recovery", value: 95),
                    MetricPoint(day: "2026-01-02", key: "sleep_performance", value: 96),
                    MetricPoint(day: "2026-01-03", key: "recovery", value: 97),
                ],
                journalReplacement: nil,
                officialWorkouts: [],
                fillOnlyWorkouts: [
                    workout(start: firstStart, end: firstStart + 3_600, energy: 200),
                    workout(start: secondStart, end: secondStart + 3_600, energy: 300),
                ],
                officialDeviceId: official,
                fillOnlyDeviceId: local
            )
        )

        XCTAssertEqual(counts.dailyMetrics, 3)
        XCTAssertEqual(counts.sleepSessions, 1)
        XCTAssertEqual(counts.workouts, 1)

        let officialDays = try await store.dailyMetrics(
            deviceId: official, from: "2026-01-02", to: "2026-01-03")
        XCTAssertEqual(officialDays.map(\.recovery), [91])
        let localDays = try await store.dailyMetrics(
            deviceId: local, from: "2026-01-02", to: "2026-01-03")
        XCTAssertEqual(localDays.map(\.recovery), [20, 93])
        XCTAssertEqual(localDays.first?.totalSleepMin, 480)

        let sleeps = try await store.sleepSessions(
            deviceId: local, from: firstStart - 1, to: secondStart + 1, limit: 10)
        XCTAssertEqual(sleeps.map(\.efficiency), [0.5, 0.8])
        XCTAssertEqual(sleeps.first?.endTs, firstStart + 20_000)

        let officialRecovery = try await store.metricSeries(
            deviceId: official, key: "recovery", from: "2026-01-02", to: "2026-01-03")
        XCTAssertEqual(officialRecovery.map(\.value), [94])
        let localRecovery = try await store.metricSeries(
            deviceId: local, key: "recovery", from: "2026-01-02", to: "2026-01-03")
        XCTAssertEqual(localRecovery.map(\.value), [30, 97])
        let localPerformance = try await store.metricSeries(
            deviceId: local, key: "sleep_performance", from: "2026-01-02", to: "2026-01-03")
        XCTAssertEqual(localPerformance.map(\.value), [40])

        let workouts = try await store.workouts(
            deviceId: local, from: firstStart - 1, to: secondStart + 1, limit: 10)
        XCTAssertEqual(workouts.map(\.energyKcal), [100, 300])
        XCTAssertEqual(workouts.first?.endTs, firstStart + 1_800)
    }

    func testLateWorkoutFailureRollsBackEarlierRowsAndRangeDeletion() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "wearable-import"
        try await store.upsertMetricSeries(
            [MetricPoint(day: "2026-01-02", key: "recovery", value: 55)],
            deviceId: deviceId
        )
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER abort_csv_import_workout
                BEFORE INSERT ON workout
                WHEN NEW.sport = 'Abort transaction'
                BEGIN
                    SELECT RAISE(ABORT, 'forced late import failure');
                END
                """)
        }

        do {
            _ = try await store.importWhoopCSV(
                WhoopCSVImportBatch(
                    officialDailyMetrics: [daily(day: "2026-01-02", recovery: 90)],
                    fillOnlyDailyMetrics: [],
                    officialSleepSessions: [],
                    fillOnlySleepSessions: [],
                    officialMetricSeriesReplacements: [
                        WhoopCSVMetricSeriesReplacement(
                            rows: [],
                            deviceId: deviceId,
                            from: "2026-01-02",
                            to: "2026-01-02",
                            managedKeys: ["recovery"]
                        ),
                    ],
                    fillOnlyMetricSeries: [],
                    journalReplacement: nil,
                    officialWorkouts: [
                        WorkoutRow(
                            startTs: 1_767_300_000,
                            endTs: 1_767_303_600,
                            sport: "Abort transaction",
                            source: "wearable",
                            durationS: 3_600,
                            energyKcal: nil,
                            avgHr: nil,
                            maxHr: nil,
                            strain: nil,
                            distanceM: nil,
                            zonesJSON: nil,
                            notes: nil
                        ),
                    ],
                    fillOnlyWorkouts: [],
                    officialDeviceId: deviceId,
                    fillOnlyDeviceId: "\(deviceId)-noop"
                )
            )
            XCTFail("Expected the trigger to abort the import")
        } catch {
            // Expected: every mutation in the transaction must roll back.
        }

        let days = try await store.dailyMetrics(
            deviceId: deviceId, from: "2026-01-02", to: "2026-01-02")
        XCTAssertTrue(days.isEmpty)
        let recovery = try await store.metricSeries(
            deviceId: deviceId, key: "recovery", from: "2026-01-02", to: "2026-01-02")
        XCTAssertEqual(recovery.map(\.value), [55])
    }

    func testOfficialSleepReimportPreservesEditedWindowStagesAndLocalEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "wearable-import"
        let start = 1_767_300_000
        try await store.upsertSleepSessions(
            [
                CachedSleepSession(
                    startTs: start,
                    endTs: start + 28_800,
                    efficiency: 0.72,
                    restingHr: 61,
                    avgHrv: 39,
                    stagesJSON: #"{"stage":"edited"}"#,
                    userEdited: true,
                    startTsAdjusted: start + 900
                ),
            ],
            deviceId: deviceId
        )
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE sleepSession
                    SET motionJSON = '[0.1,0.2]', sleepStateJSON = '[1,2]',
                        gravitySparse = 1
                    WHERE deviceId = ? AND startTs = ?
                    """,
                arguments: [deviceId, start]
            )
        }

        _ = try await store.importWhoopCSV(
            WhoopCSVImportBatch(
                officialDailyMetrics: [],
                fillOnlyDailyMetrics: [],
                officialSleepSessions: [
                    CachedSleepSession(
                        startTs: start,
                        endTs: start + 32_400,
                        efficiency: 0.91,
                        restingHr: 52,
                        avgHrv: 62,
                        stagesJSON: #"{"stage":"provider"}"#
                    ),
                ],
                fillOnlySleepSessions: [],
                officialMetricSeriesReplacements: [],
                fillOnlyMetricSeries: [],
                journalReplacement: nil,
                officialWorkouts: [],
                fillOnlyWorkouts: [],
                officialDeviceId: deviceId,
                fillOnlyDeviceId: "\(deviceId)-noop"
            )
        )

        let sessions = try await store.sleepSessions(
            deviceId: deviceId,
            from: start,
            to: start,
            limit: 1
        )
        let persisted = try XCTUnwrap(sessions.first)
        XCTAssertEqual(persisted.endTs, start + 28_800)
        XCTAssertEqual(persisted.efficiency, 0.72)
        XCTAssertEqual(persisted.restingHr, 61)
        XCTAssertEqual(persisted.avgHrv, 39)
        XCTAssertEqual(persisted.stagesJSON, #"{"stage":"edited"}"#)
        XCTAssertTrue(persisted.userEdited)
        XCTAssertEqual(persisted.startTsAdjusted, start + 900)
        XCTAssertEqual(persisted.gravitySparse, true)
        try await store.registryWriter.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT motionJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                    arguments: [deviceId, start]
                ),
                "[0.1,0.2]"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT sleepStateJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                    arguments: [deviceId, start]
                ),
                "[1,2]"
            )
        }
    }

    func testOfficialSleepReimportRefreshesUneditedWindowWithoutClearingGravityEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "wearable-import"
        let start = 1_767_300_000
        try await store.upsertSleepSessions(
            [
                CachedSleepSession(
                    startTs: start,
                    endTs: start + 28_800,
                    efficiency: 0.72,
                    restingHr: 61,
                    avgHrv: 39,
                    stagesJSON: #"{"stage":"local"}"#,
                    gravitySparse: false
                ),
            ],
            deviceId: deviceId
        )

        _ = try await store.importWhoopCSV(
            WhoopCSVImportBatch(
                officialDailyMetrics: [],
                fillOnlyDailyMetrics: [],
                officialSleepSessions: [
                    CachedSleepSession(
                        startTs: start,
                        endTs: start + 32_400,
                        efficiency: 0.91,
                        restingHr: 52,
                        avgHrv: 62,
                        stagesJSON: #"{"stage":"provider"}"#
                    ),
                ],
                fillOnlySleepSessions: [],
                officialMetricSeriesReplacements: [],
                fillOnlyMetricSeries: [],
                journalReplacement: nil,
                officialWorkouts: [],
                fillOnlyWorkouts: [],
                officialDeviceId: deviceId,
                fillOnlyDeviceId: "\(deviceId)-noop"
            )
        )

        let sessions = try await store.sleepSessions(
            deviceId: deviceId,
            from: start,
            to: start,
            limit: 1
        )
        let persisted = try XCTUnwrap(sessions.first)
        XCTAssertEqual(persisted.endTs, start + 32_400)
        XCTAssertEqual(persisted.efficiency, 0.91)
        XCTAssertEqual(persisted.stagesJSON, #"{"stage":"provider"}"#)
        XCTAssertEqual(persisted.gravitySparse, false)
    }

    func testOfficialRangesRemoveMissingRowsWithoutDeletingLocalSleepEvidenceOrEdits() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "wearable-import"
        let firstStart = 1_767_300_000
        let secondStart = firstStart + 86_400
        let thirdStart = secondStart + 86_400
        let fourthStart = thirdStart + 86_400

        try await store.upsertDailyMetrics(
            [
                daily(day: "2026-01-02", recovery: 20),
                daily(day: "2026-01-03", recovery: 30),
                daily(day: "2026-01-04", recovery: 40),
            ],
            deviceId: deviceId
        )
        try await store.upsertSleepSessions(
            [
                sleep(start: firstStart, end: firstStart + 20_000, efficiency: 0.7),
                sleep(start: secondStart, end: secondStart + 20_000, efficiency: 0.7),
                sleep(start: thirdStart, end: thirdStart + 20_000, efficiency: 0.7),
                CachedSleepSession(
                    startTs: fourthStart,
                    endTs: fourthStart + 20_000,
                    efficiency: 0.7,
                    restingHr: nil,
                    avgHrv: nil,
                    stagesJSON: #"{"edited":true}"#,
                    userEdited: true
                ),
            ],
            deviceId: deviceId
        )
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE sleepSession
                    SET motionJSON = '[0.1,0.2]', gravitySparse = 0
                    WHERE deviceId = ? AND startTs = ?
                    """,
                arguments: [deviceId, secondStart]
            )
        }
        try await store.upsertWorkouts(
            [
                workout(
                    start: firstStart, end: firstStart + 1_800, energy: 100,
                    source: "whoop"),
                workout(
                    start: secondStart, end: secondStart + 1_800, energy: 200,
                    source: "whoop"),
            ],
            deviceId: deviceId
        )

        _ = try await store.importWhoopCSV(
            WhoopCSVImportBatch(
                officialDailyMetrics: [daily(day: "2026-01-02", recovery: 91)],
                officialDailyMetricRange: WhoopCSVDayRange(
                    from: "2026-01-02", to: "2026-01-04"),
                fillOnlyDailyMetrics: [],
                officialSleepSessions: [
                    sleep(start: firstStart, end: firstStart + 30_000, efficiency: 0.9),
                ],
                officialSleepSessionRange: WhoopCSVTimestampRange(
                    from: firstStart, to: fourthStart),
                fillOnlySleepSessions: [],
                officialMetricSeriesReplacements: [],
                fillOnlyMetricSeries: [],
                journalReplacement: nil,
                officialWorkouts: [
                    workout(
                        start: firstStart, end: firstStart + 3_600, energy: 300,
                        source: "whoop"),
                ],
                officialWorkoutRange: WhoopCSVTimestampRange(
                    from: firstStart, to: secondStart),
                fillOnlyWorkouts: [],
                officialDeviceId: deviceId,
                fillOnlyDeviceId: "\(deviceId)-noop"
            )
        )

        let days = try await store.dailyMetrics(
            deviceId: deviceId, from: "2026-01-02", to: "2026-01-04")
        XCTAssertEqual(days.map(\.day), ["2026-01-02"])
        XCTAssertEqual(days.map(\.recovery), [91])

        let sleeps = try await store.sleepSessions(
            deviceId: deviceId, from: firstStart, to: fourthStart, limit: 10)
        XCTAssertEqual(sleeps.map(\.startTs), [firstStart, secondStart, fourthStart])
        XCTAssertEqual(sleeps.first?.efficiency, 0.9)
        XCTAssertEqual(sleeps.dropFirst().first?.gravitySparse, false)
        XCTAssertEqual(sleeps.last?.stagesJSON, #"{"edited":true}"#)
        try await store.registryWriter.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT motionJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                    arguments: [deviceId, secondStart]
                ),
                "[0.1,0.2]"
            )
        }

        let workouts = try await store.workouts(
            deviceId: deviceId, from: firstStart, to: secondStart, limit: 10)
        XCTAssertEqual(workouts.map(\.startTs), [firstStart])
        XCTAssertEqual(workouts.map(\.energyKcal), [300])
    }

    func testOfficialWorkoutRangePreservesOtherSourcesAndReplacesImporterOwnedRows() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "wearable-import"
        let staleStart = 1_767_300_000
        let replacementStart = staleStart + 3_600
        let manualStart = replacementStart + 3_600
        let externalStart = manualStart + 3_600

        try await store.upsertWorkouts(
            [
                workout(
                    start: staleStart, end: staleStart + 1_800, energy: 100,
                    source: "whoop"),
                workout(
                    start: replacementStart, end: replacementStart + 1_800, energy: 200,
                    source: "whoop"),
                workout(
                    start: manualStart, end: manualStart + 1_800, energy: 300,
                    source: "manual"),
                workout(
                    start: externalStart, end: externalStart + 1_800, energy: 400,
                    source: "garmin"),
            ],
            deviceId: deviceId
        )

        let counts = try await store.importWhoopCSV(
            WhoopCSVImportBatch(
                officialDailyMetrics: [],
                fillOnlyDailyMetrics: [],
                officialSleepSessions: [],
                fillOnlySleepSessions: [],
                officialMetricSeriesReplacements: [],
                fillOnlyMetricSeries: [],
                journalReplacement: nil,
                officialWorkouts: [
                    workout(
                        start: replacementStart,
                        end: replacementStart + 3_600,
                        energy: 900,
                        source: "untrusted-row-source"),
                    workout(
                        start: manualStart,
                        end: manualStart + 3_600,
                        energy: 999,
                        source: "untrusted-row-source"),
                ],
                officialWorkoutRange: WhoopCSVTimestampRange(
                    from: staleStart,
                    to: externalStart
                ),
                fillOnlyWorkouts: [],
                officialDeviceId: deviceId,
                fillOnlyDeviceId: "\(deviceId)-noop"
            )
        )

        XCTAssertEqual(counts.workouts, 1)
        let rows = try await store.workouts(
            deviceId: deviceId,
            from: staleStart,
            to: externalStart,
            limit: 10
        )
        XCTAssertEqual(rows.map(\.startTs), [replacementStart, manualStart, externalStart])
        XCTAssertEqual(rows[0].source, "whoop")
        XCTAssertEqual(rows[0].energyKcal, 900)
        XCTAssertEqual(rows[1].source, "manual")
        XCTAssertEqual(rows[1].energyKcal, 300)
        XCTAssertEqual(rows[2].source, "garmin")
        XCTAssertEqual(rows[2].energyKcal, 400)
    }

    func testRangeReimportCountsOnlyInsertedOrUpdatedRows() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "wearable-import"
        let day = "2026-01-02"
        let start = 1_767_300_000

        try await store.upsertDailyMetrics(
            [daily(day: day, recovery: 10)],
            deviceId: deviceId
        )
        try await store.upsertSleepSessions(
            [sleep(start: start, end: start + 20_000, efficiency: 0.5)],
            deviceId: deviceId
        )
        try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: "recovery", value: 10)],
            deviceId: deviceId
        )
        try await store.upsertJournal(
            [JournalEntry(
                day: day,
                question: "Did you hydrate?",
                answeredYes: false,
                notes: nil
            )],
            deviceId: deviceId
        )
        try await store.upsertWorkouts(
            [workout(
                start: start, end: start + 1_800, energy: 100,
                source: "whoop")],
            deviceId: deviceId
        )

        let counts = try await store.importWhoopCSV(
            WhoopCSVImportBatch(
                officialDailyMetrics: [daily(day: day, recovery: 90)],
                officialDailyMetricRange: WhoopCSVDayRange(from: day, to: day),
                fillOnlyDailyMetrics: [],
                officialSleepSessions: [
                    sleep(start: start, end: start + 30_000, efficiency: 0.9),
                ],
                officialSleepSessionRange: WhoopCSVTimestampRange(from: start, to: start),
                fillOnlySleepSessions: [],
                officialMetricSeriesReplacements: [
                    WhoopCSVMetricSeriesReplacement(
                        rows: [MetricPoint(day: day, key: "recovery", value: 90)],
                        deviceId: deviceId,
                        from: day,
                        to: day,
                        managedKeys: ["recovery"]
                    ),
                ],
                fillOnlyMetricSeries: [],
                journalReplacement: WhoopCSVJournalReplacement(
                    rows: [JournalEntry(
                        day: day,
                        question: "Did you hydrate?",
                        answeredYes: true,
                        notes: nil
                    )],
                    deviceId: deviceId,
                    from: day,
                    to: day
                ),
                officialWorkouts: [
                    workout(
                        start: start, end: start + 3_600, energy: 300,
                        source: "ignored-row-source"),
                ],
                officialWorkoutRange: WhoopCSVTimestampRange(from: start, to: start),
                fillOnlyWorkouts: [],
                officialDeviceId: deviceId,
                fillOnlyDeviceId: "\(deviceId)-noop"
            )
        )

        XCTAssertEqual(counts.dailyMetrics, 1)
        XCTAssertEqual(counts.sleepSessions, 1)
        XCTAssertEqual(counts.metricSeries, 1)
        XCTAssertEqual(counts.journal, 1)
        XCTAssertEqual(counts.workouts, 1)
    }

    func testWideTableImportDropsNonFiniteOptionalValues() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "wearable-import"
        let start = 1_767_300_000

        _ = try await store.importWhoopCSV(
            WhoopCSVImportBatch(
                officialDailyMetrics: [
                    DailyMetric(
                        day: "2026-01-02",
                        totalSleepMin: .infinity,
                        efficiency: .nan,
                        deepMin: nil,
                        remMin: nil,
                        lightMin: nil,
                        disturbances: nil,
                        restingHr: nil,
                        avgHrv: -.infinity,
                        recovery: 80,
                        strain: nil,
                        exerciseCount: nil
                    ),
                ],
                fillOnlyDailyMetrics: [],
                officialSleepSessions: [
                    CachedSleepSession(
                        startTs: start,
                        endTs: start + 20_000,
                        efficiency: .infinity,
                        restingHr: nil,
                        avgHrv: .nan,
                        stagesJSON: nil
                    ),
                ],
                fillOnlySleepSessions: [],
                officialMetricSeriesReplacements: [],
                fillOnlyMetricSeries: [],
                journalReplacement: nil,
                officialWorkouts: [
                    WorkoutRow(
                        startTs: start,
                        endTs: start + 3_600,
                        sport: "Run",
                        source: "wearable",
                        durationS: .infinity,
                        energyKcal: .nan,
                        avgHr: nil,
                        maxHr: nil,
                        strain: -.infinity,
                        distanceM: .infinity,
                        zonesJSON: nil,
                        notes: nil
                    ),
                ],
                fillOnlyWorkouts: [],
                officialDeviceId: deviceId,
                fillOnlyDeviceId: "\(deviceId)-noop"
            )
        )

        let days = try await store.dailyMetrics(
            deviceId: deviceId, from: "2026-01-02", to: "2026-01-02")
        let day = try XCTUnwrap(days.first)
        XCTAssertNil(day.totalSleepMin)
        XCTAssertNil(day.efficiency)
        XCTAssertNil(day.avgHrv)
        XCTAssertEqual(day.recovery, 80)

        let sleeps = try await store.sleepSessions(
            deviceId: deviceId, from: start, to: start, limit: 1)
        let sleep = try XCTUnwrap(sleeps.first)
        XCTAssertNil(sleep.efficiency)
        XCTAssertNil(sleep.avgHrv)

        let workouts = try await store.workouts(
            deviceId: deviceId, from: start, to: start, limit: 1)
        let workout = try XCTUnwrap(workouts.first)
        XCTAssertNil(workout.durationS)
        XCTAssertNil(workout.energyKcal)
        XCTAssertNil(workout.strain)
        XCTAssertNil(workout.distanceM)
    }

    private static func daily(
        day: String,
        recovery: Double,
        totalSleepMin: Double? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: recovery,
            strain: nil,
            exerciseCount: nil
        )
    }

    private static func sleep(start: Int, end: Int, efficiency: Double) -> CachedSleepSession {
        CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: efficiency,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil
        )
    }

    private static func workout(
        start: Int,
        end: Int,
        energy: Double,
        source: String = "analytics"
    ) -> WorkoutRow {
        WorkoutRow(
            startTs: start,
            endTs: end,
            sport: "Run",
            source: source,
            durationS: Double(end - start),
            energyKcal: energy,
            avgHr: nil,
            maxHr: nil,
            strain: nil,
            distanceM: nil,
            zonesJSON: nil,
            notes: nil
        )
    }

    private func daily(
        day: String,
        recovery: Double,
        totalSleepMin: Double? = nil
    ) -> DailyMetric {
        Self.daily(day: day, recovery: recovery, totalSleepMin: totalSleepMin)
    }

    private func sleep(start: Int, end: Int, efficiency: Double) -> CachedSleepSession {
        Self.sleep(start: start, end: end, efficiency: efficiency)
    }

    private func workout(
        start: Int,
        end: Int,
        energy: Double,
        source: String = "analytics"
    ) -> WorkoutRow {
        Self.workout(start: start, end: end, energy: energy, source: source)
    }
}
