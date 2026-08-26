package com.noop.analytics

import com.noop.data.RespSample
import com.noop.data.RrInterval

/*
 * ScoreConfidence.kt — per-score certainty tier for Charge / Effort / Rest.
 *
 * Faithful Kotlin mirror of StrandAnalytics/ScoreConfidence.swift. Keep the cases,
 * raw strings, and the derive() thresholds byte-identical to Swift — cross-platform
 * parity tests enforce it.
 *
 * Each daily score (Charge = recovery, Effort = strain, Rest = sleep_performance)
 * carries a tier so a sparse 5/MG day reads truthfully instead of faking a number:
 *
 *   CALIBRATING — the score cannot honestly compute yet: the personal baseline isn't
 *                 usable (Charge), there's no in-bed data (Rest), or no HR window
 *                 (Effort). Usually paired with a null score.
 *   BUILDING    — usable but thin: e.g. < ~7 nights of baseline, or a 5/MG day whose
 *                 HR is mostly PPG-derived.
 *   SOLID       — full inputs present.
 *
 * Surfaced as a small label/dot under each score; the metric itself stays nil-honest
 * where it can't compute.
 */
enum class ScoreConfidence(val raw: String) {
    CALIBRATING("calibrating"),
    BUILDING("building"),
    SOLID("solid");

    /** Stable projection for the local `rest_confidence` metric series. */
    val persistedValue: Double
        get() = when (this) {
            CALIBRATING -> 0.0
            BUILDING -> 1.0
            SOLID -> 2.0
        }

    /** Evidence limits behind a Rest tier. These never alter the Rest score. */
    enum class RestLimitation(val raw: String) {
        NO_SESSION("noSession"),
        NO_STAGED_SLEEP("noStagedSleep"),
        MOTION_UNAVAILABLE("motionUnavailable"),
        SPARSE_MOTION("sparseMotion"),
        MISSING_RR_EVIDENCE("missingRREvidence"),
        MISSING_RESPIRATION_EVIDENCE("missingRespirationEvidence"),
        IMPLAUSIBLE_STAGE_MIX("implausibleStageMix"),
    }

    /** Rest certainty plus the concrete evidence limits behind it. */
    data class RestAssessment(
        val confidence: ScoreConfidence,
        val limitations: List<RestLimitation>,
    )

    /** Independently persisted evidence behind a Rest tier. Bit positions are durable across platforms. */
    data class RestEvidenceFlags private constructor(val rawValue: Int) {
        fun contains(flag: RestEvidenceFlags): Boolean = rawValue and flag.rawValue == flag.rawValue

        val persistedValue: Double get() = rawValue.toDouble()

        companion object {
            val NONE = RestEvidenceFlags(0)
            val SESSION_PRESENT = RestEvidenceFlags(1 shl 0)
            val STAGED_SLEEP_PRESENT = RestEvidenceFlags(1 shl 1)
            val MOTION_AVAILABLE = RestEvidenceFlags(1 shl 2)
            val SPARSE_MOTION = RestEvidenceFlags(1 shl 3)
            val RR_EVIDENCE_PRESENT = RestEvidenceFlags(1 shl 4)
            val RESPIRATION_EVIDENCE_PRESENT = RestEvidenceFlags(1 shl 5)
            val IMPLAUSIBLE_STAGE_MIX = RestEvidenceFlags(1 shl 6)

            private const val KNOWN_MASK: Int =
                (1 shl 0) or (1 shl 1) or (1 shl 2) or (1 shl 3) or
                    (1 shl 4) or (1 shl 5) or (1 shl 6)

            fun fromPersistedValue(value: Double?): RestEvidenceFlags? {
                if (value == null || !value.isFinite() || value < 0.0 ||
                    value > Int.MAX_VALUE.toDouble() || value % 1.0 != 0.0
                ) {
                    return null
                }
                val raw = value.toInt()
                if (raw and KNOWN_MASK.inv() != 0) return null
                val flags = RestEvidenceFlags(raw)
                if (flags.contains(STAGED_SLEEP_PRESENT) && !flags.contains(SESSION_PRESENT)) return null
                if (flags.contains(SPARSE_MOTION) && !flags.contains(MOTION_AVAILABLE)) return null
                if (
                    flags.contains(IMPLAUSIBLE_STAGE_MIX) &&
                    (!flags.contains(SESSION_PRESENT) || !flags.contains(STAGED_SLEEP_PRESENT))
                ) {
                    return null
                }
                return flags
            }

            internal fun of(rawValue: Int): RestEvidenceFlags = RestEvidenceFlags(rawValue)
        }
    }

    /** Raw main-night evidence retained across the user-edit recompute seam. */
    data class RestRawEvidence(
        val hasRREvidence: Boolean,
        val hasRespirationEvidence: Boolean,
        val mainSessionStarts: Set<Long> = emptySet(),
        internal val countsBySessionStart: Map<Long, AnalyticsEngine.RestEvidenceCounts> =
            emptyMap(),
    ) {
        /**
         * Resolve the compact raw evidence for the post-edit main-night group. A manually-constructed
         * legacy value may preserve its original selection but cannot lend evidence to another block.
         */
        fun selecting(mainSessionStarts: Set<Long>): RestRawEvidence {
            if (countsBySessionStart.isEmpty()) {
                return if (mainSessionStarts == this.mainSessionStarts) {
                    this
                } else {
                    RestRawEvidence(
                        hasRREvidence = false,
                        hasRespirationEvidence = false,
                        mainSessionStarts = mainSessionStarts,
                    )
                }
            }
            val counts = mainSessionStarts.fold(AnalyticsEngine.RestEvidenceCounts.ZERO) {
                    total, start ->
                total + (countsBySessionStart[start] ?: AnalyticsEngine.RestEvidenceCounts.ZERO)
            }
            val resolved = counts.resolved
            return RestRawEvidence(
                hasRREvidence = resolved.hasRREvidence,
                hasRespirationEvidence = resolved.hasRespirationEvidence,
                mainSessionStarts = mainSessionStarts,
                countsBySessionStart = countsBySessionStart,
            )
        }
    }

    companion object {
        // Durable storage contracts shared with Apple. Never rename an existing key.
        const val sleepPerformanceSeriesKey: String = "sleep_performance"
        const val restConfidenceSeriesKey: String = "rest_confidence"
        const val restEvidenceSeriesKey: String = "rest_evidence_flags"
        val managedRestSeriesKeys: Set<String> = setOf(
            sleepPerformanceSeriesKey,
            restConfidenceSeriesKey,
            restEvidenceSeriesKey,
        )

        fun fromPersistedValue(value: Double?): ScoreConfidence? {
            if (value == null || !value.isFinite()) return null
            return when (value) {
                0.0 -> CALIBRATING
                1.0 -> BUILDING
                2.0 -> SOLID
                else -> null
            }
        }

        /** Nights of usable baseline below which a present score is only "building". */
        const val buildingNightsThreshold: Int = 7

        /**
         * Charge (recovery) confidence.
         * - null score → CALIBRATING (HRV baseline not usable yet, or no driver).
         * - score present but the HRV baseline has < [buildingNightsThreshold] valid
         *   nights (still PROVISIONAL, not TRUSTED) → BUILDING.
         * - otherwise → SOLID.
         *
         * @param score the computed Charge, or null when the scorer refused.
         * @param hrvBaseline the HRV baseline driving the cold-start gate (nullable).
         */
        fun forCharge(score: Double?, hrvBaseline: BaselineState?): ScoreConfidence {
            if (score == null || hrvBaseline == null || !hrvBaseline.usable) return CALIBRATING
            return if (hrvBaseline.nValid < buildingNightsThreshold || !hrvBaseline.trusted) {
                BUILDING
            } else {
                SOLID
            }
        }

        /**
         * Effort (strain) confidence.
         * - null score (no HR window / invalid HRR) → CALIBRATING.
         * - score present but backed by fewer than [solidHrSamples] HR samples (a thin
         *   window, typically a 5/MG day leaning on PPG-derived HR) → BUILDING.
         * - otherwise → SOLID.
         *
         * @param score the computed Effort, or null.
         * @param hrSampleCount number of HR samples in the day's window.
         */
        fun forEffort(score: Double?, hrSampleCount: Int): ScoreConfidence {
            if (score == null) return CALIBRATING
            return if (hrSampleCount < solidHrSamples) BUILDING else SOLID
        }

        /** HR samples below which Effort is "building" (≈1 h at 1 Hz over a thin day). */
        const val solidHrSamples: Int = 3600

        /**
         * Rest (sleep performance) confidence — mirrors Swift `ScoreConfidence.rest`. The tier
         * reflects how complete THIS night's Rest inputs are, not the sleep-need history length.
         * - no in-bed session → CALIBRATING.
         * - a session exists but has no staged sleep (no deep/REM — e.g. a sparse night), so
         *   restorative + efficiency aren't real inputs → BUILDING.
         * - a session with staged sleep present → SOLID.
         *
         * @param hasSession whether the day has at least one matched in-bed session.
         * @param hasStagedSleep whether the night has staged sleep (deep + REM seconds > 0).
         */
        fun forRest(hasSession: Boolean, hasStagedSleep: Boolean): ScoreConfidence {
            if (!hasSession) return CALIBRATING
            return if (hasStagedSleep) SOLID else BUILDING
        }

        // ── H9 stage low-confidence (restorative-share floor on a high-efficiency night) ──────────────

        /**
         * Restorative (deep+REM) share of asleep time below which staging is treated as LOW-CONFIDENCE on
         * an otherwise high-efficiency night. A genuine well-structured adult night sits ~40–50% deep+REM;
         * a near-zero restorative share on a night that ALSO scored high efficiency is far more likely a
         * staging miss (the EEG-free classifier's weakest link) than a real night with no deep or REM — so
         * we flag the LOW CONFIDENCE rather than fake stages or tank Rest. Mirrors Swift
         * `restorativeLowConfidenceShare`. (#H9)
         */
        const val restorativeLowConfidenceShare: Double = 0.10

        /** Efficiency above which the restorative-share floor applies. A low-efficiency (fragmented) night
         *  legitimately carries less deep/REM, so the floor only flags the suspicious high-efficiency case.
         *  Mirrors Swift `highEfficiencyThreshold`. (#H9) */
        const val highEfficiencyThreshold: Double = 0.85

        /**
         * Rest confidence WITH the H9 stage-quality check and evidence-availability guards. Starts from
         * [forRest], then DOWNGRADES a [SOLID] tier to [BUILDING] (low-confidence) when EITHER:
         *  - the night was staged on SPARSE gravity ([gravitySparse]) — a WHOOP 4.0 synced/offload night
         *    banks motion coarsely, too sparse to reliably stage sleep (#345), so a confident 85–100 Rest
         *    is unearned however the engine filled the stages. This catches the case H9 MISSES: a sparse
         *    night whose staging manufactures HIGH efficiency AND HIGH restorative reads SOLID under H9
         *    alone (the #319 signature), yet the underlying data can't support it; OR
         *  - R-R or respiration evidence was unavailable, leaving the staged night without one of the
         *    cardiorespiratory lanes used to distinguish deep and REM; OR
         *  - the night is high-efficiency yet its restorative (deep+REM) share is below
         *    [restorativeLowConfidenceShare] — a likely staging miss (#H9).
         * [CALIBRATING]/[BUILDING] from the base call are returned unchanged. Engine output only; the UI
         * surfaces the tier later. Confidence-only — it never changes the Rest score or invents stages.
         * Mirrors Swift `rest(hasSession:hasStagedSleep:asleepSeconds:restorativeSeconds:efficiency:gravitySparse:)`.
         * (#H9, #345)
         */
        fun forRest(
            hasSession: Boolean,
            hasStagedSleep: Boolean,
            asleepSeconds: Double,
            restorativeSeconds: Double,
            efficiency: Double,
            gravitySparse: Boolean = false,
            hasRREvidence: Boolean = true,
            hasRespirationEvidence: Boolean = true,
        ): ScoreConfidence {
            val base = forRest(hasSession, hasStagedSleep)
            if (base != SOLID) return base
            if (gravitySparse) return BUILDING   // #345: sparse-motion staging can't earn a SOLID Rest
            if (!hasRREvidence || !hasRespirationEvidence) return BUILDING
            if (asleepSeconds <= 0.0) return base
            val restorativeShare = restorativeSeconds / asleepSeconds
            return if (efficiency >= highEfficiencyThreshold && restorativeShare < restorativeLowConfidenceShare) {
                BUILDING   // high-efficiency night with near-zero deep+REM → low-confidence staging (#H9)
            } else {
                base
            }
        }

        /**
         * Explainable companion to [forRest]. It reports only evidence limitations and never changes
         * score inputs or weights.
         */
        fun restAssessment(
            hasSession: Boolean,
            hasStagedSleep: Boolean,
            asleepSeconds: Double,
            restorativeSeconds: Double,
            efficiency: Double,
            gravitySparse: Boolean = false,
            motionUnavailable: Boolean = false,
            hasRREvidence: Boolean = true,
            hasRespirationEvidence: Boolean = true,
        ): RestAssessment = restAssessment(
            restEvidenceFlags(
                hasSession = hasSession,
                hasStagedSleep = hasStagedSleep,
                asleepSeconds = asleepSeconds,
                restorativeSeconds = restorativeSeconds,
                efficiency = efficiency,
                motionAvailable = !motionUnavailable,
                gravitySparse = gravitySparse,
                hasRREvidence = hasRREvidence,
                hasRespirationEvidence = hasRespirationEvidence,
            )
        )

        /** Build the durable evidence record after user-edited sleep aggregates have been applied. */
        fun restEvidenceFlags(
            hasSession: Boolean,
            hasStagedSleep: Boolean,
            asleepSeconds: Double,
            restorativeSeconds: Double,
            efficiency: Double,
            motionAvailable: Boolean,
            gravitySparse: Boolean,
            hasRREvidence: Boolean,
            hasRespirationEvidence: Boolean,
        ): RestEvidenceFlags {
            var raw = 0
            if (hasSession) raw = raw or RestEvidenceFlags.SESSION_PRESENT.rawValue
            if (hasSession && hasStagedSleep) {
                raw = raw or RestEvidenceFlags.STAGED_SLEEP_PRESENT.rawValue
            }
            if (motionAvailable) raw = raw or RestEvidenceFlags.MOTION_AVAILABLE.rawValue
            if (motionAvailable && gravitySparse) {
                raw = raw or RestEvidenceFlags.SPARSE_MOTION.rawValue
            }
            if (hasRREvidence) raw = raw or RestEvidenceFlags.RR_EVIDENCE_PRESENT.rawValue
            if (hasRespirationEvidence) {
                raw = raw or RestEvidenceFlags.RESPIRATION_EVIDENCE_PRESENT.rawValue
            }
            if (
                hasSession && hasStagedSleep && asleepSeconds > 0.0 &&
                efficiency >= highEfficiencyThreshold &&
                restorativeSeconds / asleepSeconds < restorativeLowConfidenceShare
            ) {
                raw = raw or RestEvidenceFlags.IMPLAUSIBLE_STAGE_MIX.rawValue
            }
            return RestEvidenceFlags.of(raw)
        }

        /** Decode a persisted evidence record into both the tier and its independent limitations. */
        fun restAssessment(evidence: RestEvidenceFlags): RestAssessment {
            val hasSession = evidence.contains(RestEvidenceFlags.SESSION_PRESENT)
            val hasStagedSleep = evidence.contains(RestEvidenceFlags.STAGED_SLEEP_PRESENT)
            val motionAvailable = evidence.contains(RestEvidenceFlags.MOTION_AVAILABLE)
            val gravitySparse = evidence.contains(RestEvidenceFlags.SPARSE_MOTION)
            val hasRREvidence = evidence.contains(RestEvidenceFlags.RR_EVIDENCE_PRESENT)
            val hasRespirationEvidence =
                evidence.contains(RestEvidenceFlags.RESPIRATION_EVIDENCE_PRESENT)
            val implausibleStageMix =
                evidence.contains(RestEvidenceFlags.IMPLAUSIBLE_STAGE_MIX)
            val confidence = when {
                !hasSession -> CALIBRATING
                !hasStagedSleep -> BUILDING
                !motionAvailable || gravitySparse || !hasRREvidence ||
                    !hasRespirationEvidence || implausibleStageMix -> BUILDING
                else -> SOLID
            }
            val limitations = buildList {
                if (!hasSession) {
                    add(RestLimitation.NO_SESSION)
                } else if (!hasStagedSleep) {
                    add(RestLimitation.NO_STAGED_SLEEP)
                }
                if (!motionAvailable) {
                    add(RestLimitation.MOTION_UNAVAILABLE)
                } else if (gravitySparse) {
                    add(RestLimitation.SPARSE_MOTION)
                }
                if (!hasRREvidence) {
                    add(RestLimitation.MISSING_RR_EVIDENCE)
                }
                if (!hasRespirationEvidence) {
                    add(RestLimitation.MISSING_RESPIRATION_EVIDENCE)
                }
                if (implausibleStageMix) {
                    add(RestLimitation.IMPLAUSIBLE_STAGE_MIX)
                }
            }
            return RestAssessment(confidence = confidence, limitations = limitations)
        }

        /**
         * Capture the same sustained five-minute evidence verdict [AnalyticsEngine] used for this main
         * night while exposing only stable booleans to the persistence seam.
         */
        fun restRawEvidence(
            sessions: List<DetectedSleep>,
            rr: List<RrInterval>,
            resp: List<RespSample>,
            offsetSec: Long,
            habitualMidsleepSec: Long?,
        ): RestRawEvidence {
            val indices = SleepStageTotals.mainNightGroupIndices(
                sessions.map { SleepStageTotals.NightBlock(it.start, it.end) },
                offsetSec,
                habitualMidsleepSec,
            ).orEmpty()
            val mainSessionStarts = indices.mapTo(mutableSetOf()) { sessions[it].start }
            val countsBySessionStart = sessions.associate { session ->
                session.start to AnalyticsEngine.mainSleepEvidenceCounts(
                    listOf(session),
                    rr,
                    resp,
                )
            }
            val counts = mainSessionStarts.fold(AnalyticsEngine.RestEvidenceCounts.ZERO) {
                    total, start ->
                total + (countsBySessionStart[start] ?: AnalyticsEngine.RestEvidenceCounts.ZERO)
            }
            val raw = counts.resolved
            return RestRawEvidence(
                hasRREvidence = raw.hasRREvidence,
                hasRespirationEvidence = raw.hasRespirationEvidence,
                mainSessionStarts = mainSessionStarts,
                countsBySessionStart = countsBySessionStart,
            )
        }
    }
}
