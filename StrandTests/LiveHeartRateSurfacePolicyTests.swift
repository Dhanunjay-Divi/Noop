import XCTest
@testable import Strand

final class LiveHeartRateSurfacePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testFreshPacketRequiresConnectionAndPlausibleBPM() {
        XCTAssertTrue(LiveHeartRateSurfacePolicy.isLive(
            connected: true, bpm: 68, observedAt: now.addingTimeInterval(-2), now: now
        ))
        XCTAssertFalse(LiveHeartRateSurfacePolicy.isLive(
            connected: false, bpm: 68, observedAt: now.addingTimeInterval(-2), now: now
        ))
        XCTAssertFalse(LiveHeartRateSurfacePolicy.isLive(
            connected: true, bpm: 0, observedAt: now.addingTimeInterval(-2), now: now
        ))
        XCTAssertFalse(LiveHeartRateSurfacePolicy.isLive(
            connected: true, bpm: 68, observedAt: nil, now: now
        ))
    }

    func testReconnectCannotReviveStaleOrFuturePacket() {
        XCTAssertFalse(LiveHeartRateSurfacePolicy.isLive(
            connected: true, bpm: 68,
            observedAt: now.addingTimeInterval(-LiveHeartRateSurfacePolicy.maximumSampleAge - 0.001),
            now: now
        ))
        XCTAssertFalse(LiveHeartRateSurfacePolicy.isLive(
            connected: true, bpm: 68, observedAt: now.addingTimeInterval(1), now: now
        ))
    }

    func testExpiryUsesObservationClockRatherThanRepublishClock() {
        let observed = now.addingTimeInterval(-10)
        XCTAssertEqual(LiveHeartRateSurfacePolicy.expiryDelay(observedAt: observed, now: now), 20,
                       accuracy: 0.001)
        XCTAssertEqual(LiveHeartRateSurfacePolicy.expiryDelay(
            observedAt: now.addingTimeInterval(-31), now: now
        ), 0)
    }
}
