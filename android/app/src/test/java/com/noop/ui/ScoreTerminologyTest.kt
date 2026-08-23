package com.noop.ui

import com.noop.R
import org.junit.Assert.assertEquals
import org.junit.Test

/** Locks the product-facing score names without changing persisted or analytics identifiers. */
class ScoreTerminologyTest {

    @Test
    fun stableMetricKeysUseClearDisplayNames() {
        assertEquals("charge", KeyMetric.CHARGE.raw)
        assertEquals(R.string.l10n_today_screen_recovery_ea924f72, KeyMetric.CHARGE.titleRes)
        assertEquals("rest", KeyMetric.REST.raw)
        assertEquals(R.string.l10n_today_screen_sleep_3cac34e6, KeyMetric.REST.titleRes)
    }

    @Test
    fun liquidProgressIsLimitedToGenuinelyBoundedDailyScores() {
        assertEquals(
            listOf(KeyMetric.CHARGE, KeyMetric.EFFORT, KeyMetric.REST),
            KeyMetric.entries.filter { it.isBoundedProgress },
        )
    }

    @Test
    fun heroAndGuideUseRecoveryAndSleep() {
        assertEquals("Recovery", DomainTheme.Charge.label)
        assertEquals("Sleep", DomainTheme.Rest.label)
        assertEquals("Recovery", ScoreSection.CHARGE.label)
        assertEquals("Sleep", ScoreSection.REST.label)
        assertEquals("Recovery / Effort / Sleep", TodaySection.HERO.title)
    }

    @Test
    fun detailedSleepMetricNamesTheScore() {
        assertEquals("Sleep Score", sleepMetricSpec("performance").title)
    }

    @Test
    fun analyticsAliasesKeepOldEngineNamesCompatible() {
        assertEquals("recovery", InsightsHubViewModel.outcomeKeyFor("Charge"))
        assertEquals("recovery", InsightsHubViewModel.outcomeKeyFor("Recovery"))
        assertEquals("sleep_performance", InsightsHubViewModel.outcomeKeyFor("Rest"))
        assertEquals("sleep_performance", InsightsHubViewModel.outcomeKeyFor("Sleep Score"))
    }
}
