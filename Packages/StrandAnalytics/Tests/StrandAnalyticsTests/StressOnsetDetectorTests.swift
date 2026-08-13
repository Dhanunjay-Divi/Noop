import XCTest
@testable import StrandAnalytics

/// Pins the L3 `StressOnsetDetector` — the highest-value test, guarding the credibility line: it fires
/// ONCE on a fresh non-metabolic HRV dip after four distinct baseline windows, fails closed without
/// motion evidence, honours the session/rate-limit gates, and replays safely.
/// GOLDEN/behaviour vectors the Kotlin `StressOnsetDetectorTest` mirrors.
/// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3).
final class StressOnsetDetectorTests: XCTestCase {

    private let on = StressOnsetDetector.Config(enabled: true, autoNudge: true)

    /// A clean R-R buffer of `n` beats all equal to `rrMs` (RMSSD 0 if constant) — for the seed step.
    private func flat(_ rrMs: Int, _ n: Int) -> [Int] { Array(repeating: rrMs, count: n) }

    /// A clean R-R buffer of `n` beats alternating ±`jitterMs` around `rrMs`, giving a controllable RMSSD
    /// (≈ 2*jitter). Larger jitter → higher RMSSD → higher HRV.
    private func jittered(_ rrMs: Int, jitter: Int, _ n: Int) -> [Int] {
        (0..<n).map { rrMs + ($0 % 2 == 0 ? jitter : -jitter) }
    }

    /// Establish the minimum trusted baseline with four physiologically-equivalent but distinct windows.
    /// Changing the centre by 1 ms preserves the high RMSSD while giving each tail a real new identity.
    private func warmedBaseline(startSec: Int = 10_000) -> StressOnsetDetector.Decision {
        var state = StressOnsetDetector.State.initial
        var decision: StressOnsetDetector.Decision!
        for index in 0..<StressOnsetDetector.minimumTrustedBaselineWindows {
            decision = StressOnsetDetector.evaluate(
                rrBuffer: jittered(900 + index, jitter: 60, 60),
                currentHR: 70, recentMotionG: 0.0, sessionActive: false,
                state: state, config: on, nowSec: startSec + index * 60, tzOffsetSec: 0)
            XCTAssertFalse(decision.shouldNudge)
            XCTAssertEqual(decision.reason, .warmingUp)
            XCTAssertEqual(decision.nextState.trustedWindowCount, index + 1)
            state = decision.nextState
        }
        return decision
    }

    // Establish a HEALTHY baseline, then a deep dip → fires exactly once (the edge), with resting HR + still.
    func test_fires_once_on_fresh_dip_then_not_again() {
        // 1) Warm a high-HRV baseline (jitter 60 → RMSSD ~120) across four distinct windows.
        var d = warmedBaseline()
        XCTAssertNotNil(d.baselineRMSSD)

        // 2) A deep HRV dip (jitter 5 → RMSSD ~10, well under baseline*0.6) while resting + still → FIRE.
        let lowHRV = jittered(910, jitter: 5, 60)
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 10_240, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldNudge)
        XCTAssertEqual(d.reason, .onset)

        // 3) A distinct but still-dipped window is not a fresh edge → no re-fire.
        d = StressOnsetDetector.evaluate(rrBuffer: jittered(911, jitter: 5, 60), currentHR: 70,
            recentMotionG: 0.0, sessionActive: false, state: d.nextState, config: on,
            nowSec: 10_300, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .notAnEdge)
    }

    func test_requires_four_distinct_trusted_windows_before_auto_fire() {
        XCTAssertGreaterThanOrEqual(StressOnsetDetector.minimumTrustedBaselineWindows, 4)
        var d = StressOnsetDetector.evaluate(
            rrBuffer: jittered(900, jitter: 60, 60), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 0, tzOffsetSec: 0)
        XCTAssertEqual(d.reason, .warmingUp)
        XCTAssertEqual(d.nextState.trustedWindowCount, 1)

        let firstBaseline = d.nextState.baselineRMSSD
        d = StressOnsetDetector.evaluate(
            rrBuffer: jittered(900, jitter: 60, 60), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 60, tzOffsetSec: 0)
        XCTAssertEqual(d.reason, .duplicateWindow)
        XCTAssertEqual(d.nextState.trustedWindowCount, 1)
        XCTAssertEqual(d.nextState.baselineRMSSD, firstBaseline)

        for index in 1..<StressOnsetDetector.minimumTrustedBaselineWindows {
            d = StressOnsetDetector.evaluate(
                rrBuffer: jittered(900 + index, jitter: 60, 60), currentHR: 70,
                recentMotionG: 0.0, sessionActive: false, state: d.nextState, config: on,
                nowSec: 60 + index * 60, tzOffsetSec: 0)
            XCTAssertFalse(d.shouldNudge)
            XCTAssertEqual(d.reason, .warmingUp)
        }
        XCTAssertEqual(d.nextState.trustedWindowCount,
                       StressOnsetDetector.minimumTrustedBaselineWindows)

        d = StressOnsetDetector.evaluate(
            rrBuffer: jittered(910, jitter: 5, 60), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 360, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldNudge)
    }

    func test_legacy_state_defaults_to_safe_warmup() {
        let legacyShape = StressOnsetDetector.State(
            baselineRMSSD: 72, wasBelow: false, lastFireAt: 0)
        XCTAssertEqual(legacyShape.trustedWindowCount, 0)
        XCTAssertEqual(legacyShape.lastTrustedWindowFingerprint, 0)
        XCTAssertEqual(legacyShape.lastTrustedWindowAt, 0)

        let d = StressOnsetDetector.evaluate(
            rrBuffer: jittered(900, jitter: 5, 60), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: legacyShape, config: on, nowSec: 60, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .warmingUp)
        XCTAssertEqual(d.nextState.baselineRMSSD, d.fastRMSSD,
                       "The first newly trusted window must replace, not blend with, a legacy ungated EMA")
    }

    func test_outlier_first_warmup_uses_mean_then_normal_window_cannot_fire() throws {
        // RMSSD windows are approximately [200, 60, 60, 60] ms. A 0.98 EMA from the first window would
        // finish warm-up near 192 ms; the exact mean is 95 ms and cannot turn another normal 60 ms window
        // into an autonomic-drop alert. Distinct centres give each otherwise-equivalent tail a new identity.
        let warmupWindows = [
            jittered(1_100, jitter: 100, 60),
            jittered(901, jitter: 30, 60),
            jittered(902, jitter: 30, 60),
            jittered(903, jitter: 30, 60),
        ]
        var state = StressOnsetDetector.State.initial
        var observedRMSSD: [Double] = []

        for (index, window) in warmupWindows.enumerated() {
            let decision = StressOnsetDetector.evaluate(
                rrBuffer: window, currentHR: 70, recentMotionG: 0.0,
                sessionActive: false, state: state, config: on,
                nowSec: index * 60, tzOffsetSec: 0)
            let fast = try XCTUnwrap(decision.fastRMSSD)
            observedRMSSD.append(fast)
            let expectedMean = observedRMSSD.reduce(0, +) / Double(observedRMSSD.count)

            XCTAssertEqual(decision.reason, .warmingUp)
            XCTAssertEqual(decision.nextState.baselineRMSSD, expectedMean, accuracy: 0.000_001)
            state = decision.nextState
        }

        let baselineAfterWarmup = state.baselineRMSSD
        let nextNormal = StressOnsetDetector.evaluate(
            rrBuffer: jittered(904, jitter: 30, 60), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: state, config: on, nowSec: 240, tzOffsetSec: 0)
        let nextFast = try XCTUnwrap(nextNormal.fastRMSSD)
        let expectedEMA = baselineAfterWarmup * StressOnsetDetector.baselineEmaAlpha
            + nextFast * (1 - StressOnsetDetector.baselineEmaAlpha)

        XCTAssertFalse(nextNormal.shouldNudge)
        XCTAssertEqual(nextNormal.reason, .noDip)
        XCTAssertEqual(nextNormal.nextState.baselineRMSSD, expectedEMA, accuracy: 0.000_001,
                       "Only post-warm-up windows should use the slow EMA")
        XCTAssertGreaterThanOrEqual(nextFast,
                                    nextNormal.nextState.baselineRMSSD * StressOnsetDetector.dropRatio)
    }

    func test_rapid_overlapping_windows_do_not_counterfeit_warmup() {
        var d = StressOnsetDetector.evaluate(
            rrBuffer: jittered(900, jitter: 60, 60), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 10_000, tzOffsetSec: 0)
        XCTAssertEqual(d.nextState.trustedWindowCount, 1)

        d = StressOnsetDetector.evaluate(
            rrBuffer: jittered(901, jitter: 60, 60), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 10_010, tzOffsetSec: 0)
        XCTAssertEqual(d.reason, .duplicateWindow)
        XCTAssertEqual(d.nextState.trustedWindowCount, 1)

        d = StressOnsetDetector.evaluate(
            rrBuffer: jittered(902, jitter: 60, 60), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 10_060, tzOffsetSec: 0)
        XCTAssertEqual(d.reason, .warmingUp)
        XCTAssertEqual(d.nextState.trustedWindowCount, 2)
    }

    // The EXERCISE GATE: the SAME deep dip must NOT fire when HR is out of the resting band (a workout).
    func test_exercise_gate_suppresses_when_hr_out_of_band() {
        var d = warmedBaseline(startSec: 0)
        let lowHRV = jittered(910, jitter: 5, 60)
        // HR 140 (brisk exercise) → out of [55,100] → gated, never a "you're stressed" cue.
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 140, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 240, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .exerciseGated)
    }

    // The EXERCISE GATE: motion (recent gravity above the move threshold) also suppresses, even in-band HR.
    func test_exercise_gate_suppresses_when_moving() {
        var d = warmedBaseline(startSec: 0)
        let lowHRV = jittered(910, jitter: 5, 60)
        // Resting HR but the wrist is moving (0.5 g » 0.15 gate) → metabolic dip → gated.
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.5,
            sessionActive: false, state: d.nextState, config: on, nowSec: 240, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .exerciseGated)
    }

    // Missing motion cannot support a "still" inference, even with in-band HR and a real dip.
    func test_missing_motion_suppresses_auto_nudge() {
        var d = warmedBaseline(startSec: 0)
        d = StressOnsetDetector.evaluate(
            rrBuffer: jittered(910, jitter: 5, 60), currentHR: 70, recentMotionG: nil,
            sessionActive: false, state: d.nextState, config: on, nowSec: 240, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .motionUnavailable)
    }

    func test_missing_motion_cannot_train_baseline() {
        let state = StressOnsetDetector.State.initial
        let d = StressOnsetDetector.evaluate(
            rrBuffer: jittered(900, jitter: 60, 60), currentHR: 70, recentMotionG: nil,
            sessionActive: false, state: state, config: on, nowSec: 60, tzOffsetSec: 0)
        XCTAssertEqual(d.reason, .motionUnavailable)
        XCTAssertEqual(d.nextState, state)
    }

    func test_movement_or_exercise_cannot_train_baseline() {
        let state = StressOnsetDetector.State.initial
        let moving = StressOnsetDetector.evaluate(
            rrBuffer: jittered(900, jitter: 60, 60), currentHR: 70, recentMotionG: 0.5,
            sessionActive: false, state: state, config: on, nowSec: 60, tzOffsetSec: 0)
        let exercising = StressOnsetDetector.evaluate(
            rrBuffer: jittered(901, jitter: 60, 60), currentHR: 140, recentMotionG: 0.0,
            sessionActive: false, state: state, config: on, nowSec: 120, tzOffsetSec: 0)
        XCTAssertEqual(moving.reason, .exerciseGated)
        XCTAssertEqual(exercising.reason, .exerciseGated)
        XCTAssertEqual(moving.nextState, state)
        XCTAssertEqual(exercising.nextState, state)
    }

    // Replay-safety: re-feeding the SAME firing window with the post-fire state can't re-fire.
    func test_replay_safe_cannot_refire() {
        let lowHRV = jittered(910, jitter: 5, 60)
        var d = warmedBaseline(startSec: 0)
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 240, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldNudge)
        let firedState = d.nextState
        // Replay the exact same low window + state → wasBelow is true, so no fresh edge → no fire.
        let replay = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: firedState, config: on, nowSec: 241, tzOffsetSec: 0)
        XCTAssertFalse(replay.shouldNudge)
        XCTAssertEqual(replay.reason, .duplicateWindow)
    }

    // Rate limit: even a fresh edge within 15 min of the last fire is suppressed.
    func test_rate_limit_blocks_second_fire_within_window() {
        let highHRV = jittered(920, jitter: 60, 60)
        let lowHRV = jittered(910, jitter: 5, 60)
        // Fire once.
        var d = warmedBaseline(startSec: 0)
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 240, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldNudge)
        // Recover above (fresh edge reset), then dip AGAIN only 5 min after the fire → rate-limited.
        d = StressOnsetDetector.evaluate(rrBuffer: highHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 300, tzOffsetSec: 0)
        d = StressOnsetDetector.evaluate(rrBuffer: jittered(911, jitter: 5, 60), currentHR: 70,
            recentMotionG: 0.0, sessionActive: false, state: d.nextState, config: on,
            nowSec: 540, tzOffsetSec: 0)   // +5 min
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .suppressed)
    }

    // Master toggle off → never fires, state untouched.
    func test_disabled_never_fires() {
        let off = StressOnsetDetector.Config(enabled: false, autoNudge: true)
        let d = StressOnsetDetector.evaluate(rrBuffer: jittered(900, jitter: 5, 60), currentHR: 70,
            recentMotionG: 0.0, sessionActive: false, state: .initial, config: off,
            nowSec: 0, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .disabled)
        XCTAssertEqual(d.nextState, StressOnsetDetector.State.initial)
    }

    // A running manual session suppresses the auto-nudge.
    func test_active_session_suppresses() {
        let lowHRV = jittered(910, jitter: 5, 60)
        var d = warmedBaseline(startSec: 0)
        let stateBeforeSession = d.nextState
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: true, state: d.nextState, config: on, nowSec: 240, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .suppressed)
        XCTAssertEqual(d.nextState, stateBeforeSession,
                       "A workout/coaching/breathing session must not train the resting baseline")
    }

    // Too few clean beats → insufficientData, never invented.
    func test_insufficient_data() {
        let d = StressOnsetDetector.evaluate(rrBuffer: flat(900, 5), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 0, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .insufficientData)
    }
}
