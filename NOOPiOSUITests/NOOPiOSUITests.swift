import XCTest

final class NOOPiOSUITests: XCTestCase {
    private enum PreferredContentSize {
        static let standard = "UICTContentSizeCategoryL"
        static let accessibilityLarge = "UICTContentSizeCategoryAccessibilityL"
    }

    private func launchApp(
        tab: String = "today",
        extraArguments: [String] = [],
        preferredContentSize: String = PreferredContentSize.standard
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UIPreferredContentSizeCategoryName", preferredContentSize,
            "--demo-seed", "--demo-tab", tab,
        ] + extraArguments
        app.launch()
        return app
    }

    private func launchDemoScreen(
        _ name: String,
        extraArguments: [String] = [],
        preferredContentSize: String = PreferredContentSize.standard
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UIPreferredContentSizeCategoryName", preferredContentSize,
            "--demo-seed", "--demo-screen", name,
        ] + extraArguments
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

    func testScrollingCompactsNavigationIntoTheCornerControl() {
        let app = launchApp(tab: "trends")
        let expanded = app.buttons["noop.tab.1"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 20))

        app.swipeUp()

        let compact = app.buttons["noop.tab.compact"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertFalse(expanded.exists)
        XCTAssertTrue(app.buttons["noop.quick-actions"].exists)
        keepScreenshot(app, name: "floating-navigation-scroll-compact")
    }

    func testAccessibilityNavigationRetainsLabelsAcrossDenseScreens() {
        var app = launchApp(
            tab: "more",
            preferredContentSize: PreferredContentSize.accessibilityLarge
        )
        let explore = app.buttons["Explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 20))
        assertExpandedNavigationLabels(selectedTab: 4, in: app)
        app.swipeUp()
        assertExpandedNavigationLabels(selectedTab: 4, in: app)
        keepScreenshot(app, name: "se-accessibility-more-clear-navigation")

        app.terminate()
        app = launchApp(
            tab: "workouts",
            preferredContentSize: PreferredContentSize.accessibilityLarge
        )
        let activityCalendar = app.staticTexts["Activity calendar"]
        XCTAssertTrue(activityCalendar.waitForExistence(timeout: 20))
        assertExpandedNavigationLabels(selectedTab: 2, in: app)
        app.swipeUp()
        assertExpandedNavigationLabels(selectedTab: 2, in: app)
        keepScreenshot(app, name: "se-accessibility-workouts-clear-navigation")
    }

    func testActiveMinutesCardExplainsCreditAndCoverageAtLargeText() {
        let app = launchApp(
            tab: "workouts",
            preferredContentSize: PreferredContentSize.accessibilityLarge
        )
        let activeMinutes = app.descendants(matching: .any)["noop.workouts.active-minutes"]
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 20))

        // The Workouts body is lazy. Move in short steps so this card is materialized and inspected
        // instead of jumping from above it to below it on the compact SE viewport.
        for _ in 0..<24 where !activeMinutes.isHittable {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
            start.press(
                forDuration: 0.05,
                thenDragTo: end,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
        }

        XCTAssertTrue(activeMinutes.isHittable)
        let summary = activeMinutes.label
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("weekly activity guideline"))
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("moderate"))
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("vigorous"))
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("HR coverage"))
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("missing wear time stays unmeasured"))

        // `isHittable` becomes true as soon as the combined card clips the viewport edge. Move it into
        // the readable area before retaining visual evidence, otherwise the screenshot proves only that
        // the accessibility tree contains the copy while the card itself remains behind the floating bar.
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        start.press(
            forDuration: 0.05,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        XCTAssertGreaterThan(activeMinutes.frame.intersection(app.frame).height, 120)
        keepScreenshot(app, name: "workouts-active-minutes-accessibility-summary")

        // The complete card is taller than one SE viewport at this text size. Verify that the scaffold's
        // bottom inset lets the final coverage note scroll above the floating navigation instead of being
        // permanently obscured by it, and retain that lower-card state separately.
        let navigation = app.buttons["noop.tab.2"]
        XCTAssertTrue(navigation.exists)
        for _ in 0..<4 where activeMinutes.frame.maxY >= navigation.frame.minY {
            let lowerStart = scroll.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let lowerEnd = scroll.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
            lowerStart.press(
                forDuration: 0.05,
                thenDragTo: lowerEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
        }
        XCTAssertLessThan(activeMinutes.frame.maxY, navigation.frame.minY)
        keepScreenshot(app, name: "workouts-active-minutes-accessibility-details")
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
        XCTAssertTrue(app.buttons["noop.calendar.metric.stress"].exists)
        XCTAssertTrue(app.buttons["noop.calendar.metric.energy"].exists)
        XCTAssertTrue(app.buttons["noop.calendar.metric.nutrition"].exists)
        XCTAssertFalse(app.buttons["noop.calendar.metric.stress"].isSelected)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        XCTAssertEqual(
            app.staticTexts["noop.calendar.month"].label,
            formatter.string(from: Date())
        )
    }

    func testPullToSyncRevealsCircularFeedback() {
        let app = launchApp()
        let calendar = app.buttons["noop.today.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["noop.today.pull-sync"].exists)

        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)

        let sync = app.descendants(matching: .any)["noop.today.pull-sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 3))
        XCTAssertTrue(
            sync.label.localizedCaseInsensitiveContains("refresh")
                || sync.label.localizedCaseInsensitiveContains("sync"),
            "Unexpected pull feedback: \(sync.label)"
        )
        XCTAssertTrue(
            String(describing: sync.value).localizedCaseInsensitiveContains("progress")
                || sync.label.localizedCaseInsensitiveContains("syncing")
        )
        keepScreenshot(app, name: "today-pull-sync-circular-feedback")
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

    func testNutritionSummaryUsesLoggedMacrosAndLabBookReading() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed",
            "--demo-more-route", "nutrition",
            "--demo-nutrition",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Today’s foods"].waitForExistence(timeout: 20))
        let calories = app.descendants(matching: .any)["noop.nutrition.calories"]
        let protein = app.descendants(matching: .any)["noop.nutrition.protein"]
        let carbs = app.descendants(matching: .any)["noop.nutrition.carbs"]
        let fat = app.descendants(matching: .any)["noop.nutrition.fat"]
        let glucose = app.descendants(matching: .any)["noop.nutrition.fasting-glucose"]
        XCTAssertTrue(calories.waitForExistence(timeout: 5))
        XCTAssertTrue(protein.waitForExistence(timeout: 5))
        XCTAssertTrue(carbs.waitForExistence(timeout: 5))
        XCTAssertTrue(fat.waitForExistence(timeout: 5))
        XCTAssertTrue(glucose.waitForExistence(timeout: 5))
        XCTAssertTrue(String(describing: calories.value).contains("2,100"))
        XCTAssertEqual(protein.value as? String, "140 g")
        XCTAssertEqual(carbs.value as? String, "220 g")
        XCTAssertEqual(fat.value as? String, "70 g")
        XCTAssertEqual(glucose.label, "Fasting glucose")
        XCTAssertTrue((glucose.value as? String)?.contains("5.2 mmol/L") == true)
        XCTAssertTrue((glucose.value as? String)?.contains("Lab Book") == true)
        XCTAssertFalse(app.staticTexts["Blood glucose"].exists)
        keepScreenshot(app, name: "nutrition-logged-summary")
    }

    func testTermsPrimaryActionRemainsVisible() {
        let app = launchDemoScreen("terms")
        XCTAssertTrue(app.staticTexts["NOOP Band is coming"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts.matching(identifier: "NOOP Band is coming").count, 1)
        XCTAssertTrue(
            app.staticTexts[
                "Until NOOP Band is ready, this version works with a compatible band you own."
            ].exists
        )
        XCTAssertFalse(app.staticTexts["Independent: not affiliated with WHOOP"].exists)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "WHOOP")).count,
            0
        )
        let accept = app.buttons["noop.terms.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
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

    func testOnboardingScanEndpointClearsFooterAtAccessibilitySize() {
        let app = launchDemoScreen(
            "onboarding",
            extraArguments: ["--demo-onboarding-step", "5"],
            preferredContentSize: PreferredContentSize.accessibilityLarge
        )
        let primaryAction = app.buttons["noop.onboarding.primary"]
        let footer = app.descendants(matching: .any)["noop.onboarding.footer"]
        let scanHelp = app.buttons["Don't see it?"]
        let scanFootnote = app.staticTexts["noop.onboarding.scan-footnote"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 20))
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertTrue(scanHelp.waitForExistence(timeout: 5))
        XCTAssertTrue(scanFootnote.waitForExistence(timeout: 5))
        XCTAssertFalse(
            scanHelp.isHittable && scanHelp.frame.intersects(footer.frame),
            "Visible Scan help must not be exposed underneath the fixed onboarding footer."
        )

        for _ in 0..<8
            where !scanFootnote.isHittable
                || scanFootnote.frame.maxY + 12 > footer.frame.minY {
            app.swipeUp()
        }

        XCTAssertTrue(
            scanFootnote.isHittable,
            "The final Scan guidance must be reachable above the fixed onboarding footer."
        )
        XCTAssertLessThanOrEqual(
            scanFootnote.frame.maxY + 12,
            footer.frame.minY,
            "The fixed onboarding footer must not cover the Scan step's final guidance."
        )
        XCTAssertFalse(scanFootnote.frame.intersects(footer.frame))
        XCTAssertFalse(scanFootnote.frame.intersects(primaryAction.frame))
        keepScreenshot(app, name: "se-accessibility-onboarding-clear-footer")
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
        XCTAssertTrue(height.isHittable, "Height must remain above the software keyboard while weight is active.")
        height.tap()
        let clearHeight = app.buttons["noop.profile.height.clear"]
        XCTAssertTrue(clearHeight.waitForExistence(timeout: 3))
        XCTAssertTrue(clearHeight.isHittable)
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
        XCTAssertTrue(app.staticTexts["4 of 5 pinned"].waitForExistence(timeout: 3))
        XCTAssertEqual(hrv.value as? String, "1")
        XCTAssertTrue(recovery.isEnabled)

        recovery.tap()
        XCTAssertTrue(app.staticTexts["3 of 5 pinned"].waitForExistence(timeout: 3))
        XCTAssertEqual(recovery.value as? String, "0")
        XCTAssertFalse(hrv.isEnabled)

        recovery.tap()
        XCTAssertTrue(app.staticTexts["4 of 5 pinned"].waitForExistence(timeout: 3))
        restingHR.tap()
        XCTAssertTrue(app.staticTexts["5 of 5 pinned"].waitForExistence(timeout: 3))
        XCTAssertEqual(restingHR.value as? String, "1")
        XCTAssertFalse(bloodOxygen.isEnabled)
        keepScreenshot(app, name: "key-metrics-accessible-color-boundaries")
    }

    func testTodayKeepsTheCompleteMetricCatalogVisible() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed",
            "--demo-tab", "today",
            "--demo-key-metrics",
        ]
        app.launch()

        let metricIDs = [
            "charge", "effort", "rest", "hrv", "restingHr",
            "bloodOxygen", "respiratory", "steps", "weight", "calories",
        ]
        for id in metricIDs {
            let tile = app.descendants(matching: .any)["noop.today.key-metric.\(id)"]
            for _ in 0..<4 where !tile.exists { app.swipeUp() }
            XCTAssertTrue(tile.waitForExistence(timeout: 3), "\(id) must remain in the Today catalog.")
        }
        keepScreenshot(app, name: "today-complete-key-metric-catalog")
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
        let metricReminderToggle = app.switches.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "noop.metric.reminder.")
        ).firstMatch
        XCTAssertTrue(
            metricReminderToggle.waitForExistence(timeout: 3),
            app.debugDescription
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
                NSPredicate(format: "label CONTAINS[c] %@", "not biological or medical age")
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

    func testDeviceActionsAndFooterClearPersistentNavigation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed",
            "--demo-more-route", "devices",
            "--demo-scroll-bottom",
            "--demo-compact-tab-bar",
        ]
        app.launch()

        let actions = app.buttons["noop.device.actions"].firstMatch
        let technicalDetails = app.buttons["Technical details"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 20))
        XCTAssertTrue(technicalDetails.waitForExistence(timeout: 5))
        XCTAssertFalse(
            actions.frame.intersects(technicalDetails.frame),
            "The device action menu must not cover the disclosure control."
        )

        let footer = app.descendants(matching: .any)["noop.devices.footer"]
        let compactNavigation = app.buttons["noop.tab.compact"]
        let expandedNavigation = app.buttons["noop.tab.4"]
        let quickActions = app.buttons["noop.quick-actions"]
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertTrue(
            compactNavigation.exists || expandedNavigation.waitForExistence(timeout: 5),
            "Navigation must remain available in its compact or accessibility-expanded presentation."
        )
        let navigationY = compactNavigation.exists
            ? compactNavigation.frame.minY
            : expandedNavigation.frame.minY
        let firstFloatingControlY = min(navigationY, quickActions.frame.minY)
        XCTAssertLessThanOrEqual(
            footer.frame.maxY + 8,
            firstFloatingControlY,
            "The Devices footer must settle above both floating controls."
        )
        keepScreenshot(app, name: "devices-actions-and-clear-endpoint")
    }

    func testRecoveryTrendSupportsExactDateScrubbing() {
        let app = launchApp(tab: "trends")
        // NavigationLink mirrors child accessibility metadata onto its button. Select the chart's
        // concrete element so the gesture lands in the plot instead of matching both elements.
        let chart = app.otherElements["noop.trends.recovery.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 20))
        let quickActions = app.buttons["noop.quick-actions"]
        XCTAssertTrue(quickActions.waitForExistence(timeout: 5))
        for _ in 0..<6 where chart.frame.maxY + 12 > quickActions.frame.minY {
            app.swipeUp()
        }
        XCTAssertTrue(chart.isHittable)
        XCTAssertLessThanOrEqual(chart.frame.maxY + 12, quickActions.frame.minY)
        let chartFrame = chart.frame

        let summary = String(describing: chart.value)
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("points"))

        let july29Area = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.71, dy: 0.50))
        let nearby = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.50))
        july29Area.press(forDuration: 0.35, thenDragTo: nearby)

        let selected = String(describing: chart.value)
        XCTAssertNotEqual(selected, summary)
        XCTAssertFalse(selected.localizedCaseInsensitiveContains("points"))
        keepScreenshot(app, name: "trends-recovery-date-selection")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: chartFrame.midX, dy: chartFrame.midY))
            .tap()
        XCTAssertTrue(app.navigationBars["Recovery"].waitForExistence(timeout: 5))
    }

    func testTrendsRangeCopyStaysClearAtCompactWidths() {
        let app = launchApp(tab: "trends")
        let rangeLabel = app.staticTexts["noop.trends.range-label"]
        let rangeDates = app.staticTexts["noop.trends.range-dates"]
        let coverage = app.staticTexts["noop.trends.range-coverage"]
        XCTAssertTrue(rangeLabel.waitForExistence(timeout: 20))
        XCTAssertTrue(rangeDates.exists)
        XCTAssertTrue(coverage.exists)

        for _ in 0..<8 where !coverage.isHittable {
            app.swipeUp()
        }

        XCTAssertTrue(rangeLabel.isHittable)
        XCTAssertTrue(rangeDates.isHittable)
        XCTAssertTrue(coverage.isHittable)
        XCTAssertTrue(rangeLabel.label.localizedCaseInsensitiveContains("last 3 months"))
        XCTAssertTrue(coverage.label.localizedCaseInsensitiveContains("recovery scores"))
        XCTAssertTrue(
            coverage.label.range(
                of: #"Recovery scores: [1-9][0-9]* of 90 days\."#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
            "Unexpected coverage copy: \(coverage.label)"
        )
        XCTAssertTrue(coverage.label.localizedCaseInsensitiveContains("one score per day"))
        XCTAssertFalse(coverage.label.localizedCaseInsensitiveContains("readings"))
        XCTAssertFalse(coverage.label.localizedCaseInsensitiveContains("average across"))
        XCTAssertFalse(rangeLabel.frame.intersects(coverage.frame))
        XCTAssertFalse(rangeDates.frame.intersects(coverage.frame))
        keepScreenshot(app, name: "trends-range-compact-copy")
    }

    private func assertExpandedNavigationLabels(
        selectedTab: Int,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let labels = ["Today", "Trends", "Fitness", "Sleep", "More"]
        for (index, label) in labels.enumerated() {
            let tab = app.buttons["noop.tab.\(index)"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), file: file, line: line)
            XCTAssertEqual(tab.label, label, file: file, line: line)
            XCTAssertEqual(tab.isSelected, index == selectedTab, file: file, line: line)
        }
        XCTAssertFalse(
            app.buttons["noop.tab.compact"].exists,
            "Accessibility Dynamic Type must keep visible navigation labels.",
            file: file,
            line: line
        )
        XCTAssertTrue(app.buttons["noop.quick-actions"].exists, file: file, line: line)
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
