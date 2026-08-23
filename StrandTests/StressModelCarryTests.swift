import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Presentation-level coverage for the causal `DailyAutonomicLoad` integration. The analytics package
/// owns the scoring edge cases; these tests pin that the app model preserves real as-of dates and never
/// revives opaque imported stress values or a fabricated neutral score.
final class StressModelCarryTests: XCTestCase {

    private func day(_ d: String, rhr: Int?, hrv: Double?) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    // Varied physiology is intentional: a perfectly flat baseline must not produce a fake 1.5.
    private var baseline: [DailyMetric] {
        (1...30).map { i in
            day(String(format: "2026-06-%02d", i),
                rhr: 53 + (i % 5), hrv: 56 + Double((i * 3) % 9))
        } + [day("2026-07-01", rhr: 55, hrv: 60)]
    }

    func testVitalsLessTodayCarriesInsteadOfCalibrating() {
        // Control: today HAS vitals → builds (unchanged).
        XCTAssertNotNil(StressModel(days: baseline + [day("2026-07-02", rhr: 58, hrv: 45)], stored: []))
        // The fix: today has NO RHR/HRV yet (the post-update window) but a prior day does → carries, not nil.
        XCTAssertNotNil(StressModel(days: baseline + [day("2026-07-02", rhr: nil, hrv: nil)], stored: []),
                        "a vitals-less today must carry the last day with RHR/HRV, not calibrate")
        let carried = StressModel(days: baseline + [day("2026-07-02", rhr: nil, hrv: nil)], stored: [])
        XCTAssertEqual(carried?.asOfDay, "2026-07-01")
        XCTAssertTrue(carried?.limitations.contains(.staleSourceDay) == true)
    }

    func testNoVitalsAnywhereStillCalibrates() {
        // Genuine cold start: no day has RHR/HRV and nothing stored → honestly calibrating (nil).
        let days = (1...5).map { day("2026-07-0\($0)", rhr: nil, hrv: nil) }
        XCTAssertNil(StressModel(days: days, stored: []))
    }

    func testOpaqueStoredStressDoesNotOverrideCausalEstimate() {
        // The source and algorithm behind an opaque persisted "stress" row are not guaranteed to match
        // this experimental proxy, so the model ignores it and truthfully carries the prior observed day.
        let days = baseline + [day("2026-07-02", rhr: nil, hrv: nil)]
        let model = StressModel(days: days, stored: [(day: "2026-07-02", value: 2.5)])
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.asOfDay, "2026-07-01")
        XCTAssertFalse(model?.usingStored ?? true)
        XCTAssertNotEqual(model?.score ?? -1, 2.5, accuracy: 0.001)
    }

    func testFlatBaselineDoesNotManufactureNeutralScore() {
        let flat = (1...8).map {
            day(String(format: "2026-07-%02d", $0), rhr: 55, hrv: 60)
        }
        XCTAssertNil(StressModel(days: flat, stored: []))
    }

    func testAppendingFutureDayCannotRewriteHistoricalScore() {
        let target = day("2026-07-02", rhr: 59, hrv: 51)
        let original = StressModel(days: baseline + [target], stored: [])
        let withFuture = StressModel(days: baseline + [target, day("2026-07-03", rhr: 90, hrv: 12)], stored: [])
        let originalTarget = original?.fullTrend.first { Self.key($0.date) == "2026-07-02" }?.value
        let futureTarget = withFuture?.fullTrend.first { Self.key($0.date) == "2026-07-02" }?.value
        XCTAssertNotNil(originalTarget)
        XCTAssertEqual(originalTarget ?? -1, futureTarget ?? -2, accuracy: 1e-12)
    }

    func testSourceAwareModelPrefersScorableDirectStrapSeries() {
        let direct = variedDays(startDay: 1, count: 10, month: 7).map {
            SourcedDailyMetric(metric: $0, source: .noopComputed)
        }
        let apple = variedDays(startDay: 1, count: 20, month: 6).map {
            SourcedDailyMetric(metric: $0, source: .appleHealth)
        }
        let model = StressModel(sourceRows: apple + direct)
        XCTAssertEqual(model?.sourceTitle, "NOOP strap")
        XCTAssertGreaterThanOrEqual(model?.baselineDays ?? 0, 7)
    }

    func testSourceAwareModelUsesAppleReferenceWhileNewStrapCalibrates() {
        let direct = variedDays(startDay: 9, count: 3, month: 7).map {
            SourcedDailyMetric(metric: $0, source: .noopComputed)
        }
        let apple = variedDays(startDay: 1, count: 20, month: 6).map {
            SourcedDailyMetric(metric: $0, source: .appleHealth)
        }
        let model = StressModel(sourceRows: direct + apple)
        XCTAssertEqual(model?.sourceTitle, "Apple Health reference")
        XCTAssertTrue(model?.sourceNote?.contains("HRV sampling and method may differ") == true)
        XCTAssertGreaterThanOrEqual(model?.baselineDays ?? 0, 7)
    }

    func testSourceAwareModelNeverCombinesShortSourcesIntoBaseline() {
        let direct = variedDays(startDay: 1, count: 4, month: 7).map {
            SourcedDailyMetric(metric: $0, source: .noopComputed)
        }
        let apple = variedDays(startDay: 5, count: 4, month: 7).map {
            SourcedDailyMetric(metric: $0, source: .appleHealth)
        }
        XCTAssertNil(StressModel(sourceRows: direct + apple),
                     "four strap plus four Apple days must not become a blended seven-day baseline")
    }

    func testSourceAwareTodayCanRejectAnOlderCarriedRead() {
        let currentDay = "2026-07-11"
        let direct = variedDays(startDay: 1, count: 10, month: 7).map {
            SourcedDailyMetric(metric: $0, source: .noopComputed)
        } + [SourcedDailyMetric(metric: day(currentDay, rhr: nil, hrv: nil), source: .noopComputed)]

        let model = StressModel(sourceRows: direct)
        XCTAssertEqual(model?.asOfDay, "2026-07-10")
        XCTAssertTrue(model?.limitations.contains(.staleSourceDay) == true)
        XCTAssertNotEqual(model?.asOfDay, currentDay,
                          "Today must not relabel a carried stress estimate as a current reading")
    }

    func testCausalReportSeriesIgnoresOpaquePersistedStress() {
        let rows = variedDays(startDay: 1, count: 12, month: 7).map {
            SourcedDailyMetric(metric: $0, source: .noopComputed)
        }
        let assessment = StressModel.preferredAssessment(sourceRows: rows)
        let causal = DailyAutonomicLoad.causalTrend(days: StressModel.engineDays(assessment.days))
        let map = Dictionary(causal.compactMap { read -> (String, Double)? in
            guard let day = read.asOf, let value = read.value else { return nil }
            return (day, value)
        }, uniquingKeysWith: { _, latest in latest })

        XCTAssertFalse(map.isEmpty)
        XCTAssertNil(map["legacy-import-only"],
                     "Report input must come from the causal source series, never an opaque stored stress point")
        XCTAssertTrue(map.values.allSatisfy { (0...3).contains($0) })
    }

    private func variedDays(startDay: Int, count: Int, month: Int) -> [DailyMetric] {
        (0..<count).map { offset in
            let i = startDay + offset
            return day(String(format: "2026-%02d-%02d", month, i),
                       rhr: 52 + (i % 7), hrv: 54 + Double((i * 5) % 13))
        }
    }

    private static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

/// Pins the fail-closed contract between the Automations UI and the automatic stress detector. The
/// source path is available, but every event still needs fresh timestamp-matched wrist evidence.
final class BiofeedbackCapabilityTests: XCTestCase {

    func testCurrentLiveSourceCanHonorExplicitAutomaticStressOptIn() {
        XCTAssertTrue(BiofeedbackPrefs.automaticStressNudgesAvailable)

        let config = BiofeedbackPrefs.stressConfig(
            storedCheckInEnabled: true,
            storedAutoNudge: true,
            capability: BiofeedbackPrefs.automaticStressNudgeCapability)

        XCTAssertTrue(config.enabled)
        XCTAssertTrue(config.autoNudge)
    }

    func testUnavailableSourceCannotHonorStoredChoices() {
        let config = BiofeedbackPrefs.stressConfig(
            storedCheckInEnabled: true,
            storedAutoNudge: true,
            capability: .unavailableNeedsTimestampMatchedWristMotion,
            quietHoursEnabled: false)

        XCTAssertFalse(config.enabled)
        XCTAssertFalse(config.autoNudge)
        XCTAssertFalse(config.quietHoursEnabled)
    }

    func testCapabilityDoesNotOverrideUserOptOut() {
        let config = BiofeedbackPrefs.stressConfig(
            storedCheckInEnabled: false,
            storedAutoNudge: true,
            capability: .availableWithTimestampMatchedWristMotion)

        XCTAssertFalse(config.enabled)
        XCTAssertFalse(config.autoNudge,
                       "a stale child opt-in must not bypass the stored master opt-out")
    }
}
