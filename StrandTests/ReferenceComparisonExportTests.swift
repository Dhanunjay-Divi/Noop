import XCTest
import StrandAnalytics
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
        XCTAssertTrue(summary.contains("WHOOP import revision: whoop-csv-import-v2"))
        XCTAssertTrue(summary.contains("NOOP algorithm revision: \(algorithmVersion)"))
        XCTAssertTrue(summary.contains("NOOP did not upload this export"))
        XCTAssertTrue(summary.contains("TESTER SHARING CHECKLIST"))
        XCTAssertTrue(summary.contains("[ ] Latest original, unmodified WHOOP export ZIP"))
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
            day,official_whoop_value,noop_value,noop_minus_official
            2026-06-01,70,72,+2
            2026-06-03,80,79,-1
            2026-06-10,90,94,+4

            """
        )
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
}
