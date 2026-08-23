import Foundation
import XCTest
import WhoopStore
@testable import StrandAnalytics

final class IllnessSignalPipelineTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func day(_ offset: Int, from anchor: String = "2026-08-23",
                     rhr: Int? = 50, hrv: Double? = 60,
                     skin: Double? = 0, respiration: Double? = 14) -> DailyMetric {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let date = calendar.date(
            byAdding: .day,
            value: offset,
            to: formatter.date(from: anchor)!
        )!
        return DailyMetric(
            day: formatter.string(from: date),
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv,
            recovery: nil, strain: nil, exerciseCount: nil,
            skinTempDevC: skin, respRateBpm: respiration
        )
    }

    func testFreshCorroboratedShiftUsesOnlyTrustedPerSignalBaselines() {
        var days = (-30 ... -3).map { offset in
            day(offset, rhr: 50 + (offset.isMultiple(of: 2) ? 1 : -1),
                hrv: 60 + (offset.isMultiple(of: 2) ? 2 : -2),
                skin: 0, respiration: 14)
        }
        days += [
            day(-1, rhr: 60, hrv: 40, skin: 0.9, respiration: 18),
            day(0, rhr: 60, hrv: 40, skin: 0.9, respiration: 18),
        ]

        let prepared = IllnessSignalPipeline.prepare(days: days, todayKey: "2026-08-23")
        XCTAssertEqual(prepared.trustedSignalCount, 4)
        XCTAssertTrue(prepared.baselineTrusted)
        let result = IllnessSignalEngine.evaluate(
            prepared.inputs,
            context: .init(baselineTrusted: prepared.baselineTrusted),
            firedLabels: prepared.firedLabels
        )
        XCTAssertEqual(result.level, .raised)
        XCTAssertGreaterThanOrEqual(result.signalCount, 2)
    }

    func testTrustedQuietSignalsAreNotReportedAsStillLearning() {
        let days = (-30 ... -3).map { day($0) } + [day(-1), day(0)]
        let prepared = IllnessSignalPipeline.prepare(days: days, todayKey: "2026-08-23")
        XCTAssertTrue(prepared.baselineTrusted)
        let result = IllnessSignalEngine.evaluate(
            prepared.inputs,
            context: .init(baselineTrusted: prepared.baselineTrusted),
            firedLabels: prepared.firedLabels
        )
        XCTAssertEqual(result.level, .quiet)
        XCTAssertTrue(result.copy.contains("No corroborated shift"))
        XCTAssertFalse(result.copy.contains("learning"))
    }

    func testSparseRowsDoNotCompressCalendarGapsIntoTrustedHistory() {
        var days = (-60 ... -33).map { day($0) }
        days += [
            day(-1, rhr: 65, hrv: 30, skin: 1.2, respiration: 20),
            day(0, rhr: 65, hrv: 30, skin: 1.2, respiration: 20),
        ]
        let prepared = IllnessSignalPipeline.prepare(days: days, todayKey: "2026-08-23")
        XCTAssertEqual(prepared.trustedSignalCount, 0)
        XCTAssertFalse(prepared.baselineTrusted)
        XCTAssertFalse(prepared.inputs.restingHR?.present ?? true)
    }

    func testUntrustedSkinCannotInflateAResultBackedByOnlyOneTrustedSignal() {
        var days = (-30 ... -3).map {
            day($0, rhr: 50, hrv: nil, skin: nil, respiration: nil)
        }
        days += [
            day(-1, rhr: 65, hrv: nil, skin: 1.5, respiration: nil),
            day(0, rhr: 65, hrv: nil, skin: 1.5, respiration: nil),
        ]
        let prepared = IllnessSignalPipeline.prepare(days: days, todayKey: "2026-08-23")
        XCTAssertEqual(prepared.trustedSignalCount, 1)
        XCTAssertFalse(prepared.baselineTrusted)
        XCTAssertFalse(prepared.inputs.skinTemp?.present ?? true)
    }

    func testStaleFutureAndNonFiniteRowsCannotBecomeCurrentEvidence() {
        var days = (-30 ... -3).map { day($0) }
        days.append(day(-5, rhr: 70, hrv: 20, skin: 1, respiration: 20))
        days.append(day(1, rhr: 80, hrv: 10, skin: 2, respiration: 25))
        days.append(day(0, rhr: 50, hrv: .nan, skin: .infinity, respiration: 14))

        let prepared = IllnessSignalPipeline.prepare(days: days, todayKey: "2026-08-23")
        XCTAssertNil(prepared.hrv)
        XCTAssertNil(prepared.skinTemp)
        XCTAssertEqual(prepared.restingHR?.latestDay, "2026-08-23")
        XCTAssertEqual(prepared.respiration?.latestDay, "2026-08-23")
    }
}
