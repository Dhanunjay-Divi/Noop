#if !os(watchOS)
import XCTest
@testable import StrandDesign

final class TrendChartSelectionTests: XCTestCase {
    func testHoverEndClearsOnlyPointerOwnedSelection() {
        XCTAssertTrue(
            TrendChart.clearsSelectionOnHoverEnd(source: .pointer)
        )
        XCTAssertFalse(
            TrendChart.clearsSelectionOnHoverEnd(source: .touchPinned)
        )
        XCTAssertFalse(
            TrendChart.clearsSelectionOnHoverEnd(source: .accessibility)
        )
        XCTAssertFalse(
            TrendChart.clearsSelectionOnHoverEnd(source: .none)
        )
    }
}
#endif
