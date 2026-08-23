import XCTest

final class NOOPiOSUITests: XCTestCase {
    private func launchApp(tab: String = "today") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-tab", tab]
        app.launch()
        return app
    }

    private func launchDemoScreen(_ name: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-screen", name] + extraArguments
        app.launch()
        return app
    }

    func testPrimaryTabsNavigateAndExposeSelection() {
        let app = launchApp()
        let today = app.buttons["noop.tab.0"]
        let trends = app.buttons["noop.tab.1"]
        let workouts = app.buttons["noop.tab.2"]
        let sleep = app.buttons["noop.tab.3"]
        let more = app.buttons["noop.tab.4"]

        XCTAssertTrue(today.waitForExistence(timeout: 20))
        XCTAssertTrue(trends.exists)
        XCTAssertTrue(workouts.exists)
        XCTAssertTrue(sleep.exists)
        XCTAssertTrue(more.exists)
        XCTAssertTrue(today.isSelected)

        trends.tap()
        XCTAssertTrue(trends.isSelected)
        workouts.tap()
        XCTAssertTrue(workouts.isSelected)
        sleep.tap()
        XCTAssertTrue(sleep.isSelected)
        more.tap()
        XCTAssertTrue(more.isSelected)
    }

    func testFloatingQuickActionsOpenTheProductionLauncher() {
        let app = launchApp()
        let quickActions = app.buttons["noop.quick-actions"]
        XCTAssertTrue(quickActions.waitForExistence(timeout: 20))

        quickActions.tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Strength"].exists)
        XCTAssertTrue(app.buttons["Meal"].exists)
        XCTAssertTrue(app.buttons["Live HR"].exists)
    }

    func testCompactTabControlExpandsWithoutChangingTheSelectedTab() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed",
            "--demo-tab", "today",
            "--demo-compact-tab-bar",
        ]
        app.launch()

        let compact = app.buttons["noop.tab.compact"]
        XCTAssertTrue(compact.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["noop.tab.1"].exists)
        XCTAssertTrue(app.buttons["noop.quick-actions"].exists)

        compact.tap()
        let today = app.buttons["noop.tab.0"]
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        XCTAssertTrue(today.isSelected)
        XCTAssertTrue(app.buttons["noop.tab.4"].exists)
        XCTAssertTrue(app.buttons["noop.quick-actions"].exists)
    }

    func testTodayCalendarButtonOpensMonthHistory() {
        let app = launchApp()
        let calendar = app.buttons["noop.today.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 20))

        calendar.tap()
        XCTAssertTrue(app.staticTexts["Your month"].waitForExistence(timeout: 5))
        let recovery = app.buttons["noop.calendar.metric.recovery"]
        XCTAssertTrue(recovery.exists)
        XCTAssertTrue(recovery.isSelected)
        XCTAssertTrue(app.buttons["noop.calendar.metric.sleep"].exists)
        XCTAssertTrue(app.buttons["noop.calendar.metric.effort"].exists)
        XCTAssertFalse(app.buttons["noop.calendar.metric.load"].isSelected)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        XCTAssertEqual(
            app.staticTexts["noop.calendar.month"].label,
            formatter.string(from: Date())
        )
    }

    func testBandBatteryShowsChargingStateFromLiveFixture() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed",
            "--demo-tab", "today",
            "--demo-band-charging",
        ]
        app.launch()

        let battery = app.buttons["noop.today.band-battery"]
        XCTAssertTrue(battery.waitForExistence(timeout: 20))
        XCTAssertTrue(
            battery.label.localizedCaseInsensitiveContains("charging"),
            "The real masthead battery must announce the charger state, not only its percentage."
        )
    }

    func testDailySignalAlertStateIsActionable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed",
            "--demo-tab", "today",
            "--demo-daily-signal", "alert",
        ]
        app.launch()

        let signal = app.buttons["noop.today.daily-signal"]
        XCTAssertTrue(signal.waitForExistence(timeout: 20))
        XCTAssertTrue(signal.label.localizedCaseInsensitiveContains("check in"))
        keepScreenshot(app, name: "daily-signal-alert")
    }

    func testTermsPrimaryActionRemainsVisible() {
        let app = launchDemoScreen("terms")
        let accept = app.buttons["noop.terms.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 20))
        XCTAssertEqual(accept.label, "Accept & Continue")
        keepScreenshot(app, name: "terms-readable-primary-action")
    }

    func testOnboardingPairingUsesGenericNoopBandAndAutomaticDetection() {
        let app = launchDemoScreen(
            "onboarding",
            extraArguments: ["--demo-onboarding-step", "5"]
        )

        let band = app.staticTexts["noop.onboarding.band"]
        XCTAssertTrue(band.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["noop.onboarding.scan"].exists)
        XCTAssertFalse(app.staticTexts["Which strap are you pairing?"].exists)
        XCTAssertFalse(app.staticTexts["WHOOP 4.0"].exists)
        XCTAssertFalse(app.staticTexts["WHOOP 5.0 / MG"].exists)
        keepScreenshot(app, name: "onboarding-noop-band")
    }

    func testProfileMeasurementsCanBeClearedAndRetyped() {
        let app = launchDemoScreen(
            "onboarding",
            extraArguments: ["--demo-onboarding-step", "7"]
        )

        let weight = app.textFields["noop.profile.weight"]
        XCTAssertTrue(weight.waitForExistence(timeout: 20))
        weight.tap()
        let clearWeight = app.buttons["noop.profile.weight.clear"]
        XCTAssertTrue(clearWeight.waitForExistence(timeout: 3))
        clearWeight.tap()
        weight.typeText("82.5")
        XCTAssertEqual(weight.value as? String, "82.5")

        let height = app.textFields["noop.profile.height.cm"]
        XCTAssertTrue(height.exists)
        height.tap()
        let clearHeight = app.buttons["noop.profile.height.clear"]
        XCTAssertTrue(clearHeight.waitForExistence(timeout: 3))
        clearHeight.tap()
        height.typeText("183")
        XCTAssertEqual(height.value as? String, "183")
        keepScreenshot(app, name: "onboarding-editable-measurements")
    }

    func testKeyMetricSelectionEnforcesAccessibleThreeToFiveBoundaries() {
        let app = launchDemoScreen("keymetricseditor")
        let recovery = app.switches["noop.key-metric.toggle.charge"]
        let hrv = app.switches["noop.key-metric.toggle.hrv"]
        let restingHR = app.switches["noop.key-metric.toggle.restingHr"]
        let bloodOxygen = app.switches["noop.key-metric.toggle.bloodOxygen"]

        XCTAssertTrue(recovery.waitForExistence(timeout: 20))
        XCTAssertTrue(hrv.exists)
        XCTAssertEqual(recovery.value as? String, "1")
        XCTAssertFalse(recovery.isEnabled)
        XCTAssertEqual(hrv.value as? String, "0")
        XCTAssertTrue(hrv.isEnabled)

        hrv.tap()
        XCTAssertTrue(app.staticTexts["4 of 5 selected"].waitForExistence(timeout: 3))
        XCTAssertEqual(hrv.value as? String, "1")
        XCTAssertTrue(recovery.isEnabled)

        recovery.tap()
        XCTAssertTrue(app.staticTexts["3 of 5 selected"].waitForExistence(timeout: 3))
        XCTAssertEqual(recovery.value as? String, "0")
        XCTAssertFalse(hrv.isEnabled)

        recovery.tap()
        XCTAssertTrue(app.staticTexts["4 of 5 selected"].waitForExistence(timeout: 3))
        restingHR.tap()
        XCTAssertTrue(app.staticTexts["5 of 5 selected"].waitForExistence(timeout: 3))
        XCTAssertEqual(restingHR.value as? String, "1")
        XCTAssertFalse(bloodOxygen.isEnabled)
        keepScreenshot(app, name: "key-metrics-accessible-color-boundaries")
    }

    func testMetricScreensExposeTheirOwnReminderControls() {
        var app = launchDemoScreen("hydration")
        let waterReminders = app.staticTexts["Water reminders"]
        for _ in 0..<6 where !waterReminders.exists { app.swipeUp() }
        XCTAssertTrue(waterReminders.waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["noop.hydration.reminders"].exists)
        keepScreenshot(app, name: "hydration-reminders")

        app.terminate()
        app = launchDemoScreen("sleep")
        let sleepReminders = app.staticTexts["Reminders & alarms"]
        for _ in 0..<6 where !sleepReminders.exists { app.swipeUp() }
        XCTAssertTrue(sleepReminders.waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["Wind-down reminder"].exists)
        XCTAssertTrue(app.switches["Band wake alarm"].exists)
        XCTAssertTrue(app.buttons["noop.sleep.planner"].exists)
        keepScreenshot(app, name: "sleep-reminders-and-alarms")

        app.terminate()
        app = launchDemoScreen(
            "metricdetail",
            extraArguments: ["--demo-metric", "hrv", "--demo-source", "my-whoop"]
        )
        let metricReminder = app.staticTexts["Metric review"]
        for _ in 0..<6 where !metricReminder.exists { app.swipeUp() }
        XCTAssertTrue(metricReminder.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.switches.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "noop.metric.reminder.")
            ).firstMatch.exists
        )
        keepScreenshot(app, name: "metric-detail-reminder")
    }

    func testAgeMetricHeroesExposeHonestModelRanges() {
        var app = launchDemoScreen("fitnessage")
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "not a biological age")
            ).firstMatch.waitForExistence(timeout: 25)
        )

        app.terminate()
        app = launchDemoScreen("vitality")
        let range = app.staticTexts["noop.wellness-age.model-range"]
        XCTAssertTrue(range.waitForExistence(timeout: 25))
        XCTAssertTrue(range.label.localizedCaseInsensitiveContains("not a confidence interval"))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "not biological, medical")
            ).firstMatch.exists
        )
    }

    func testAutomationsExposeConservativeContextualControls() {
        let app = launchDemoScreen("automations")
        XCTAssertTrue(app.staticTexts["Daily review"].waitForExistence(timeout: 20))
        keepScreenshot(app, name: "automations-top")

        let coaching = app.staticTexts["Haptic coaching"]
        for _ in 0..<10 where !coaching.exists { app.swipeUp() }
        XCTAssertTrue(coaching.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Stress check-ins"].exists)
        keepScreenshot(app, name: "automations-stress")

        let vitalReviews = app.staticTexts["Vital trend reviews"]
        for _ in 0..<10 where !vitalReviews.exists { app.swipeUp() }
        XCTAssertTrue(vitalReviews.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Oxygen & body temperature"].exists)
        XCTAssertTrue(app.staticTexts["VO₂ max trend"].exists)
        keepScreenshot(app, name: "automations-vital-reviews")
    }

    func testSleepPlannerEndpointClearsFloatingNavigation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed",
            "--demo-more-route", "alarms",
            "--demo-scroll-bottom",
            "--demo-compact-tab-bar",
        ]
        app.launch()

        let finalControl = app.switches["noop.sleep-planner.per-day"]
        let compactNavigation = app.buttons["noop.tab.compact"]
        let quickActions = app.buttons["noop.quick-actions"]
        XCTAssertTrue(finalControl.waitForExistence(timeout: 20))
        XCTAssertTrue(compactNavigation.waitForExistence(timeout: 5))
        XCTAssertTrue(quickActions.exists)
        var firstFloatingControlY = min(
            compactNavigation.frame.minY,
            quickActions.frame.minY
        )
        for _ in 0..<10 where finalControl.frame.maxY + 8 > firstFloatingControlY {
            app.swipeUp()
            firstFloatingControlY = min(
                compactNavigation.frame.minY,
                quickActions.frame.minY
            )
        }
        XCTAssertTrue(finalControl.isHittable)
        XCTAssertLessThanOrEqual(
            finalControl.frame.maxY + 8,
            firstFloatingControlY,
            "The Sleep Planner's final switch must settle above both floating navigation controls."
        )
        keepScreenshot(app, name: "sleep-planner-clear-endpoint")
    }

    func testSleepPlannerWeekdaysClearCompactNavigation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed",
            "--demo-more-route", "alarms",
            "--demo-compact-tab-bar",
            "--demo-sleep-per-day",
        ]
        app.launch()

        let monday = app.staticTexts["Monday"]
        let sundayWakeTime = app.descendants(matching: .any)["Sunday wake time"]
        let compactNavigation = app.buttons["noop.tab.compact"]
        let quickActions = app.buttons["noop.quick-actions"]
        let perDay = app.switches["noop.sleep-planner.per-day"]
        XCTAssertTrue(perDay.waitForExistence(timeout: 20))
        XCTAssertEqual(perDay.value as? String, "1")
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        XCTAssertTrue(sundayWakeTime.waitForExistence(timeout: 5))
        var firstFloatingControlY = min(compactNavigation.frame.minY, quickActions.frame.minY)
        for _ in 0..<8 where sundayWakeTime.frame.maxY + 8 > firstFloatingControlY {
            app.swipeUp()
            firstFloatingControlY = min(compactNavigation.frame.minY, quickActions.frame.minY)
        }
        XCTAssertTrue(sundayWakeTime.isHittable)
        XCTAssertLessThanOrEqual(sundayWakeTime.frame.maxY + 8, firstFloatingControlY)
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
