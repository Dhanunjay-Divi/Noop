import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the source-aware vital-sign resolution (PR#261): the field-by-field daily merge, the per-metric
/// source precedence (imported WHOOP > NOOP-computed > Apple Health), skin temp's deliberate exclusion of
/// Apple, the provenance captions, and the "latest day that has a value" fallback. All pure — no store.
final class VitalSourceResolutionTests: XCTestCase {
    func testMergeDailyFillsOnlyMissingImportedFields() {
        let imported = daily(
            day: "2026-06-12",
            totalSleepMin: 420,
            recovery: nil,
            strain: 8.4,
            spo2Pct: 97,
            skinTempDevC: nil,
            steps: nil
        )
        let computed = daily(
            day: "2026-06-12",
            totalSleepMin: 390,
            recovery: 82,
            strain: 12.6,
            spo2Pct: 95,
            skinTempDevC: 0.3,
            steps: 9_240
        )

        let merged = Repository.mergeDaily(imported: [imported], computed: [computed])

        XCTAssertEqual(merged.count, 1)
        // Imported non-nil fields win…
        XCTAssertEqual(merged[0].totalSleepMin, 420)
        XCTAssertEqual(merged[0].strain, 8.4)
        XCTAssertEqual(merged[0].spo2Pct, 97)
        // …and computed fills only the fields the import left nil.
        XCTAssertEqual(merged[0].recovery, 82)
        XCTAssertEqual(merged[0].skinTempDevC, 0.3)
        XCTAssertEqual(merged[0].steps, 9_240)
    }

    func testActivityFileStepsFillMissingStepDaysOnly() {
        let base = [
            daily(day: "2026-06-14", recovery: 70, steps: nil),
            daily(day: "2026-06-15", steps: 9000),
        ]
        let activity = [
            daily(day: "2026-06-14", steps: 1175),
            daily(day: "2026-06-15", steps: 2222),
            daily(day: "2026-06-16", steps: 3333),
        ]

        let merged = Repository.mergeActivityFileSteps(into: base, activity)

        XCTAssertEqual(merged.first { $0.day == "2026-06-14" }?.steps, 1175)
        XCTAssertEqual(merged.first { $0.day == "2026-06-15" }?.steps, 9000)
        XCTAssertEqual(merged.first { $0.day == "2026-06-16" }?.steps, 3333)
    }

    func testAppleHealthCanFillBloodOxygenWhenStrapSourcesAreMissing() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 98), source: .appleHealth)
            ],
            temperatureUnit: .celsius
        )

        let spo2 = readings.first { $0.key == "spo2" }
        XCTAssertEqual(spo2?.value, 98)
        XCTAssertEqual(spo2?.source, .appleHealth)
        XCTAssertTrue(spo2?.stateCaption.contains("Apple Health") == true)
    }

    func testWhoopBloodOxygenWinsOverAppleHealthForSameDay() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 96), source: .whoopImport),
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 99), source: .appleHealth)
            ],
            temperatureUnit: .celsius
        )

        let spo2 = readings.first { $0.key == "spo2" }
        XCTAssertEqual(spo2?.value, 96)
        XCTAssertEqual(spo2?.source, .whoopImport)
    }

    func testAppleHealthDoesNotFillSkinTemperature() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", skinTempDevC: 34.2), source: .appleHealth)
            ],
            temperatureUnit: .celsius
        )

        let skin = readings.first { $0.key == "skin" }
        XCTAssertNil(skin?.value)
        XCTAssertNil(skin?.source)
    }

    func testComputedSkinTemperatureShowsComputedCaption() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", skinTempDevC: 0.2), source: .noopComputed)
            ],
            temperatureUnit: .celsius
        )

        let skin = readings.first { $0.key == "skin" }
        XCTAssertEqual(skin?.value, 0.2)
        XCTAssertEqual(skin?.source, .noopComputed)
        XCTAssertTrue(skin?.stateCaption.contains("Overnight computed") == true)
    }

    func testVitalsFallBackToLatestHistoricalDayWhenTodayHasNoValue() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-11", respRateBpm: 15.2), source: .whoopImport),
                SourcedDailyMetric(metric: daily(day: "2026-06-12", respRateBpm: 16.1), source: .noopComputed)
            ],
            temperatureUnit: .celsius,
            now: localNoon(day: "2026-06-13")
        )

        let resp = readings.first { $0.key == "resp" }
        XCTAssertEqual(resp?.day, "2026-06-12")
        XCTAssertEqual(resp?.value, 16.1)
        XCTAssertEqual(resp?.source, .noopComputed)
        XCTAssertEqual(BodyVitalSigns.latestDayLabel(readings), BodyVitalReading.dayLabel("2026-06-12"))
    }

    func testSleepVitalUsesObservedDurationAndTypicalRange() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(
                    metric: daily(day: "2026-06-12", totalSleepMin: 500),
                    source: .whoopImport
                )
            ],
            temperatureUnit: .celsius,
            now: localNoon(day: "2026-06-13")
        )

        let sleep = readings.first { $0.key == "sleep" }
        XCTAssertEqual(sleep?.value ?? -1, 500.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(sleep?.formattedValue, "8h 20m")
        XCTAssertEqual(sleep?.source, .whoopImport)
        XCTAssertEqual(sleep?.banding.basis, .population)
        XCTAssertEqual(sleep?.banding.range, 7...9)
        XCTAssertEqual(sleep?.banding.band, .inRange)
    }

    func testEditedSleepDayUsesCorrectedComputedDurationAheadOfImport() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(
                    metric: daily(day: "2026-06-12", totalSleepMin: 500),
                    source: .whoopImport
                ),
                SourcedDailyMetric(
                    metric: daily(day: "2026-06-12", totalSleepMin: 420),
                    source: .noopComputed
                ),
            ],
            temperatureUnit: .celsius,
            now: localNoon(day: "2026-06-13"),
            sleepOverrideDays: ["2026-06-12"]
        )

        let sleep = readings.first { $0.key == "sleep" }
        XCTAssertEqual(sleep?.formattedValue, "7h")
        XCTAssertEqual(sleep?.source, .noopComputed)
    }

    @MainActor
    func testRepositoryRetainsEditedWakeDayWhenSleepMergeSelectsImport() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(store)

        let calendar = Calendar.current
        let wakeDay = calendar.date(
            byAdding: .day,
            value: -2,
            to: calendar.startOfDay(for: Date())
        )!
        let wake = calendar.date(byAdding: .hour, value: 8, to: wakeDay)!
        let wakeTs = Int(wake.timeIntervalSince1970)
        let editedSession = CachedSleepSession(
            startTs: wakeTs - 7 * 3_600,
            endTs: wakeTs,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil,
            userEdited: true
        )
        let day = Repository.userEditedDays([editedSession]).first!

        _ = try await store.upsertDailyMetrics(
            [daily(day: day, totalSleepMin: 500)],
            deviceId: Repository.whoopSource
        )
        _ = try await store.upsertDailyMetrics(
            [daily(day: day, totalSleepMin: 420)],
            deviceId: Repository.whoopSource + "-noop"
        )
        try await store.upsertSleepSessions(
            [
                CachedSleepSession(
                    startTs: wakeTs - 8 * 3_600,
                    endTs: wakeTs,
                    efficiency: nil,
                    restingHr: nil,
                    avgHrv: nil,
                    stagesJSON: nil,
                    userEdited: false
                )
            ],
            deviceId: Repository.whoopSource
        )
        try await store.upsertSleepSessions(
            [editedSession],
            deviceId: Repository.whoopSource + "-noop"
        )

        await repo.refresh(days: 30)

        XCTAssertEqual(repo.editedSleepDays, [day])
        XCTAssertFalse(
            repo.sleeps.contains(where: \.userEdited),
            "The fixture must prove the display merge selected the imported session."
        )
        let sleep = BodyVitalSigns.readings(
            sourceRows: repo.vitalMetricRows,
            temperatureUnit: .celsius,
            sleepOverrideDays: repo.editedSleepDays
        ).first { $0.key == "sleep" }
        XCTAssertEqual(sleep?.formattedValue, "7h")
        XCTAssertEqual(sleep?.source, .noopComputed)
    }

    func testRecordedDayLabelDoesNotShiftWestOfUTC() {
        XCTAssertEqual(BodyVitalReading.dayLabel("2026-08-22"), "22 Aug")
    }

    // MARK: - Fixtures

    private func daily(
        day: String,
        totalSleepMin: Double? = nil,
        recovery: Double? = nil,
        strain: Double? = nil,
        spo2Pct: Double? = nil,
        skinTempDevC: Double? = nil,
        respRateBpm: Double? = nil,
        steps: Int? = nil
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
            strain: strain,
            exerciseCount: nil,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateBpm,
            steps: steps,
            activeKcalEst: nil
        )
    }

    private func localNoon(day: String) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2],
            hour: 12
        ))!
    }
}

final class ReferenceDataIntegrityTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func sleep(
        start: Date,
        end: Date,
        adjustedStart: Date? = nil
    ) -> CachedSleepSession {
        CachedSleepSession(
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(end.timeIntervalSince1970),
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil,
            userEdited: adjustedStart != nil,
            startTsAdjusted: adjustedStart.map { Int($0.timeIntervalSince1970) }
        )
    }

    func testStressCalendarOmitsLimitedSingleSignalEstimate() {
        let values = CalendarMonthSeries.reliableStress([
            DailyAutonomicLoad.Readout(
                value: 2.6,
                band: .high,
                confidence: .limited,
                asOf: "2026-08-20",
                baselineDays: 14,
                observedSignals: [.restingHeartRate],
                limitations: [.singleSignalEstimate]
            ),
            DailyAutonomicLoad.Readout(
                value: 0.8,
                band: .low,
                confidence: .reliable,
                asOf: "2026-08-21",
                baselineDays: 14,
                observedSignals: [.restingHeartRate, .heartRateVariability],
                limitations: [.experimentalNonClinicalProxy]
            ),
        ])

        XCTAssertNil(values["2026-08-20"])
        XCTAssertEqual(values["2026-08-21"], 0.8)
    }

    func testTimelineCollapsesEditedSplitNightAndExcludesNap() {
        let editedOnset = date(2026, 8, 20, hour: 22, minute: 15)
        let events = HealthSleepTimelineResolver.primaryEvents(
            sessions: [
                sleep(
                    start: date(2026, 8, 20, hour: 22),
                    end: date(2026, 8, 21, hour: 2),
                    adjustedStart: editedOnset
                ),
                sleep(
                    start: date(2026, 8, 21, hour: 2, minute: 30),
                    end: date(2026, 8, 21, hour: 6, minute: 30)
                ),
                sleep(
                    start: date(2026, 8, 21, hour: 14),
                    end: date(2026, 8, 21, hour: 15)
                ),
            ],
            calendar: calendar
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.day, "2026-08-21")
        XCTAssertEqual(events.first?.startTs, Int(editedOnset.timeIntervalSince1970))
        XCTAssertEqual(
            events.first?.endTs,
            Int(date(2026, 8, 21, hour: 6, minute: 30).timeIntervalSince1970)
        )
        XCTAssertEqual(events.first?.durationSeconds, 8 * 3_600 + 15 * 60)
    }

    func testBiomarkerSparklineRequiresRecentCloselySpacedObservations() {
        let now = date(2026, 8, 23, hour: 12)
        let dense = BiomarkerTrendIntegrity.snapshot(
            points: [
                ("2026-08-20", 80),
                ("2026-08-21", 82),
                ("2026-08-22", 81),
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(dense.sparklineValues, [80, 82, 81])
        XCTAssertFalse(dense.isStale)

        let sparse = BiomarkerTrendIntegrity.snapshot(
            points: [
                ("2026-06-01", 75),
                ("2026-08-22", 81),
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertNil(sparse.sparklineValues)
        XCTAssertEqual(sparse.latestDay, "2026-08-22")

        let stale = BiomarkerTrendIntegrity.snapshot(
            points: [("2026-06-01", 75)],
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(stale.isStale)
        XCTAssertNil(stale.sparklineValues)
    }
}
