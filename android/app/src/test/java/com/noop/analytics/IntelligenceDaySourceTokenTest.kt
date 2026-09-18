package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the per-day scoring-diagnostic SOURCE token (Sleep overhaul §2.5). Each scored day emits
 * "sleep day=… totalSleepMin=… matched=… source=<token>" into the shareable strap log so the next
 * report ships PROOF of what was computed per day — the project's log-failures-not-successes blind
 * spot, and the data to settle "Rest repeats across days". The token resolves from the imported
 * day-key sets with the SAME precedence the dashboard merge uses (WHOOP import > Apple > computed).
 * Pure + set-based; the SAME `daySourceToken` analyzeRecent ships. Mirrors Swift DaySource.classify
 * (.logToken) so the two platforms log identical tokens.
 */
class IntelligenceDaySourceTokenTest {

    private val day = "2026-06-12"

    @Test
    fun computed_whenNoImportCoversTheDay() {
        assertEquals("computed",
            IntelligenceEngine.daySourceToken(day, emptySet(), emptySet()))
    }

    @Test
    fun importedWhoop_whenWhoopExportCoversTheDay() {
        assertEquals("imported:whoop",
            IntelligenceEngine.daySourceToken(day, setOf(day), emptySet()))
    }

    @Test
    fun importedApple_whenOnlyAppleCoversTheDay() {
        assertEquals("imported:apple",
            IntelligenceEngine.daySourceToken(day, emptySet(), setOf(day)))
    }

    @Test
    fun whoopBeatsApple_whenBothCoverTheSameDay() {
        // Must agree with the merge's source priority + the macOS classify (whoop wins over apple).
        assertEquals("imported:whoop",
            IntelligenceEngine.daySourceToken(day, setOf(day), setOf(day)))
    }

    @Test
    fun perDay_notGlobal() {
        // A set covering a DIFFERENT day leaves this day computed — the token is resolved per day,
        // which is the whole point of the honesty fix (an import elsewhere must not relabel this day).
        val imported = setOf("2026-06-10")
        assertEquals("computed", IntelligenceEngine.daySourceToken("2026-06-12", imported, emptySet()))
        assertEquals("imported:whoop", IntelligenceEngine.daySourceToken("2026-06-10", imported, emptySet()))
    }

    @Test
    fun diagnosticLineFormat_isStableAndParsable() {
        // The exact line shape the engine builds, assembled from the same parts, so the format stays
        // pinned: counts + a rounded minute only (no HR/HRV/timestamps), no em-dash. `stages=`/`eff=`
        // (#386) sit between the rollup and the counts so the rollup-vs-stages identity reads in place.
        val line = "analysis.sleep_scored " +
            "source=${IntelligenceEngine.daySourceToken(day, setOf(day), emptySet())} " +
            "sessions=2 stages=present efficiency=present hrv=present hrv_window=deep"
        assertEquals(
            "analysis.sleep_scored source=imported:whoop sessions=2 stages=present " +
                "efficiency=present hrv=present hrv_window=deep",
            line,
        )
        assertEquals(false, line.contains(day))
        assertEquals(false, line.contains("totalSleepMin"))
        assertEquals(false, line.contains("—"))
    }

    @Test
    fun skippedDayDiagnosticsAggregateByBoundedReasonAndCount() {
        val lines = IntelligenceEngine.skippedDayDiagnosticLines(
            mapOf(
                IntelligenceEngine.AnalysisSkippedDayReason.INSUFFICIENT_HR to 37,
                IntelligenceEngine.AnalysisSkippedDayReason.INVALID_CIVIL_DAY_BOUNDS to 2,
            ),
        )

        assertEquals(
            listOf(
                "analysis.sleep_skipped reason=insufficient_hr count=37",
                "analysis.sleep_skipped reason=invalid_civil_day_bounds count=2",
            ),
            lines,
        )
        assertEquals(false, lines.any { it.contains(day) })
    }

    @Test
    fun skippedDayDiagnosticCountIsCappedForHistoricalMigration() {
        assertEquals(
            listOf(
                "analysis.sleep_skipped reason=insufficient_hr count=4000",
            ),
            IntelligenceEngine.skippedDayDiagnosticLines(
                mapOf(
                    IntelligenceEngine.AnalysisSkippedDayReason.INSUFFICIENT_HR to Int.MAX_VALUE,
                    IntelligenceEngine.AnalysisSkippedDayReason.INVALID_CIVIL_DAY_BOUNDS to 0,
                ),
            ),
        )
    }

    // ── stages= token (#386) ────────────────────────────────────────────────────

    @Test
    fun stagesToken_fullSplitPrintsComponentsAndSum() {
        // The sum is PRINTED (not left to the reader) so a rollup-vs-stages divergence is a one-line
        // visual check against totalSleepMin — the identity #386's screens must agree on.
        assertEquals("160+77+279=516", IntelligenceEngine.sleepStagesLogToken(159.6, 77.4, 279.2))
    }

    @Test
    fun stagesToken_componentsRoundIndividually_sumRoundsTheRawTotal() {
        // The printed sum rounds the RAW deep+rem+light (31.2 -> 31), not the rounded components
        // (10+10+10 = 30), so it matches how totalSleepMin itself is rounded and the two fields stay
        // comparable digit-for-digit.
        assertEquals("10+10+10=31", IntelligenceEngine.sleepStagesLogToken(10.4, 10.4, 10.4))
    }

    @Test
    fun stagesToken_nilWhenAnyComponentMissing() {
        // An unstaged night (or an imported day that only brought a total) must read nil, never a
        // fabricated 0-minute stage.
        assertEquals("nil", IntelligenceEngine.sleepStagesLogToken(null, 77.0, 279.0))
        assertEquals("nil", IntelligenceEngine.sleepStagesLogToken(160.0, null, 279.0))
        assertEquals("nil", IntelligenceEngine.sleepStagesLogToken(160.0, 77.0, null))
        assertEquals("nil", IntelligenceEngine.sleepStagesLogToken(null, null, null))
    }
}
