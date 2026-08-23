package com.noop.analytics

// IllnessSignalEngine.kt - multi-signal "Heads-Up" early-warning.
// Byte-for-byte mirror of Strand/Packages/StrandAnalytics/Sources/StrandAnalytics/IllnessSignalEngine.swift.
//
// INDEPENDENT implementation of the published multi-parameter pre-symptomatic signature documented across
// the wearable literature (e.g. the Stanford/Snyder resting-HR-elevation work and successor studies):
// resting HR ↑, skin temperature ↑, HRV (RMSSD) ↓ and respiration ↑ move TOGETHER, days before symptoms.
// NOOP re-derives the PATTERN, transparently, against the user's OWN rolling baseline — never a population
// cutoff. Replaces the blunt 2-of-4 threshold rule with a calibrated 0–100 score and a >=2-signal
// corroboration gate. Journal context is explanatory only and never suppresses a corroborated shift.
//
// WELLNESS ONLY - APPROXIMATE, NOT A DIAGNOSIS. Never names a condition; copy is always "a heads-up to
// rest" / "consider taking it easy".
object IllnessSignalEngine {

    // ── Tuning constants (pinned by test; mirror the Swift twin exactly) ──
    const val raiseThreshold: Double = 50.0
    const val mildThreshold: Double = 25.0
    const val minCorroboratingSignals: Int = 2
    const val signalZThreshold: Double = 2.0
    const val kZToScore: Double = 22.0
    const val perSignalCap: Double = 40.0
    @Deprecated("Journal context is explanatory and no longer dampens health signals.")
    const val confounderDampen: Double = 0.45

    /** Standing not-a-diagnosis tail reused verbatim from the shipped IllnessNotifier copy. */
    const val disclaimerTail = "On-device estimate - not a diagnosis."

    // ── Inputs ──

    /**
     * One signal's recent-vs-baseline reading, already z-scored against the personal baseline by the
     * caller. [zIllnessward] is the deviation ORIENTED so positive always means "more illness-like":
     * RHR ↑, skin-temp ↑, respiration ↑ pass their raw z; HRV ↓ passes the NEGATED z. [present] = false
     * means the signal had no usable data and is skipped (not counted as corroboration).
     */
    data class SignalReading(val zIllnessward: Double, val present: Boolean = true)

    /** All four signal readings for the recent window. Any may be absent (sparse 5/MG nights). */
    data class Inputs(
        val restingHR: SignalReading? = null,
        val skinTemp: SignalReading? = null,
        val hrv: SignalReading? = null,
        val respiration: SignalReading? = null,
    )

    /**
     * Same-day behaviour context that may contribute to a shift. It is explanatory only and never changes
     * score or level. [travelPhaseJump] is the cross-feature hook from CircadianEngine.
     */
    data class Context(
        val alcohol: Boolean = false,
        val stress: Boolean = false,
        val sauna: Boolean = false,
        val hardOrLateWorkout: Boolean = false,
        val travelPhaseJump: Boolean = false,
        val alreadyUnwell: Boolean = false,
        /** User-entered recent start/dose change; explanatory only, never a score or level input. */
        val recentMedicationChange: Boolean = false,
        val baselineTrusted: Boolean = true,
    )

    // ── Output ──

    enum class Level(val raw: String) {
        QUIET("quiet"),
        MILD("mild"),
        RAISED("raised"),
        SUPPRESSED("suppressed"), // legacy only; current evaluation never emits it
        ALREADY_UNWELL("alreadyUnwell"),
    }

    enum class DisplayState {
        BUILDING,
        STEADY,
        WATCH,
        ALERT,
    }

    data class Result(
        val score: Double,
        val level: Level,
        val firedSignals: List<String>,
        val suppressedBy: List<String>,
        val signalCount: Int,
        val copy: String,
        /** Fresh, finite inputs backed by their own trusted personal baseline. */
        val trustedSignalCount: Int = 0,
    ) {
        val displayState: DisplayState
            get() = when (level) {
                Level.RAISED, Level.ALREADY_UNWELL -> DisplayState.ALERT
                Level.MILD, Level.SUPPRESSED -> DisplayState.WATCH
                Level.QUIET ->
                    if (trustedSignalCount >= minCorroboratingSignals) DisplayState.STEADY
                    else DisplayState.BUILDING
            }
    }

    // ── Evaluate ──

    /**
     * Score the recent window and decide the heads-up level + copy. [firedLabels] maps a signal key to
     * the caller-rendered phrase shown when that signal fires (e.g. {"restingHR": "RHR +6"}). Only keys
     * for signals that clear [signalZThreshold] are surfaced.
     */
    fun evaluate(inputs: Inputs, context: Context, firedLabels: Map<String, String> = emptyMap()): Result {
        // Order is fixed so firedSignals is deterministic across platforms.
        val ordered: List<Pair<String, SignalReading?>> = listOf(
            "restingHR" to inputs.restingHR,
            "skinTemp" to inputs.skinTemp,
            "hrv" to inputs.hrv,
            "respiration" to inputs.respiration,
        )

        var rawScore = 0.0
        val firedKeys = mutableListOf<String>()
        for ((key, reading) in ordered) {
            if (reading == null || !reading.present || !reading.zIllnessward.isFinite()) continue
            val over = reading.zIllnessward - signalZThreshold
            if (over <= 0) continue
            firedKeys.add(key)
            rawScore += minOf(perSignalCap, kZToScore * over)
        }
        val score = minOf(100.0, rawScore)
        val signalCount = firedKeys.size
        val firedSignals = firedKeys.mapNotNull { firedLabels[it] }
        val trustedSignalCount = if (context.baselineTrusted) {
            ordered.count { (_, reading) ->
                reading?.present == true && reading.zIllnessward.isFinite()
            }
        } else {
            0
        }

        // A symptom report outranks every wearable-data gate.
        if (context.alreadyUnwell) {
            val agreeing = score >= mildThreshold && signalCount >= 1
            val copy = if (agreeing)
                "You logged feeling unwell, and some wearable signals also shifted. Wearable data cannot assess severity. If symptoms are severe or worsening, seek urgent help. $disclaimerTail"
            else
                "You logged feeling unwell. Missing or unchanged wearable data cannot rule out a problem or assess severity. If symptoms are severe or worsening, seek urgent help. $disclaimerTail"
            return Result(
                score, Level.ALREADY_UNWELL, firedSignals, emptyList(), signalCount, copy,
                trustedSignalCount,
            )
        }

        // Untrusted or insufficient per-signal baselines are not a normal result.
        if (!context.baselineTrusted) {
            return Result(score, Level.QUIET, firedSignals, emptyList(), signalCount,
                "Not enough fresh, baseline-backed signals to assess a pattern. Missing data is not a healthy result.",
                trustedSignalCount)
        }

        // Corroboration + magnitude gate.
        if (signalCount < minCorroboratingSignals || score < mildThreshold) {
            return Result(score, Level.QUIET, firedSignals, emptyList(), signalCount,
                "No corroborated shift in the fresh signals checked. This does not assess overall health or symptoms.",
                trustedSignalCount)
        }

        // Nearby context is explanatory only. It never changes score or level.
        val contextualFactors = mutableListOf<String>()
        if (context.alcohol) contextualFactors.add("alcohol")
        if (context.stress) contextualFactors.add("stress")
        if (context.sauna) contextualFactors.add("sauna")
        if (context.hardOrLateWorkout) contextualFactors.add("a hard or late workout")
        if (context.travelPhaseJump) contextualFactors.add("travel")
        if (context.recentMedicationChange) contextualFactors.add("a recent medication change")

        val signalsPhrase = if (firedSignals.isEmpty()) "Some signals are up" else firedSignals.joinToString(", ")
        val contextSuffix = if (contextualFactors.isEmpty()) "" else
            " You also logged ${joinReasons(contextualFactors)}; that may contribute but does not rule out the shift."

        // Mild stays in the detail view; a strong composite raises.
        if (score < raiseThreshold) {
            val copy = "A few signals are mildly up ($signalsPhrase). The shift is small; keep monitoring " +
                "how you feel.$contextSuffix $disclaimerTail"
            return Result(
                score, Level.MILD, firedSignals, contextualFactors, signalCount, copy,
                trustedSignalCount,
            )
        }

        val copy = "Several signals shifted together ($signalsPhrase). Many things can cause this " +
            "pattern; review how you feel.$contextSuffix Symptoms matter more than this estimate. $disclaimerTail"
        return Result(
            score, Level.RAISED, firedSignals, contextualFactors, signalCount, copy,
            trustedSignalCount,
        )
    }

    // ── Helpers ──

    /** Join named confounders into a natural list ("alcohol", "alcohol and stress", "a, b and c"). */
    internal fun joinReasons(reasons: List<String>): String = when (reasons.size) {
        0 -> "something"
        1 -> reasons[0]
        2 -> "${reasons[0]} and ${reasons[1]}"
        else -> {
            val head = reasons.dropLast(1).joinToString(", ")
            "$head and ${reasons.last()}"
        }
    }
}
