import XCTest
@testable import WhoopProtocol

final class RRStableOrderingTests: XCTestCase {
    func testTimestampSortPreservesBeatOrderWithinASecond() {
        let beats = [
            RRInterval(ts: 20, rrMs: 910, srcChannel: .greenQuality),
            RRInterval(ts: 10, rrMs: 800, srcChannel: .ibiBare),
            RRInterval(ts: 20, rrMs: 720, srcChannel: .ibiAmplitude),
            RRInterval(ts: 20, rrMs: 850, srcChannel: .greenQuality),
        ]

        let sorted = beats.sortedByTsStable()

        XCTAssertEqual(sorted.map(\.ts), [10, 20, 20, 20])
        XCTAssertEqual(sorted.map(\.rrMs), [800, 910, 720, 850],
                       "equal-second beats must not be reordered by interval value")
    }

    func testSourceChannelCodesAreDurableAndRoundTrip() throws {
        XCTAssertEqual(RRSourceChannel.allCases.map(\.rawValue), [1, 2, 3, 4])
        let original = RRInterval(ts: 123, rrMs: 812, srcChannel: .ibiAmplitude)
        let decoded = try JSONDecoder().decode(
            RRInterval.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }
}
