import XCTest
@testable import HistoryHarnessCore

final class HistoryHarnessCoreTests: XCTestCase {
    func testManagedRetentionProfileIsBoundedByDataClass() throws {
        XCTAssertEqual(
            try HistoryHarness.plan(days: 10),
            HistoryDatasetPlan(
                requestedDays: 10
            )
        )
        let ten = try HistoryHarness.plan(days: 10)
        XCTAssertEqual(ten.rawHistoryDays, 7)
        XCTAssertEqual(ten.essentialHistoryDays, 10)
        XCTAssertEqual(ten.aggregateHistoryDays, 10)

        let year = try HistoryHarness.plan(days: 365)
        XCTAssertEqual(year.rawHistoryDays, 7)
        XCTAssertEqual(year.essentialHistoryDays, 30)
        XCTAssertEqual(year.aggregateHistoryDays, 365)
    }

    func testOnlyReleaseScenariosAreAccepted() throws {
        XCTAssertThrowsError(try HistoryHarness.plan(days: 9)) { error in
            XCTAssertEqual(error as? HistoryHarnessError, .unsupportedDays(9))
        }
        XCTAssertEqual(HistoryHarness.supportedDays, [10, 30, 90, 365])
    }
}
