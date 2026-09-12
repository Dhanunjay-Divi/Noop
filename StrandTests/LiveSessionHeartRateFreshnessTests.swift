import Combine
import XCTest
@testable import Strand

@MainActor
final class LiveSessionHeartRateFreshnessTests: XCTestCase {

    func testBandReadinessRequiresConnectedBondedEncryptedAndWorn() {
        let live = LiveState()
        live.connected = true
        live.bonded = true
        live.encryptedBond = true
        live.worn = true
        XCTAssertTrue(liveSessionBandReady(live))

        live.encryptedBond = false
        XCTAssertFalse(liveSessionBandReady(live))
        live.encryptedBond = true
        live.worn = false
        XCTAssertFalse(liveSessionBandReady(live))
    }

    func testSilentTransportDoesNotConsumeCachedPreSessionHeartRate() {
        let live = LiveState()
        live.setHeartRate(140)
        var cursor = LiveSessionHeartRateCursor(
            consumedSequence: live.heartRateSampleSequence
        )

        XCTAssertNil(cursor.consume(live.heartRateSample),
                     "A BPM cached before Start is not the session's first sensor event.")
        XCTAssertNil(cursor.consume(live.heartRateSample),
                     "Clock ticks over the same cached value must keep feeding nil to the engine.")
    }

    func testStoppedTransportCannotReplayTheLastPacket() {
        let live = LiveState()
        var cursor = LiveSessionHeartRateCursor(
            consumedSequence: live.heartRateSampleSequence
        )

        live.setHeartRate(140)
        XCTAssertEqual(cursor.consume(live.heartRateSample), 140)
        XCTAssertNil(cursor.consume(live.heartRateSample))
        XCTAssertNil(cursor.consume(live.heartRateSample))
    }

    func testBackgroundResumeNeedsANewPacketSequenceEvenAtSameBpm() {
        let live = LiveState()
        var cursor = LiveSessionHeartRateCursor(
            consumedSequence: live.heartRateSampleSequence
        )

        live.setHeartRate(140)
        XCTAssertEqual(cursor.consume(live.heartRateSample), 140)

        // Background transport is disarmed: the cached state remains, but no packet identity advances.
        XCTAssertNil(cursor.consume(live.heartRateSample))

        // Foreground transport resumes and reports the same numeric BPM. It is still a genuine new sample.
        live.setHeartRate(140, publishEvenIfUnchanged: false)
        XCTAssertEqual(cursor.consume(live.heartRateSample), 140)
        XCTAssertNil(cursor.consume(live.heartRateSample))
    }

    func testEveryAcceptedPacketEmitsFreshnessWithoutRepublishingUnchangedUiBpm() {
        let live = LiveState()
        var bpmPublications: [Int?] = []
        var packets: [LiveState.HeartRateSample] = []
        let bpmSink = live.$heartRate.dropFirst().sink { bpmPublications.append($0) }
        let packetSink = live.heartRateSamplePublisher.sink { packets.append($0) }

        let firstAt = Date(timeIntervalSince1970: 100)
        let secondAt = Date(timeIntervalSince1970: 101)
        live.setHeartRate(80, receivedAt: firstAt, publishEvenIfUnchanged: false)
        live.setHeartRate(80, receivedAt: secondAt, publishEvenIfUnchanged: false)

        XCTAssertEqual(bpmPublications, [80], "WHOOP raw-frame UI updates remain change-only.")
        XCTAssertEqual(packets, [
            LiveState.HeartRateSample(bpm: 80, sequence: 1, receivedAt: firstAt),
            LiveState.HeartRateSample(bpm: 80, sequence: 2, receivedAt: secondAt)
        ], "Both genuine packets retain identity and transport receipt time.")
        XCTAssertEqual(live.heartRateSampleSequence, 2)
        withExtendedLifetime((bpmSink, packetSink)) {}
    }

    func testClearingBiometricsDoesNotInventAPacket() {
        let live = LiveState()
        live.setHeartRate(90)
        let sequence = live.heartRateSampleSequence

        live.clearBiometrics()

        XCTAssertNil(live.heartRate)
        XCTAssertEqual(live.heartRateSampleSequence, sequence)
        XCTAssertNil(live.heartRateSample)
    }
}
