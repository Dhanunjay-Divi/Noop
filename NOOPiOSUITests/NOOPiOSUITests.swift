import XCTest

final class NOOPiOSUITests: XCTestCase {
    private func launchApp(tab: String = "today") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-tab", tab]
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
}
