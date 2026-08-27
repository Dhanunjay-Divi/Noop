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
            OuraHR(ringTimestamp: 100, bpm: 60, ibiMs: 1_000, derivation: .medianOfRecordIntervals),
            OuraHR(ringTimestamp: 200, bpm: 66, ibiMs: 905, derivation: .medianOfRecordIntervals),
        ])
    }

    func testInvalidIntervalsAreOmittedRatherThanClamped() {
        XCTAssertEqual(
            OuraIbiHr.perRecordMedianHR([ibi(1, 100), ibi(1, 1_000), ibi(1, 3_000)]),
            [OuraHR(ringTimestamp: 1, bpm: 60, ibiMs: 1_000, derivation: .medianOfRecordIntervals)]
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
        }, [OuraHR(ringTimestamp: 300, bpm: 59, ibiMs: 1_010, derivation: .medianOfRecordIntervals)])

        let existing = OuraHR(ringTimestamp: 300, bpm: 61, ibiMs: 984)
        let withExisting = OuraIbiHr.appendingDerivedHR(toHistoryEvents: queued + [.hr(existing)])
        XCTAssertEqual(withExisting.compactMap { event -> OuraHR? in
            if case .hr(let hr) = event { return hr }
            return nil
        }, [existing])
    }

    /// Derived rows must be distinguishable from ring-reported ones once they are in the HR series.
    ///
    /// Overnight history is where resting HR is drawn from and Recovery weights resting HR at 0.20, so if a
    /// median-of-intervals row were indistinguishable from a live ring push, the personal baseline would
    /// shift when the MIX of sources changed rather than when the wearer did. This mirrors the guarantee
    /// WatchRecovery.HRVProvenance gives for SDNN versus RMSSD.
    func testDerivedRowsDeclareTheirDerivation() {
        let derived = OuraIbiHr.perRecordMedianHR([ibi(400, 1_000), ibi(400, 1_000)])
        XCTAssertEqual(derived.first?.derivation, .medianOfRecordIntervals)

        let live = OuraHR(ringTimestamp: 400, bpm: 60, ibiMs: 1_000)
        XCTAssertEqual(live.derivation, .ringReported,
                       "the default must stay ring-reported so only OuraIbiHr claims the derived case")
        XCTAssertNotEqual(derived.first, live,
                          "same numbers, different provenance: these must not compare equal")
    }

    /// A payload written before `derivation` existed must still decode, rather than failing and silently
    /// dropping a night of heart rate.
    func testLegacyPayloadWithoutDerivationDecodesAsRingReported() throws {
        let json = Data(#"{"ringTimestamp":500,"bpm":58,"ibiMs":1034}"#.utf8)
        let decoded = try JSONDecoder().decode(OuraHR.self, from: json)
        XCTAssertEqual(decoded.derivation, .ringReported)
        XCTAssertEqual(decoded.bpm, 58)
    }
}
