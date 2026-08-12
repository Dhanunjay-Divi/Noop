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
        HydrationReminders.independentChannelsMigrationKey,
        "notif.masterEnabled",
        "notif.quietHoursEnabled",
        "notif.quietStartMinutes",
        "notif.quietEndMinutes",
        "hydrationReminders.lastClaimedStrapSlot",
        "hydrationReminders.scheduledRequestIDs",
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testDefaultsAreOffAndConservative() {
        XCTAssertFalse(HydrationReminders.isEnabled)
        XCTAssertFalse(HydrationReminders.strapBuzzEnabled)
        XCTAssertEqual(HydrationReminders.intervalMinutes, 120)
        XCTAssertEqual(HydrationReminders.activeStartMinutes, 8 * 60)
        XCTAssertEqual(HydrationReminders.activeEndMinutes, 21 * 60)
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

    func testReminderCopyIsGenericAndRoutesToToday() {
        let specs = HydrationReminders.reminderSpecs(start: 8 * 60, end: 12 * 60, interval: 120)

        XCTAssertEqual(specs.map(\.route), [.today, .today])
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

        XCTAssertTrue(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
        XCTAssertFalse(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))

        defaults.set(false, forKey: "notif.masterEnabled")
        defaults.removeObject(forKey: "hydrationReminders.lastClaimedStrapSlot")
        XCTAssertFalse(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
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

        XCTAssertFalse(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
        defaults.set(false, forKey: HydrationReminders.enabledKey)
        XCTAssertFalse(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
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

        XCTAssertFalse(HydrationReminders.claimDueStrapBuzz(now: now, calendar: calendar))
    }
}
