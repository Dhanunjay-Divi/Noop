import XCTest
import Foundation
import StrandAnalytics
import WhoopStore
@testable import Strand

final class WhoopProvenanceImportTests: XCTestCase {
    func testNoopApproximateRowsNeverEnterOfficialReferenceNamespace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-whoop-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let csv = """
        Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Day Strain,Sleep performance %,Source
        2026-01-01 00:00:00,2026-01-01 23:59:00,UTC+00:00,60,10,70,noop (APPROXIMATE)
        2026-01-02 00:00:00,2026-01-02 23:59:00,UTC+00:00,80,12,90,import
        2026-01-03 00:00:00,2026-01-03 23:59:00,UTC+00:00,99,20,99,other-app
        """
        try csv.write(
            to: directory.appendingPathComponent("physiological_cycles.csv"),
            atomically: true,
            encoding: .utf8)

        let store = try await WhoopStore.inMemory()
        let deviceId = "test-whoop-\(UUID().uuidString)"
        defer { WhoopReferenceImportManifest().remove(deviceId: deviceId) }

        // Seed rows produced by the pre-v3 importer plus unrelated data. Official re-imports may replace
        // their managed range; local projections are fill-only in the analytics-owned `-noop` namespace.
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-01-02", key: "stress", value: 1.8),
            MetricPoint(day: "2026-01-02", key: "note", value: 7),
            MetricPoint(day: "2026-01-03", key: "stress", value: 2.2), // quarantined source day
            MetricPoint(day: "2025-12-31", key: "stress", value: 0.4),
        ], deviceId: deviceId)
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-01-01", key: "stress", value: 1.2),
            MetricPoint(day: "2025-12-31", key: "stress", value: 0.6),
        ], deviceId: deviceId + "-noop")
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-01-02", key: "stress", value: 2.8),
        ], deviceId: "unrelated-device")

        _ = try await WhoopImporter.importExport(
            url: directory, into: store, deviceId: deviceId)

        let official = try await store.dailyMetrics(
            deviceId: deviceId, from: "2026-01-01", to: "2026-01-03")
        let local = try await store.dailyMetrics(
            deviceId: deviceId + "-noop", from: "2026-01-01", to: "2026-01-03")

        XCTAssertEqual(official.map(\.day), ["2026-01-02"])
        XCTAssertEqual(official.first?.recovery, 80)
        XCTAssertEqual(local.map(\.day), ["2026-01-01"])
        XCTAssertEqual(local.first?.recovery, 60)

        let officialSeries = try await store.metricSeries(
            deviceId: deviceId, key: "recovery", from: "2026-01-01", to: "2026-01-03")
        let localSeries = try await store.metricSeries(
            deviceId: deviceId + "-noop", key: "recovery",
            from: "2026-01-01", to: "2026-01-03")
        let officialStress = try await store.metricSeries(
            deviceId: deviceId, key: "stress", from: "2026-01-02", to: "2026-01-02")
        let localStress = try await store.metricSeries(
            deviceId: deviceId + "-noop", key: "stress", from: "2026-01-01", to: "2026-01-01")
        XCTAssertEqual(officialSeries.map(\.day), ["2026-01-02"])
        XCTAssertEqual(localSeries.map(\.day), ["2026-01-01"])
        XCTAssertTrue(officialStress.isEmpty,
                      "WHOOP CSV does not provide Stress Monitor values; NOOP must not invent one in the official namespace")
        XCTAssertEqual(localStress.map(\.value), [1.2],
                       "a local export must not delete an analytics-owned value at the same natural key")
        let preservedOfficialStress = try await store.metricSeries(
            deviceId: deviceId, key: "stress", from: "2025-12-31", to: "2026-01-03")
        let preservedLocalStress = try await store.metricSeries(
            deviceId: deviceId + "-noop", key: "stress", from: "2025-12-31", to: "2026-01-03")
        let preservedNote = try await store.metricSeries(
            deviceId: deviceId, key: "note", from: "2026-01-02", to: "2026-01-02")
        let unrelatedStress = try await store.metricSeries(
            deviceId: "unrelated-device", key: "stress", from: "2026-01-02", to: "2026-01-02")
        XCTAssertEqual(preservedOfficialStress.map(\.day), ["2025-12-31", "2026-01-03"])
        XCTAssertEqual(preservedLocalStress.map(\.day), ["2025-12-31", "2026-01-01"])
        XCTAssertEqual(preservedNote.count, 1)
        XCTAssertEqual(unrelatedStress.count, 1)
        XCTAssertFalse((official + local).contains { $0.day == "2026-01-03" })
        XCTAssertEqual(
            WhoopReferenceImportManifest().verifiedDays(
                deviceId: deviceId,
                schemaRevision: WhoopImporter.schemaRevision,
                metricKey: "recovery"),
            Set(["2026-01-02"]))
        XCTAssertTrue(
            WhoopReferenceImportManifest().verifiedDays(
                deviceId: deviceId,
                schemaRevision: WhoopImporter.schemaRevision,
                metricKey: "hrv").isEmpty)
    }

    func testCalibrationSchemaRevisionIsDerivedFromImporterVersion() {
        XCTAssertEqual(
            WhoopImporter.schemaRevision,
            "whoop-csv-import-v\(WhoopImporter.importerVersion)")
    }

    func testReimportRemovesManagedSeriesValuesMissingFromNewerExport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-wearable-reimport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cyclesURL = directory.appendingPathComponent("physiological_cycles.csv")
        let workoutsURL = directory.appendingPathComponent("workouts.csv")
        try """
        Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Heart rate variability (ms)
        2026-01-01 22:00:00,2026-01-02 22:00:00,UTC+00:00,70,55
        """.write(to: cyclesURL, atomically: true, encoding: .utf8)
        try """
        Workout start time,Workout end time,Cycle timezone,Activity name,HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %
        2026-01-02 10:00:00,2026-01-02 11:00:00,UTC+00:00,Run,10,20,30,20,20
        """.write(to: workoutsURL, atomically: true, encoding: .utf8)

        let store = try await WhoopStore.inMemory()
        let deviceId = "test-reimport-\(UUID().uuidString)"
        defer { WhoopReferenceImportManifest().remove(deviceId: deviceId) }
        try await store.upsertMetricSeries(
            [MetricPoint(day: "2026-01-02", key: "unmanaged", value: 9)],
            deviceId: deviceId)

        _ = try await WhoopImporter.importExport(
            url: directory, into: store, deviceId: deviceId)

        try """
        Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Heart rate variability (ms)
        2026-01-01 22:00:00,2026-01-02 22:00:00,UTC+00:00,72,
        """.write(to: cyclesURL, atomically: true, encoding: .utf8)
        try """
        Workout start time,Workout end time,Cycle timezone,Activity name,HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %
        2026-01-02 10:00:00,2026-01-02 11:00:00,UTC+00:00,Mobility,,,,,
        """.write(to: workoutsURL, atomically: true, encoding: .utf8)

        _ = try await WhoopImporter.importExport(
            url: directory, into: store, deviceId: deviceId)

        let recovery = try await store.metricSeries(
            deviceId: deviceId, key: "recovery",
            from: "2026-01-02", to: "2026-01-02")
        let hrv = try await store.metricSeries(
            deviceId: deviceId, key: "hrv",
            from: "2026-01-02", to: "2026-01-02")
        let zone = try await store.metricSeries(
            deviceId: deviceId, key: "hr_zone3_min",
            from: "2026-01-02", to: "2026-01-02")
        let unmanaged = try await store.metricSeries(
            deviceId: deviceId, key: "unmanaged",
            from: "2026-01-02", to: "2026-01-02")

        XCTAssertEqual(recovery.map(\.value), [72])
        XCTAssertTrue(hrv.isEmpty)
        XCTAssertTrue(zone.isEmpty)
        XCTAssertEqual(unmanaged.map(\.value), [9])
    }

    func testAuthoritativeReimportRemovesInteriorRelationalRowsAndCalibrationFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-relational-reimport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cyclesURL = directory.appendingPathComponent("physiological_cycles.csv")
        let sleepsURL = directory.appendingPathComponent("sleeps.csv")
        let workoutsURL = directory.appendingPathComponent("workouts.csv")
        let allCycles = """
        Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Heart rate variability (ms),Resting heart rate (bpm)
        2026-04-01 22:00:00,2026-04-02 22:00:00,UTC+00:00,61,51,61
        2026-04-02 22:00:00,2026-04-03 22:00:00,UTC+00:00,62,52,62
        2026-04-03 22:00:00,2026-04-04 22:00:00,UTC+00:00,63,53,63
        """
        let allSleeps = """
        Cycle start time,Cycle timezone,Sleep onset,Wake onset,Nap,Sleep efficiency %,Light sleep duration (min)
        2026-04-01 22:00:00,UTC+00:00,2026-04-01 23:00:00,2026-04-02 07:00:00,false,90,360
        2026-04-02 22:00:00,UTC+00:00,2026-04-02 23:00:00,2026-04-03 07:00:00,false,91,365
        2026-04-03 22:00:00,UTC+00:00,2026-04-03 23:00:00,2026-04-04 07:00:00,false,92,370
        """
        let allWorkouts = """
        Workout start time,Workout end time,Cycle timezone,Activity name,Energy burned (cal)
        2026-04-02 10:00:00,2026-04-02 11:00:00,UTC+00:00,Run,200
        2026-04-03 10:00:00,2026-04-03 11:00:00,UTC+00:00,Ride,300
        2026-04-04 10:00:00,2026-04-04 11:00:00,UTC+00:00,Swim,400
        """
        try allCycles.write(to: cyclesURL, atomically: true, encoding: .utf8)
        try allSleeps.write(to: sleepsURL, atomically: true, encoding: .utf8)
        try allWorkouts.write(to: workoutsURL, atomically: true, encoding: .utf8)

        let store = try await WhoopStore.inMemory()
        let deviceId = "test-relational-reimport-\(UUID().uuidString)"
        let computedDeviceId = "\(deviceId)-noop"
        let manifest = WhoopReferenceImportManifest()
        defer { manifest.remove(deviceId: deviceId) }

        _ = try await WhoopImporter.importExport(
            url: directory, into: store, deviceId: deviceId)

        let retainedCycles = """
        Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Heart rate variability (ms),Resting heart rate (bpm)
        2026-04-01 22:00:00,2026-04-02 22:00:00,UTC+00:00,71,51,61
        2026-04-03 22:00:00,2026-04-04 22:00:00,UTC+00:00,73,53,63
        """
        let retainedSleeps = """
        Cycle start time,Cycle timezone,Sleep onset,Wake onset,Nap,Sleep efficiency %,Light sleep duration (min)
        2026-04-01 22:00:00,UTC+00:00,2026-04-01 23:00:00,2026-04-02 07:00:00,false,90,360
        2026-04-03 22:00:00,UTC+00:00,2026-04-03 23:00:00,2026-04-04 07:00:00,false,92,370
        """
        let retainedWorkouts = """
        Workout start time,Workout end time,Cycle timezone,Activity name,Energy burned (cal)
        2026-04-02 10:00:00,2026-04-02 11:00:00,UTC+00:00,Run,210
        2026-04-04 10:00:00,2026-04-04 11:00:00,UTC+00:00,Swim,410
        """
        try retainedCycles.write(to: cyclesURL, atomically: true, encoding: .utf8)
        try retainedSleeps.write(to: sleepsURL, atomically: true, encoding: .utf8)
        try retainedWorkouts.write(to: workoutsURL, atomically: true, encoding: .utf8)

        _ = try await WhoopImporter.importExport(
            url: directory, into: store, deviceId: deviceId)

        let days = try await store.dailyMetrics(
            deviceId: deviceId, from: "2026-04-02", to: "2026-04-04")
        XCTAssertEqual(days.map(\.day), ["2026-04-02", "2026-04-04"])
        XCTAssertEqual(days.map(\.recovery), [71, 73])

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func timestamp(_ value: String) throws -> Int {
            Int(try XCTUnwrap(formatter.date(from: value)).timeIntervalSince1970)
        }
        let firstSleep = try timestamp("2026-04-01 23:00:00")
        let middleSleep = try timestamp("2026-04-02 23:00:00")
        let lastSleep = try timestamp("2026-04-03 23:00:00")
        let sleeps = try await store.sleepSessions(
            deviceId: deviceId, from: firstSleep, to: lastSleep, limit: 10)
        XCTAssertEqual(sleeps.map(\.startTs), [firstSleep, lastSleep])
        XCTAssertFalse(sleeps.contains { $0.startTs == middleSleep })

        let firstWorkout = try timestamp("2026-04-02 10:00:00")
        let middleWorkout = try timestamp("2026-04-03 10:00:00")
        let lastWorkout = try timestamp("2026-04-04 10:00:00")
        let workouts = try await store.workouts(
            deviceId: deviceId, from: firstWorkout, to: lastWorkout, limit: 10)
        XCTAssertEqual(workouts.map(\.startTs), [firstWorkout, lastWorkout])
        XCTAssertFalse(workouts.contains { $0.startTs == middleWorkout })

        let verifiedOfficialDays = manifest.verifiedDays(
            deviceId: deviceId,
            schemaRevision: WhoopImporter.schemaRevision,
            metricKey: "recovery"
        )
        XCTAssertEqual(verifiedOfficialDays, Set(["2026-04-02", "2026-04-04"]))

        func computedDay(_ day: String, recovery: Double) -> DailyMetric {
            DailyMetric(
                day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                avgHrv: nil, recovery: recovery, strain: nil, exerciseCount: nil
            )
        }
        try await store.upsertDailyMetrics(
            [
                computedDay("2026-04-02", recovery: 76),
                computedDay("2026-04-03", recovery: 77),
                computedDay("2026-04-04", recovery: 78),
            ],
            deviceId: computedDeviceId
        )

        let report = try await WhoopReferenceCalibration.report(
            store: store,
            metric: .recoveryScore,
            importedDeviceId: deviceId,
            computedDeviceId: computedDeviceId,
            from: "2026-04-02",
            to: "2026-04-04",
            noopAlgorithmVersion: NoopScoreAlgorithmRevision.charge,
            verifiedOfficialReferenceDays: verifiedOfficialDays,
            verifiedCurrentNoopDays: Set(["2026-04-02", "2026-04-03", "2026-04-04"]),
            whoopImportSchemaRevision: WhoopImporter.schemaRevision
        )
        XCTAssertEqual(report.pairs.map(\.day), ["2026-04-02", "2026-04-04"])
        XCTAssertEqual(report.audit.unpairedNoopDays, 1)
        XCTAssertEqual(
            report.audit.unverifiedStoredOfficialDays,
            0,
            "the removed daily row must not return through the official daily-value fallback"
        )
    }

    func testWorkoutZoneTotalsRejectImpossibleRowsAndBoundRoundingOverflow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-zone-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        Workout start time,Workout end time,Cycle timezone,Activity name,HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %
        2026-01-02 10:00:00,2026-01-02 11:00:00,UTC+00:00,Run,20,20,20,20,21
        2026-01-03 10:00:00,2026-01-03 11:00:00,UTC+00:00,Run,21,21,21,21,21
        """.write(
            to: directory.appendingPathComponent("workouts.csv"),
            atomically: true,
            encoding: .utf8
        )

        let store = try await WhoopStore.inMemory()
        let deviceId = "test-zone-integrity-\(UUID().uuidString)"
        defer { WhoopReferenceImportManifest().remove(deviceId: deviceId) }
        _ = try await WhoopImporter.importExport(
            url: directory,
            into: store,
            deviceId: deviceId
        )

        let rounded = try await store.metricSeries(
            deviceId: deviceId,
            key: "hr_zones_all_min",
            from: "2026-01-02",
            to: "2026-01-02"
        )
        let impossible = try await store.metricSeries(
            deviceId: deviceId,
            key: "hr_zones_all_min",
            from: "2026-01-03",
            to: "2026-01-03"
        )
        XCTAssertEqual(try XCTUnwrap(rounded.first).value, 60, accuracy: 1e-9)
        XCTAssertTrue(impossible.isEmpty)
        for zone in 1...5 {
            let rows = try await store.metricSeries(
                deviceId: deviceId,
                key: "hr_zone\(zone)_min",
                from: "2026-01-03",
                to: "2026-01-03"
            )
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testApproximateProjectionFillsMissingRowsWithoutReplacingAnalyticsRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-fill-only-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Sleep efficiency %,Sleep performance %,Source
        2026-02-01 22:00:00,2026-02-02 22:00:00,UTC+00:00,90,55,90,91,noop (APPROXIMATE)
        2026-02-02 22:00:00,2026-02-03 22:00:00,UTC+00:00,80,56,80,81,noop (APPROXIMATE)
        """.write(
            to: directory.appendingPathComponent("physiological_cycles.csv"),
            atomically: true,
            encoding: .utf8
        )
        try """
        Cycle start time,Cycle timezone,Sleep onset,Wake onset,Nap,Sleep efficiency %,Light sleep duration (min),Source
        2026-02-01 22:00:00,UTC+00:00,2026-02-01 23:00:00,2026-02-02 07:00:00,false,90,400,noop (APPROXIMATE)
        2026-02-02 22:00:00,UTC+00:00,2026-02-02 23:00:00,2026-02-03 07:00:00,false,80,380,noop (APPROXIMATE)
        """.write(
            to: directory.appendingPathComponent("sleeps.csv"),
            atomically: true,
            encoding: .utf8
        )
        try """
        Workout start time,Workout end time,Cycle timezone,Activity name,Energy burned (cal),Source
        2026-02-02 10:00:00,2026-02-02 11:00:00,UTC+00:00,Run,999,noop (APPROXIMATE)
        2026-02-03 10:00:00,2026-02-03 11:00:00,UTC+00:00,Ride,200,noop (APPROXIMATE)
        """.write(
            to: directory.appendingPathComponent("workouts.csv"),
            atomically: true,
            encoding: .utf8
        )

        let store = try await WhoopStore.inMemory()
        let deviceId = "test-fill-only-\(UUID().uuidString)"
        let localDeviceId = "\(deviceId)-noop"
        defer { WhoopReferenceImportManifest().remove(deviceId: deviceId) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let sleepStart = Int(try XCTUnwrap(
            formatter.date(from: "2026-02-01 23:00:00")).timeIntervalSince1970)
        let secondSleepStart = Int(try XCTUnwrap(
            formatter.date(from: "2026-02-02 23:00:00")).timeIntervalSince1970)
        let workoutStart = Int(try XCTUnwrap(
            formatter.date(from: "2026-02-02 10:00:00")).timeIntervalSince1970)
        let secondWorkoutStart = Int(try XCTUnwrap(
            formatter.date(from: "2026-02-03 10:00:00")).timeIntervalSince1970)

        try await store.upsertDailyMetrics(
            [
                DailyMetric(
                    day: "2026-02-02", totalSleepMin: 333, efficiency: 0.5,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: nil, avgHrv: nil, recovery: 12, strain: nil,
                    exerciseCount: nil
                ),
            ],
            deviceId: localDeviceId
        )
        try await store.upsertSleepSessions(
            [
                CachedSleepSession(
                    startTs: sleepStart, endTs: sleepStart + 20_000, efficiency: 0.5,
                    restingHr: nil, avgHrv: nil, stagesJSON: "{\"analytics\":1}"
                ),
            ],
            deviceId: localDeviceId
        )
        try await store.upsertMetricSeries(
            [
                MetricPoint(day: "2026-02-02", key: "recovery", value: 13),
                MetricPoint(day: "2026-02-02", key: "sleep_performance", value: 14),
            ],
            deviceId: localDeviceId
        )
        try await store.upsertWorkouts(
            [
                WorkoutRow(
                    startTs: workoutStart, endTs: workoutStart + 1_800, sport: "Run",
                    source: "analytics", durationS: 1_800, energyKcal: 15,
                    avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                    zonesJSON: nil, notes: nil
                ),
            ],
            deviceId: localDeviceId
        )

        _ = try await WhoopImporter.importExport(
            url: directory, into: store, deviceId: deviceId)

        let days = try await store.dailyMetrics(
            deviceId: localDeviceId, from: "2026-02-02", to: "2026-02-03")
        XCTAssertEqual(days.map(\.recovery), [12, 80])
        XCTAssertEqual(days.first?.totalSleepMin, 333)
        XCTAssertEqual(days.first?.efficiency, 0.5)
        XCTAssertEqual(days.first?.restingHr, 55)

        let sleeps = try await store.sleepSessions(
            deviceId: localDeviceId,
            from: sleepStart,
            to: secondSleepStart,
            limit: 10
        )
        XCTAssertEqual(sleeps.map(\.efficiency), [0.5, 0.8])
        XCTAssertEqual(sleeps.first?.endTs, sleepStart + 20_000)
        XCTAssertEqual(sleeps.first?.stagesJSON, "{\"analytics\":1}")

        let recovery = try await store.metricSeries(
            deviceId: localDeviceId, key: "recovery",
            from: "2026-02-02", to: "2026-02-03")
        XCTAssertEqual(recovery.map(\.value), [13, 80])
        let performance = try await store.metricSeries(
            deviceId: localDeviceId, key: "sleep_performance",
            from: "2026-02-02", to: "2026-02-03")
        XCTAssertEqual(performance.map(\.value), [14, 81])

        let workouts = try await store.workouts(
            deviceId: localDeviceId,
            from: workoutStart,
            to: secondWorkoutStart,
            limit: 10
        )
        XCTAssertEqual(workouts.map(\.energyKcal), [15, 200])
        XCTAssertEqual(workouts.first?.endTs, workoutStart + 1_800)
    }

    func testOnePercentSleepEfficiencyUsesFractionInWideAndSeriesRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-efficiency-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        Cycle start time,Cycle end time,Cycle timezone,Sleep efficiency %
        2026-03-01 22:00:00,2026-03-02 22:00:00,UTC+00:00,1
        """.write(
            to: directory.appendingPathComponent("physiological_cycles.csv"),
            atomically: true,
            encoding: .utf8
        )

        let store = try await WhoopStore.inMemory()
        let deviceId = "test-efficiency-\(UUID().uuidString)"
        defer { WhoopReferenceImportManifest().remove(deviceId: deviceId) }
        _ = try await WhoopImporter.importExport(
            url: directory, into: store, deviceId: deviceId)

        let days = try await store.dailyMetrics(
            deviceId: deviceId, from: "2026-03-02", to: "2026-03-02")
        let seriesRows = try await store.metricSeries(
            deviceId: deviceId, key: "sleep_efficiency",
            from: "2026-03-02", to: "2026-03-02")
        let day = try XCTUnwrap(days.first)
        let series = try XCTUnwrap(seriesRows.first)
        XCTAssertEqual(day.efficiency ?? -1, 0.01, accuracy: 1e-12)
        XCTAssertEqual(series.value, 0.01, accuracy: 1e-12)
    }

    func testExtremeFiniteHeartRatesAreTreatedAsMissingInsteadOfTrapping() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-finite-int-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        Cycle start time,Cycle end time,Cycle timezone,Resting heart rate (bpm)
        2026-03-01 22:00:00,2026-03-02 22:00:00,UTC+00:00,1e300
        """.write(
            to: directory.appendingPathComponent("physiological_cycles.csv"),
            atomically: true,
            encoding: .utf8
        )
        try """
        Workout start time,Workout end time,Cycle timezone,Activity name,Average HR (bpm),Max HR (bpm)
        2026-03-02 10:00:00,2026-03-02 11:00:00,UTC+00:00,Run,1e300,-1e300
        """.write(
            to: directory.appendingPathComponent("workouts.csv"),
            atomically: true,
            encoding: .utf8
        )

        let store = try await WhoopStore.inMemory()
        let deviceId = "test-finite-int-\(UUID().uuidString)"
        defer { WhoopReferenceImportManifest().remove(deviceId: deviceId) }
        _ = try await WhoopImporter.importExport(
            url: directory,
            into: store,
            deviceId: deviceId
        )

        let days = try await store.dailyMetrics(
            deviceId: deviceId, from: "2026-03-02", to: "2026-03-02")
        XCTAssertNil(try XCTUnwrap(days.first).restingHr)
        let workouts = try await store.workouts(
            deviceId: deviceId, from: 0, to: Int.max, limit: 10)
        let workout = try XCTUnwrap(workouts.first)
        XCTAssertNil(workout.avgHr)
        XCTAssertNil(workout.maxHr)
    }

    func testReferenceManifestIsMetricAndImporterRevisionScoped() throws {
        let suite = "noop-reference-manifest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = WhoopReferenceImportManifest(
            defaults: defaults, namespace: "test.referenceManifest")
        manifest.recordOfficialMetrics(
            [
                (day: "2026-01-01", metricKey: "recovery"),
                (day: "2026-01-02", metricKey: "strain"),
                (day: "not-a-day", metricKey: "recovery"),
            ],
            deviceId: "my-whoop",
            schemaRevision: "import-v2")

        XCTAssertEqual(
            manifest.verifiedDays(
                deviceId: "my-whoop", schemaRevision: "import-v2", metricKey: "recovery"),
            Set(["2026-01-01"]))
        XCTAssertEqual(
            manifest.verifiedDays(
                deviceId: "my-whoop", schemaRevision: "import-v2", metricKey: "strain"),
            Set(["2026-01-02"]))
        XCTAssertTrue(
            manifest.verifiedDays(
                deviceId: "my-whoop", schemaRevision: "import-v1", metricKey: "recovery").isEmpty)

        manifest.replaceOfficialMetrics(
            [(day: "2026-01-02", metricKey: "recovery")],
            deviceId: "my-whoop",
            schemaRevision: "import-v3",
            from: "2026-01-01",
            to: "2026-01-02",
            managedKeys: ["recovery"]
        )
        XCTAssertEqual(
            manifest.verifiedDays(
                deviceId: "my-whoop", schemaRevision: "import-v3", metricKey: "recovery"),
            Set(["2026-01-02"]))
        XCTAssertTrue(
            manifest.verifiedDays(
                deviceId: "my-whoop", schemaRevision: "import-v2", metricKey: "recovery").isEmpty)
        XCTAssertEqual(
            manifest.verifiedDays(
                deviceId: "my-whoop", schemaRevision: "import-v2", metricKey: "strain"),
            Set(["2026-01-02"]),
            "replacement must not remove provenance for unmanaged metric keys"
        )
    }
}
