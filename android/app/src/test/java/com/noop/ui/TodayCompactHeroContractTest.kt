package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TodayCompactHeroContractTest {
    @Test
    fun sleepStatusUsesShortScoreBands() {
        assertEquals(CompactDailyMetricStatus.NEED_MORE_REST, compactSleepMetricStatus(59.9))
        assertEquals(CompactDailyMetricStatus.STEADY, compactSleepMetricStatus(60.0))
        assertEquals(CompactDailyMetricStatus.STEADY, compactSleepMetricStatus(79.9))
        assertEquals(CompactDailyMetricStatus.WELL_RESTED, compactSleepMetricStatus(80.0))
        assertNull(compactSleepMetricStatus(Double.NaN))
    }

    @Test
    fun effortStatusUsesCanonicalHundredPointScale() {
        assertEquals(CompactDailyMetricStatus.LIGHT, compactEffortMetricStatus(29.9))
        assertEquals(CompactDailyMetricStatus.MODERATE, compactEffortMetricStatus(30.0))
        assertEquals(CompactDailyMetricStatus.MODERATE, compactEffortMetricStatus(69.9))
        assertEquals(CompactDailyMetricStatus.HIGH, compactEffortMetricStatus(70.0))
        assertNull(compactEffortMetricStatus(Double.POSITIVE_INFINITY))
    }

    @Test
    fun recoveryValueKeepsScoreCalibrationAndMissingStatesDistinct() {
        assertEquals("72", compactRecoveryHeroValue(recovery = 72.4, calibrationNights = null))
        assertEquals("2/4", compactRecoveryHeroValue(recovery = null, calibrationNights = 2, seed = 4))
        assertEquals("0/4", compactRecoveryHeroValue(recovery = null, calibrationNights = -1, seed = 4))
        assertEquals("4/4", compactRecoveryHeroValue(recovery = null, calibrationNights = 4, seed = 4))
        assertEquals(NoopDisplayFormat.MISSING, compactRecoveryHeroValue(null, null))
        assertEquals(
            CompactRecoveryCalibrationStatus.CALIBRATING,
            compactRecoveryCalibrationStatus(calibrationNights = 0, seed = 4),
        )
        assertEquals(
            CompactRecoveryCalibrationStatus.CALIBRATING,
            compactRecoveryCalibrationStatus(calibrationNights = 3, seed = 4),
        )
        assertEquals(
            CompactRecoveryCalibrationStatus.BASELINE_READY,
            compactRecoveryCalibrationStatus(calibrationNights = 4, seed = 4),
        )
        assertEquals(
            CompactRecoveryCalibrationStatus.BASELINE_READY,
            compactRecoveryCalibrationStatus(calibrationNights = 5, seed = 4),
        )
        assertEquals(null, compactRecoveryCalibrationStatus(calibrationNights = null, seed = 4))
    }

    @Test
    fun heroUsesThreeEqualMetricCellsWithoutRecoveryCentricRings() {
        val today = source()
        val scoreBlock = today.substring(
            today.indexOf("private fun ScoreHeroRow("),
            today.indexOf("internal fun compactRecoveryHeroValue("),
        )
        val metricBlock = today.substring(
            today.indexOf("private fun CompactHeroMetric("),
            today.indexOf("@Composable\nprivate fun HeroMetricDivider("),
        )

        assertEquals(
            3,
            Regex("""(?m)^        CompactHeroMetricSpec\(""")
                .findAll(scoreBlock)
                .count(),
        )
        assertTrue(scoreBlock.contains("LocalDensity.current.fontScale >= 1.3f"))
        assertTrue(scoreBlock.contains("modifier = Modifier.fillMaxWidth()"))
        assertTrue(scoreBlock.contains("modifier = Modifier.weight(1f)"))
        assertTrue(scoreBlock.contains("onScoreInfo(ScoreSection.CHARGE)"))
        assertTrue(scoreBlock.contains("onScoreInfo(ScoreSection.REST)"))
        assertTrue(scoreBlock.contains("onScoreInfo(ScoreSection.EFFORT)"))
        assertTrue(scoreBlock.contains("lastScoredCharge.caption"))
        assertTrue(scoreBlock.contains("restStageLowConfidence(day)"))
        assertTrue(scoreBlock.contains("appwide_charge_confidence_baseline_ready"))
        assertTrue(scoreBlock.contains("appwide_v4_value_out_of_format"))
        assertTrue(scoreBlock.contains("appwide_v4_value_out_of_with_context_format"))
        assertTrue(scoreBlock.contains("""unit = if (recovery != null) "%" else """""))
        assertTrue(scoreBlock.contains("""unit = if (restScore != null) "%" else """""))
        assertTrue(scoreBlock.contains(""""/ 21""""))
        assertTrue(scoreBlock.contains(""""/ 100""""))
        assertTrue(metricBlock.indexOf("text = spec.value") < metricBlock.indexOf("text = spec.label.uppercase"))
        assertTrue(metricBlock.contains("if (spec.unit.isNotEmpty())"))
        assertTrue(metricBlock.contains("text = spec.unit"))
        assertTrue(metricBlock.contains(".height(3.dp)"))
        assertFalse(today.contains("V2HeroArc("))
        assertFalse(today.contains("V2SatelliteRing("))
    }

    @Test
    fun sourceProvenanceIsQuietVisibleTextAndNotASeparateBadge() {
        val today = source()
        val header = today.substring(
            today.indexOf("private fun DailySignalHeader("),
            today.indexOf("@Composable\nprivate fun DailySignalSourceLabel("),
        )
        val sourceLabel = today.substring(
            today.indexOf("private fun DailySignalSourceLabel("),
            today.indexOf("@Composable\nprivate fun DailySignalIdentity("),
        )

        assertTrue(header.contains("sourceLabel.orEmpty()"))
        assertTrue(header.contains("DailySignalSourceLabel("))
        assertTrue(header.contains("DailySignalStatePill("))
        assertFalse(header.contains("DailySignalSourceBadge"))
        assertTrue(sourceLabel.contains("style = NoopType.caption"))
        assertTrue(sourceLabel.contains("maxLines = 1"))
        assertTrue(sourceLabel.contains("overflow = TextOverflow.Ellipsis"))
        assertFalse(today.contains("private fun DailySignalSourceBadge("))
        assertFalse(today.contains("private fun DailySignalSourceBadgeLive("))
    }

    @Test
    fun reorderableFeedNeverReservesInvisibleSectionHeight() {
        val today = source()
        val feed = today.substring(
            today.indexOf("sectionOrder.forEach { section ->"),
            today.indexOf("// Auto-detect workouts (MVP"),
        )

        assertFalse(feed.contains(".staggeredAppear("))
        assertTrue(feed.contains("Reorderable sections render at full opacity."))
    }

    private fun source(): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/TodayScreen.kt"),
            File(root, "app/src/main/java/com/noop/ui/TodayScreen.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/TodayScreen.kt"),
        ).firstOrNull(File::isFile)?.readText()
            ?: error("TodayScreen.kt unavailable from $root")
    }
}
