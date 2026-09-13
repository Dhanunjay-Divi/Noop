import XCTest
@testable import StrandAnalytics

final class AdaptiveDayGuidanceTests: XCTestCase {
    private let dayStart = 1_800_000_000 - (1_800_000_000 % 86_400)

    private func window(dayOffset: Int, onsetMinute: Int, durationMinutes: Int)
        -> AdaptiveDayGuidance.SleepWindow {
        let start = dayStart + dayOffset * 86_400 + onsetMinute * 60
        return .init(startSec: start, endSec: start + durationMinutes * 60)
    }

    private func input(
        sleepDays: [AdaptiveDayGuidance.SleepDay] = [],
        windows: [AdaptiveDayGuidance.SleepWindow] = [],
        change: AdaptiveDayGuidance.TimeZoneChange? = nil,
        sleepTargetMinutes: Int = 8 * 60,
        sleepTargetIsExplicit: Bool = true,
        today: String = "2027-01-15",
        nowSec: Int? = nil,
        routineHistoryStartSec: Int? = nil
    ) -> AdaptiveDayGuidance.Input {
        .init(
            today: today,
            nowSec: nowSec ?? dayStart + 12 * 60 * 60,
            currentTimeZoneOffsetSec: 0,
            sleepTargetMinutes: sleepTargetMinutes,
            sleepTargetIsExplicit: sleepTargetIsExplicit,
            sleepDays: sleepDays,
            sleepWindows: windows,
            timeZoneChange: change,
            routineHistoryStartSec: routineHistoryStartSec
        )
    }

    func testTwoHourTravelChangeWinsAndOneHourDSTDoesNotTrigger() {
        let now = dayStart + 12 * 60 * 60
        let travel = AdaptiveDayGuidance.recommendation(input(change: .init(
            previousOffsetSec: -5 * 60 * 60,
            currentOffsetSec: 60 * 60,
            observedAtSec: now - 60
        )))
        XCTAssertEqual(travel?.kind, .travelAdjustment)
        XCTAssertEqual(travel?.confidence, .strong)

        let dst = AdaptiveDayGuidance.recommendation(input(change: .init(
            previousOffsetSec: -5 * 60 * 60,
            currentOffsetSec: -4 * 60 * 60,
            observedAtSec: now - 60
        )))
        XCTAssertNil(dst)
    }

    func testDateLineTravelUsesShortestWallClockShift() {
        XCTAssertEqual(
            AdaptiveDayGuidance.normalizedTravelDeltaSeconds(
                previousOffsetSec: 12 * 60 * 60,
                currentOffsetSec: -10 * 60 * 60
            ),
            2 * 60 * 60
        )
        XCTAssertEqual(
            AdaptiveDayGuidance.normalizedTravelDeltaSeconds(
                previousOffsetSec: -10 * 60 * 60,
                currentOffsetSec: 14 * 60 * 60
            ),
            0
        )

        let now = dayStart + 12 * 60 * 60
        let twoHourShift = AdaptiveDayGuidance.recommendation(input(change: .init(
            previousOffsetSec: 12 * 60 * 60,
            currentOffsetSec: -10 * 60 * 60,
            observedAtSec: now - 60
        )))
        XCTAssertEqual(twoHourShift?.kind, .travelAdjustment)

        let sameLocalClock = AdaptiveDayGuidance.recommendation(input(change: .init(
            previousOffsetSec: -10 * 60 * 60,
            currentOffsetSec: 14 * 60 * 60,
            observedAtSec: now - 60
        )))
        XCTAssertNil(sameLocalClock)
    }

    func testLateShortNightNeedsPersonalRoutineAndOutranksShortSleep() {
        var windows = (2...8).map { nightsAgo in
            window(dayOffset: -nightsAgo, onsetMinute: 23 * 60, durationMinutes: 8 * 60)
        }
        // 01:00 to 06:00 today, two hours later and three hours shorter than the learned routine.
        windows.append(window(dayOffset: 0, onsetMinute: 60, durationMinutes: 5 * 60))

        let result = AdaptiveDayGuidance.recommendation(input(
            sleepDays: [.init(day: "2027-01-15", totalSleepMinutes: 300)],
            windows: windows
        ))

        XCTAssertEqual(result?.kind, .routineRecovery)
        XCTAssertEqual(result?.confidence, .strong)
        XCTAssertEqual(result?.evidence, [
            "personal-sleep-timing", "later-onset", "shorter-sleep"
        ])
    }

    func testRoutineShiftFailsClosedWithoutFivePriorNights() {
        var windows = (2...5).map { nightsAgo in
            window(dayOffset: -nightsAgo, onsetMinute: 23 * 60, durationMinutes: 8 * 60)
        }
        windows.append(window(dayOffset: 0, onsetMinute: 60, durationMinutes: 5 * 60))

        let result = AdaptiveDayGuidance.recommendation(input(windows: windows))

        XCTAssertEqual(result?.kind, .sleepRecovery)
        XCTAssertEqual(result?.confidence, .building)
    }

    func testFragmentedWindowsCannotImpersonateFiveRoutineNights() {
        var windows: [AdaptiveDayGuidance.SleepWindow] = []
        for dayOffset in -4 ... -2 {
            windows.append(window(
                dayOffset: dayOffset,
                onsetMinute: 20 * 60,
                durationMinutes: 3 * 60
            ))
            windows.append(window(
                dayOffset: dayOffset,
                onsetMinute: 23 * 60 + 30,
                durationMinutes: 7 * 60
            ))
        }
        windows.append(window(dayOffset: 0, onsetMinute: 60, durationMinutes: 5 * 60))

        let result = AdaptiveDayGuidance.recommendation(input(windows: windows))

        XCTAssertEqual(result?.kind, .sleepRecovery)
        XCTAssertEqual(result?.confidence, .building)
    }

    func testCurrentMeasuredShortSleepTriggersButStaleDayDoesNot() {
        let current = AdaptiveDayGuidance.recommendation(input(
            sleepDays: [.init(day: "2027-01-15", totalSleepMinutes: 360)],
            windows: [window(dayOffset: -1, onsetMinute: 23 * 60, durationMinutes: 6 * 60)]
        ))
        XCTAssertEqual(current?.kind, .sleepRecovery)
        XCTAssertEqual(current?.confidence, .strong)

        let stale = AdaptiveDayGuidance.recommendation(input(
            sleepDays: [.init(day: "2027-01-14", totalSleepMinutes: 300)]
        ))
        XCTAssertNil(stale)
    }

    func testCurrentMeasuredSleepDoesNotBorrowAStaleWindowTimestamp() {
        let value = input(
            sleepDays: [.init(day: "2027-01-15", totalSleepMinutes: 360)],
            windows: [window(dayOffset: -10, onsetMinute: 23 * 60, durationMinutes: 6 * 60)]
        )

        let result = AdaptiveDayGuidance.recommendation(value)

        XCTAssertNil(result)
    }

    func testCurrentMeasuredSleepDoesNotBorrowFreshWindowFromAnotherDay() {
        let result = AdaptiveDayGuidance.recommendation(input(
            sleepDays: [.init(day: "2027-01-16", totalSleepMinutes: 360)],
            windows: [window(dayOffset: -1, onsetMinute: 23 * 60, durationMinutes: 6 * 60)],
            today: "2027-01-16"
        ))

        XCTAssertNil(result)
    }

    func testImplicitReferenceTargetDoesNotTriggerTargetBasedGuidance() {
        let result = AdaptiveDayGuidance.recommendation(input(
            sleepDays: [.init(day: "2027-01-15", totalSleepMinutes: 360)],
            windows: [window(dayOffset: -1, onsetMinute: 23 * 60, durationMinutes: 6 * 60)],
            sleepTargetIsExplicit: false
        ))

        XCTAssertNil(result)
    }

    func testLateNightThatIsNotShorterThanPersonalPatternIsNotRoutineRecovery() {
        var windows = (2...8).map { nightsAgo in
            window(dayOffset: -nightsAgo, onsetMinute: 23 * 60, durationMinutes: 6 * 60)
        }
        windows.append(window(dayOffset: 0, onsetMinute: 60, durationMinutes: 6 * 60))

        let result = AdaptiveDayGuidance.recommendation(input(windows: windows))

        XCTAssertEqual(result?.kind, .sleepRecovery)
    }

    func testFragmentedLatestNightUsesCombinedDuration() {
        var windows = (2...8).map { nightsAgo in
            window(dayOffset: -nightsAgo, onsetMinute: 23 * 60, durationMinutes: 8 * 60)
        }
        windows += [
            window(dayOffset: 0, onsetMinute: 60, durationMinutes: 4 * 60),
            window(dayOffset: 0, onsetMinute: 5 * 60, durationMinutes: 4 * 60),
        ]

        XCTAssertNil(AdaptiveDayGuidance.recommendation(input(windows: windows)))
    }

    func testNearbySubThreeHourFragmentsMergeBeforeEligibilityAndKeepEarliestOnset() {
        var windows = (2...8).map { nightsAgo in
            window(dayOffset: -nightsAgo, onsetMinute: 23 * 60, durationMinutes: 8 * 60)
        }
        windows += [
            window(dayOffset: -1, onsetMinute: 23 * 60, durationMinutes: 2 * 60),
            window(dayOffset: 0, onsetMinute: 2 * 60, durationMinutes: 5 * 60),
        ]

        XCTAssertNil(AdaptiveDayGuidance.recommendation(input(
            windows: windows,
            sleepTargetIsExplicit: false
        )))
    }

    func testDistantMorningNapDoesNotExtendTheOvernightCluster() {
        let result = AdaptiveDayGuidance.recommendation(input(
            windows: [
                window(dayOffset: -1, onsetMinute: 23 * 60, durationMinutes: 5 * 60),
                window(dayOffset: 0, onsetMinute: 8 * 60, durationMinutes: 2 * 60),
            ],
            sleepTargetMinutes: 6 * 60 + 30
        ))

        XCTAssertEqual(result?.kind, .sleepRecovery)
        XCTAssertEqual(result?.confidence, .building)
    }

    func testShortSessionCannotPromoteDailyAggregateToStrongEvidence() {
        let result = AdaptiveDayGuidance.recommendation(input(
            sleepDays: [.init(day: "2027-01-15", totalSleepMinutes: 360)],
            windows: [
                window(dayOffset: 0, onsetMinute: 60, durationMinutes: 3 * 60),
            ]
        ))

        XCTAssertEqual(result?.kind, .sleepRecovery)
        XCTAssertEqual(result?.confidence, .building)
    }

    func testTravelResetExcludesOldZoneHistoryUntilNewRoutineBuilds() {
        let resetAt = dayStart - 8 * 86_400
        let oldHistory = (9...14).map { nightsAgo in
            window(dayOffset: -nightsAgo, onsetMinute: 23 * 60, durationMinutes: 8 * 60)
        }
        let newHistory = (2...7).map { nightsAgo in
            window(dayOffset: -nightsAgo, onsetMinute: 23 * 60, durationMinutes: 8 * 60)
        }
        let latest = window(dayOffset: 0, onsetMinute: 60, durationMinutes: 5 * 60)

        XCTAssertNil(AdaptiveDayGuidance.recommendation(input(
            windows: oldHistory + [latest],
            sleepTargetIsExplicit: false,
            routineHistoryStartSec: resetAt
        )))
        XCTAssertEqual(
            AdaptiveDayGuidance.recommendation(input(
                windows: newHistory + [latest],
                sleepTargetIsExplicit: false,
                routineHistoryStartSec: resetAt
            ))?.kind,
            .routineRecovery
        )
    }

    func testTravelResetExcludesWindowThatStartedBeforeTheReset() {
        let crossing = window(
            dayOffset: -6,
            onsetMinute: 23 * 60,
            durationMinutes: 8 * 60
        )
        let resetAt = crossing.startSec + 2 * 60 * 60
        let postResetHistory = (2...5).map { nightsAgo in
            window(dayOffset: -nightsAgo, onsetMinute: 23 * 60, durationMinutes: 8 * 60)
        }
        let latest = window(dayOffset: 0, onsetMinute: 60, durationMinutes: 5 * 60)

        XCTAssertNil(AdaptiveDayGuidance.recommendation(input(
            windows: [crossing] + postResetHistory + [latest],
            sleepTargetIsExplicit: false,
            routineHistoryStartSec: resetAt
        )))
    }
}
