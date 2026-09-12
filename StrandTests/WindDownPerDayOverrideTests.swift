import XCTest
import UserNotifications
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

    func testNotificationPlanWrapsAcrossMidnight() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setSleepNeedMinutes(8 * 60)
        WindDownNudge.setRecoveryMinutes(0)
        WindDownNudge.setLeadMinutes(30)

        XCTAssertEqual(
            WindDownNudge.notificationPlan(forWeekday: 3),
            WindDownNotificationPlan(
                windDownMinuteOfDay: 22 * 60 + 30,
                bedtimeMinuteOfDay: 23 * 60
            )
        )
    }

    func testNotificationCopyUsesPerDayOverrideAndOnlyPlannerTimes() {
        let locale = Locale(identifier: "en_GB")
        let timeZone = TimeZone(secondsFromGMT: 0)!
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setSleepNeedMinutes(8 * 60)
        WindDownNudge.setRecoveryMinutes(0)
        WindDownNudge.setLeadMinutes(30)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)

        let defaultCopy = WindDownNudge.notificationCopy(
            forWeekday: 3,
            locale: locale,
            timeZone: timeZone
        )
        let saturdayCopy = WindDownNudge.notificationCopy(
            forWeekday: 7,
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(
            defaultCopy.body,
            "Plan: wind down at 22:30; bedtime at 23:00, if that works for you."
        )
        XCTAssertEqual(
            saturdayCopy.body,
            "Plan: wind down at 00:30; bedtime at 01:00, if that works for you."
        )
        XCTAssertLessThanOrEqual(saturdayCopy.body.count, 90)
    }

    func testNotificationContentUsesPrivatePreviewCategoryAndSleepRoute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let fireDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 12, hour: 21, minute: 45
        )))
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setSleepNeedMinutes(8 * 60)
        WindDownNudge.setRecoveryMinutes(45)
        WindDownNudge.setLeadMinutes(30)

        let content = WindDownNudge.notificationContent(
            for: ScheduledWindDownReminder(
                identifier: "wind-down-nudge-2026-09-12",
                fireTimestamp: Int(fireDate.timeIntervalSince1970),
                bedtimeTimestamp: Int(
                    fireDate.addingTimeInterval(30 * 60).timeIntervalSince1970
                ),
                wakeTimestamp: Int(
                    fireDate.addingTimeInterval(8.5 * 60 * 60).timeIntervalSince1970
                ),
                dayKey: "2026-09-12",
                wakeDayKey: "2026-09-13",
                wakeWeekday: 1,
                usesContextualCopy: true
            ),
            calendar: calendar,
            locale: Locale(identifier: "en_GB")
        )
        XCTAssertEqual(content.title, "Wind down for tonight")
        XCTAssertEqual(
            content.body,
            "Plan: wind down at 21:45; bedtime at 22:15, if that works for you."
        )
        XCTAssertTrue(content.subtitle.isEmpty)
        XCTAssertEqual(
            content.categoryIdentifier,
            DailyReviewNotifications.privacyCategoryID
        )
        XCTAssertEqual(
            content.userInfo[NotificationRouteBridge.userInfoKey] as? String,
            NoopNotificationRoute.sleep.rawValue
        )

        let exposed = "\(content.title) \(content.subtitle) \(content.body)".lowercased()
        for forbidden in [
            "recovery", "sleep score", "journal", "calendar", "event",
            "optimal performance", "apple health", "wearable", "nights",
        ] {
            XCTAssertFalse(exposed.contains(forbidden), "Exposed private detail: \(forbidden)")
        }

        let privacyCategory = DailyReviewNotifications.privacyCategory()
        XCTAssertEqual(
            privacyCategory.hiddenPreviewsBodyPlaceholder,
            "Private NOOP check-in"
        )
        XCTAssertFalse(privacyCategory.hiddenPreviewsBodyPlaceholder.contains("21:45"))
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

    func testFridayEveningUsesSaturdayWakeOverrideAndKeepsTwentyEightFutureNights() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 11, hour: 12
        )))
        WindDownNudge.setWakeMinutes(9 * 60)
        WindDownNudge.setSleepNeedMinutes(8 * 60)
        WindDownNudge.setLeadMinutes(30)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 7 * 60)

        let reminders = WindDownNudge.reminderSchedule(
            now: now,
            horizonDays: 28,
            calendar: calendar
        )

        XCTAssertEqual(reminders.count, 28)
        XCTAssertEqual(Set(reminders.map(\.identifier)).count, 28)
        XCTAssertTrue(reminders.allSatisfy { $0.fireDate > now })
        let saturdayWake = try XCTUnwrap(reminders.first)
        XCTAssertEqual(saturdayWake.wakeWeekday, 7)
        XCTAssertEqual(calendar.component(.weekday, from: saturdayWake.fireDate), 6)
        XCTAssertEqual(calendar.component(.hour, from: saturdayWake.fireDate), 22)
        XCTAssertEqual(calendar.component(.minute, from: saturdayWake.fireDate), 30)
        XCTAssertEqual(calendar.component(.hour, from: saturdayWake.wakeDate), 7)
        XCTAssertEqual(
            WindDownNudge.notificationContent(
                for: saturdayWake,
                calendar: calendar,
                locale: Locale(identifier: "en_GB")
            ).body,
            "Plan: wind down at 22:30; bedtime at 23:00, if that works for you."
        )
    }

    func testRenewalWakeIsRequestedWhileThreeWeeksOfRemindersRemain() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 11, hour: 12
        )))
        let reminders = WindDownNudge.reminderSchedule(
            now: now,
            horizonDays: 28,
            calendar: calendar
        )
        let final = try XCTUnwrap(reminders.last?.fireDate)
        let renewal = try XCTUnwrap(WindDownNudge.renewalWakeDate(
            scheduledReminders: reminders,
            now: now,
            calendar: calendar
        ))
        let expected = try XCTUnwrap(calendar.date(
            byAdding: .day,
            value: -21,
            to: final
        ))

        XCTAssertEqual(renewal, expected)
        XCTAssertGreaterThan(renewal, now)
        XCTAssertLessThan(renewal, final)
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

    func testDatedPlanResolvesDstGapAndFormatsResolvedInstants() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/New_York")
        )
        let wakeDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8
        )))
        let plan = try XCTUnwrap(WindDownNudge.datedPlan(
            forWakeDay: wakeDay,
            wakeMinutes: 2 * 60 + 30,
            targetSleepMinutes: 60,
            leadMinutes: 30,
            calendar: calendar
        ))

        XCTAssertEqual(
            ISO8601DateFormatter().string(from: plan.wakeDate),
            "2026-03-08T07:30:00Z"
        )
        XCTAssertEqual(
            calendar.dateComponents([.hour, .minute], from: plan.wakeDate),
            DateComponents(hour: 3, minute: 30)
        )
        XCTAssertEqual(
            calendar.dateComponents([.hour, .minute], from: plan.bedtimeDate),
            DateComponents(hour: 1, minute: 30)
        )
        XCTAssertEqual(
            calendar.dateComponents([.hour, .minute], from: plan.windDownDate),
            DateComponents(hour: 1, minute: 0)
        )
        let reminder = ScheduledWindDownReminder(
            identifier: "wind-down-nudge-wake-2026-03-08",
            fireTimestamp: plan.windDownTimestamp,
            bedtimeTimestamp: plan.bedtimeTimestamp,
            wakeTimestamp: plan.wakeTimestamp,
            dayKey: "2026-03-08",
            wakeDayKey: "2026-03-08",
            wakeWeekday: plan.wakeWeekday,
            usesContextualCopy: true
        )
        XCTAssertEqual(
            WindDownNudge.notificationCopy(
                for: reminder,
                calendar: calendar,
                locale: Locale(identifier: "en_GB")
            ).body,
            "Plan: wind down at 01:00; bedtime at 01:30, if that works for you."
        )
    }

    func testDatedPlanUsesEarlierOffsetForDstOverlap() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/New_York")
        )
        let wakeDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 1
        )))
        let plan = try XCTUnwrap(WindDownNudge.datedPlan(
            forWakeDay: wakeDay,
            wakeMinutes: 1 * 60 + 30,
            targetSleepMinutes: 60,
            leadMinutes: 30,
            calendar: calendar
        ))

        XCTAssertEqual(
            ISO8601DateFormatter().string(from: plan.wakeDate),
            "2026-11-01T05:30:00Z"
        )
        XCTAssertEqual(
            ISO8601DateFormatter().string(from: plan.bedtimeDate),
            "2026-11-01T04:30:00Z"
        )
    }

    func testFarFutureReminderUsesGenericCopy() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 11,
            hour: 12
        )))
        let reminders = WindDownNudge.reminderSchedule(
            now: now,
            horizonDays: 28,
            calendar: calendar
        )
        let contextual = try XCTUnwrap(reminders.first)
        let future = try XCTUnwrap(reminders.last)

        XCTAssertTrue(contextual.usesContextualCopy)
        XCTAssertFalse(future.usesContextualCopy)
        XCTAssertTrue(
            WindDownNudge.notificationCopy(
                for: contextual,
                calendar: calendar,
                locale: Locale(identifier: "en_GB")
            ).body.contains(":")
        )
        XCTAssertEqual(
            WindDownNudge.notificationCopy(
                for: future,
                calendar: calendar,
                locale: Locale(identifier: "en_GB")
            ).body,
            "Your planned bedtime is coming up. Start settling down when it works for you."
        )
    }

    func testAuthorizationRevocationDisablesCancelsAndPublishesState() async throws {
        UserDefaults.standard.set(true, forKey: enabledKey)
        let client = FakeWindDownNotificationClient(authorization: .denied)
        let changed = expectation(description: "enabled state published")
        let observer = NotificationCenter.default.addObserver(
            forName: WindDownNudge.stateDidChange,
            object: nil,
            queue: nil
        ) { _ in
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = await WindDownNudge.reconcileScheduleIfAuthorized(
            client: client,
            retryPolicy: .init(maximumAttempts: 2, delayNanoseconds: 0)
        )

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(result, .failed(.authorizationRevoked))
        XCTAssertFalse(WindDownNudge.isEnabled)
        XCTAssertFalse(client.cancelledIdentifierBatches.isEmpty)
        XCTAssertEqual(client.addAttempts, 0)
    }

    func testNotificationCenterFailureRetriesTwiceThenFailsClosed() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 11,
            hour: 12
        )))
        let client = FakeWindDownNotificationClient(
            authorization: .authorized,
            failuresBeforeSuccess: Int.max
        )

        let outcome = await WindDownNudge.applyEnabledState(
            true,
            client: client,
            retryPolicy: .init(maximumAttempts: 2, delayNanoseconds: 0),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(outcome, .failed(.notificationCenterRejected))
        XCTAssertEqual(client.addAttempts, 2)
        XCTAssertFalse(WindDownNudge.isEnabled)
        XCTAssertTrue(client.enabledSnapshots.allSatisfy { !$0 })
        XCTAssertGreaterThanOrEqual(client.cancelledIdentifierBatches.count, 3)
        XCTAssertNil(UserDefaults.standard.data(forKey: scheduledRemindersKey))
    }

    func testFailedReplacementPreservesLastAcceptedSchedule() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 11,
            hour: 12
        )))
        let prior = WindDownNudge.reminderSchedule(
            now: now,
            calendar: calendar
        )
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set(
            try JSONEncoder().encode(prior),
            forKey: scheduledRemindersKey
        )
        let client = FakeWindDownNotificationClient(
            authorization: .authorized,
            failuresBeforeSuccess: Int.max
        )

        let result = await WindDownNudge.reconcileScheduleIfAuthorized(
            client: client,
            retryPolicy: .init(maximumAttempts: 2, delayNanoseconds: 0),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result, .failed(.notificationCenterRejected))
        XCTAssertTrue(WindDownNudge.isEnabled)
        let persisted = try JSONDecoder().decode(
            [ScheduledWindDownReminder].self,
            from: try XCTUnwrap(
                UserDefaults.standard.data(forKey: scheduledRemindersKey)
            )
        )
        XCTAssertEqual(persisted, prior)
        let priorIDs = Set(prior.map(\.identifier))
        XCTAssertTrue(
            client.cancelledIdentifierBatches
                .flatMap { $0 }
                .allSatisfy { !priorIDs.contains($0) }
        )
        XCTAssertEqual(client.addAttempts, 2)
    }

    func testCapacityLimitedReplacementPreservesCompletePriorSchedule() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 12,
            hour: 12
        )))
        let prior = WindDownNudge.reminderSchedule(
            now: now,
            calendar: calendar
        )
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set(
            try JSONEncoder().encode(prior),
            forKey: scheduledRemindersKey
        )
        let client = FakeWindDownNotificationClient(
            authorization: .authorized,
            capacityLimitAfter: 4
        )

        let result = await WindDownNudge.reconcileScheduleIfAuthorized(
            client: client,
            retryPolicy: .init(maximumAttempts: 1, delayNanoseconds: 0),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result, .failed(.capacityLimited))
        XCTAssertTrue(WindDownNudge.isEnabled)
        let persisted = try JSONDecoder().decode(
            [ScheduledWindDownReminder].self,
            from: try XCTUnwrap(
                UserDefaults.standard.data(forKey: scheduledRemindersKey)
            )
        )
        XCTAssertEqual(persisted, prior)
        let priorIDs = Set(prior.map(\.identifier))
        XCTAssertEqual(client.preservedIdentifierBatches, [priorIDs])
        XCTAssertTrue(
            client.cancelledIdentifierBatches
                .flatMap { $0 }
                .allSatisfy { !priorIDs.contains($0) }
        )
        XCTAssertEqual(client.addAttempts, 4)
        XCTAssertEqual(
            Set(client.cancelledIdentifierBatches.flatMap { $0 }),
            Set(client.reconciledRequestBatches[0].prefix(4))
        )
    }

    func testTransientSchedulingFailureCommitsOnlyAfterRetryAcceptance() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 11,
            hour: 12
        )))
        let client = FakeWindDownNotificationClient(
            authorization: .authorized,
            failuresBeforeSuccess: 1
        )

        let outcome = await WindDownNudge.applyEnabledState(
            true,
            client: client,
            retryPolicy: .init(maximumAttempts: 2, delayNanoseconds: 0),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(outcome, .scheduled)
        XCTAssertTrue(WindDownNudge.isEnabled)
        XCTAssertTrue(client.enabledSnapshots.allSatisfy { !$0 })
        XCTAssertGreaterThan(client.addAttempts, 2)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: scheduledRemindersKey))
    }

    func testAuthorizationRevokedAfterAcceptanceCancelsWithoutCommitting() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 11,
            hour: 12
        )))
        let client = FakeWindDownNotificationClient(
            authorization: .authorized,
            revokeAfterAddAttempts: 28
        )

        let outcome = await WindDownNudge.applyEnabledState(
            true,
            client: client,
            retryPolicy: .init(maximumAttempts: 1, delayNanoseconds: 0),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(outcome, .failed(.authorizationRevoked))
        XCTAssertFalse(WindDownNudge.isEnabled)
        XCTAssertEqual(client.addAttempts, 28)
        XCTAssertFalse(client.cancelledIdentifierBatches.isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: scheduledRemindersKey))
    }

    func testRestoreRearmsAuthorizedScheduleAndKeepsEnabled() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 11,
            hour: 12
        )))
        UserDefaults.standard.set(true, forKey: enabledKey)
        let client = FakeWindDownNotificationClient(authorization: .authorized)

        let result = await WindDownNudge.reconcileScheduleIfAuthorized(
            client: client,
            retryPolicy: .init(maximumAttempts: 1, delayNanoseconds: 0),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result, .scheduled(count: 28))
        XCTAssertTrue(WindDownNudge.isEnabled)
        XCTAssertEqual(client.addAttempts, 28)
    }

    func testSchedulingLaneCoalescesQueuedRebuildsAndOnlyLatestPublishesState() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 11,
            hour: 12
        )))
        UserDefaults.standard.set(true, forKey: enabledKey)
        let firstAuthorizationStarted = expectation(
            description: "first scheduling owner entered authorization"
        )
        let firstClient = FakeWindDownNotificationClient(
            authorization: .authorized,
            failuresBeforeSuccess: Int.max,
            pauseFirstAuthorization: true,
            onAuthorizationPaused: { firstAuthorizationStarted.fulfill() }
        )
        let staleClient = FakeWindDownNotificationClient(
            authorization: .authorized,
            failuresBeforeSuccess: Int.max
        )
        let latestClient = FakeWindDownNotificationClient(authorization: .authorized)

        let first = Task { @MainActor in
            await WindDownNudge.reconcileScheduleIfAuthorized(
                client: firstClient,
                retryPolicy: .init(maximumAttempts: 1, delayNanoseconds: 0),
                now: now,
                calendar: calendar
            )
        }
        await fulfillment(of: [firstAuthorizationStarted], timeout: 1)

        let stale = Task { @MainActor in
            await WindDownNudge.reconcileScheduleIfAuthorized(
                client: staleClient,
                retryPolicy: .init(maximumAttempts: 1, delayNanoseconds: 0),
                now: now,
                calendar: calendar
            )
        }
        await Task.yield()
        let latest = Task { @MainActor in
            await WindDownNudge.reconcileScheduleIfAuthorized(
                client: latestClient,
                retryPolicy: .init(maximumAttempts: 1, delayNanoseconds: 0),
                now: now,
                calendar: calendar
            )
        }
        await Task.yield()
        firstClient.releaseAuthorization()

        let firstResult = await first.value
        let staleResult = await stale.value
        let latestResult = await latest.value
        XCTAssertNil(firstResult)
        XCTAssertNil(staleResult)
        XCTAssertEqual(latestResult, .scheduled(count: 28))
        XCTAssertEqual(firstClient.addAttempts, 1)
        XCTAssertEqual(
            staleClient.authorizationChecks,
            0,
            "A coalesced stale owner must not reach authorization or request mutation"
        )
        XCTAssertEqual(staleClient.addAttempts, 0)
        XCTAssertTrue(staleClient.cancelledIdentifierBatches.isEmpty)
        XCTAssertEqual(latestClient.addAttempts, 28)
        XCTAssertTrue(WindDownNudge.isEnabled)
        let stored = try JSONDecoder().decode(
            [ScheduledWindDownReminder].self,
            from: try XCTUnwrap(
                UserDefaults.standard.data(forKey: scheduledRemindersKey)
            )
        )
        XCTAssertEqual(stored.count, 28)
    }

    func testSupersededOwnerCannotCommitAfterReconciliationReturns() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 12,
            hour: 12
        )))
        UserDefaults.standard.set(true, forKey: enabledKey)
        let reconciliationPaused = expectation(
            description: "first reconciliation paused"
        )
        let firstClient = FakeWindDownNotificationClient(
            authorization: .authorized,
            pauseFirstReconciliation: true,
            onReconciliationPaused: {
                reconciliationPaused.fulfill()
            }
        )
        let latestClient = FakeWindDownNotificationClient(
            authorization: .authorized
        )

        let first = Task { @MainActor in
            await WindDownNudge.reconcileScheduleIfAuthorized(
                client: firstClient,
                retryPolicy: .init(maximumAttempts: 1, delayNanoseconds: 0),
                now: now,
                calendar: calendar
            )
        }
        await fulfillment(of: [reconciliationPaused], timeout: 1)

        let latest = Task { @MainActor in
            await WindDownNudge.reconcileScheduleIfAuthorized(
                client: latestClient,
                retryPolicy: .init(maximumAttempts: 1, delayNanoseconds: 0),
                now: now,
                calendar: calendar
            )
        }
        await Task.yield()
        firstClient.releaseReconciliation()

        let firstResult = await first.value
        let latestResult = await latest.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(latestResult, .scheduled(count: 28))
        let firstIDs = Set(
            try XCTUnwrap(firstClient.reconciledRequestBatches.first)
        )
        let latestIDs = Set(
            try XCTUnwrap(latestClient.reconciledRequestBatches.first)
        )
        XCTAssertEqual(
            Set(firstClient.cancelledIdentifierBatches.flatMap { $0 }),
            firstIDs
        )
        let stored = try JSONDecoder().decode(
            [ScheduledWindDownReminder].self,
            from: try XCTUnwrap(
                UserDefaults.standard.data(forKey: scheduledRemindersKey)
            )
        )
        XCTAssertEqual(Set(stored.map(\.identifier)), latestIDs)
        XCTAssertTrue(firstIDs.isDisjoint(with: latestIDs))
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
                bedtimeTimestamp: Int(
                    currentNight.addingTimeInterval(30 * 60).timeIntervalSince1970
                ),
                wakeTimestamp: Int(
                    currentNight.addingTimeInterval(9 * 60 * 60).timeIntervalSince1970
                ),
                dayKey: "2026-09-11",
                wakeDayKey: "2026-09-12",
                wakeWeekday: 7,
                usesContextualCopy: true
            ),
            ScheduledWindDownReminder(
                identifier: "wind-down-nudge-2026-09-12",
                fireTimestamp: Int(nextEvening.timeIntervalSince1970),
                bedtimeTimestamp: Int(
                    nextEvening.addingTimeInterval(30 * 60).timeIntervalSince1970
                ),
                wakeTimestamp: Int(
                    nextEvening.addingTimeInterval(9 * 60 * 60).timeIntervalSince1970
                ),
                dayKey: "2026-09-12",
                wakeDayKey: "2026-09-13",
                wakeWeekday: 1,
                usesContextualCopy: true
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
            horizonDays: 28,
            calendar: calendar
        )
        let excluded = try XCTUnwrap(baseline.first?.dayKey)
        let filtered = WindDownNudge.reminderSchedule(
            now: now,
            horizonDays: 28,
            calendar: calendar,
            excludedDayKeys: [excluded]
        )

        XCTAssertEqual(filtered.count, 28)
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

@MainActor
private final class FakeWindDownNotificationClient: WindDownNotificationClient {
    enum FakeError: Error { case rejected }

    var authorizationValue: WindDownNotificationAuthorization
    var requestAuthorizationResult = false
    var failuresBeforeSuccess: Int
    var revokeAfterAddAttempts: Int?
    var capacityLimitAfter: Int?
    var pauseFirstAuthorization: Bool
    var pauseFirstReconciliation: Bool
    var onAuthorizationPaused: (() -> Void)?
    var onReconciliationPaused: (() -> Void)?
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var reconciliationContinuation: CheckedContinuation<Void, Never>?
    private(set) var authorizationChecks = 0
    private(set) var addAttempts = 0
    private(set) var enabledSnapshots: [Bool] = []
    private(set) var cancelledIdentifierBatches: [[String]] = []
    private(set) var preservedIdentifierBatches: [Set<String>] = []
    private(set) var reconciledRequestBatches: [[String]] = []
    private(set) var registeredPrivacyCategoryCount = 0

    init(
        authorization: WindDownNotificationAuthorization,
        failuresBeforeSuccess: Int = 0,
        revokeAfterAddAttempts: Int? = nil,
        capacityLimitAfter: Int? = nil,
        pauseFirstAuthorization: Bool = false,
        pauseFirstReconciliation: Bool = false,
        onAuthorizationPaused: (() -> Void)? = nil,
        onReconciliationPaused: (() -> Void)? = nil
    ) {
        authorizationValue = authorization
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.revokeAfterAddAttempts = revokeAfterAddAttempts
        self.capacityLimitAfter = capacityLimitAfter
        self.pauseFirstAuthorization = pauseFirstAuthorization
        self.pauseFirstReconciliation = pauseFirstReconciliation
        self.onAuthorizationPaused = onAuthorizationPaused
        self.onReconciliationPaused = onReconciliationPaused
    }

    func authorization() async -> WindDownNotificationAuthorization {
        authorizationChecks += 1
        if pauseFirstAuthorization {
            pauseFirstAuthorization = false
            onAuthorizationPaused?()
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
            }
        }
        if let revokeAfterAddAttempts,
           addAttempts >= revokeAfterAddAttempts {
            return .denied
        }
        return authorizationValue
    }

    func requestAuthorization() async -> Bool {
        requestAuthorizationResult
    }

    func releaseAuthorization() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }

    func releaseReconciliation() {
        reconciliationContinuation?.resume()
        reconciliationContinuation = nil
    }

    func registerPrivacyCategory() {
        registeredPrivacyCategoryCount += 1
    }

    func add(_ request: UNNotificationRequest) async throws {
        _ = request
        addAttempts += 1
        enabledSnapshots.append(WindDownNudge.isEnabled)
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw FakeError.rejected
        }
    }

    func reconcile(
        requests: [UNNotificationRequest],
        replacingIdentifiers: Set<String>,
        preservingIdentifiers: Set<String>,
        now: Date,
        calendar: Calendar
    ) async -> LocalNotificationReconciliationResult {
        _ = replacingIdentifiers
        _ = now
        _ = calendar
        preservedIdentifierBatches.append(preservingIdentifiers)
        reconciledRequestBatches.append(requests.map(\.identifier))
        var accepted: [String] = []
        var capacityLimited: [String] = []
        var failed: [String] = []
        for (index, request) in requests.enumerated() {
            if let capacityLimitAfter, index >= capacityLimitAfter {
                capacityLimited.append(request.identifier)
                continue
            }
            do {
                try await add(request)
                accepted.append(request.identifier)
            } catch {
                failed.append(request.identifier)
                break
            }
        }
        if pauseFirstReconciliation {
            pauseFirstReconciliation = false
            onReconciliationPaused?()
            await withCheckedContinuation { continuation in
                reconciliationContinuation = continuation
            }
        }
        return LocalNotificationReconciliationResult(
            acceptedIdentifiers: accepted,
            capacityLimitedIdentifiers: capacityLimited,
            failedIdentifiers: failed,
            removedIdentifiers: []
        )
    }

    func cancel(identifiers: [String]) {
        cancelledIdentifierBatches.append(identifiers)
    }
}
