import Foundation

// StressOnsetDetector.swift - the L3 closed-loop JITAI ("just-in-time adaptive intervention") detector.
// Generalises the math currently inline in `AppModel.evaluateStress()` into an EDGE-triggered,
// motion-gated, REPLAY-SAFE detector that decides — at the moment it matters — whether to offer a 60-s
// guided breathing cue. PURE + DB-free, carrying its OWN de-dup state exactly like
// `SedentaryDetector.evaluate`: the caller persists `nextState` and feeds it back, so a replayed window
// can't re-fire. No I/O / BLE here.
//
// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3).
//
// WHAT IT GENERALISES (from AppModel.evaluateStress): a rolling clean-R-R buffer → a SLOW RMSSD baseline
// (an exact warm-up mean, then the shipped 0.98/0.02 EMA) + a resting-HR band gate (55–100 bpm) + a
// `rmssd < baseline × 0.6` drop +
// a once-per-15-min limiter + a single confirming buzz. What this engine ADDS, per spec:
//   1. A FAST short-window RMSSD (the latest beats) vs the slow baseline - "fast dropped below baseline".
//   2. EDGE trigger: fire ONCE on the fresh crossing (was-above → now-below), not every tick.
//   3. The EXERCISE GATE (the credibility line): suppress when HR is out of the resting band AND/OR recent
//      motion says "metabolic, not stress" (gravity activity above a threshold, the same `recentGravity`
//      source `SedentaryDetector` reads). A brisk walk's HRV dip must NOT fire a "you're stressed" cue.
//   4. Rate-limit + quiet hours + master toggle, and never while a manual Breathe/L1/L2 session runs.
//
// HONEST / NON-CLINICAL: "stress" is an autonomic PROXY (HRV-down vs the user's OWN baseline), never a
// diagnosis. The card the caller shows says "short-window HRV moved below its recent baseline" - never
// "you are stressed", and never claims stillness unless motion was actually observed.
// On fire: a single confirming buzz + a passive in-app card; NEVER a push notification unless the user
// opted into notifications (matches DaytimeStress's "passive suggestion, never a notification" stance).
//
// All `ts`/`nowSec` are wall-clock unix SECONDS. Outputs are APPROXIMATE, not medical advice.

public enum StressOnsetDetector {

    // MARK: - Tunables (evaluateStress parity + the new fast/gate pieces)

    /// Slow-baseline EMA weight on the prior value (the shipped 0.98). New RMSSD gets `1 − this`.
    public static let baselineEmaAlpha: Double = 0.98
    /// Fast RMSSD must drop below `baseline × this` to count as a dip (the shipped 0.6 threshold).
    public static let dropRatio: Double = 0.6
    /// Resting HR band — outside it the dip is treated as metabolic (workout), not stress (the shipped
    /// 55–100 bpm gate).
    public static let restingHRLow: Double = 55.0
    public static let restingHRHigh: Double = 100.0
    /// Beats in the FAST short window (the latest clean beats) used for the momentary RMSSD.
    public static let fastWindowBeats: Int = 60
    /// Minimum clean beats before either RMSSD is trusted (mirrors `HRVAnalyzer.minBeats`).
    public static let minBeats: Int = HRVAnalyzer.minBeats
    /// Rate limit — at most one fire per this many seconds (the shipped 900 s = 15 min).
    public static let minSecondsBetweenFires: Int = 900
    /// Recent smoothed wrist-motion (g) at/above this means "moving" → exercise gate suppresses the fire
    /// (reuses the `SedentaryDetector` move threshold so the two gates agree on what "moving" is).
    public static let motionGateG: Double = SedentaryDetector.defaultMoveThresholdG
    /// A baseline must contain this many DISTINCT trusted short windows before a later window may fire.
    /// Four is deliberately conservative: one clean R-R window seeds a number, not a personal baseline.
    public static let minimumTrustedBaselineWindows: Int = 4
    /// Sliding R-R callbacks overlap heavily. Count baseline observations at most once per minute so four
    /// windows represent separate evidence rather than four adjacent packets from the same brief moment.
    public static let minimumTrustedWindowSpacingSeconds: Int = 60

    // MARK: - Config

    /// The L3 master/sub toggles + quiet-hours window, passed in as plain values so the engine stays pure.
    /// All default OFF / safe — manual-first ethos (the feature is opt-in per layer).
    public struct Config: Equatable, Sendable {
        /// Master "stress check-ins (haptic)" toggle (default OFF). Inert when off.
        public var enabled: Bool
        /// Auto-nudge sub-toggle (default OFF) — when off the detector still reports state but never fires.
        public var autoNudge: Bool
        /// Suppress fires during quiet hours.
        public var quietHoursEnabled: Bool
        /// Quiet-hours window, local minute-of-day [0,1440) (defaults 22:00 → 07:00).
        public var quietStartMinutes: Int
        public var quietEndMinutes: Int
        /// Buzz strength (loops) for the confirming buzz — one light pulse, like evaluateStress.
        public var buzzLoops: Int

        public init(enabled: Bool = false,
                    autoNudge: Bool = false,
                    quietHoursEnabled: Bool = false,
                    quietStartMinutes: Int = SedentaryDetector.defaultQuietStartMin,
                    quietEndMinutes: Int = SedentaryDetector.defaultQuietEndMin,
                    buzzLoops: Int = 1) {
            self.enabled = enabled
            self.autoNudge = autoNudge
            self.quietHoursEnabled = quietHoursEnabled
            self.quietStartMinutes = quietStartMinutes
            self.quietEndMinutes = quietEndMinutes
            self.buzzLoops = buzzLoops
        }
    }

    // MARK: - State (de-dup / EMA carry — persisted verbatim, replay-safe)

    /// The persisted state the detector carries between evaluations (restart-safe). The caller stores this
    /// verbatim and feeds the prior value back in, exactly like `SedentaryState`. A fresh user starts from
    /// `.initial`. Carries the slow EMA baseline (so it survives relaunch), the edge state (was the fast
    /// RMSSD below the threshold on the previous tick?), the baseline warm-up, and the rate-limit clock.
    public struct State: Equatable, Sendable {
        /// Slow RMSSD baseline, ms: exact mean during warm-up, then EMA. 0 = uninitialised.
        public var baselineRMSSD: Double
        /// Whether the fast RMSSD was BELOW the drop threshold on the previous evaluation — drives the
        /// EDGE (we fire only on a fresh above→below crossing, not every tick it stays below).
        public var wasBelow: Bool
        /// Unix-seconds of the last fire (0 = never) — the rate limiter.
        public var lastFireAt: Int
        /// Number of distinct, trusted fast windows incorporated into the baseline, capped at the warm-up
        /// requirement. Defaults to zero so a state saved by an older build warms up safely after upgrade.
        public var trustedWindowCount: Int
        /// Deterministic identity of the last trusted fast window. Replaying the same R-R tail must not
        /// advance either the EMA or the warm-up count. Zero means no window has been accepted yet.
        public var lastTrustedWindowFingerprint: UInt64
        /// Unix-seconds of the last window admitted to the baseline. Zero is safe for old persisted state;
        /// `trustedWindowCount` distinguishes an actual epoch-zero test fixture from an uninitialised state.
        public var lastTrustedWindowAt: Int

        public init(baselineRMSSD: Double = 0, wasBelow: Bool = false, lastFireAt: Int = 0,
                    trustedWindowCount: Int = 0, lastTrustedWindowFingerprint: UInt64 = 0,
                    lastTrustedWindowAt: Int = 0) {
            self.baselineRMSSD = baselineRMSSD
            self.wasBelow = wasBelow
            self.lastFireAt = lastFireAt
            self.trustedWindowCount = max(0, min(trustedWindowCount, minimumTrustedBaselineWindows))
            self.lastTrustedWindowFingerprint = lastTrustedWindowFingerprint
            self.lastTrustedWindowAt = lastTrustedWindowAt
        }

        /// Cold-start state (no baseline, not below, never fired).
        public static let initial = State()
    }

    // MARK: - Decision

    /// Why the detector did / didn't nudge — drives logs and the honest card copy.
    public enum Reason: String, Equatable, Sendable {
        /// A fresh non-metabolic HRV dip — offer a minute to breathe.
        case onset
        /// Disabled / auto-nudge off.
        case disabled
        /// Too few clean beats to judge honestly.
        case insufficientData
        /// A valid window is still building the minimum distinct-window personal baseline.
        case warmingUp
        /// The same trusted R-R tail was evaluated again; it cannot advance baseline or edge state.
        case duplicateWindow
        /// Fast RMSSD is at/above the threshold — no dip.
        case noDip
        /// The dip isn't a fresh edge (already below last tick).
        case notAnEdge
        /// No contemporaneous motion observation exists, so stillness cannot be established.
        case motionUnavailable
        /// Suppressed by the exercise gate (HR out of band and/or recent motion = metabolic, not stress).
        case exerciseGated
        /// Inside the rate-limit window or quiet hours, or a manual session is running.
        case suppressed
    }

    /// The decision returned each evaluation: whether to nudge, why, and the next state to persist. Mirrors
    /// `SedentaryDecision`: the caller acts on `shouldNudge` and stores `nextState` (always advanced) so a
    /// replayed window can't re-fire.
    public struct Decision: Equatable, Sendable {
        /// True if the app should offer the breathing cue now (single confirming buzz + passive card).
        public let shouldNudge: Bool
        /// Why (whether or not it nudged).
        public let reason: Reason
        /// Buzz loops to play when `shouldNudge` (the confirming buzz).
        public let buzzLoops: Int
        /// The fast short-window RMSSD this tick (ms), or nil when insufficient — for logs / the card.
        public let fastRMSSD: Double?
        /// The slow baseline RMSSD this tick (ms), or nil when uninitialised.
        public let baselineRMSSD: Double?
        /// The state to persist for the next evaluation (always carries the advanced EMA / edge / clock).
        public let nextState: State

        public init(shouldNudge: Bool, reason: Reason, buzzLoops: Int,
                    fastRMSSD: Double?, baselineRMSSD: Double?, nextState: State) {
            self.shouldNudge = shouldNudge; self.reason = reason; self.buzzLoops = buzzLoops
            self.fastRMSSD = fastRMSSD; self.baselineRMSSD = baselineRMSSD; self.nextState = nextState
        }
    }

    // MARK: - The detector

    /// Evaluate the live window and decide whether to fire a JITAI nudge.
    ///
    /// - `rrBuffer`: the rolling clean-able R-R buffer (rrMs, newest LAST). The fast RMSSD is taken over
    ///   the latest `fastWindowBeats` clean beats; the slow baseline EMA absorbs each trusted fast value.
    /// - `currentHR`: latest smoothed live HR (bpm), or nil if unknown (then the HR half of the gate can't
    ///   pass and we treat HR as out-of-band — conservative).
    /// - `recentMotionG`: recent smoothed wrist-motion (g) from `collector.recentGravity`, or nil if no
    ///   recent gravity. Missing motion cannot establish stillness, so it suppresses auto-nudges.
    /// - `sessionActive`: true if a manual Breathe/L1/L2 session is already running (never nudge over it).
    /// - `state`: the prior persisted state; `nowSec` / `tzOffsetSec` passed IN (never read a clock).
    ///
    /// The EXERCISE GATE suppresses when EITHER signal says metabolic: HR outside [55,100], OR recent
    /// motion at/above `motionGateG`. Missing HR is treated as out-of-band (can't confirm resting), and
    /// missing motion also suppresses: an in-band HR cannot truthfully establish that the wearer is still.
    public static func evaluate(rrBuffer: [Int],
                                currentHR: Double?,
                                recentMotionG: Double?,
                                sessionActive: Bool,
                                state: State,
                                config: Config,
                                nowSec: Int,
                                tzOffsetSec: Int) -> Decision {

        // 1) Master gates: off / auto-nudge off → never nudge, state untouched.
        if !config.enabled || !config.autoNudge {
            return Decision(shouldNudge: false, reason: .disabled, buzzLoops: config.buzzLoops,
                            fastRMSSD: nil, baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }
        // A user-started workout/coaching/breathing session is not baseline-learning time either. Keep the
        // state untouched so session physiology cannot contaminate the resting comparison after it ends.
        if sessionActive {
            return Decision(shouldNudge: false, reason: .suppressed, buzzLoops: config.buzzLoops,
                            fastRMSSD: nil, baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 2) Fast RMSSD over the latest clean beats. Clean first (range + Malik), then take the tail.
        let cleanAll = HRVAnalyzer.cleanRR(rrBuffer.map { Double($0) })
        let fastWindow = cleanAll.count > fastWindowBeats
            ? Array(cleanAll.suffix(fastWindowBeats))
            : cleanAll
        guard fastWindow.count >= minBeats, let fast = HRVAnalyzer.rmssdRaw(fastWindow), fast > 0 else {
            // Not enough signal — report, don't guess. Edge state is preserved (no crossing observed).
            return Decision(shouldNudge: false, reason: .insufficientData, buzzLoops: config.buzzLoops,
                            fastRMSSD: nil, baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 3) Establish the credibility gate BEFORE learning the personal baseline. A window can only
        // become a trusted resting reference when both HR and motion positively support that context.
        // Missing motion is not evidence of stillness, and exercise/ordinary movement must not train
        // the baseline that later powers an interruptive stress suggestion.
        let hrInBand: Bool = {
            guard let hr = currentHR else { return false }
            return hr >= restingHRLow && hr <= restingHRHigh
        }()
        guard let recentMotionG else {
            return Decision(shouldNudge: false, reason: .motionUnavailable,
                            buzzLoops: config.buzzLoops, fastRMSSD: fast,
                            baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }
        guard hrInBand, recentMotionG < motionGateG else {
            return Decision(shouldNudge: false, reason: .exerciseGated,
                            buzzLoops: config.buzzLoops, fastRMSSD: fast,
                            baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 4) Only a DISTINCT trusted R-R tail may advance the baseline. `evaluate` can be reached from
        // both HR and R-R publishers, so the exact same cached window may otherwise be counted repeatedly.
        let fingerprint = trustedWindowFingerprint(fastWindow)
        let overlapsPriorWindow = state.trustedWindowCount > 0
            && (nowSec - state.lastTrustedWindowAt) < minimumTrustedWindowSpacingSeconds
        if fingerprint == state.lastTrustedWindowFingerprint || overlapsPriorWindow {
            return Decision(shouldNudge: false, reason: .duplicateWindow, buzzLoops: config.buzzLoops,
                            fastRMSSD: fast,
                            baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 5) Build the minimum personal baseline with an exact running mean, then advance it with the slow
        // EMA. Applying alpha=0.98 during a four-window warm-up would leave ~94% of an outlier first window
        // in the baseline, so ordinary later windows could be misclassified as a fresh dip. Older builds
        // persisted an EMA without the evidence count; count==0 deliberately replaces that legacy value.
        var next = state
        next.lastTrustedWindowFingerprint = fingerprint
        next.lastTrustedWindowAt = nowSec
        next.trustedWindowCount = min(minimumTrustedBaselineWindows, state.trustedWindowCount + 1)
        if state.trustedWindowCount < minimumTrustedBaselineWindows {
            let priorCount = Double(state.trustedWindowCount)
            next.baselineRMSSD = (state.baselineRMSSD * priorCount + fast) / (priorCount + 1)
        } else {
            next.baselineRMSSD = state.baselineRMSSD * baselineEmaAlpha
                + fast * (1.0 - baselineEmaAlpha)
        }
        let baseline = next.baselineRMSSD

        // 6) Is the fast RMSSD below the drop threshold? (the dip test)
        let threshold = baseline * dropRatio
        let isBelow = fast < threshold
        // The edge: a FRESH crossing (above on the previous tick → below now). Always record the new
        // below-state so the NEXT tick can edge-detect, regardless of whether we fire.
        let isEdge = isBelow && !state.wasBelow
        next.wasBelow = isBelow

        func decide(_ nudge: Bool, _ reason: Reason) -> Decision {
            Decision(shouldNudge: nudge, reason: reason, buzzLoops: config.buzzLoops,
                     fastRMSSD: fast, baselineRMSSD: baseline, nextState: next)
        }

        // The current window may complete warm-up, but it cannot also be judged against a baseline that
        // partly contains itself. Auto-fire begins only on a later distinct trusted window.
        if state.trustedWindowCount < minimumTrustedBaselineWindows {
            return decide(false, .warmingUp)
        }
        if !isBelow { return decide(false, .noDip) }
        if !isEdge { return decide(false, .notAnEdge) }

        // 7) Remaining suppressors: the rate limit or quiet hours. Session activity was rejected before
        // signal processing so it could not train the resting baseline.
        if state.lastFireAt != 0 && (nowSec - state.lastFireAt) < minSecondsBetweenFires {
            return decide(false, .suppressed)
        }
        if config.quietHoursEnabled {
            let mod = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
            if SedentaryDetector.windowContains(mod, startMin: config.quietStartMinutes,
                                                endMin: config.quietEndMinutes) {
                return decide(false, .suppressed)
            }
        }

        // 8) Fire — a fresh short-window HRV dip with observed low motion. Stamp the rate-limit clock.
        next.lastFireAt = nowSec
        return decide(true, .onset)
    }

    /// Stable across launches (unlike `Hasher`) so the persisted state can reject a replay after relaunch.
    /// The clean window contains finite millisecond values; hashing each exact Double bit pattern preserves
    /// even a one-millisecond tail change without retaining any biometric samples in preferences.
    private static func trustedWindowFingerprint(_ window: [Double]) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for value in window {
            hash ^= value.bitPattern
            hash &*= 1_099_511_628_211
        }
        hash ^= UInt64(window.count)
        return hash == 0 ? 1 : hash
    }
}
