import XCTest
@testable import OuraProtocol

final class OuraIbiHrTests: XCTestCase {
    private func ibi(_ ringTimestamp: UInt32, _ milliseconds: Int) -> OuraIBI {
        OuraIBI(ringTimestamp: ringTimestamp, ibiMs: milliseconds)
    }

    func testPerRecordMedianHRGroupsAndOrdersRecords() {
        let result = OuraIbiHr.perRecordMedianHR([
            ibi(200, 900),
            ibi(100, 1_020),
            ibi(100, 980),
            ibi(200, 910),
            ibi(100, 1_000),
        ])

        XCTAssertEqual(result, [
            OuraHR(ringTimestamp: 100, bpm: 60, ibiMs: 1_000),
            OuraHR(ringTimestamp: 200, bpm: 66, ibiMs: 905),
        ])
    }

    func testInvalidIntervalsAreOmittedRatherThanClamped() {
        XCTAssertEqual(
            OuraIbiHr.perRecordMedianHR([ibi(1, 100), ibi(1, 1_000), ibi(1, 3_000)]),
            [OuraHR(ringTimestamp: 1, bpm: 60, ibiMs: 1_000)]
        )
        XCTAssertTrue(OuraIbiHr.perRecordMedianHR([ibi(2, 100), ibi(2, 5_000)]).isEmpty)
    }

    func testQueuedHistoryEventsMaterializeAfterAnchorWithoutDuplicatingExistingHR() {
        let queued: [OuraEvent] = [
            .ibi(ibi(300, 1_000)),
            .ibi(ibi(300, 1_020)),
        ]
        let materialized = OuraIbiHr.appendingDerivedHR(toHistoryEvents: queued)

        XCTAssertEqual(materialized.compactMap { event -> OuraHR? in
            if case .hr(let hr) = event { return hr }
            return nil
        }, [OuraHR(ringTimestamp: 300, bpm: 59, ibiMs: 1_010)])

        let existing = OuraHR(ringTimestamp: 300, bpm: 61, ibiMs: 984)
        let withExisting = OuraIbiHr.appendingDerivedHR(toHistoryEvents: queued + [.hr(existing)])
        XCTAssertEqual(withExisting.compactMap { event -> OuraHR? in
            if case .hr(let hr) = event { return hr }
            return nil
        }, [existing])
    }
}
