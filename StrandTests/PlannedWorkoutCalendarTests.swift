import XCTest
@testable import Strand

final class PlannedWorkoutCalendarTests: XCTestCase {
    func testSnapshotBridgesCivilWorkoutIntoLogicalPlanningDayWithoutChangingTime() {
        let snapshot = PlannedWorkoutCalendarSnapshot(
            day: "2026-09-10",
            startSec: 1_789_060_200,
            endSec: 1_789_063_800,
            observedAtSec: 1_789_010_000,
            revision: 3
        )

        let workout = snapshot.plannedWorkout(forPlanningDay: "2026-09-09")

        XCTAssertEqual(workout.day, "2026-09-09")
        XCTAssertEqual(workout.startSec, snapshot.startSec)
        XCTAssertEqual(workout.endSec, snapshot.endSec)
    }

    @MainActor
    func testProviderChangeRequestsFreshGuidanceEvaluationWhenEnabled() async {
        let defaults = UserDefaults.standard
        let adaptiveKey = ContextualInterventionSettings.adaptiveDayGuidanceEnabledKey
        let calendarKey = PlannedWorkoutCalendarSettings.enabledKey
        let priorAdaptive = defaults.object(forKey: adaptiveKey)
        let priorCalendar = defaults.object(forKey: calendarKey)
        defer {
            if let priorAdaptive {
                defaults.set(priorAdaptive, forKey: adaptiveKey)
            } else {
                defaults.removeObject(forKey: adaptiveKey)
            }
            if let priorCalendar {
                defaults.set(priorCalendar, forKey: calendarKey)
            } else {
                defaults.removeObject(forKey: calendarKey)
            }
            PlannedWorkoutCalendarStore.shared.clear()
        }
        defaults.set(true, forKey: adaptiveKey)
        defaults.set(true, forKey: calendarKey)

        let requested = expectation(description: "calendar provider change")
        let observer = NotificationCenter.default.addObserver(
            forName: PlannedWorkoutCalendarStore.providerDidChange,
            object: nil,
            queue: .main
        ) { _ in
            requested.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await PlannedWorkoutCalendarStore.shared.handleProviderChange()

        await fulfillment(of: [requested], timeout: 1)
    }
}
