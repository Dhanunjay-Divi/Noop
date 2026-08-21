import XCTest
@testable import Strand

final class LiveActivitySelectionTests: XCTestCase {
    func testEmptyInputHasNoCanonicalOrDuplicates() {
        XCTAssertEqual(LiveActivitySelection.select([]),
                       LiveActivitySelection(canonicalID: nil, duplicateIDs: []))
    }

    func testNewestFreshnessDateWinsAndEveryOtherIDIsDuplicate() {
        let old = Date(timeIntervalSince1970: 100)
        let newest = Date(timeIntervalSince1970: 300)
        let middle = Date(timeIntervalSince1970: 200)

        let selection = LiveActivitySelection.select([
            .init(id: "old", freshnessDate: old),
            .init(id: "newest", freshnessDate: newest),
            .init(id: "middle", freshnessDate: middle)
        ])

        XCTAssertEqual(selection.canonicalID, "newest")
        XCTAssertEqual(selection.duplicateIDs, ["old", "middle"])
    }

    func testMissingFreshnessIsOlderThanAnyDatedCandidate() {
        let selection = LiveActivitySelection.select([
            .init(id: "legacy", freshnessDate: nil),
            .init(id: "dated", freshnessDate: Date(timeIntervalSince1970: 1))
        ])

        XCTAssertEqual(selection.canonicalID, "dated")
        XCTAssertEqual(selection.duplicateIDs, ["legacy"])
    }

    func testTieBreakIsStableRegardlessOfInputOrder() {
        let date = Date(timeIntervalSince1970: 100)
        let forward = LiveActivitySelection.select([
            .init(id: "a", freshnessDate: date),
            .init(id: "b", freshnessDate: date)
        ])
        let reversed = LiveActivitySelection.select([
            .init(id: "b", freshnessDate: date),
            .init(id: "a", freshnessDate: date)
        ])

        XCTAssertEqual(forward.canonicalID, "b")
        XCTAssertEqual(reversed.canonicalID, "b")
        XCTAssertEqual(Set(forward.duplicateIDs), ["a"])
        XCTAssertEqual(Set(reversed.duplicateIDs), ["a"])
    }
}
