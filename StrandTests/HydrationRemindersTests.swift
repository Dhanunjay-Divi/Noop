import XCTest
@testable import Strand

@MainActor
final class HydrationRemindersTests: XCTestCase {
    private let keys = [
        HydrationReminders.enabledKey,
        HydrationReminders.intervalMinutesKey,
        HydrationReminders.activeStartMinutesKey,
        HydrationReminders.activeEndMinutesKey,
        HydrationReminders.strapBuzzEnabledKey,
        HydrationReminders.adaptiveEnabledKey,
        HydrationReminders.doubleTapConfirmEnabledKey,
        HydrationReminders.doubleTapAmountMLKey,
        HydrationReminders.doubleTapWindowMinutesKey,
        HydrationReminders.bandFirstEnabledKey,
        HydrationReminders.independentChannelsMigrationKey,
        "notif.masterEnabled",
        "notif.quietHoursEnabled",
        "notif.quietStartMinutes",
        "notif.quietEndMinutes",
        "hydrationReminders.lastClaimedStrapSlot",
        "hydrationReminders.scheduledRequestIDs",
        "hydrationReminders.adaptiveIntervalMinutes",
        "hydrationReminders.adaptiveReason",
        "hydrationReminders.adaptiveDay",
        "hydrationReminders.lastConfirmedStrapSlot",
        "hydrationReminders.pendingEscalationSlot",
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        TapAutomationStore.clear()
        super.tearDown()
    }

    func testDefaultsAreOffAndConservative() {
        XCTAssertFalse(HydrationReminders.isEnabled)
        XCTAssertFalse(HydrationReminders.strapBuzzEnabled)
        XCTAssertEqual(HydrationReminders.intervalMinutes, 120)
        XCTAssertEqual(HydrationReminders.activeStartMinutes, 8 * 60)
        XCTAssertEqual(HydrationReminders.activeEndMinutes, 21 * 60)
        XCTAssertTrue(HydrationReminders.adaptiveEnabled)
        XCTAssertFalse(HydrationReminders.doubleTapConfirmEnabled)
        XCTAssertFalse(HydrationReminders.bandFirstEnabled)
    }

    func testChannelMigrationClearsDormantLegacyWristFlagOnlyOnce() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: HydrationReminders.enabledKey)
        defaults.set(true, forKey: HydrationReminders.strapBuzzEnabledKey)

        HydrationReminders.migrateIndependentChannelsIfNeeded(defaults: defaults)

        XCTAssertFalse(HydrationReminders.strapBuzzEnabled)
        XCTAssertTrue(defaults.bool(forKey: HydrationReminders.independentChannelsMigrationKey))

        defaults.set(true, forKey: HydrationReminders.strapBuzzEnabledKey)
        HydrationReminders.migrateIndependentChannelsIfNeeded(defaults: defaults)
        XCTAssertTrue(HydrationReminders.strapBuzzEnabled,
                      "The migration must not override a post-upgrade independent choice.")
    }

    func testChannelMigrationPreservesAnActiveLegacyPair() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: HydrationReminders.enabledKey)
        defaults.set(true, forKey: HydrationReminders.strapBuzzEnabledKey)

        HydrationReminders.migrateIndependentChannelsIfNeeded(defaults: defaults)

        XCTAssertTrue(HydrationReminders.isEnabled)
        XCTAssertTrue(HydrationReminders.strapBuzzEnabled)
    }

    func testIntervalIsClampedToNotificationBudget() {
        XCTAssertEqual(HydrationReminders.clampedInterval(1), 60)
        XCTAssertEqual(HydrationReminders.clampedInterval(90), 90)
        XCTAssertEqual(HydrationReminders.clampedInterval(9_000), 240)
    }

    func testAdaptivePlanShortensForHeatEffortAndBehindGoalButNeverBelowHourly() {
        let plan = HydrationReminders.adaptivePlan(
            baseInterval: 120,
            start: 8 * 60,
            end: 20 * 60,
            context: .init(
                temperatureC: 32,
                effort: 75,
                consumedML: 200,
                goalML: 2_000,
                minuteOfDay: 14 * 60
            )
        )

        XCTAssertEqual(plan.intervalMinutes, 60)
        XCTAssertTrue(plan.reasons.contains("hot weather"))
        XCTAssertTrue(plan.reasons.contains("higher Effort"))
        XCTAssertTrue(plan.reasons.contains("behind goal"))
    }

    func testAdaptivePlanCanRelaxWhenAheadAndIgnoresMissingContext() {
        let ahead = HydrationReminders.adaptivePlan(
            baseInterval: 120,
            start: 8 * 60,
            end: 20 * 60,
            context: .init(
                temperatureC: nil,
                effort: nil,
                consumedML: 1_700,
                goalML: 2_000,
                minuteOfDay: 12 * 60
            )
        )
        XCTAssertEqual(ahead.intervalMinutes, 135)
        XCTAssertEqual(ahead.reasons, ["ahead of goal"])

        let noData = HydrationReminders.adaptivePlan(
            baseInterval: 120,
            start: 8 * 60,
            end: 20 * 60,
            context: .init(
                temperatureC: nil,
                effort: nil,
                consumedML: nil,
                goalML: nil,
                minuteOfDay: 12 * 60
            )
        )
        XCTAssertEqual(noData.intervalMinutes, 120)
        XCTAssertTrue(noData.reasons.isEmpty)

        let goalWithoutIntake = HydrationReminders.adaptivePlan(
            baseInterval: 120,
            start: 8 * 60,
            end: 20 * 60,
            context: .init(
                temperatureC: nil,
                effort: nil,
                consumedML: nil,
                goalML: 2_000,
                minuteOfDay: 12 * 60
            )
        )
        XCTAssertEqual(goalWithoutIntake.intervalMinutes, 120)
        XCTAssertTrue(goalWithoutIntake.reasons.isEmpty)
    }

    func testAdaptiveProgressDoesNotGuessOutsideActiveHours() {
        let plan = HydrationReminders.adaptivePlan(
            baseInterval: 120,
            start: 8 * 60,
            end: 20 * 60,
            context: .init(
                temperatureC: nil,
                effort: nil,
                consumedML: 0,
                goalML: 2_000,
                minuteOfDay: 22 * 60
            )
        )

        XCTAssertEqual(plan.intervalMinutes, 120)
        XCTAssertTrue(plan.reasons.isEmpty)
    }

    func testNormalAndOvernightWindowsProduceDeterministicSlots() {
        XCTAssertEqual(
            HydrationReminders.reminderMinutes(start: 8 * 60, end: 12 * 60, interval: 120),
            [8 * 60, 10 * 60]
        )
        XCTAssertEqual(
            HydrationReminders.reminderMinutes(start: 22 * 60, end: 2 * 60, interval: 120),
            [22 * 60, 0]
        )
        XCTAssertEqual(
            HydrationReminders.reminderMinutes(start: 9 * 60, end: 9 * 60, interval: 240),
            [9 * 60, 13 * 60, 17 * 60, 21 * 60, 60, 5 * 60]
        )
    }

    func testReminderCopyIsGenericAndRoutesToHydration() {
        let specs = HydrationReminders.reminderSpecs(start: 8 * 60, end: 12 * 60, interval: 120)

        XCTAssertEqual(specs.map(\.route), [.hydration, .hydration])
        XCTAssertEqual(specs.map(\.minuteOfDay), [8 * 60, 10 * 60])
        for spec in specs {
            XCTAssertTrue(spec.title.localizedCaseInsensitiveContains("hydration"))
            XCTAssertNil(spec.body.rangeOfCharacter(from: .decimalDigits))
            XCTAssertFalse(spec.body.localizedCaseInsensitiveContains("score"))
            XCTAssertFalse(spec.body.localizedCaseInsensitiveContains("log"))
        }
    }

    func testOneHourAllDayScheduleStaysWithinNotificationBudget() {
        let specs = HydrationReminders.reminderSpecs(start: 0, end: 0, interval: 60)
        XCTAssertEqual(specs.count, 24)
        XCTAssertEqual(Set(specs.map(\.identifier)).count, 24)
    }

    func testQuietWindowIsStartInclusiveEndExclusiveAndCanWrapMidnight() {
        XCTAssertTrue(HydrationReminders.windowContains(22 * 60, start: 22 * 60, end: 7 * 60))
        XCTAssertTrue(HydrationReminders.windowContains(6 * 60 + 59, start: 22 * 60, end: 7 * 60))
        XCTAssertFalse(HydrationReminders.windowContains(7 * 60, start: 22 * 60, end: 7 * 60))
        XCTAssertFalse(HydrationReminders.windowContains(12 * 60, start: 22 * 60, end: 7 * 60))
        XCTAssertFalse(HydrationReminders.windowContains(12 * 60, start: 12 * 60, end: 12 * 60))
    }

    func testDueSlotCarriesPreviousDayAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 12, hour: 0, minute: 2
        )))

        let slot = HydrationReminders.dueSlot(
            now: now,
            calendar: calendar,
            slots: [23 * 60 + 59],
            graceMinutes: 5
        )

        XCTAssertEqual(slot, .init(minuteOfDay: 23 * 60 + 59, localDay: "2026-08-11"))
    }

    func testAdaptiveRealignmentCannotDoubleBuzzInsideOneHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertFalse(HydrationReminders.strapOccurrenceIsSeparated(
            previousToken: "2026-08-12-480",
            due: .init(minuteOfDay: 510, localDay: "2026-08-12"),
            calendar: calendar
        ))
        XCTAssertTrue(HydrationReminders.strapOccurrenceIsSeparated(
            previousToken: "2026-08-12-480",
            due: .init(minuteOfDay: 540, localDay: "2026-08-12"),
            calendar: calendar
        ))
    }

    func testStrapSlotIsIndependentFromPhoneNotificationsAndClaimsOnlyOnce() throws {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: HydrationReminders.enabledKey)
        defaults.set(true, forKey: HydrationReminders.strapBuzzEnabledKey)
        defaults.set(true, forKey: "notif.masterEnabled")
        defaults.set(10 * 60, forKey: HydrationReminders.activeStartMinutesKey)
        defaults.set(10 * 60, forKey: HydrationReminders.activeEndMinutesKey)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 11, hour: 10, minute: 3
        )))

        XCTAssertNotNil(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
        XCTAssertNil(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))

        defaults.set(false, forKey: "notif.masterEnabled")
        defaults.removeObject(forKey: "hydrationReminders.lastClaimedStrapSlot")
        XCTAssertNil(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
    }

    func testPhoneOnlyAndNeitherDoNotClaimStrapBuzz() throws {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: HydrationReminders.enabledKey)
        defaults.set(false, forKey: HydrationReminders.strapBuzzEnabledKey)
        defaults.set(true, forKey: "notif.masterEnabled")
        defaults.set(10 * 60, forKey: HydrationReminders.activeStartMinutesKey)
        defaults.set(10 * 60, forKey: HydrationReminders.activeEndMinutesKey)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 11, hour: 10, minute: 3
        )))

        XCTAssertNil(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
        defaults.set(false, forKey: HydrationReminders.enabledKey)
        XCTAssertNil(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
    }

    func testStrapClaimRespectsGlobalQuietHours() throws {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: HydrationReminders.enabledKey)
        defaults.set(true, forKey: HydrationReminders.strapBuzzEnabledKey)
        defaults.set(true, forKey: "notif.masterEnabled")
        defaults.set(true, forKey: "notif.quietHoursEnabled")
        defaults.set(22 * 60, forKey: "notif.quietStartMinutes")
        defaults.set(7 * 60, forKey: "notif.quietEndMinutes")
        defaults.set(23 * 60, forKey: HydrationReminders.activeStartMinutesKey)
        defaults.set(23 * 60, forKey: HydrationReminders.activeEndMinutesKey)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 11, hour: 23, minute: 2
        )))

        XCTAssertNil(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
    }

    func testBandFirstRequiresBandAndExplicitTapConfirmation() {
        HydrationReminders.setBandFirstEnabled(true)
        XCTAssertFalse(HydrationReminders.bandFirstEnabled)

        HydrationReminders.setStrapBuzzEnabled(true)
        HydrationReminders.setDoubleTapConfirmEnabled(true)
        HydrationReminders.setBandFirstEnabled(true)
        XCTAssertTrue(HydrationReminders.bandFirstEnabled)

        HydrationReminders.setDoubleTapConfirmEnabled(false)
        XCTAssertFalse(HydrationReminders.bandFirstEnabled)
    }

    func testBandCueArmsSlotScopedHydrationConfirmation() {
        UserDefaults.standard.set(true, forKey: HydrationReminders.doubleTapConfirmEnabledKey)
        UserDefaults.standard.set(275, forKey: HydrationReminders.doubleTapAmountMLKey)
        let slot = HydrationReminders.DueSlot(minuteOfDay: 8 * 60, localDay: "2026-08-23")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        HydrationReminders.armDoubleTapConfirmation(for: slot, now: now)
        let action = TapAutomationStore.consume(now: now)

        XCTAssertEqual(action?.kind, .hydrationConfirm)
        XCTAssertEqual(action?.value, 275)
        XCTAssertEqual(action?.contextKey, slot.token)
    }
}
