package com.noop.analytics

// SleepStageEvidence.kt — Kotlin twin of StrandAnalytics/SleepStageEvidence.swift.
// Keep byte-for-byte behavioural parity with the Swift original; see that file for the full rationale.
//
// Short version: SleepStager always emits four classes, so every night looks equally well-measured, and it
// is not. Against expert polysomnography (n=6, 5,720 epochs) REM recall was 3.7% and deep recall 6.9%
// without R-R intervals, with 51% of REM epochs classified as wake, because the deep rule reads
// parasympathetic tone from R-R and the REM rule reads respiratory irregularity. Deprived of those inputs
// the classifier still labels confidently and is wrong about half the time.
//
// This reports provenance rather than changing staging. Collapsing REM and deep into light was rejected:
// it asserts the epoch WAS light sleep, which is the same fabrication in a different coat, and inflates
// light minutes. Sleep/wake validated at 71.8% and stays reportable.

/** Whether a night had the physiological inputs REM and deep discrimination require. */
enum class SleepStageEvidence(val rawValue: String) {
    /** R-R intervals present in usable quantity. Four-class staging is reportable. */
    CARDIAC_RESOLVED("cardiacResolved"),

    /** Motion and heart rate only. Sleep/wake and duration are reportable; REM and deep are NOT. */
    MOTION_ONLY("motionOnly");

    /** True when REM and deep minutes may be presented to the user as measurements. */
    val remDeepReportable: Boolean get() = this == CARDIAC_RESOLVED

    companion object {
        fun fromRawValue(raw: String): SleepStageEvidence? =
            entries.firstOrNull { it.rawValue == raw }
    }
}

/**
 * Sleep totals carrying their own provenance, so a caller cannot read REM without seeing whether it was
 * measured. [deepMin] and [remMin] are null when the night lacked the R-R needed to discriminate them.
 */
data class AttributedSleepTotals(
    val totalSleepMin: Double,
    val efficiency: Double,
    val lightMin: Double,
    val deepMin: Double?,
    val remMin: Double?,
    val evidence: SleepStageEvidence,
)

object SleepStageEvidenceGate {

    /**
     * Minimum R-R intervals across a session before four-class staging is trusted.
     *
     * HRVAnalyzer already refuses RMSSD below 20 intervals and the stager consumes R-R in 5-minute
     * windows, so a night carrying a handful of intervals has R-R present in a technical sense while
     * supplying no usable parasympathetic signal. The bar sits well above 20 rather than at "non-empty".
     * A judgement, not a validated threshold, and pinned by a test so changing it is a decision.
     */
    const val MINIMUM_INTERVALS_FOR_STAGING = 120

    /** Classify the evidence available for one session. */
    fun evidence(rrIntervalCount: Int, respSampleCount: Int = 0): SleepStageEvidence =
        if (rrIntervalCount >= MINIMUM_INTERVALS_FOR_STAGING) {
            SleepStageEvidence.CARDIAC_RESOLVED
        } else {
            SleepStageEvidence.MOTION_ONLY
        }

    /**
     * Attach provenance to a night's totals, withholding REM and deep when they were not measured.
     *
     * Light minutes are still reported under MOTION_ONLY: sleep/wake separation validated at 71.8%, so
     * "asleep and not otherwise resolved" is defensible where "REM" is not. Unresolved epochs are NOT
     * folded into light; the remainder stays accounted for by totalSleepMin exceeding the sum of the
     * resolved stages.
     */
    fun attribute(
        totalSleepMin: Double,
        efficiency: Double,
        lightMin: Double,
        deepMin: Double,
        remMin: Double,
        evidence: SleepStageEvidence,
    ): AttributedSleepTotals {
        val reportable = evidence.remDeepReportable
        return AttributedSleepTotals(
            totalSleepMin = totalSleepMin,
            efficiency = efficiency,
            lightMin = lightMin,
            deepMin = if (reportable) deepMin else null,
            remMin = if (reportable) remMin else null,
            evidence = evidence,
        )
    }
}
