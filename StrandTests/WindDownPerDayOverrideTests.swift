import XCTest
@testable import Strand

/// PR#554 (MumiZed, reimplemented as NoopApp) — per-day wake overrides for the wind-down nudge.
///
/// The nudge derives its fire time from the user's wake time minus sleep need minus lead. Per-day overrides
/// let a single weekday use a DIFFERENT wake time (a weekend lie-in, say) while every un-overridden day
/// falls back to the default. These pin: the override round-trips through the store, an absent override
/// reverts a day to the default, the per-weekday nudge math follows the override, and clamping is honest.
///
/// `WindDownNudge` is @MainActor and backed by UserDefaults.standard, so each test clears its keys first.
@MainActor
final class WindDownPerDayOverrideTests: XCTestCase {

    private let perDayKey = "windDown.perDayWakeMinutes"
    private let wakeKey = "windDown.wakeMinutes"
    private let sleepNeedKey = "windDown.sleepNeedMinutes"
    private let recoveryKey = "windDown.recoveryMinutes"
    private let leadKey = "windDown.leadMinutes"

    override func setUp() {
        super.setUp()
        clearPlannerDefaults()
    }

    override func tearDown() {
        clearPlannerDefaults()
        super.tearDown()
    }

    private func clearPlannerDefaults() {
        [perDayKey, wakeKey, sleepNeedKey, recoveryKey, leadKey].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }

    func testNoOverrides_everyDayUsesDefaultWake() {
        WindDownNudge.setWakeMinutes(7 * 60)   // 07:00 default
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
        for weekday in 1...7 {
            XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: weekday), 7 * 60)
        }
    }

    func testSetOverride_appliesToThatDayOnly() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)   // Saturday lie-in to 09:00
        XCTAssertTrue(WindDownNudge.hasPerDayOverrides)
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 7), 9 * 60)
        // Every other day still uses the default.
        for weekday in 1...6 {
            XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: weekday), 7 * 60)
        }
    }

    func testClearOverride_revertsDayToDefault() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 1, minutes: 8 * 60)   // Sunday 08:00
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 1), 8 * 60)
        WindDownNudge.setWakeOverride(weekday: 1, minutes: nil)      // clear it
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 1), 7 * 60)
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
    }

    func testPerDayNudgeMinute_followsTheOverride() {
        // Defaults: 8h need + 30m lead. Wake 07:00 default → nudge 22:00. Override Saturday wake 09:00 →
        // nudge 00:00 the previous day's evening? No — 09:00 − 8:30 = 00:30. Just assert it tracks the math.
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)
        let target = WindDownNudge.targetSleepMinutes, lead = WindDownNudge.leadMinutes
        let expectedSat = (((9 * 60 - target - lead) % 1440) + 1440) % 1440
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(forWeekday: 7), expectedSat)
        // A non-overridden day uses the default wake.
        let expectedDefault = (((7 * 60 - target - lead) % 1440) + 1440) % 1440
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(forWeekday: 3), expectedDefault)
    }

    func testPlannerRecoveryShiftsReminderAndIsClamped() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setSleepNeedMinutes(8 * 60)
        WindDownNudge.setLeadMinutes(30)
        WindDownNudge.setRecoveryMinutes(45)

        XCTAssertEqual(WindDownNudge.targetSleepMinutes, 8 * 60 + 45)
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(), 21 * 60 + 45)

        WindDownNudge.setRecoveryMinutes(500)
        XCTAssertEqual(WindDownNudge.recoveryMinutes, 60)
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(), 21 * 60 + 30)
    }

    func testOverrideMinutesAreClamped() {
        WindDownNudge.setWakeOverride(weekday: 4, minutes: 5_000)   // way past a day
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 4), 24 * 60 - 1)
        WindDownNudge.setWakeOverride(weekday: 4, minutes: -100)
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 4), 0)
    }

    func testInvalidWeekday_isIgnored() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 9, minutes: 8 * 60)   // no weekday 9
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
    }

    func testNotificationContentIsGenericAndUsesPrivatePreviewCategory() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setSleepNeedMinutes(8 * 60)
        WindDownNudge.setRecoveryMinutes(45)

        let content = WindDownNudge.notificationContent()
        XCTAssertEqual(content.title, "Wind down for tonight")
        XCTAssertEqual(
            content.body,
            "Your planned bedtime is coming up. Start settling down when it works for you."
        )
        XCTAssertTrue(content.subtitle.isEmpty)
        XCTAssertEqual(
            content.categoryIdentifier,
            DailyReviewNotifications.privacyCategoryID
        )

        let exposed = "\(content.title) \(content.subtitle) \(content.body)".lowercased()
        for forbidden in [
            "7:00", "10:00", "8 hr", "45 min", "apple health",
            "wearable", "nights", "sleep target",
        ] {
            XCTAssertFalse(exposed.contains(forbidden), "Exposed private detail: \(forbidden)")
        }
    }

    func testReminderPolicyUsesHealthFallbackWithoutDoubleCountingOverlap() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 22, hour: 12
        )))
        let context = ReminderDataPolicy.sleepContext(
            observations: [
                .init(day: "2026-08-20", minutes: 300, source: .appleHealth),
                .init(day: "2026-08-20", minutes: 480, source: .wearable),
                .init(day: "2026-08-21", minutes: 420, source: .appleHealth),
                .init(day: "2026-08-22", minutes: 420, source: .wearable),
            ],
            targetMinutes: 480,
            goalMode: .balance,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(context.isCurrent)
        XCTAssertEqual(context.historyNights, 3)
        XCTAssertEqual(context.source, .mixed)
        XCTAssertEqual(context.recoveryMinutes, 45)
    }
}
