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

    func testAdaptiveEvaluationStopsAfterCalendarRefreshWhenCancelled() throws {
        let source = try source("Strand/App/AppModel.swift")
        let method = try XCTUnwrap(
            source.range(of: "private func evaluateAdaptiveDayGuidance")
        )
        let tail = source[method.lowerBound...]
        let refresh = try XCTUnwrap(
            tail.range(of: "await PlannedWorkoutCalendarStore.shared.refresh")
        )
        let cancellation = try XCTUnwrap(
            tail.range(
                of: "guard !Task.isCancelled else { return }",
                range: refresh.upperBound..<tail.endIndex
            )
        )
        let plan = try XCTUnwrap(
            tail.range(
                of: "let plan = DailyActionPlanner.plan",
                range: cancellation.upperBound..<tail.endIndex
            )
        )
        XCTAssertLessThan(cancellation.lowerBound, plan.lowerBound)
    }

    func testAdaptiveEvaluationSchedulesTheTwoHourBoundaryAndCancelsBeforeLiveDelivery() throws {
        let source = try source("Strand/App/AppModel.swift")
        let method = try XCTUnwrap(
            source.range(of: "private func evaluateAdaptiveDayGuidance")
        )
        let tail = source[method.lowerBound...]
        let schedule = try XCTUnwrap(
            tail.range(of: "AdaptivePlannedWorkoutScheduler.schedule")
        )
        let cancel = try XCTUnwrap(
            tail.range(
                of: "AdaptivePlannedWorkoutScheduler.cancelPending()",
                range: schedule.upperBound..<tail.endIndex
            )
        )
        let post = try XCTUnwrap(
            tail.range(
                of: "ContextualInterventionCenter.post",
                range: cancel.upperBound..<tail.endIndex
            )
        )

        XCTAssertLessThan(schedule.lowerBound, cancel.lowerBound)
        XCTAssertLessThan(cancel.lowerBound, post.lowerBound)
    }

    func testEventKitQueryRejectsCurrentUserDeclinedInvitations() throws {
        let source = try source("Strand/System/PlannedWorkoutCalendar.swift")
        XCTAssertTrue(source.contains("!plannedWorkoutWasDeclinedByCurrentUser(event)"))
        XCTAssertTrue(source.contains("participant.isCurrentUser"))
        XCTAssertTrue(source.contains("participant.participantStatus == .declined"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
