package com.noop.analytics

/*
 * StressOnsetDetector.kt — the L3 closed-loop JITAI ("just-in-time adaptive intervention") detector.
 * Generalises the math currently inline in AppModel.evaluateStress() into an EDGE-triggered, motion-gated,
 * REPLAY-SAFE detector that decides — at the moment it matters — whether to offer a 60-s guided breathing
 * cue. PURE + DB-free, carrying its OWN de-dup state exactly like [SedentaryDetector.evaluate]: the caller
 * persists [Decision.nextState] and feeds it back, so a replayed window can't re-fire. No I/O / BLE here.
 *
 * Faithful Kotlin mirror of StrandAnalytics/StressOnsetDetector.swift — keep the warmed personal baseline,
 * drop threshold, edge trigger, credibility gate, and rate-limit/quiet-hours suppressors byte-identical to
 * Swift (cross-platform parity is the contract, pinned by matching golden-vector tests).
 * See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3).
 *
 * WHAT IT GENERALISES (from AppModel.evaluateStress): a rolling clean-R-R buffer → a SLOW RMSSD baseline
 * (an exact warm-up mean, then the shipped 0.98/0.02 EMA) + a resting-HR band gate (55–100 bpm) + a
 * `rmssd < baseline × 0.6` drop +
 * a once-per-15-min limiter + a single confirming buzz. What this engine ADDS, per spec:
 *   1. A FAST short-window RMSSD (the latest beats) vs the slow baseline.
 *   2. EDGE trigger: fire ONCE on the fresh crossing (was-above → now-below), not every tick.
 *   3. The EXERCISE GATE (the credibility line): suppress when HR is out of the resting band AND/OR recent
 *      motion says "metabolic, not stress". A brisk walk's HRV dip must NOT fire a "you're stressed" cue.
 *   4. Rate-limit + quiet hours + master toggle, and never while a manual Breathe/L1/L2 session runs.
 *
 * HONEST / NON-CLINICAL: "stress" is an autonomic PROXY (HRV-down vs the user's OWN baseline), never a
 * diagnosis. The card says "short-window HRV moved below its recent baseline" and only mentions stillness
 * after contemporaneous motion evidence was actually observed — never "you are stressed".
 * On fire: a single confirming buzz + a passive in-app card; NEVER a push notification unless the user
 * opted into notifications (matches DaytimeStress's "passive suggestion, never a notification" stance).
 *
 * All `ts`/`nowSec` are wall-clock unix SECONDS. Outputs are APPROXIMATE, not medical advice.
 */
object StressOnsetDetector {

    // ── Tunables (evaluateStress parity + the new fast/gate pieces) ────────────
    /** Slow-baseline EMA weight on the prior value (the shipped 0.98). New RMSSD gets `1 − this`. */
    const val BASELINE_EMA_ALPHA: Double = 0.98

    /** Fast RMSSD must drop below `baseline × this` to count as a dip (the shipped 0.6 threshold). */
    const val DROP_RATIO: Double = 0.6

    /** Resting HR band — outside it the dip is treated as metabolic (workout), not stress (shipped gate). */
    const val RESTING_HR_LOW: Double = 55.0
    const val RESTING_HR_HIGH: Double = 100.0

    /** Beats in the FAST short window (the latest clean beats) used for the momentary RMSSD. */
    const val FAST_WINDOW_BEATS: Int = 60

    /** Minimum clean beats before either RMSSD is trusted (mirrors [HrvAnalyzer.MIN_BEATS]). */
    val MIN_BEATS: Int = HrvAnalyzer.MIN_BEATS

    /** Rate limit — at most one fire per this many seconds (the shipped 900 s = 15 min). */
    const val MIN_SECONDS_BETWEEN_FIRES: Long = 900L

    /** Recent smoothed wrist-motion (g) at/above this means "moving" → exercise gate suppresses the fire
     *  (reuses the [SedentaryDetector] move threshold so the two gates agree on what "moving" is). */
    val MOTION_GATE_G: Double = SedentaryDetector.DEFAULT_MOVE_THRESHOLD_G

    /** A baseline needs this many DISTINCT, trusted short windows before a later window may fire. */
    const val MINIMUM_TRUSTED_BASELINE_WINDOWS: Int = 4

    /** Overlapping callbacks cannot counterfeit warm-up: admit at most one trusted window per minute. */
    const val MINIMUM_TRUSTED_WINDOW_SPACING_SECONDS: Long = 60L

    // ── Config ────────────────────────────────────────────────────────────────

    /**
     * The L3 master/sub toggles + quiet-hours window, passed in as plain values so the engine stays pure.
     * All default OFF / safe — manual-first ethos (the feature is opt-in per layer).
     */
    data class Config(
        /** Master "stress check-ins (haptic)" toggle (default OFF). Inert when off. */
        val enabled: Boolean = false,
        /** Auto-nudge sub-toggle (default OFF) — when off the detector still reports state but never fires. */
        val autoNudge: Boolean = false,
        /** Suppress fires during quiet hours. */
        val quietHoursEnabled: Boolean = false,
        /** Quiet-hours window, local minute-of-day [0,1440) (defaults 22:00 → 07:00). */
        val quietStartMinutes: Int = SedentaryDetector.DEFAULT_QUIET_START_MIN,
        val quietEndMinutes: Int = SedentaryDetector.DEFAULT_QUIET_END_MIN,
        /** Buzz strength (loops) for the confirming buzz — one light pulse, like evaluateStress. */
        val buzzLoops: Int = 1,
    )

    // ── State (de-dup / EMA carry — persisted verbatim, replay-safe) ───────────

    /**
     * The persisted state the detector carries between evaluations (restart-safe). The caller stores this
     * verbatim and feeds the prior value back in, exactly like [SedentaryState]. A fresh user starts from
     * [INITIAL]. Carries the slow EMA baseline (so it survives relaunch), the edge state (was the fast
     * RMSSD below the threshold on the previous tick?), the baseline warm-up, and the rate-limit clock.
     */
    data class State(
        /** Slow RMSSD baseline (EMA), ms. 0 = uninitialised (seeds from the first trusted fast RMSSD). */
        val baselineRMSSD: Double = 0.0,
        /** Whether the fast RMSSD was BELOW the drop threshold on the previous evaluation — drives the
         *  EDGE (we fire only on a fresh above→below crossing, not every tick it stays below). */
        val wasBelow: Boolean = false,
        /** Unix-seconds of the last fire (0 = never) — the rate limiter. */
        val lastFireAt: Long = 0L,
        /** Number of distinct trusted windows incorporated into the baseline, capped at the warm-up floor.
         *  Zero is the compatible default for legacy state, forcing a safe re-warm after upgrade. */
        val trustedWindowCount: Int = 0,
        /** Stable identity of the last trusted clean R-R tail. Zero means no accepted window yet. */
        val lastTrustedWindowFingerprint: Long = 0L,
        /** Unix-seconds when the last distinct trusted window was admitted. */
        val lastTrustedWindowAt: Long = 0L,
    ) {
        companion object {
            /** Cold-start state (no baseline, not below, never fired). */
            val INITIAL = State()
        }
    }

    // ── Decision ──────────────────────────────────────────────────────────────

    /** Why the detector did / didn't nudge — drives logs and the honest card copy. */
    enum class Reason {
        /** A fresh non-metabolic HRV dip — offer a minute to breathe. */
        ONSET,

        /** Disabled / auto-nudge off. */
        DISABLED,

        /** Too few clean beats to judge honestly. */
        INSUFFICIENT_DATA,

        /** A valid window is still building the minimum distinct-window personal baseline. */
        WARMING_UP,

        /** The same or an overlapping trusted R-R tail cannot advance baseline or edge state. */
        DUPLICATE_WINDOW,

        /** Fast RMSSD is at/above the threshold — no dip. */
        NO_DIP,

        /** The dip isn't a fresh edge (already below last tick). */
        NOT_AN_EDGE,

        /** No contemporaneous motion observation exists, so stillness cannot be established. */
        MOTION_UNAVAILABLE,

        /** Suppressed by the exercise gate (HR out of band and/or recent motion = metabolic, not stress). */
        EXERCISE_GATED,

        /** Inside the rate-limit window or quiet hours, or a manual session is running. */
        SUPPRESSED,
    }

    /**
     * The decision returned each evaluation: whether to nudge, why, and the next state to persist. Mirrors
     * [SedentaryDecision]: the caller acts on [shouldNudge] and stores [nextState] (always advanced) so a
     * replayed window can't re-fire.
     */
    data class Decision(
        /** True if the app should offer the breathing cue now (single confirming buzz + passive card). */
        val shouldNudge: Boolean,
        /** Why (whether or not it nudged). */
        val reason: Reason,
        /** Buzz loops to play when [shouldNudge] (the confirming buzz). */
        val buzzLoops: Int,
        /** The fast short-window RMSSD this tick (ms), or null when insufficient — for logs / the card. */
        val fastRMSSD: Double?,
        /** The slow baseline RMSSD this tick (ms), or null when uninitialised. */
        val baselineRMSSD: Double?,
        /** The state to persist for the next evaluation (always carries the advanced EMA / edge / clock). */
        val nextState: State,
    )

    // ── The detector ──────────────────────────────────────────────────────────

    /**
     * Evaluate the live window and decide whether to fire a JITAI nudge.
     *
     * - [rrBuffer]: the rolling clean-able R-R buffer (rrMs, newest LAST). The fast RMSSD is taken over the
     *   latest [FAST_WINDOW_BEATS] clean beats; the slow baseline EMA absorbs each trusted fast value.
     * - [currentHR]: latest smoothed live HR (bpm), or null if unknown (then the HR half of the gate can't
     *   pass and we treat HR as out-of-band — conservative).
     * - [recentMotionG]: timestamp-validated, recent smoothed wrist-motion (g) from banked gravity, or null
     *   when motion is absent/stale. Missing motion cannot establish stillness, so it suppresses nudges.
     * - [sessionActive]: true if a manual Breathe/L1/L2 session is already running (never nudge over it).
     * - [state]: the prior persisted state; [nowSec] / [tzOffsetSec] passed IN (never read a clock).
     *
     * The EXERCISE GATE suppresses when EITHER signal says metabolic: HR outside [55,100], OR recent motion
     * at/above [MOTION_GATE_G]. Missing HR is treated as out-of-band, and missing/stale motion also
     * suppresses: an in-band HR cannot truthfully establish that the wearer is still.
     */
    fun evaluate(
        rrBuffer: List<Int>,
        currentHR: Double?,
        recentMotionG: Double?,
        sessionActive: Boolean,
        state: State,
        config: Config,
        nowSec: Long,
        tzOffsetSec: Long,
    ): Decision {

        // 1) Master gates: off / auto-nudge off → never nudge, state untouched.
        if (!config.enabled || !config.autoNudge) {
            return Decision(
                shouldNudge = false, reason = Reason.DISABLED, buzzLoops = config.buzzLoops,
                fastRMSSD = null, baselineRMSSD = state.baselineRMSSD.takeIf { it > 0.0 },
                nextState = state,
            )
        }

        // A user-started workout/coaching/breathing session is not baseline-learning time either. Keep
        // state untouched so session physiology cannot contaminate the resting comparison after it ends.
        if (sessionActive) {
            return Decision(
                shouldNudge = false, reason = Reason.SUPPRESSED, buzzLoops = config.buzzLoops,
                fastRMSSD = null, baselineRMSSD = state.baselineRMSSD.takeIf { it > 0.0 },
                nextState = state,
            )
        }

        // 2) Fast RMSSD over the latest clean beats. Clean first (range + Malik), then take the tail.
        val cleanAll = HrvAnalyzer.cleanRR(rrBuffer.map { it.toDouble() })
        val fastWindow = if (cleanAll.size > FAST_WINDOW_BEATS) cleanAll.takeLast(FAST_WINDOW_BEATS) else cleanAll
        val fast = if (fastWindow.size >= MIN_BEATS) HrvAnalyzer.rmssdRaw(fastWindow) else null
        if (fast == null || fast <= 0.0) {
            // Not enough signal — report, don't guess. Edge state is preserved (no crossing observed).
            return Decision(
                shouldNudge = false, reason = Reason.INSUFFICIENT_DATA, buzzLoops = config.buzzLoops,
                fastRMSSD = null, baselineRMSSD = state.baselineRMSSD.takeIf { it > 0.0 },
                nextState = state,
            )
        }

        // 3) Establish credibility BEFORE learning. Only a window whose HR and observed motion both support
        // a resting context may train the personal baseline behind an interruptive suggestion.
        val hrInBand = currentHR != null && currentHR >= RESTING_HR_LOW && currentHR <= RESTING_HR_HIGH
        if (recentMotionG == null || !recentMotionG.isFinite()) {
            return Decision(
                shouldNudge = false, reason = Reason.MOTION_UNAVAILABLE, buzzLoops = config.buzzLoops,
                fastRMSSD = fast, baselineRMSSD = state.baselineRMSSD.takeIf { it > 0.0 },
                nextState = state,
            )
        }
        if (!hrInBand || recentMotionG >= MOTION_GATE_G) {
            return Decision(
                shouldNudge = false, reason = Reason.EXERCISE_GATED, buzzLoops = config.buzzLoops,
                fastRMSSD = fast, baselineRMSSD = state.baselineRMSSD.takeIf { it > 0.0 },
                nextState = state,
            )
        }

        // 4) Only a DISTINCT trusted R-R tail may advance the baseline. The same cached window may reach
        // this engine more than once, and heavily-overlapping callbacks are not independent evidence.
        val fingerprint = trustedWindowFingerprint(fastWindow)
        val priorCount = state.trustedWindowCount.coerceIn(0, MINIMUM_TRUSTED_BASELINE_WINDOWS)
        val overlapsPriorWindow = priorCount > 0 &&
            (nowSec - state.lastTrustedWindowAt) < MINIMUM_TRUSTED_WINDOW_SPACING_SECONDS
        if (fingerprint == state.lastTrustedWindowFingerprint || overlapsPriorWindow) {
            return Decision(
                shouldNudge = false, reason = Reason.DUPLICATE_WINDOW, buzzLoops = config.buzzLoops,
                fastRMSSD = fast, baselineRMSSD = state.baselineRMSSD.takeIf { it > 0.0 },
                nextState = state,
            )
        }

        // 5) Use an exact running mean throughout the four-window warm-up, then the slow EMA. A legacy
        // state has count==0, so its old ungated EMA is deliberately replaced by the first trusted window.
        val baseline = if (priorCount < MINIMUM_TRUSTED_BASELINE_WINDOWS) {
            (state.baselineRMSSD * priorCount.toDouble() + fast) / (priorCount + 1).toDouble()
        } else {
            state.baselineRMSSD * BASELINE_EMA_ALPHA + fast * (1.0 - BASELINE_EMA_ALPHA)
        }
        var next = state.copy(
            baselineRMSSD = baseline,
            trustedWindowCount = minOf(MINIMUM_TRUSTED_BASELINE_WINDOWS, priorCount + 1),
            lastTrustedWindowFingerprint = fingerprint,
            lastTrustedWindowAt = nowSec,
        )

        // 6) Is the fast RMSSD below the drop threshold? (the dip test)
        val threshold = baseline * DROP_RATIO
        val isBelow = fast < threshold
        // The edge: a FRESH crossing (above on the previous tick → below now). Always record the new
        // below-state so the NEXT tick can edge-detect, regardless of whether we fire.
        val isEdge = isBelow && !state.wasBelow
        next = next.copy(wasBelow = isBelow)

        fun decide(nudge: Boolean, reason: Reason) = Decision(
            shouldNudge = nudge, reason = reason, buzzLoops = config.buzzLoops,
            fastRMSSD = fast, baselineRMSSD = baseline, nextState = next,
        )

        // The current window may complete warm-up, but cannot also be judged against a baseline that partly
        // contains itself. Auto-fire begins only on a later distinct trusted window.
        if (priorCount < MINIMUM_TRUSTED_BASELINE_WINDOWS) return decide(false, Reason.WARMING_UP)
        if (!isBelow) return decide(false, Reason.NO_DIP)
        if (!isEdge) return decide(false, Reason.NOT_AN_EDGE)

        // 7) Remaining suppressors: rate limit or quiet hours. Sessions were rejected before learning.
        if (state.lastFireAt != 0L && (nowSec - state.lastFireAt) < MIN_SECONDS_BETWEEN_FIRES) {
            return decide(false, Reason.SUPPRESSED)
        }
        if (config.quietHoursEnabled) {
            val mod = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec)
            if (SedentaryDetector.windowContains(mod, config.quietStartMinutes, config.quietEndMinutes)) {
                return decide(false, Reason.SUPPRESSED)
            }
        }

        // 8) Fire — a fresh short-window HRV dip with observed low motion. Stamp the rate-limit clock.
        next = next.copy(lastFireAt = nowSec)
        return decide(true, Reason.ONSET)
    }

    /** Stable across launches (unlike `hashCode`) so persisted state rejects a replay after relaunch. */
    private fun trustedWindowFingerprint(window: List<Double>): Long {
        // FNV-1a offset basis represented as the same signed 64-bit pattern as Swift's UInt64 value.
        var hash = -3_750_763_034_362_895_579L
        for (value in window) {
            hash = (hash xor java.lang.Double.doubleToRawLongBits(value)) * 1_099_511_628_211L
        }
        hash = hash xor window.size.toLong()
        return if (hash == 0L) 1L else hash
    }
}
