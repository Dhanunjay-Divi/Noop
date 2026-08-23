import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

final class SleepDurationAlarmTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(
        year: Int = 2026,
        month: Int = 8,
        day: Int,
        hour: Int,
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

    private func session(
        start: Date,
        stages: [(minutes: Int, stage: String)]
    ) -> CachedSleepSession {
        var cursor = Int(start.timeIntervalSince1970)
        let segments = stages.map { item -> StageSegment in
            let segment = StageSegment(
                start: cursor,
                end: cursor + item.minutes * 60,
                stage: item.stage
            )
            cursor = segment.end
            return segment
        }
        return CachedSleepSession(
            startTs: Int(start.timeIntervalSince1970),
            endTs: cursor,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: AnalyticsEngine.encodeStages(segments),
            gravitySparse: false
        )
    }

    func testProjectsRemainingDetectedSleepAndAccountsForAwakeTime() {
        let sleep = session(
            start: date(day: 21, hour: 22),
            stages: [(360, "light"), (30, "wake")]
        )
        let now = date(day: 22, hour: 4, minute: 31)

        let decision = SleepDurationAlarmPolicy.decision(
            sessions: [sleep],
            targetMinutes: 8 * 60,
            weekdays: [],
            lastFiredSessionStart: 0,
            now: now,
            calendar: calendar
        )

        guard case .schedule(let fireDate, let observation, let target) = decision else {
            return XCTFail("Expected a projected duration alarm")
        }
        XCTAssertEqual(fireDate, date(day: 22, hour: 6, minute: 30))
        XCTAssertEqual(observation.asleepMinutes, 360)
        XCTAssertEqual(target, 480)
    }

    func testFiresWhenDetectedAsleepTargetIsReached() {
        let sleep = session(
            start: date(day: 21, hour: 22),
            stages: [(450, "light"), (30, "wake"), (30, "rem")]
        )
        let now = date(day: 22, hour: 6, minute: 31)

        let decision = SleepDurationAlarmPolicy.decision(
            sessions: [sleep],
            targetMinutes: 8 * 60,
            weekdays: [],
            lastFiredSessionStart: 0,
            now: now,
            calendar: calendar
        )

        guard case .fire(let observation, let target) = decision else {
            return XCTFail("Expected the reached target to fire")
        }
        XCTAssertEqual(observation.asleepMinutes, 480)
        XCTAssertEqual(target, 480)
    }

    func testSameSleepSessionCannotFireTwice() {
        let sleep = session(
            start: date(day: 21, hour: 22),
            stages: [(480, "light")]
        )
        let start = Int(date(day: 21, hour: 22).timeIntervalSince1970)

        let decision = SleepDurationAlarmPolicy.decision(
            sessions: [sleep],
            targetMinutes: 8 * 60,
            weekdays: [],
            lastFiredSessionStart: start,
            now: date(day: 22, hour: 6, minute: 1),
            calendar: calendar
        )

        guard case .alreadyFired(let observation, _) = decision else {
            return XCTFail("Expected a durable duplicate guard")
        }
        XCTAssertEqual(observation.sessionStart, start)
    }

    func testWeekdaySelectionUsesProjectedWakeDay() {
        // Friday night projects to Saturday. Monday-Friday selection must not arm it.
        let sleep = session(
            start: date(day: 21, hour: 22),
            stages: [(360, "light")]
        )
        let decision = SleepDurationAlarmPolicy.decision(
            sessions: [sleep],
            targetMinutes: 8 * 60,
            weekdays: Set(2...6),
            lastFiredSessionStart: 0,
            now: date(day: 22, hour: 4, minute: 1),
            calendar: calendar
        )
        XCTAssertEqual(decision, .waiting)
    }

    func testImportedSummaryAndStaleObservationsCannotDriveAlarm() {
        let start = date(day: 21, hour: 22)
        let imported = CachedSleepSession(
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(date(day: 22, hour: 6).timeIntervalSince1970),
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: #"{"light":360,"deep":60,"rem":60,"awake":30}"#
        )
        XCTAssertEqual(
            SleepDurationAlarmPolicy.decision(
                sessions: [imported],
                targetMinutes: 480,
                weekdays: [],
                lastFiredSessionStart: 0,
                now: date(day: 22, hour: 6),
                calendar: calendar
            ),
            .waiting
        )

        let importedTimeline = CachedSleepSession(
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(date(day: 22, hour: 6).timeIntervalSince1970),
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: AnalyticsEngine.encodeStages([
                StageSegment(
                    start: Int(start.timeIntervalSince1970),
                    end: Int(date(day: 22, hour: 6).timeIntervalSince1970),
                    stage: "light"
                ),
            ])
        )
        XCTAssertEqual(
            SleepDurationAlarmPolicy.decision(
                sessions: [importedTimeline],
                targetMinutes: 480,
                weekdays: [],
                lastFiredSessionStart: 0,
                now: date(day: 22, hour: 6),
                calendar: calendar
            ),
            .waiting
        )

        let stageRich = session(start: start, stages: [(480, "light")])
        XCTAssertEqual(
            SleepDurationAlarmPolicy.decision(
                sessions: [stageRich],
                targetMinutes: 480,
                weekdays: [],
                lastFiredSessionStart: 0,
                now: date(day: 22, hour: 10),
                calendar: calendar
            ),
            .waiting
        )
    }

    func testSparseLocalIsRejectedAndOverlappingFragmentsAreNotDoubleCounted() {
        let start = date(day: 21, hour: 22)
        let sparse = CachedSleepSession(
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(date(day: 22, hour: 6).timeIntervalSince1970),
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: AnalyticsEngine.encodeStages([
                StageSegment(
                    start: Int(start.timeIntervalSince1970),
                    end: Int(date(day: 22, hour: 6).timeIntervalSince1970),
                    stage: "light"
                ),
            ]),
            gravitySparse: true
        )
        XCTAssertEqual(
            SleepDurationAlarmPolicy.decision(
                sessions: [sparse],
                targetMinutes: 480,
                weekdays: [],
                lastFiredSessionStart: 0,
                now: date(day: 22, hour: 6),
                calendar: calendar
            ),
            .waiting
        )

        let first = session(start: start, stages: [(300, "light")])
        let overlapping = session(
            start: date(day: 22, hour: 2),
            stages: [(240, "rem")]
        )
        let overlapDecision = SleepDurationAlarmPolicy.decision(
            sessions: [first, overlapping],
            targetMinutes: 480,
            weekdays: [],
            lastFiredSessionStart: 0,
            now: date(day: 22, hour: 6),
            calendar: calendar
        )
        guard case .schedule(let fireDate, let observation, _) = overlapDecision else {
            return XCTFail("Expected the latest independent observation to remain scheduled")
        }
        XCTAssertEqual(observation.sessionStart, overlapping.startTs)
        XCTAssertEqual(observation.asleepMinutes, 240)
        XCTAssertEqual(fireDate, date(day: 22, hour: 10))
    }

    func testDurationTargetIsClampedToSupportedRange() {
        XCTAssertEqual(SleepDurationAlarmPolicy.normalizedTargetMinutes(60), 240)
        XCTAssertEqual(SleepDurationAlarmPolicy.normalizedTargetMinutes(600), 600)
        XCTAssertEqual(SleepDurationAlarmPolicy.normalizedTargetMinutes(900), 720)
    }
}
