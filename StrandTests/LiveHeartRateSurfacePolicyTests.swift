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
        XCTAssertTrue(LiveHeartRateSurfacePolicy.isLive(
            connected: true, bpm: 30, observedAt: now, now: now
        ))
        XCTAssertTrue(LiveHeartRateSurfacePolicy.isLive(
            connected: true, bpm: 220, observedAt: now, now: now
        ))
        XCTAssertFalse(LiveHeartRateSurfacePolicy.isLive(
            connected: true, bpm: 29, observedAt: now, now: now
        ))
        XCTAssertFalse(LiveHeartRateSurfacePolicy.isLive(
            connected: true, bpm: 221, observedAt: now, now: now
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

    func testPresentationStateDoesNotInventAReading() {
        XCTAssertEqual(
            LiveHeartRatePresentationState.resolve(
                enabled: false,
                connected: true,
                bpm: 72,
                observedAt: now,
                now: now
            ),
            .hidden
        )
        XCTAssertEqual(
            LiveHeartRatePresentationState.resolve(
                enabled: true,
                connected: true,
                bpm: nil,
                observedAt: nil,
                now: now
            ),
            .waiting
        )
        XCTAssertEqual(
            LiveHeartRatePresentationState.resolve(
                enabled: true,
                connected: true,
                bpm: 72,
                observedAt: now.addingTimeInterval(-31),
                now: now
            ),
            .reconnecting
        )
        XCTAssertEqual(
            LiveHeartRatePresentationState.resolve(
                enabled: true,
                connected: true,
                bpm: 72,
                observedAt: now,
                now: now
            ),
            .live(72)
        )
    }
}
