import XCTest
@testable import StrandAnalytics

final class WorkoutCautionPolicyTests: XCTestCase {
    private func policy() -> WorkoutCautionPolicy {
        WorkoutCautionPolicy(config: .init(hrMax: 190), startTs: 0)
    }

    func testOneSpikeIsRejectedAndCannotCue() {
        var policy = policy()
        _ = policy.update(now: 0, bpm: 120)
        let spike = policy.update(now: 1, bpm: 190)

        XCTAssertFalse(spike.sampleArrived)
        XCTAssertNil(spike.cue)
        XCTAssertEqual(spike.smoothedBpm, 120)
    }

    func testRepeatedJumpCorroboratesButStillNeedsSustainedDwell() {
        var policy = policy()
        _ = policy.update(now: 0, bpm: 120)
        XCTAssertFalse(policy.update(now: 1, bpm: 186).sampleArrived)
        XCTAssertTrue(policy.update(now: 2, bpm: 185).sampleArrived)

        let outputs = (3...200).map { policy.update(now: $0, bpm: 185) }
        XCTAssertEqual(outputs.filter { $0.cue == .pauseAndAssess }.count, 1)
        XCTAssertFalse(outputs.contains { $0.cue == .easeOff })
    }

    func testSustainedHighExertionEasesOffOnce() {
        var policy = policy()
        let outputs = (0...80).map { policy.update(now: $0, bpm: 175) }

        XCTAssertEqual(outputs.filter { $0.cue == .easeOff }.count, 1)
        XCTAssertFalse(outputs.contains { $0.cue == .pauseAndAssess })
    }

    func testReadingsAboveEstimatedMaxRemainEligibleButImpossibleValuesDoNot() {
        var policy = WorkoutCautionPolicy(config: .init(hrMax: 170), startTs: 0)
        let aboveReference = policy.update(now: 0, bpm: 180)
        let impossible = policy.update(now: 1, bpm: 241)

        XCTAssertTrue(aboveReference.sampleArrived)
        XCTAssertFalse(impossible.sampleArrived)
    }

    func testGapResetsDwellAndRecoveryFiresOnlyAfterARealCue() {
        var policy = policy()
        _ = (0...30).map { policy.update(now: $0, bpm: 175) }
        _ = policy.update(now: 50, bpm: 175)
        let beforeDwell = (51..<95).map { policy.update(now: $0, bpm: 175) }
        XCTAssertFalse(beforeDwell.contains { $0.cue != nil })

        let cue = policy.update(now: 95, bpm: 175)
        XCTAssertEqual(cue.cue, .easeOff)

        let recovery = (96...115).map { policy.update(now: $0, bpm: 150) }
        XCTAssertEqual(recovery.filter { $0.cue == .recovered }.count, 1)
    }
}
