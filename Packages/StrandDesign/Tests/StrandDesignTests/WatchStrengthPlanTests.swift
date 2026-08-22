import XCTest
@testable import StrandDesign

final class WatchStrengthPlanTests: XCTestCase {
    func testBoundsLatestStateForWatchPayload() throws {
        let routines = (0..<10).map { index in
            WatchStrengthRoutine(
                id: "routine-\(index)",
                name: "Routine \(index)",
                exerciseNames: (0..<9).map { "Exercise \($0)" },
                targetSetCount: -1
            )
        }
        let plan = WatchStrengthPlan(
            routines: routines,
            activeSessionName: "Day A",
            activeCompletedSets: -3,
            activeTargetSets: 12,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(plan.routines.count, 8)
        XCTAssertEqual(plan.routines[0].exerciseNames.count, 6)
        XCTAssertEqual(plan.routines[0].targetSetCount, 0)
        XCTAssertEqual(plan.activeCompletedSets, 0)

        let decoded = try JSONDecoder().decode(
            WatchStrengthPlan.self,
            from: JSONEncoder().encode(plan)
        )
        XCTAssertEqual(decoded, plan)
    }
}
