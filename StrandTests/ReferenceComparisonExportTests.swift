import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

final class ReferenceComparisonExportTests: XCTestCase {
    private let algorithmVersion = "noop-charge-test-v1"

    func testSummaryScopeContainsOnlyAggregateComparisonInformation() throws {
        let package = try XCTUnwrap(
            ReferenceComparisonExport.makePackage(
                report: report(),
                metricName: "Charge",
                units: "0–100 score",
                context: .init(
                    appVersion: "9.1.1",
                    platform: "iOS",
                    whoopImporterRevision: "whoop-csv-import-v2"
                ),
                scope: .summaryOnly,
                date: Date(timeIntervalSince1970: 0)
            )
        )

        XCTAssertEqual(package.entries.map(\.name), ["summary.txt"])
        let summary = try text(named: "summary.txt", in: package)
        XCTAssertTrue(summary.contains("Scope: Aggregate summary only"))
        XCTAssertTrue(summary.contains("Paired days: 3"))
        XCTAssertTrue(summary.contains("Comparison span: 10 calendar days"))
        XCTAssertTrue(summary.contains("Bias: +1.666667"))
        XCTAssertTrue(summary.contains("Mean absolute error (MAE): 2.333333"))
        XCTAssertTrue(summary.contains("Root mean squared error (RMSE): 2.645751"))
        XCTAssertTrue(summary.contains("Provider import revision: wearable-csv-import-v2"))
        XCTAssertTrue(summary.contains("NOOP algorithm revision: \(algorithmVersion)"))
        XCTAssertTrue(summary.contains("NOOP did not upload this export"))
        XCTAssertTrue(summary.contains("TESTER SHARING CHECKLIST"))
        XCTAssertTrue(summary.contains("[ ] Latest original, unmodified wearable export ZIP"))
        XCTAssertTrue(summary.contains("[ ] This NOOP comparison ZIP"))
        XCTAssertTrue(summary.contains("select both ZIPs together"))
        XCTAssertTrue(summary.contains("Share → Messages"))
        XCTAssertTrue(summary.contains("same iMessage conversation with your trial coordinator"))
        XCTAssertTrue(summary.contains("NOOP does not choose a recipient"))

        // Aggregate-only means neither study dates nor daily values/personal means are encoded.
        XCTAssertFalse(summary.contains("2026-06-01"))
        XCTAssertFalse(summary.contains("2026-06-03"))
        XCTAssertFalse(summary.contains("2026-06-10"))
        XCTAssertFalse(summary.contains("Official mean:"))
        XCTAssertFalse(summary.contains("NOOP mean:"))
        XCTAssertFalse(summary.contains("daily_pairs.csv"))
        XCTAssertFalse(package.suggestedName.contains("2026-06"))
        assertNoRetiredBrand(in: package)
    }

    func testExactScopeAddsSortedDailyPairsOnlyAfterThatScopeIsRequested() throws {
        let package = try XCTUnwrap(
            ReferenceComparisonExport.makePackage(
                report: report(),
                metricName: "Charge",
                units: "0–100 score",
                context: .init(
                    appVersion: "9.1.1",
                    platform: "iOS",
                    whoopImporterRevision: "whoop-csv-import-v2"
                ),
                scope: .exactDailyPairs,
                date: Date(timeIntervalSince1970: 0)
            )
        )

        XCTAssertEqual(package.entries.map(\.name), ["summary.txt", "daily_pairs.csv"])
        let summary = try text(named: "summary.txt", in: package)
        XCTAssertTrue(summary.contains("Scope: Aggregate summary plus exact daily pairs"))
        XCTAssertTrue(summary.contains("Treat that CSV as sensitive health data"))
        XCTAssertFalse(summary.contains("2026-06-01"))

        let csv = try text(named: "daily_pairs.csv", in: package)
        XCTAssertEqual(
            csv,
            """
            day,official_provider_value,noop_value,noop_minus_official
            2026-06-01,70,72,+2
            2026-06-03,80,79,-1
            2026-06-10,90,94,+4

            """
        )
        assertNoRetiredBrand(in: package)
    }

    func testNoStatisticsProducesNoExportPackage() {
        let emptyReport = WhoopReferenceCalibration.report(
            metric: .recoveryScore,
            observations: [],
            noopAlgorithmVersion: algorithmVersion
        )

        XCTAssertNil(
            ReferenceComparisonExport.makePackage(
                report: emptyReport,
                metricName: "Charge",
                units: "0–100 score",
                context: .init(
                    appVersion: "9.1.1",
                    platform: "macOS",
                    whoopImporterRevision: "whoop-csv-import-v2"
                ),
                scope: .summaryOnly
            )
        )
    }

    func testPortableComparisonSidecarsAreSourceSeparatedAndIdentifierFree() throws {
        let importedDay = DailyMetric(
            day: "2026-06-01",
            totalSleepMin: 420,
            efficiency: 0.92,
            deepMin: 95,
            remMin: 115,
            lightMin: 210,
            disturbances: 5,
            restingHr: 52,
            avgHrv: 68.4,
            recovery: 72,
            strain: 45,
            exerciseCount: 1,
            spo2Pct: 96,
            skinTempDevC: 33.1,
            respRateBpm: 14.2,
            steps: 6_000,
            activeKcalEst: 350,
            hrvMethod: .sdnn
        )
        let computedDay = DailyMetric(
            day: "2026-06-01",
            totalSleepMin: 400,
            efficiency: 0.9,
            deepMin: 80,
            remMin: 100,
            lightMin: 220,
            disturbances: 3,
            restingHr: 55,
            avgHrv: 42,
            recovery: 61,
            strain: 42,
            exerciseCount: 1,
            skinTempDevC: 0.2,
            respRateBpm: 15.2,
            steps: 5_000,
            activeKcalEst: 300,
            spo2Red: 10,
            spo2Ir: 20,
            hrvMethod: .rmssd
        )
        let sleep = CachedSleepSession(
            startTs: 0,
            endTs: 3_600,
            efficiency: 0.8,
            restingHr: 54,
            avgHrv: 50,
            stagesJSON: #"{"light":30,"deep":10,"rem":8,"awake":12}"#,
            userEdited: true,
            rrEligibleWindowCount: 10,
            rrValidWindowCount: 8
        )
        let workout = WorkoutRow(
            startTs: 0,
            endTs: 1_800,
            sport: "=private formula",
            source: "device-secret-noop",
            durationS: 1_800,
            energyKcal: 220,
            avgHr: 145,
            maxHr: 172,
            strain: 37.5,
            distanceM: 5_000,
            zonesJSON: #"{"z1":5,"z2":15,"z3":40,"z4":30,"z5":10}"#,
            notes: "private note",
            steps: 4_200
        )
        let entries = try CsvExport.comparisonEntries(
            context: .init(
                generatedAtUTC: "2026-08-28T12:00:00Z",
                platform: "iOS",
                appVersion: "9.2.0"
            ),
            daily: [
                .init(source: .wearableImport, metric: importedDay,
                      publishDetailedStages: true),
                .init(source: .noopComputed, metric: computedDay,
                      publishDetailedStages: false),
            ],
            sleeps: [
                .init(source: .noopComputed, session: sleep,
                      publishDetailedStages: true),
            ],
            workouts: [
                .init(source: .noopComputed, workout: workout),
            ],
            metricSeries: [
                .init(source: .wearableImport, day: "2026-06-01",
                      key: "recovery", value: 72),
                .init(source: .noopComputed, day: "2026-06-01",
                      key: "skin_temp", value: 0.2),
            ],
            detectorDecisions: [
                AutoWorkoutDecisionRecord(
                    candidateStartSec: 60,
                    candidateEndSec: 1_860,
                    recordedAtSec: 2_000,
                    action: .accepted,
                    actor: .user,
                    activityName: "Running",
                    detectorVersion: AutoWorkoutDetector.detectorVersion,
                    averageBpm: 145,
                    peakBpm: 172,
                    eventConfidence: nil,
                    confidenceStatus: "uncalibrated",
                    evidenceProvenance: "heart_rate_and_motion",
                    suggestedClass: "run",
                    suggestionConfidence: 0.8,
                    origin: "recorded_event"
                ),
                AutoWorkoutDecisionRecord(
                    candidateStartSec: 3_000,
                    candidateEndSec: nil,
                    recordedAtSec: nil,
                    action: .dismissed,
                    actor: .user,
                    activityName: nil,
                    detectorVersion: nil,
                    averageBpm: nil,
                    peakBpm: nil,
                    eventConfidence: nil,
                    confidenceStatus: nil,
                    evidenceProvenance: nil,
                    suggestedClass: nil,
                    suggestionConfidence: nil,
                    origin: "legacy_dismissal_tombstone"
                ),
            ]
        )
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.data) })

        XCTAssertEqual(
            String(decoding: try XCTUnwrap(byName["comparison/daily_metrics.csv"]),
                   as: UTF8.self),
            """
            source,day,recovery_score_0_100,effort_score_0_100,total_sleep_min,sleep_efficiency_fraction,light_sleep_min,deep_sleep_min,rem_sleep_min,disturbances_count,resting_hr_bpm,hrv_ms,hrv_method,spo2_pct,skin_temperature_value_c,skin_temperature_semantics,respiratory_rate_per_min,steps_count,energy_kcal,raw_spo2_red_adc,raw_spo2_ir_adc,detailed_sleep_stages_status\r
            noop_computed,2026-06-01,61,42,400,0.9,,,,3,55,42,RMSSD,,0.2,deviation_from_personal_baseline,15.2,5000,300,10,20,withheld_insufficient_evidence\r
            wearable_import,2026-06-01,72,45,420,0.92,210,95,115,5,52,68.4,SDNN,96,33.1,absolute_temperature,14.2,6000,350,,,available\r

            """
        )
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(byName["comparison/metric_series.csv"]),
                   as: UTF8.self),
            """
            source,day,metric_key,value,unit\r
            noop_computed,2026-06-01,skin_temp,0.2,celsius_delta_from_baseline\r
            wearable_import,2026-06-01,recovery,72,score_0_100\r

            """
        )

        let workoutCSV = String(
            decoding: try XCTUnwrap(byName["comparison/workouts.csv"]),
            as: UTF8.self
        )
        XCTAssertTrue(workoutCSV.contains("noop_computed,1970-01-01T00:00:00Z"))
        XCTAssertTrue(workoutCSV.contains("'=private formula"))
        XCTAssertFalse(workoutCSV.contains("private note"))
        XCTAssertFalse(workoutCSV.contains("device-secret"))

        let decisionsCSV = String(
            decoding: try XCTUnwrap(byName["comparison/detector_decisions.csv"]),
            as: UTF8.self
        )
        XCTAssertTrue(decisionsCSV.contains(
            "accepted,user,Running,\(AutoWorkoutDetector.detectorVersion),145,172,,run,0.8,"
                + "uncalibrated,heart_rate_and_motion,recorded_event"
        ))
        XCTAssertTrue(decisionsCSV.contains(
            "1970-01-01T00:50:00Z,,,dismissed,user,,,,,,,,,,legacy_dismissal_tombstone"
        ))

        let manifestData = try XCTUnwrap(byName["comparison/manifest.json"])
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        XCTAssertEqual(manifest["schema"] as? String, "noop.parallel_wear.v1")
        XCTAssertEqual(manifest["contains_device_identifiers"] as? Bool, false)
        XCTAssertEqual(
            manifest["detector_decisions_schema"] as? String,
            "noop.detector_decisions.v1"
        )
        XCTAssertEqual(
            (manifest["algorithm_revisions"] as? [String: Any])?["auto_workout_detector"]
                as? String,
            AutoWorkoutDetector.detectorVersion
        )

        let detectorData = try XCTUnwrap(byName["comparison/workout_detector.json"])
        let detector = try XCTUnwrap(
            JSONSerialization.jsonObject(with: detectorData) as? [String: Any]
        )
        XCTAssertEqual(detector["event_confidence_status"] as? String, "uncalibrated")
        XCTAssertEqual(detector["unattended_save_permitted"] as? Bool, false)
        let decisionHistory = detector["decision_history"] as? [String: Any]
        XCTAssertEqual(
            decisionHistory?["computed_workout_rows_imply_acceptance"] as? Bool,
            false
        )

        for data in byName.values {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("device-secret"))
            XCTAssertFalse(text.contains("private note"))
        }
    }

    func testDetectorDecisionHistoryDeduplicatesAndKeepsLegacyUnknownsHonest() throws {
        let suiteName = "ReferenceComparisonExportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let candidate = DetectedWorkout(
            startSec: 1_000,
            endSec: 2_000,
            avgBpm: 140,
            peakBpm: 170,
            durationMin: 16,
            suggestedClass: .run,
            suggestionConfidence: 0.75,
            evidenceProvenance: .heartRateAndMotion
        )

        AutoWorkoutDecisionHistory.record(
            candidate: candidate,
            action: .accepted,
            actor: .user,
            activityName: "Running",
            nowSec: 2_100,
            defaults: defaults
        )
        AutoWorkoutDecisionHistory.record(
            candidate: candidate,
            action: .accepted,
            actor: .user,
            activityName: "Running",
            nowSec: 2_200,
            defaults: defaults
        )

        let exported = AutoWorkoutDecisionHistory.exportRecords(
            legacyDismissedTokens: ["start:3000", "4000:5000", "broken"],
            defaults: defaults
        )
        XCTAssertEqual(exported.filter { $0.action == .accepted }.count, 1)
        XCTAssertEqual(
            exported.first { $0.action == .accepted }?.recordedAtSec,
            2_200
        )
        let modernLegacy = try XCTUnwrap(
            exported.first { $0.candidateStartSec == 3_000 }
        )
        XCTAssertNil(modernLegacy.candidateEndSec)
        XCTAssertNil(modernLegacy.recordedAtSec)
        XCTAssertEqual(modernLegacy.origin, "legacy_dismissal_tombstone")
        XCTAssertEqual(
            exported.first { $0.candidateStartSec == 4_000 }?.candidateEndSec,
            5_000
        )
    }

    private func report() -> WhoopReferenceComparisonReport {
        let rows: [(day: String, official: Double, noop: Double)] = [
            ("2026-06-10", 90, 94),
            ("2026-06-01", 70, 72),
            ("2026-06-03", 80, 79),
        ]
        let observations = rows.flatMap { row in
            [
                ReferenceMetricObservation.whoopExport(
                    day: row.day,
                    metric: .recoveryScore,
                    value: row.official,
                    schemaRevision: "whoop-csv-import-v2"
                ),
                ReferenceMetricObservation.noopComputed(
                    day: row.day,
                    metric: .recoveryScore,
                    value: row.noop,
                    algorithmVersion: algorithmVersion
                ),
            ]
        }
        return WhoopReferenceCalibration.report(
            metric: .recoveryScore,
            observations: observations,
            noopAlgorithmVersion: algorithmVersion
        )
    }

    private func text(
        named name: String,
        in package: ReferenceComparisonExport.ExportPackage
    ) throws -> String {
        let entry = try XCTUnwrap(package.entries.first { $0.name == name })
        return try XCTUnwrap(String(data: entry.data, encoding: .utf8))
    }

    private func assertNoRetiredBrand(
        in package: ReferenceComparisonExport.ExportPackage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            package.suggestedName.localizedCaseInsensitiveContains("whoop"),
            file: file,
            line: line
        )
        for entry in package.entries {
            let text = String(data: entry.data, encoding: .utf8) ?? ""
            XCTAssertFalse(text.localizedCaseInsensitiveContains("whoop"), file: file, line: line)
        }
    }
}
