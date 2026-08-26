package com.noop.analytics

/**
 * Recovery/Charge from DAILY aggregates (Apple Watch / Health Connect / an Oura/Fitbit/Garmin export).
 * Kotlin twin of the Swift `WatchRecovery`.
 *
 * A strap gives dense overnight R-R intervals, so RecoveryScorer runs off raw-derived nightly RMSSD.
 * A daily-aggregate source does not: it gives one source-specific HRV statistic plus resting HR. This is
 * a genuinely lower-density computation, and its source/method identity must remain attached.
 *
 * We do NOT invent a new formula. Recovery is HRV-and-RHR-vs-personal-baseline, and because every term is
 * relative to the person's OWN baseline, the metric scale cancels out: SDNN-vs-SDNN-baseline behaves like
 * RMSSD-vs-RMSSD-baseline. So we build HRV and RHR baselines through the existing [Baselines] machinery and
 * feed them straight into the SAME [RecoveryScorer.recovery] the strap uses. Source-only recovery and strap
 * recovery therefore land on the same 0-100 scale and read against the same bands.
 *
 * What we drop vs the strap path: the respiration, sleep-performance and skin-temp terms are not supplied
 * here, so RecoveryScorer renormalises the remaining HRV + RHR weights. The HRV term stays dominant.
 *
 * Honesty rule: return null recovery + CALIBRATING when today's HRV is missing, OR the HRV baseline isn't
 * usable yet, OR there are fewer than [minBaselineNights] nights of history. We NEVER fabricate a number to
 * fill a sparse week. Confidence comes from the existing [ScoreConfidence.forCharge].
 */
object WatchRecovery {

    /** SDNN and RMSSD share milliseconds as a unit but are not interchangeable measurements. */
    enum class HRVMethod { SDNN, RMSSD }

    /** Stable identity of one HRV series. A baseline belongs to exactly one source and method. */
    data class HRVProvenance(
        val sourceId: String,
        val method: HRVMethod,
    ) {
        init {
            require(sourceId.isNotBlank()) { "HRV sourceId must not be blank" }
        }

        val label: String get() = "$sourceId HRV (${method.name})"
    }

    /** One HRV value with enough identity to decide whether it belongs in a baseline. */
    data class HRVSample(
        val value: Double,
        val provenance: HRVProvenance,
    )

    /** Result plus the exact HRV source/method used for both today and its isolated baseline. */
    data class Result(
        val recovery: Double?,
        val confidence: ScoreConfidence,
        val hrvProvenance: HRVProvenance,
    )

    /**
     * Minimum nights of HRV history before we score recovery from a daily-aggregate source. Sits ABOVE the
     * baseline's own seed gate (4) deliberately: a strap user crosses the seed faster on dense data, but a
     * sparse daily HRV deserves a longer warm-up before we trust it. Mirrors the Swift constant.
     */
    const val minBaselineNights = 7

    /**
     * Compute recovery/Charge from one explicitly identified HRV series + resting HR.
     *
     * @param provenance source and method this computation is allowed to use.
     * @param todayHrv today's source-and-method-identified HRV reading, or null.
     * @param todayRhr today's resting HR (bpm), or null to drop the RHR term.
     * @param hrvHistory ordered nightly HRV samples (oldest -> newest). Mismatched source/method
     * samples are excluded before baseline construction.
     * @param rhrHistory ordered nightly resting-HR values (oldest -> newest).
     */
    fun compute(
        provenance: HRVProvenance,
        todayHrv: HRVSample?,
        todayRhr: Int?,
        hrvHistory: List<HRVSample>,
        rhrHistory: List<Double>,
    ): Result {
        // Enforce isolation here rather than relying on every caller to pre-filter correctly. Switching
        // source or statistic therefore starts calibration again even when the values look plausible.
        val isolatedHistory = hrvHistory
            .filter { it.provenance == provenance }
            .map(HRVSample::value)
        val isolatedToday = todayHrv
            ?.takeIf { it.provenance == provenance }
            ?.value

        // Build both baselines through the production model (Winsorized EWMA + cold-start gating), exactly
        // as the strap path does. HRV feeds the HRV config; resting HR feeds the RHR config.
        val hrvBase = Baselines.foldHistory(isolatedHistory, Baselines.hrvCfg)
        val rhrBase = Baselines.foldHistory(rhrHistory, Baselines.restingHRCfg)

        // Confidence is the SAME helper the strap Charge uses, so the calibrating -> building -> solid arc
        // matches. It reads CALIBRATING whenever recovery would be null (no usable HRV baseline).
        val conf = ScoreConfidence.forCharge(isolatedToday, hrvBase)

        // Honesty gate: no number unless we have today's HRV, a usable baseline, AND at least a week of
        // nights. Any miss -> null recovery + calibrating, never a fabricated value.
        if (isolatedToday == null || !hrvBase.usable ||
            isolatedHistory.size < minBaselineNights
        ) {
            return Result(
                recovery = null,
                confidence = ScoreConfidence.CALIBRATING,
                hrvProvenance = provenance,
            )
        }

        // Reuse the canonical Charge engine. Drop the resp / sleep / skin-temp terms (the daily aggregate
        // doesn't carry them here) -> RecoveryScorer renormalises to HRV + RHR. RHR is optional: a missing
        // resting HR today passes the at-baseline value (z~0, neutral term) and drops the RHR term entirely.
        val recovery = RecoveryScorer.recovery(
            hrv = isolatedToday,
            rhr = todayRhr?.toDouble() ?: rhrBase.baseline,
            resp = null,
            hrvBaseline = hrvBase,
            rhrBaseline = if (todayRhr != null) rhrBase else null,
            respBaseline = null,
            sleepPerf = null,
        ) ?: return Result(
            recovery = null,
            confidence = ScoreConfidence.CALIBRATING,
            hrvProvenance = provenance,
        )

        return Result(
            recovery = recovery,
            confidence = conf,
            hrvProvenance = provenance,
        )
    }
}
