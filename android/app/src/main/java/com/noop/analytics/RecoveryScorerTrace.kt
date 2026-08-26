package com.noop.analytics

import kotlin.math.abs

// RecoveryScorerTrace.kt - Kotlin twin of RecoveryScorer+Trace.swift. The Charge TERM-BREAKDOWN
// diagnostic for the Recovery test mode.
//
// Recomputes the four-plus-one weighted Charge terms from the SAME inputs RecoveryScorer.recovery
// reads, then reuses recovery(...) verbatim for the final score so the trace can never disagree with
// the number the dashboard shows. Pure and side-effect-free: no clock, no I/O, so a fixture night pins
// the exact lines. The Recovery test mode gates this behind TestCentre.active(RECOVERY) at the call
// site (IntelligenceEngine recomputeRecovery); when the mode is off it is never called, so there is zero
// cost. Byte-aligned with the Swift line shape so the parity test passes. No em-dashes.

object RecoveryScorerTrace {

    private fun r2(x: Double): Double = Math.round(x * 100.0) / 100.0

    /**
     * Side-effect-free diagnostic twin of [RecoveryScorer.recovery]: returns the SAME score recovery(...)
     * would, plus the per-term Charge breakdown trace. The four inputs (hrv / rhr / resp / sleepPerf) plus
     * the skin-temp deviation each get a baseline line (mean / spread / nValid / status), a term line
     * (z * weight), the renormalization (total weight, composite z), and the final logistic score + band.
     * Crucially the trace names WHICH TERM WAS NIL and forced the renorm (or the nil score).
     *
     * Every number is computed with the EXACT same expressions as recovery(...) (the same zScore call, the
     * same skin-temp penalty, the same weights), and the returned score IS recovery(...) verbatim, so the
     * trace and the headline can never diverge. Mirrors the Swift RecoveryScorer.recoveryTrace.
     */
    fun recoveryTrace(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: BaselineState,
        rhrBaseline: BaselineState?,
        respBaseline: BaselineState?,
        sleepPerf: Double?,
        restQualityBaseline: BaselineState? = null,
        skinTempDev: Double? = null,
    ): Pair<Double?, List<String>> {
        val lines = ArrayList<String>()
        val nilTerms = ArrayList<String>()
        val validSkinTempDev = VitalBands.skinTempDeviation(skinTempDev)

        // The score the dashboard reads, verbatim, so the trace cannot diverge from it.
        val score = RecoveryScorer.recovery(
            hrv = hrv, rhr = rhr, resp = resp,
            hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
            respBaseline = respBaseline, sleepPerf = sleepPerf,
            restQualityBaseline = restQualityBaseline, skinTempDev = validSkinTempDev,
        )

        // Cold-start gate: HRV baseline not usable -> recovery() returns null before any term is built.
        if (!hrvBaseline.usable) {
            lines.add(
                "charge nilScore reason=hrvBaselineNotUsable " +
                    "hrvStatus=${hrvBaseline.status.raw} hrvNValid=${hrvBaseline.nValid} " +
                    "(need nValid>=${Baselines.minNightsSeed})",
            )
            return score to lines
        }
        if (
            score == null ||
            !hrv.isFinite() ||
            !rhr.isFinite() ||
            RecoveryScorer.validDriverBaseline(RecoveryScorer.DriverBaseline(hrvBaseline)) == null
        ) {
            lines.add("charge nilScore reason=invalidRequiredInput")
            return score to lines
        }
        val validRhrBaseline = rhrBaseline?.takeIf {
            RecoveryScorer.validDriverBaseline(RecoveryScorer.DriverBaseline(it)) != null
        }
        val validRespBaseline = respBaseline?.takeIf {
            RecoveryScorer.validDriverBaseline(RecoveryScorer.DriverBaseline(it)) != null
        }
        val validRestBaseline = restQualityBaseline?.takeIf {
            it.usable && RecoveryScorer.validDriverBaseline(RecoveryScorer.DriverBaseline(it)) != null
        }

        // Per-driver baseline state lines (mean / spread / nValid / status).
        lines.add(
            "charge baseline hrv mean=${r2(hrvBaseline.baseline)} spread=${r2(hrvBaseline.spread)} " +
                "nValid=${hrvBaseline.nValid} status=${hrvBaseline.status.raw}",
        )
        validRhrBaseline?.let { b ->
            lines.add(
                "charge baseline rhr mean=${r2(b.baseline)} spread=${r2(b.spread)} " +
                    "nValid=${b.nValid} status=${b.status.raw}",
            )
        }
        validRespBaseline?.let { b ->
            lines.add(
                "charge baseline resp mean=${r2(b.baseline)} spread=${r2(b.spread)} " +
                    "nValid=${b.nValid} status=${b.status.raw}",
            )
        }
        validRestBaseline?.let { b ->
            lines.add(
                "charge baseline restQuality mean=${r2(b.baseline)} spread=${r2(b.spread)} " +
                    "nValid=${b.nValid} status=${b.status.raw}",
            )
        }

        // Per-term z * weight, built with the EXACT expressions recovery(...) uses, in the SAME append order.
        val terms = ArrayList<Pair<Double, Double>>() // (z, weight)

        // L9: every WEIGHT / SCALE / centre constant goes through r2() too (not just the z-scores), so a
        // future non-round weight (e.g. 0.333) renders identically on Swift and Kotlin and the parity
        // fixture cannot silently desync. The values render the same as before today.
        // HRV term: higher is better. (Always present once usable; the cold-start guard above returned.)
        val hrvZ = RecoveryScorer.zScore(hrv, hrvBaseline.baseline, hrvBaseline.spread)
        terms.add(hrvZ to RecoveryScorer.wHRV)
        lines.add("charge term hrv z=${r2(hrvZ)} w=${r2(RecoveryScorer.wHRV)} (higher HRV is better)")

        // RHR term: lower is better -> (mu - x) / sigma.
        if (validRhrBaseline != null) {
            val z = RecoveryScorer.zScore(validRhrBaseline.baseline, rhr, validRhrBaseline.spread)
            terms.add(z to RecoveryScorer.wRHR)
            lines.add("charge term rhr z=${r2(z)} w=${r2(RecoveryScorer.wRHR)} (lower RHR is better)")
        } else {
            nilTerms.add("rhr")
        }

        // Resp term: lower is better, optional (needs BOTH the value and a baseline).
        if (resp != null && resp.isFinite() && validRespBaseline != null) {
            val z = RecoveryScorer.zScore(validRespBaseline.baseline, resp, validRespBaseline.spread)
            terms.add(z to RecoveryScorer.wResp)
            lines.add("charge term resp z=${r2(z)} w=${r2(RecoveryScorer.wResp)} (lower resp is better)")
        } else {
            nilTerms.add("resp")
        }

        // Rest quality uses the personal center when usable and the fixed center during cold start.
        RecoveryScorer.validRestQuality(sleepPerf)?.let { rest ->
            val restBaseline = validRestBaseline?.let { RecoveryScorer.DriverBaseline(it) }
            val center = RecoveryScorer.restQualityCenter(restBaseline)
            val z = (rest - center) / RecoveryScorer.sleepPerfScale
            terms.add(z to RecoveryScorer.wSleep)
            lines.add(
                "charge term sleepPerf z=${r2(z)} w=${r2(RecoveryScorer.wSleep)} " +
                    "(rest=${r2(rest)} center=${r2(center)} " +
                    "centerSource=${if (restBaseline == null) "coldStart" else "personal"})",
            )
        } ?: run {
            nilTerms.add("sleepPerf")
        }

        // Skin-temp term: SYMMETRIC penalty on |deviation|, added only when supplied.
        if (validSkinTempDev != null) {
            val z = -abs(validSkinTempDev) / RecoveryScorer.skinTempDevScale
            terms.add(z to RecoveryScorer.wSkinTemp)
            lines.add(
                "charge term skinTempDev z=${r2(z)} w=${r2(RecoveryScorer.wSkinTemp)} " +
                    "(dev=${r2(validSkinTempDev)}C penalty=-|dev|/${r2(RecoveryScorer.skinTempDevScale)})",
            )
        } else {
            nilTerms.add("skinTempDev")
        }

        // The nil terms that dropped out and forced the weight renormalization (the killer line).
        lines.add(
            "charge nilTerm dropped=[${nilTerms.joinToString(",")}] " +
                "(each dropped term renormalizes the remaining weights)",
        )

        // Renormalization: total surviving weight and the weighted composite z, the SAME math recovery(...)
        // runs to produce the logistic input.
        val totalWeight = terms.sumOf { it.second }
        val compositeZ = if (totalWeight > 0.0) terms.sumOf { it.first * it.second } / totalWeight else 0.0
        lines.add(
            "charge renorm totalWeight=${r2(totalWeight)} compositeZ=${r2(compositeZ)} " +
                "(z = sum(z*w)/sum(w))",
        )

        // Final logistic score + band, read from recovery(...) verbatim. The
        // invalid/nil paths returned above, so score is non-null here.
        lines.add(
            "charge score=${r2(score)} band=${RecoveryScorer.band(score)} " +
                "(logistic k=${r2(RecoveryScorer.logisticK)} z0=${r2(RecoveryScorer.logisticZ0)})",
        )

        return score to lines
    }
}
