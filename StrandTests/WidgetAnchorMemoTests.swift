import XCTest
import WhoopStore
@testable import Strand

final class WidgetAnchorMemoTests: XCTestCase {
    private func row(_ recovery: Double) -> DailyMetric {
        DailyMetric(day: "2026-08-06", totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: nil, avgHrv: nil, recovery: recovery,
                    strain: nil, exerciseCount: nil)
    }

    func testReusesAnchorWhileKeyIsUnchanged() {
        var memo = WidgetAnchorMemo()
        var computeCalls = 0

        func resolve() -> DailyMetric? {
            memo.resolve(
                days: [], seq: 5,
                logicalKey: "2026-08-06", localKey: "2026-08-06"
            ) { _, _, _ in
                computeCalls += 1
                return self.row(Double(computeCalls))
            }
        }

        let first = resolve()
        for _ in 0..<1_000 {
            XCTAssertEqual(resolve(), first)
        }
        XCTAssertEqual(computeCalls, 1)
        XCTAssertEqual(first?.recovery, 1)
    }

    func testRefreshSequenceChangeRecomputes() {
        var memo = WidgetAnchorMemo()
        var computeCalls = 0
        let compute: ([DailyMetric], String, String) -> DailyMetric? = { _, _, _ in
            computeCalls += 1
            return self.row(Double(computeCalls))
        }

        _ = memo.resolve(days: [], seq: 1, logicalKey: "d", localKey: "d", compute: compute)
        _ = memo.resolve(days: [], seq: 2, logicalKey: "d", localKey: "d", compute: compute)

        XCTAssertEqual(computeCalls, 2)
    }

    func testLocalAndLogicalDayRolloversRecompute() {
        var memo = WidgetAnchorMemo()
        var computeCalls = 0
        let compute: ([DailyMetric], String, String) -> DailyMetric? = { _, _, _ in
            computeCalls += 1
            return self.row(Double(computeCalls))
        }

        _ = memo.resolve(days: [], seq: 1,
                         logicalKey: "2026-08-06", localKey: "2026-08-06", compute: compute)
        _ = memo.resolve(days: [], seq: 1,
                         logicalKey: "2026-08-06", localKey: "2026-08-07", compute: compute)
        _ = memo.resolve(days: [], seq: 1,
                         logicalKey: "2026-08-07", localKey: "2026-08-07", compute: compute)

        XCTAssertEqual(computeCalls, 3)
    }
}
