import XCTest
import WhoopStore
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
    private let enabledKey = "windDown.enabled"
    private let scheduledRemindersKey = "windDown.scheduledReminders.v2"
    private let sleepSuppressedDaysKey = "windDown.sleepSuppressedDays.v1"

    override func setUp() {
        super.setUp()
        clearPlannerDefaults()
    }

    override func tearDown() {
        clearPlannerDefaults()
        super.tearDown()
    }

    private func clearPlannerDefaults() {
        [
            perDayKey, wakeKey, sleepNeedKey, recoveryKey, leadKey, enabledKey,
            scheduledRemindersKey, sleepSuppressedDaysKey,
        ].forEach {
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

    func testFreshComputedSessionEndingAsleepSuppressesWindDown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = sleepSession(
            start: Int(now.timeIntervalSince1970) - 90 * 60,
            end: Int(now.timeIntervalSince1970) - 2 * 60,
            lastStage: "deep"
        )

        XCTAssertTrue(
            WindDownSleepStatePolicy.shouldSuppress(sessions: [session], now: now)
        )
    }

    func testAwakeStaleEditedSparseAndSummaryOnlySessionsFailOpen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seconds = Int(now.timeIntervalSince1970)
        let awake = sleepSession(
            start: seconds - 90 * 60,
            end: seconds - 2 * 60,
            lastStage: "wake"
        )
        let stale = sleepSession(
            start: seconds - 3 * 60 * 60,
            end: seconds - 31 * 60,
            lastStage: "rem"
        )
        let edited = sleepSession(
            start: seconds - 90 * 60,
            end: seconds - 2 * 60,
            lastStage: "light",
            userEdited: true
        )
        let sparse = sleepSession(
            start: seconds - 90 * 60,
            end: seconds - 2 * 60,
            lastStage: "light",
            gravitySparse: true
        )
        let summaryOnly = sleepSession(
            start: seconds - 90 * 60,
            end: seconds - 2 * 60,
            lastStage: "light",
            stagesJSON: #"{"light":80,"deep":10}"#
        )

        XCTAssertFalse(
            WindDownSleepStatePolicy.shouldSuppress(
                sessions: [awake, stale, edited, sparse, summaryOnly],
                now: now
            )
        )
    }

    func testMalformedOrFutureSleepEvidenceFailsOpen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seconds = Int(now.timeIntervalSince1970)
        let malformed = sleepSession(
            start: seconds - 90 * 60,
            end: seconds - 2 * 60,
            lastStage: "light",
            stagesJSON: #"[{"start":1800000000,"end":1799999940,"stage":"light"}]"#
        )
        let future = sleepSession(
            start: seconds + 60,
            end: seconds + 5 * 60,
            lastStage: "light"
        )

        XCTAssertFalse(
            WindDownSleepStatePolicy.shouldSuppress(
                sessions: [malformed, future],
                now: now
            )
        )
    }

    func testDatedScheduleUsesPerDayOverridesAndKeepsFourteenFutureNights() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 11, hour: 20
        )))
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setSleepNeedMinutes(8 * 60)
        WindDownNudge.setLeadMinutes(30)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)

        let reminders = WindDownNudge.reminderSchedule(
            now: now,
            horizonDays: 14,
            calendar: calendar
        )

        XCTAssertEqual(reminders.count, 14)
        XCTAssertEqual(Set(reminders.map(\.identifier)).count, 14)
        XCTAssertTrue(reminders.allSatisfy { $0.fireDate > now })
        let saturday = try XCTUnwrap(reminders.first {
            calendar.component(.weekday, from: $0.fireDate) == 7
        })
        XCTAssertEqual(calendar.component(.hour, from: saturday.fireDate), 0)
        XCTAssertEqual(calendar.component(.minute, from: saturday.fireDate), 30)
    }

    func testDatedSchedulePreservesLocalWallClockAcrossSpringDst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 7, hour: 23
        )))
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setSleepNeedMinutes(8 * 60)
        WindDownNudge.setLeadMinutes(30)

        let first = try XCTUnwrap(
            WindDownNudge.reminderSchedule(
                now: now,
                horizonDays: 2,
                calendar: calendar
            ).first
        )
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: first.fireDate
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 8)
        XCTAssertEqual(components.hour, 22)
        XCTAssertEqual(components.minute, 30)
    }

    func testSleepWindowSuppressionPreservesTheNextEvening() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 12, hour: 0, minute: 10
        )))
        let sessionStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 11, hour: 21, minute: 30
        )))
        let observedThrough = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 12, hour: 0, minute: 8
        )))
        let currentNight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 11, hour: 22
        )))
        let nextEvening = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 12, hour: 22
        )))
        let session = sleepSession(
            start: Int(sessionStart.timeIntervalSince1970),
            end: Int(observedThrough.timeIntervalSince1970),
            lastStage: "rem"
        )
        let reminders = [
            ScheduledWindDownReminder(
                identifier: "wind-down-nudge-2026-09-11",
                fireTimestamp: Int(currentNight.timeIntervalSince1970),
                dayKey: "2026-09-11"
            ),
            ScheduledWindDownReminder(
                identifier: "wind-down-nudge-2026-09-12",
                fireTimestamp: Int(nextEvening.timeIntervalSince1970),
                dayKey: "2026-09-12"
            ),
        ]

        XCTAssertEqual(
            WindDownNudge.remindersToSuppress(
                sessions: [session],
                scheduledReminders: reminders,
                now: now
            ).map(\.identifier),
            ["wind-down-nudge-2026-09-11"]
        )
    }

    func testSuppressedDayIsSkippedWithoutShorteningTheHorizon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 11, hour: 20
        )))
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setSleepNeedMinutes(8 * 60)
        WindDownNudge.setLeadMinutes(30)

        let baseline = WindDownNudge.reminderSchedule(
            now: now,
            horizonDays: 14,
            calendar: calendar
        )
        let excluded = try XCTUnwrap(baseline.first?.dayKey)
        let filtered = WindDownNudge.reminderSchedule(
            now: now,
            horizonDays: 14,
            calendar: calendar,
            excludedDayKeys: [excluded]
        )

        XCTAssertEqual(filtered.count, 14)
        XCTAssertFalse(filtered.contains { $0.dayKey == excluded })
    }

    private func sleepSession(
        start: Int,
        end: Int,
        lastStage: String,
        userEdited: Bool = false,
        gravitySparse: Bool = false,
        stagesJSON: String? = nil
    ) -> CachedSleepSession {
        let middle = start + (end - start) / 2
        return CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: stagesJSON ?? """
            [{"start":\(start),"end":\(middle),"stage":"light"},\
            {"start":\(middle),"end":\(end),"stage":"\(lastStage)"}]
            """,
            userEdited: userEdited,
            gravitySparse: gravitySparse
        )
    }
}
